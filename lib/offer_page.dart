import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';

import 'catalog.dart';
import 'dialogs.dart';
import 'firebase_gate.dart';
import 'format.dart';
import 'models.dart';
import 'offer_pdf.dart';
import 'offer_store.dart';
import 'pdf_preview_page.dart';

class OfferPage extends StatefulWidget {
  const OfferPage({super.key, required this.store, required this.offer});

  final OfferStore store;

  /// A working copy; it is only written to the store on save.
  final Offer offer;

  @override
  State<OfferPage> createState() => _OfferPageState();
}

enum _Action { preview, share, print, copy, delete }

class _OfferPageState extends State<OfferPage> {
  late final Offer _offer = widget.offer;
  bool get _isNew => !widget.store.offers.any((o) => o.id == _offer.id);
  late final _customerName = _controller(_offer.customerName);
  late final _customerPhone = _controller(_offer.customerPhone);
  late final _customerEmail = _controller(_offer.customerEmail);
  late final _bikeModel = _controller(_offer.bikeModel);
  late final _frameNumber = _controller(_offer.frameNumber);
  late final _problem = _controller(_offer.problem);
  late final _notes = _controller(_offer.notes);
  bool _dirty = false;
  bool _saving = false;

  ShopSettings get _settings => widget.store.settings;

  TextEditingController _controller(String text) =>
      TextEditingController(text: text)..addListener(() {
        if (!_dirty) setState(() => _dirty = true);
      });

