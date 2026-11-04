import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';
import 'models.dart';
import 'offer_store.dart';

const catalogAsset = 'assets/product_catalog.json';

Future<List<CatalogProduct>>? _catalog;

/// Loads the bundled product catalog once and keeps it for the app's lifetime.
Future<List<CatalogProduct>> loadCatalog({AssetBundle? bundle}) =>
    _catalog ??= _readCatalog(bundle ?? rootBundle);

// Decoded here rather than with loadString(), which moves files over 50 KB
// to a background isolate and caches the result; the catalog is small
// enough to parse directly.
Future<List<CatalogProduct>> _readCatalog(AssetBundle bundle) async {
  final data = await bundle.load(catalogAsset);
  return parseCatalog(utf8.decode(data.buffer.asUint8List()));
}

/// Parses the catalog JSON, skipping entries without SKU or name.
List<CatalogProduct> parseCatalog(String json) => [
  for (final row in jsonDecode(json) as List)
    CatalogProduct.fromJson(Map<String, dynamic>.from(row as Map)),
].where((p) => p.sku.isNotEmpty && p.name.isNotEmpty).toList();

/// Catalog price per SKU, for parts already on an offer.
Future<int Function(String sku)> catalogPriceLookup() async {
  final prices = {for (final p in await loadCatalog()) p.sku: p.priceCents};
  return (sku) => prices[sku] ?? 0;
}

/// Short stock text such as "Lager 3" or "Lager 2 + 1 Auto".
String stockLabel(StockLevel stock) => stock.car > 0
    ? 'Lager ${stock.workshop} + ${stock.car} Auto'
    : 'Lager ${stock.workshop}';

/// Category names in catalog order, without duplicates.
List<String> catalogCategories(List<CatalogProduct> products) => [
  ...{for (final p in products) p.category},
];

/// Lets the user pick one part from the catalog. Returns null when closed.
/// [priceOf] gives the price to show (own price or catalog price),
/// [extraProducts] are added to the bundled catalog (custom products of the
/// Inventory app) and [stockOf] shows the shared inventory stock.
Future<CatalogProduct?> showCatalogPicker(
  BuildContext context, {
  required int Function(CatalogProduct product) priceOf,
  required bool Function(CatalogProduct product) isDemoPrice,
  required String currency,
  List<CatalogProduct> extraProducts = const [],
  StockLevel? Function(String sku)? stockOf,
}) => showModalBottomSheet<CatalogProduct>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _CatalogPicker(
    priceOf: priceOf,
    isDemoPrice: isDemoPrice,
    currency: currency,
    extraProducts: extraProducts,
    stockOf: stockOf,
  ),
);

class _CatalogPicker extends StatefulWidget {
  const _CatalogPicker({
    required this.priceOf,
    required this.isDemoPrice,
    required this.currency,
    required this.extraProducts,
    required this.stockOf,
  });

  final int Function(CatalogProduct product) priceOf;
  final bool Function(CatalogProduct product) isDemoPrice;
  final String currency;
  final List<CatalogProduct> extraProducts;
  final StockLevel? Function(String sku)? stockOf;

  @override
  State<_CatalogPicker> createState() => _CatalogPickerState();
}

class _CatalogPickerState extends State<_CatalogPicker> {
  late final Future<List<CatalogProduct>> _products = loadCatalog().then((
    bundled,
  ) {
    final known = {for (final p in bundled) p.sku.toUpperCase()};
    return [
      ...bundled,
      for (final p in widget.extraProducts)
        if (!known.contains(p.sku.toUpperCase())) p,
    ];
  });
  String _query = '';
  String? _category;

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.9,
    maxChildSize: 0.95,
    builder: (context, controller) => FutureBuilder<List<CatalogProduct>>(
      future: _products,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Text('Katalog konnte nicht geladen werden'),
          );
        }
        final products = snapshot.data;
        if (products == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final visible = products
            .where(
              (p) =>
                  (_category == null || p.category == _category) &&
                  (_query.isEmpty || p.matches(_query)),
            )
            .toList();
        final scheme = Theme.of(context).colorScheme;
        return Column(
          children: [
            if (products.any(widget.isDemoPrice))
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Katalogpreise sind Demopreise und nicht verbindlich. '
                  'Vor dem Versand prüfen.',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Teil oder Artikelnummer suchen',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final c in [null, ...catalogCategories(products)])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(c ?? 'Alle'),
                        selected: _category == c,
                        onSelected: (_) => setState(() => _category = c),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('Kein Teil gefunden'))
                  : ListView.builder(
                      controller: controller,
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final p = visible[i];
                        final price = widget.priceOf(p);
                        final stock = widget.stockOf?.call(p.sku);
                        return ListTile(
                          leading: ProductImage(product: p),
                          title: Text(
                            p.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              p.sku,
                              p.category,
                              if (price > 0)
                                formatMoney(price, widget.currency) +
                                    (widget.isDemoPrice(p) ? ' (Demo)' : ''),
                              if (stock != null) stockLabel(stock),
                            ].join(' · '),
                          ),
                          onTap: () => Navigator.of(context).pop(p),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );
}

/// Small product thumbnail with a placeholder for parts without a picture.
class ProductImage extends StatelessWidget {
  const ProductImage({super.key, required this.product, this.size = 56});

  final CatalogProduct product;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Icon(
      Icons.settings_outlined,
      color: scheme.onSurfaceVariant,
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: product.imageAsset.isEmpty
          ? placeholder
          : Image.asset(
              product.imageAsset,
              fit: BoxFit.contain,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}
