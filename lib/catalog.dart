import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';
import 'models.dart';
import 'offer_store.dart';

const catalogAsset = 'assets/product_catalog.json';

Future<List<CatalogProduct>>? _catalog;

/// Forgets the cached catalog. Tests call this because a cached future
/// stays bound to the (fake async) zone of the test that loaded it.
@visibleForTesting
void resetCatalogCache() => _catalog = null;

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

/// Whether a SKU has a price in the Molenstraat product list.
Future<bool Function(String sku)> catalogListPriceLookup() async {
  final listed = {
    for (final p in await loadCatalog())
      if (p.hasListPrice) p.sku.toUpperCase(),
  };
  return (sku) => listed.contains(sku.toUpperCase());
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
  required String currency,
  List<CatalogProduct> extraProducts = const [],
  StockLevel? Function(String sku)? stockOf,
}) => showModalBottomSheet<CatalogProduct>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _CatalogPicker(
    priceOf: priceOf,
    currency: currency,
    extraProducts: extraProducts,
    stockOf: stockOf,
  ),
);

class _CatalogPicker extends StatefulWidget {
  const _CatalogPicker({
    required this.priceOf,
    required this.currency,
    required this.extraProducts,
    required this.stockOf,
  });

  final int Function(CatalogProduct product) priceOf;
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
        return Column(
          children: [
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
                  // Large pictures: two columns on a phone, more on wide
                  // screens.
                  : GridView.builder(
                      controller: controller,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 240,
                            mainAxisExtent: 270,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                          ),
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final p = visible[i];
                        final price = widget.priceOf(p);
                        return _ProductCard(
                          product: p,
                          price: price > 0
                              ? formatMoney(price, widget.currency)
                              : 'Preis fehlt',
                          stock: widget.stockOf?.call(p.sku),
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

/// One catalog part in the picker grid: large picture, name, article
/// number, price and stock.
class _ProductCard extends StatelessWidget {
  const _ProductCard({
    required this.product,
    required this.price,
    required this.stock,
    required this.onTap,
  });

  final CatalogProduct product;
  final String price;
  final StockLevel? stock;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final stock = this.stock;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: ProductImage(product: product)),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(product.sku, style: small, maxLines: 1),
                  Text(
                    price,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    stock == null ? 'Nicht im Lager' : stockLabel(stock),
                    style: small,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Product picture on white, with a placeholder for parts without one.
/// Without [size] it fills the space it is given.
class ProductImage extends StatelessWidget {
  const ProductImage({super.key, required this.product, this.size});

  final CatalogProduct product;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = this.size;
    final placeholder = Icon(
      Icons.settings_outlined,
      size: size == null ? 48 : null,
      color: scheme.onSurfaceVariant,
    );
    // The catalog pictures are only 182 × 117 px; they are decoded at full
    // size and scaled by the layout.
    final picture = product.imageAsset.isEmpty
        ? placeholder
        : Image.asset(
            product.imageAsset,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => placeholder,
          );
    if (size == null) {
      return ColoredBox(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Center(child: picture),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: picture,
    );
  }
}

/// Result of reading a pasted price list.
class PriceListImport {
  const PriceListImport({
    required this.prices,
    required this.unknownSkus,
    required this.invalidLines,
    this.listSkus = const [],
  });

  /// Known SKU (upper case) → price in cents.
  final Map<String, int> prices;

  /// SKUs with a valid price that are not in the catalog.
  final List<String> unknownSkus;

  /// Lines without a readable SKU and price, e.g. a header.
  final List<String> invalidLines;

  /// SKUs of the Molenstraat product list, which keep their list price.
  final List<String> listSkus;
}

/// Reads one SKU and price per line: the first column is the SKU, the last
/// non-empty column the price. Columns are separated by tabs (pasted from
/// Excel), semicolons or commas. Prices may be written as `24.90`, `24,90`,
/// `24.-` or `CHF 24.90`. SKUs in [listSkus] are skipped: their price comes
/// from the Molenstraat product list.
PriceListImport parsePriceList(
  String text,
  Set<String> knownSkus, {
  Set<String> listSkus = const {},
}) {
  final known = {for (final sku in knownSkus) sku.trim().toUpperCase()};
  final listed = {for (final sku in listSkus) sku.trim().toUpperCase()};
  final prices = <String, int>{};
  final unknown = <String>[];
  final invalid = <String>[];
  final fixed = <String>[];
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final separator = line.contains('\t')
        ? '\t'
        : line.contains(';')
        ? ';'
        : ',';
    final fields = [
      for (final f in line.split(separator))
        if (f.trim().isNotEmpty) f.trim(),
    ];
    final price = fields.length < 2
        ? null
        : parseMoney(fields.last.replaceAll(RegExp(r"[^0-9.,'\-]"), ''));
    if (price == null || price <= 0) {
      invalid.add(line);
      continue;
    }
    final sku = fields.first.toUpperCase();
    if (listed.contains(sku)) {
      fixed.add(fields.first);
    } else if (known.contains(sku)) {
      prices[sku] = price;
    } else {
      unknown.add(fields.first);
    }
  }
  return PriceListImport(
    prices: prices,
    unknownSkus: unknown,
    invalidLines: invalid,
    listSkus: fixed,
  );
}

/// Lets the user paste a price list and returns the prices to import.
Future<Map<String, int>?> showPriceImportDialog(
  BuildContext context, {
  required Set<String> knownSkus,
  Set<String> listSkus = const {},
  required String currency,
}) => showDialog<Map<String, int>>(
  context: context,
  builder: (_) => _PriceImportDialog(
    knownSkus: knownSkus,
    listSkus: listSkus,
    currency: currency,
  ),
);

class _PriceImportDialog extends StatefulWidget {
  const _PriceImportDialog({
    required this.knownSkus,
    required this.listSkus,
    required this.currency,
  });

  final Set<String> knownSkus;
  final Set<String> listSkus;
  final String currency;

  @override
  State<_PriceImportDialog> createState() => _PriceImportDialogState();
}

class _PriceImportDialogState extends State<_PriceImportDialog> {
  final _text = TextEditingController();
  PriceListImport? _result;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _parse(String text) => setState(
    () => _result = text.trim().isEmpty
        ? null
        : parsePriceList(text, widget.knownSkus, listSkus: widget.listSkus),
  );

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final error = Theme.of(context).colorScheme.error;
    String sample(List<String> items) =>
        items.take(3).join(', ') + (items.length > 3 ? ' …' : '');
    return AlertDialog(
      title: const Text('Katalogpreise importieren'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pro Zeile Artikelnummer und Preis in ${widget.currency} '
                'inkl. MwSt, z.B. zwei Spalten aus Excel kopiert. Die Preise '
                'gelten sofort auf allen Geräten.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                minLines: 6,
                maxLines: 12,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'OXV8-30\t24.90\nRF-M09;19.90',
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                onChanged: _parse,
              ),
              if (result != null) ...[
                const SizedBox(height: 12),
                Text('${result.prices.length} Preise erkannt'),
                if (result.unknownSkus.isNotEmpty)
                  Text(
                    '${result.unknownSkus.length} unbekannte Artikelnummern '
                    'werden ignoriert: ${sample(result.unknownSkus)}',
                    style: TextStyle(color: error),
                  ),
                if (result.listSkus.isNotEmpty)
                  Text(
                    '${result.listSkus.length} Artikel aus der Produktliste '
                    'behalten den Listenpreis: ${sample(result.listSkus)}',
                  ),
                if (result.invalidLines.isNotEmpty)
                  Text(
                    '${result.invalidLines.length} Zeilen ohne Preis werden '
                    'ignoriert: ${sample(result.invalidLines)}',
                    style: TextStyle(color: error),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: result == null || result.prices.isEmpty
              ? null
              : () => Navigator.of(context).pop(result.prices),
          child: Text(
            result == null || result.prices.isEmpty
                ? 'Importieren'
                : '${result.prices.length} Preise importieren',
          ),
        ),
      ],
    );
  }
}