  @override
  void dispose() {
    for (final c in [
      _customerName,
      _customerPhone,
      _customerEmail,
      _bikeModel,
      _frameNumber,
      _problem,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _change(VoidCallback fn) => setState(() {
    fn();
    _dirty = true;
  });

  Offer _collect() => _offer
    ..customerName = _customerName.text.trim()
    ..customerPhone = _customerPhone.text.trim()
    ..customerEmail = _customerEmail.text.trim()
    ..bikeModel = _bikeModel.text.trim()
    ..frameNumber = _frameNumber.text.trim()
    ..problem = _problem.text.trim()
    ..notes = _notes.text.trim();

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// Saves to the shared database. Returns false (and says why) on failure.
  Future<bool> _save({bool close = true}) async {
    if (_saving) return false;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await widget.store.saveOffer(_collect().copy());
      // A new offer gets its final number on save; someone else may have
      // taken the provisional one meanwhile.
      final renumbered = saved.number != _offer.number;
      _offer.number = saved.number;
      if (saved.lines.any((l) => l.sku.isNotEmpty)) {
        await widget.store.rememberPartPrices(
          saved.lines,
          catalogPriceOf: await catalogPriceLookup(),
        );
      }
      if (!mounted) return true;
      setState(() => _dirty = false);
      if (renumbered) {
        messenger.showSnackBar(
          SnackBar(content: Text('Gespeichert als ${saved.number}')),
        );
      }
      if (close) Navigator.of(context).pop();
      return true;
    } catch (e) {
      if (mounted) _snack(cloudError(e));
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addLine(LineKind kind) async {
    final line = await showLineDialog(
      context,
      kind: kind,
      hourlyRateCents: _settings.hourlyRateCents,
      currency: _settings.currency,
    );
    if (line != null) _change(() => _offer.lines.add(line));
  }

  Future<void> _editLine(int index) async {
    final line = await showLineDialog(
      context,
      line: _offer.lines[index],
      hourlyRateCents: _settings.hourlyRateCents,
      currency: _settings.currency,
    );
    if (line != null) _change(() => _offer.lines[index] = line);
  }

  Future<void> _addFromPriceList() async {
    final presets = await showPresetPicker(
      context,
      widget.store.presets,
      hourlyRateCents: _settings.hourlyRateCents,
      currency: _settings.currency,
    );
    if (presets == null || presets.isEmpty) return;
    _change(() {
      for (final p in presets) {
        _offer.lines.addAll(p.toLines(_settings.hourlyRateCents));
      }
    });
  }

  Future<void> _addFromCatalog() async {
    final store = widget.store;
    bool isDemo(CatalogProduct p) =>
        p.demoPrice && store.partPriceOverride(p.sku) <= 0;
    final product = await showCatalogPicker(
      context,
      priceOf: store.priceFor,
      isDemoPrice: isDemo,
      currency: _settings.currency,
      extraProducts: store.customProducts,
      stockOf: store.stockFor,
    );
    if (product == null || !mounted) return;
    final line = await showLineDialog(
      context,
      isNew: true,
      priceNote: isDemo(product)
          ? 'Demopreis aus dem Katalog, bitte prüfen'
          : null,
      line: OfferLine(
        kind: LineKind.part,
        description: product.name,
        quantity: 1,
        unitPriceCents: store.priceFor(product),
        sku: product.sku,
      ),
      hourlyRateCents: _settings.hourlyRateCents,
      currency: _settings.currency,
    );
    if (line != null) _change(() => _offer.lines.add(line));
  }

  Future<void> _pickValidUntil() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _offer.validUntil,
      firstDate: DateTime(_offer.createdAt.year - 1),
      lastDate: DateTime(_offer.createdAt.year + 2),
    );
    if (picked != null) _change(() => _offer.validUntil = picked);
  }

  Future<void> _onAction(_Action action) async {
    // Anything handed out must be saved, with its final number.
    if (action != _Action.delete &&
        (_dirty || _isNew) &&
        !await _save(close: false)) {
      return;
    }
    if (!mounted) return;
    final offer = _collect();
    switch (action) {
      case _Action.preview:
        final shared = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) =>
                OfferPdfPreviewPage(offer: offer.copy(), settings: _settings),
          ),
        );
        if (shared == true) await _askMarkSent();
      case _Action.share:
        final bytes = await buildOfferPdf(offer, _settings);
        await Printing.sharePdf(bytes: bytes, filename: offerFileName(offer));
        await _askMarkSent();
      case _Action.print:
        await Printing.layoutPdf(
          name: offerFileName(offer),
          onLayout: (_) => buildOfferPdf(offer, _settings),
        );
      case _Action.copy:
        await Clipboard.setData(
          ClipboardData(text: offerText(offer, _settings)),
        );
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Text kopiert')));
        }
      case _Action.delete:
        final ok = await confirm(
          context,
          title: 'Angebot löschen?',
          message: 'Angebot ${offer.number} wird endgültig gelöscht.',
          action: 'Löschen',
        );
        if (!ok) return;
        try {
          await widget.store.deleteOffer(offer.id);
          if (mounted) Navigator.of(context).pop();
        } catch (e) {
          if (mounted) _snack(cloudError(e));
        }
    }
  }

  /// After a draft was shared, offers to set its status to "Gesendet".
  Future<void> _askMarkSent() async {
    if (_offer.status != OfferStatus.draft || !mounted) return;
    final markSent = await confirm(
      context,
      title: 'Als gesendet markieren?',
      message:
          'Angebot ${_offer.number} wurde geteilt. Status auf '
          '„Gesendet“ setzen?',
      action: 'Gesendet',
    );
    if (!markSent) return;
    _change(() => _offer.status = OfferStatus.sent);
    await _save(close: false);
  }

  @override
  Widget build(BuildContext context) {
    final totals = computeTotals(
      _offer.lines,
      vatRate: _settings.vatRate,
      pricesIncludeVat: _settings.pricesIncludeVat,
    );
    final missingPrices = _offer.lines.where((l) => l.missingPrice).length;
    String money(int cents) => formatMoney(cents, _settings.currency);
    final theme = Theme.of(context);

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await confirm(
          context,
          title: 'Änderungen verwerfen?',
          message: 'Das Angebot hat ungespeicherte Änderungen.',
          action: 'Verwerfen',
        );
        if (discard && context.mounted) {
          setState(() => _dirty = false);
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_offer.number),
          actions: [
            IconButton(
              tooltip: 'PDF-Vorschau',
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed: () => _onAction(_Action.preview),
            ),
            PopupMenuButton<_Action>(
              onSelected: _onAction,
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: _Action.preview,
                  child: ListTile(
                    leading: Icon(Icons.picture_as_pdf_outlined),
                    title: Text('PDF-Vorschau'),
                  ),
                ),
                const PopupMenuItem(
                  value: _Action.share,
                  child: ListTile(
                    leading: Icon(Icons.share),
                    title: Text('PDF teilen'),
                  ),
                ),
                const PopupMenuItem(
                  value: _Action.print,
                  child: ListTile(
                    leading: Icon(Icons.print),
                    title: Text('Drucken'),
                  ),
                ),
                const PopupMenuItem(
                  value: _Action.copy,
                  child: ListTile(
                    leading: Icon(Icons.copy),
                    title: Text('Als Text kopieren'),
                  ),
                ),
                if (!_isNew)
                  const PopupMenuItem(
                    value: _Action.delete,
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Löschen'),
                    ),
                  ),
              ],
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
          children: [
            _Section(
              title: 'Status',
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final s in OfferStatus.values)
                      ChoiceChip(
                        label: Text(s.label),
                        selected: _offer.status == s,
                        onSelected: (_) => _change(() => _offer.status = s),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Erstellt ${formatDate(_offer.createdAt)}'),
                    TextButton.icon(
                      onPressed: _pickValidUntil,
                      icon: const Icon(Icons.event, size: 18),
                      label: Text(
                        'Gültig bis ${formatDate(_offer.validUntil)}',
                      ),
                    ),
                  ],
                ),
              ],
            ),
            _Section(
              title: 'Kunde',
              children: [
                TextField(
                  controller: _customerName,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TextField(
                  controller: _customerPhone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Telefon'),
                ),
                TextField(
                  controller: _customerEmail,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'E-Mail'),
                ),
              ],
            ),
            _Section(
              title: 'Fahrrad',
              children: [
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _bikeModel,
                  builder: (context, value, _) => Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final model in bikeModels)
                        ChoiceChip(
                          label: Text(model),
                          selected: value.text.trim() == model,
                          // Tapping the selected model clears it again.
                          onSelected: (on) => _bikeModel.text = on ? model : '',
                        ),
                    ],
                  ),
                ),
                TextField(
                  controller: _bikeModel,
                  decoration: const InputDecoration(
                    labelText: 'Modell',
                    hintText: 'oder anderes Modell eingeben',
                  ),
                ),
                TextField(
                  controller: _frameNumber,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Rahmennummer'),
                ),
                TextField(
                  controller: _problem,
                  minLines: 2,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Befund / Kundenwunsch',
                    hintText: 'z.B. Bremse hinten schleift, Kette rostig',
                  ),
                ),
              ],
            ),
            _Section(
              title: 'Positionen',
              children: [
                if (_offer.lines.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Noch keine Positionen. Reparaturen aus der Preisliste '
                      'oder Teile aus dem Katalog wählen, oder Teile und '
                      'Arbeit einzeln erfassen.',
                    ),
                  ),
                for (var i = 0; i < _offer.lines.length; i++)
                  _LineTile(
                    line: _offer.lines[i],
                    stock: _offer.lines[i].sku.isEmpty
                        ? null
                        : widget.store.stockFor(_offer.lines[i].sku),
                    currency: _settings.currency,
                    onTap: () => _editLine(i),
                    onDelete: () => _change(() => _offer.lines.removeAt(i)),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _addFromPriceList,
                      icon: const Icon(Icons.list_alt),
                      label: const Text('Aus Preisliste'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _addFromCatalog,
                      icon: const Icon(Icons.inventory_2_outlined),
                      label: const Text('Teil aus Katalog'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _addLine(LineKind.part),
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('Teil'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _addLine(LineKind.labour),
                      icon: const Icon(Icons.build_outlined),
                      label: const Text('Arbeit'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _addLine(LineKind.flat),
                      icon: const Icon(Icons.sell_outlined),
                      label: const Text('Pauschale'),
                    ),
                  ],
                ),
              ],
            ),
            _Section(
              title: 'Summe',
              children: [
                if (missingPrices > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      missingPrices == 1
                          ? '1 Position hat noch keinen Preis.'
                          : '$missingPrices Positionen haben noch keinen Preis.',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                _SumRow('Material', money(totals.partsCents)),
                _SumRow('Arbeit', money(totals.labourCents)),
                if (totals.vatRate > 0 && !totals.pricesIncludeVat)
                  _SumRow(
                    'MwSt ${formatVatRate(totals.vatRate)}%',
                    money(totals.vatCents),
                  ),
                const Divider(),
                _SumRow('Total', money(totals.totalCents), bold: true),
                if (totals.vatRate > 0 && totals.pricesIncludeVat)
                  _SumRow(
                    'inkl. ${formatVatRate(totals.vatRate)}% MwSt',
                    money(totals.vatCents),
                  ),
              ],
            ),
            _Section(
              title: 'Bemerkungen',
              children: [
                TextField(
                  controller: _notes,
                  minLines: 2,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'z.B. Teile bestellt, Lieferzeit ca. 1 Woche',
                  ),
                ),
              ],
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _saving ? null : () => _save(),
          icon: const Icon(Icons.check),
          label: const Text('Speichern'),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 6),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    ),
  );
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.line,
    required this.stock,
    required this.currency,
    required this.onTap,
    required this.onDelete,
  });

  final OfferLine line;

  /// Stock in the shared inventory, null for parts not stocked there.
  final StockLevel? stock;
  final String currency;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    final stock = this.stock;
    final shortage = stock != null && stock.total < line.quantity;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: Icon(switch (line.kind) {
        LineKind.labour => Icons.build_outlined,
        LineKind.flat => Icons.sell_outlined,
        LineKind.part => Icons.settings_outlined,
      }),
      title: Text(line.description),
      subtitle: Text(
        [
          if (line.sku.isNotEmpty) 'Art.-Nr. ${line.sku}',
          if (stock != null)
            stockLabel(stock) + (shortage ? ' (zu wenig)' : ''),
          line.missingPrice
              ? '${formatLineQuantity(line)} · Preis fehlt'
              : '${formatLineQuantity(line)} × ${formatMoney(line.unitPriceCents, currency)}',
        ].join(' · '),
        style: line.missingPrice || shortage ? TextStyle(color: error) : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(formatMoney(line.totalCents, currency)),
          IconButton(
            tooltip: 'Position entfernen',
            icon: const Icon(Icons.close),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _SumRow extends StatelessWidget {
  const _SumRow(this.label, this.value, {this.bold = false});

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? Theme.of(context).textTheme.titleMedium
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 12),
          Text(value, style: style),
        ],
      ),
    );
  }
}
