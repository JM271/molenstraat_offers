import 'package:flutter/material.dart';

import 'catalog.dart';
import 'dialogs.dart';
import 'firebase_gate.dart';
import 'format.dart';
import 'models.dart';
import 'offer_store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.store});

  final OfferStore store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _form = GlobalKey<FormState>();
  late final ShopSettings _s = widget.store.settings;
  late final _companyName = TextEditingController(text: _s.companyName);
  late final _address = TextEditingController(text: _s.address);
  late final _phone = TextEditingController(text: _s.phone);
  late final _email = TextEditingController(text: _s.email);
  late final _hourlyRate = TextEditingController(
    text: moneyInput(_s.hourlyRateCents),
  );
  late final _vatRate = TextEditingController(text: formatVatRate(_s.vatRate));
  late final _validityDays = TextEditingController(text: '${_s.validityDays}');
  late final _currency = TextEditingController(text: _s.currency);
  late final _footer = TextEditingController(text: _s.footer);
  late bool _pricesIncludeVat = _s.pricesIncludeVat;

  @override
  void dispose() {
    for (final c in [
      _companyName,
      _address,
      _phone,
      _email,
      _hourlyRate,
      _vatRate,
      _validityDays,
      _currency,
      _footer,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    try {
      await widget.store.saveSettings(
        _s.copyWith(
          companyName: _companyName.text.trim(),
          address: _address.text.trim(),
          phone: _phone.text.trim(),
          email: _email.text.trim(),
          hourlyRateCents: parseMoney(_hourlyRate.text),
          vatRate: double.parse(_vatRate.text.trim().replaceAll(',', '.')),
          pricesIncludeVat: _pricesIncludeVat,
          validityDays: int.parse(_validityDays.text.trim()),
          currency: _currency.text.trim(),
          footer: _footer.text.trim(),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(cloudError(e))));
      }
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  late final Future<List<CatalogProduct>> _catalog = loadCatalog();

  Future<void> _importPrices(List<CatalogProduct> products) async {
    final prices = await showPriceImportDialog(
      context,
      knownSkus: {
        for (final p in [...products, ...widget.store.customProducts]) p.sku,
      },
      currency: widget.store.settings.currency,
    );
    if (prices == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final changed = await widget.store.importPartPrices(prices);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            changed == 0
                ? 'Alle Preise waren schon gespeichert'
                : '$changed Preise gespeichert',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(cloudError(e))));
    }
  }

  Widget _catalogPrices() => FutureBuilder<List<CatalogProduct>>(
    future: _catalog,
    builder: (context, snapshot) {
      final products = snapshot.data;
      if (products == null) return const SizedBox.shrink();
      return ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final priced = products
              .where((p) => widget.store.savedPartPrice(p.sku) > 0)
              .length;
          final demo = products.where(widget.store.isDemoPrice).length;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$priced von ${products.length} Katalogteilen haben einen '
                'gespeicherten Preis.'
                '${demo > 0 ? ' $demo zeigen noch Demopreise.' : ''}',
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _importPrices(products),
                icon: const Icon(Icons.upload_outlined),
                label: const Text('Katalogpreise importieren'),
              ),
            ],
          );
        },
      );
    },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Einstellungen')),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          Text('Betrieb', style: Theme.of(context).textTheme.titleMedium),
          TextFormField(
            controller: _companyName,
            decoration: const InputDecoration(labelText: 'Firmenname'),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Firmennamen eingeben' : null,
          ),
          TextFormField(
            controller: _address,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Adresse',
              hintText: 'Strasse Nr.\nPLZ Ort',
            ),
          ),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Telefon'),
          ),
          TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'E-Mail'),
          ),
          const SizedBox(height: 24),
          Text('Preise', style: Theme.of(context).textTheme.titleMedium),
          TextFormField(
            controller: _currency,
            decoration: const InputDecoration(labelText: 'Währung'),
          ),
          TextFormField(
            controller: _hourlyRate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Stundensatz Werkstatt',
            ),
            validator: (v) => validateMoney(v, required: true),
          ),
          TextFormField(
            controller: _vatRate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'MwSt-Satz (%)',
              helperText: '0, wenn nicht mehrwertsteuerpflichtig',
            ),
            validator: (v) {
              final n = double.tryParse((v ?? '').trim().replaceAll(',', '.'));
              return n == null || n < 0 || n >= 100 ? 'Satz eingeben' : null;
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Preise inkl. MwSt'),
            subtitle: Text(
              _pricesIncludeVat
                  ? 'Eingegebene Preise enthalten die MwSt bereits'
                  : 'MwSt wird zu den Preisen addiert',
            ),
            value: _pricesIncludeVat,
            onChanged: (v) => setState(() => _pricesIncludeVat = v),
          ),
          const SizedBox(height: 16),
          Text('Katalogpreise', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          _catalogPrices(),
          const SizedBox(height: 24),
          Text('Angebot', style: Theme.of(context).textTheme.titleMedium),
          TextFormField(
            controller: _validityDays,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Gültigkeit neuer Angebote (Tage)',
            ),
            validator: (v) {
              final n = int.tryParse((v ?? '').trim());
              return n == null || n < 1 ? 'Anzahl Tage eingeben' : null;
            },
          ),
          TextFormField(
            controller: _footer,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Hinweis unten im Angebot',
            ),
          ),
        ],
      ),
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _save,
      icon: const Icon(Icons.check),
      label: const Text('Speichern'),
    ),
  );
}
