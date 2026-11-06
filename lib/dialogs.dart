import 'package:flutter/material.dart';

import 'format.dart';
import 'models.dart';

String moneyInput(int cents) =>
    cents <= 0 ? '' : formatMoney(cents, '').replaceAll("'", '');

/// A discount as typed, e.g. `10`, `12.5` or `12,5`; empty is no discount.
String percentInput(double percent) =>
    percent <= 0 ? '' : formatQuantity(percent);

double? parsePercent(String input) {
  final text = input.trim().replaceAll('%', '').trim();
  if (text.isEmpty) return 0;
  final value = double.tryParse(text.replaceAll(',', '.'));
  if (value == null || value < 0 || value > 100) return null;
  return value;
}

String? validatePercent(String? value) =>
    parsePercent(value ?? '') == null ? 'Prozent von 0 bis 100' : null;

String? validateMoney(String? value, {bool required = false}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return required ? 'Betrag eingeben' : null;
  return parseMoney(text) == null ? 'Ungültiger Betrag, z.B. 24.90' : null;
}

/// Edits or creates an offer line. Returns null when cancelled.
/// Pass [isNew] with a prefilled [line] to add a line, e.g. from the catalog.
Future<OfferLine?> showLineDialog(
  BuildContext context, {
  OfferLine? line,
  bool? isNew,
  LineKind kind = LineKind.part,
  String? priceNote,
  required int hourlyRateCents,
  required String currency,
}) => showDialog<OfferLine>(
  context: context,
  builder: (_) => _LineDialog(
    line: line,
    isNew: isNew ?? line == null,
    priceNote: priceNote,
    kind: line?.kind ?? kind,
    hourlyRateCents: hourlyRateCents,
    currency: currency,
  ),
);

class _LineDialog extends StatefulWidget {
  const _LineDialog({
    required this.line,
    required this.isNew,
    this.priceNote,
    required this.kind,
    required this.hourlyRateCents,
    required this.currency,
  });

  final OfferLine? line;
  final bool isNew;

  /// Shown under the price field, e.g. a hint that the price is missing.
  final String? priceNote;
  final LineKind kind;
  final int hourlyRateCents;
  final String currency;

  @override
  State<_LineDialog> createState() => _LineDialogState();
}

class _LineDialogState extends State<_LineDialog> {
  final _form = GlobalKey<FormState>();
  late LineKind _kind = widget.kind;
  late final _description = TextEditingController(
    text: widget.line?.description ?? '',
  );

  /// Pieces for parts, minutes for labour.
  late final _quantity = TextEditingController(
    text: widget.line == null
        ? _defaultQuantity(widget.kind)
        : widget.kind == LineKind.labour
        ? '${(widget.line!.quantity * 60).round()}'
        : formatQuantity(widget.line!.quantity),
  );

  static String _defaultQuantity(LineKind kind) =>
      kind == LineKind.labour ? '30' : '1';
  late final _price = TextEditingController(
    text: moneyInput(
      widget.line?.unitPriceCents ??
          (widget.kind == LineKind.labour ? widget.hourlyRateCents : 0),
    ),
  );

  late final _discount = TextEditingController(
    text: percentInput(widget.line?.discountPercent ?? 0),
  );

  @override
  void dispose() {
    _description.dispose();
    _quantity.dispose();
    _price.dispose();
    _discount.dispose();
    super.dispose();
  }

  bool get _free => parsePercent(_discount.text) == 100;

  void _setKind(LineKind kind) {
    setState(() => _kind = kind);
    // Pieces and minutes do not convert into each other.
    _quantity.text = _defaultQuantity(kind);
    if (kind == LineKind.labour && _price.text.trim().isEmpty) {
      _price.text = moneyInput(widget.hourlyRateCents);
    }
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).pop(
      OfferLine(
        kind: _kind,
        description: _description.text.trim(),
        quantity: _kind == LineKind.labour
            ? int.parse(_quantity.text.trim()) / 60
            : parseQuantity(_quantity.text)!,
        unitPriceCents: parseMoney(_price.text) ?? 0,
        // A catalog article number only makes sense on a part.
        sku: _kind == LineKind.part ? _sku : '',
        discountPercent: parsePercent(_discount.text) ?? 0,
      ),
    );
  }

  String get _sku => widget.line?.sku ?? '';

  @override
  Widget build(BuildContext context) {
    final labour = _kind == LineKind.labour;
    final flat = _kind == LineKind.flat;
    return AlertDialog(
      title: Text(widget.isNew ? 'Position hinzufügen' : 'Position'),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<LineKind>(
                showSelectedIcon: false,
                segments: [
                  for (final kind in LineKind.values)
                    ButtonSegment(value: kind, label: Text(kind.label)),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => _setKind(s.first),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                autofocus: widget.line == null,
                textCapitalization: TextCapitalization.sentences,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: 'Beschreibung',
                  hintText: switch (_kind) {
                    LineKind.labour => 'z.B. Bremse entlüften',
                    LineKind.flat => 'z.B. Kleine Reparatur',
                    LineKind.part => 'z.B. Kette',
                  },
                  helperText: _kind == LineKind.part && _sku.isNotEmpty
                      ? 'Art.-Nr. $_sku'
                      : null,
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Beschreibung eingeben' : null,
              ),
              TextFormField(
                controller: _quantity,
                keyboardType: labour
                    ? TextInputType.number
                    : const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: labour
                      ? 'Arbeitszeit (Minuten)'
                      : flat
                      ? 'Anzahl'
                      : 'Menge',
                ),
                validator: (v) {
                  if (!labour) {
                    return parseQuantity(v ?? '') == null
                        ? 'Zahl grösser 0'
                        : null;
                  }
                  final minutes = int.tryParse((v ?? '').trim());
                  return minutes == null || minutes <= 0
                      ? 'Ganze Minuten grösser 0'
                      : null;
                },
              ),
              TextFormField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: labour
                      ? 'Stundensatz (${widget.currency})'
                      : flat
                      ? 'Pauschalpreis (${widget.currency})'
                      : 'Stückpreis (${widget.currency})',
                  helperText:
                      widget.priceNote ??
                      'Leer lassen, wenn der Preis noch fehlt',
                  helperMaxLines: 2,
                ),
                validator: validateMoney,
                onFieldSubmitted: (_) => _submit(),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _discount,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Rabatt (%)',
                        hintText: 'z.B. 10',
                      ),
                      validator: validatePercent,
                      onChanged: (_) => setState(() {}),
                      onFieldSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: FilterChip(
                      label: const Text('Gratis'),
                      selected: _free,
                      onSelected: (on) =>
                          setState(() => _discount.text = on ? '100' : ''),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Übernehmen')),
      ],
    );
  }
}

/// Edits the discount on the whole offer. Returns null when cancelled and an
/// empty discount ([OfferDiscount.isEmpty]) when it is removed.
Future<OfferDiscount?> showDiscountDialog(
  BuildContext context, {
  OfferDiscount? discount,
  required String currency,
}) => showDialog<OfferDiscount>(
  context: context,
  builder: (_) => _DiscountDialog(discount: discount, currency: currency),
);

class _DiscountDialog extends StatefulWidget {
  const _DiscountDialog({required this.discount, required this.currency});

  final OfferDiscount? discount;
  final String currency;

  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  final _form = GlobalKey<FormState>();
  late bool _percent = widget.discount == null || widget.discount!.isPercent;
  late final _value = TextEditingController(
    text: switch (widget.discount) {
      null => '',
      final d when d.isPercent => percentInput(d.percent),
      final d => moneyInput(d.amountCents),
    },
  );
  late final _label = TextEditingController(
    text: widget.discount?.label ?? OfferDiscount.defaultLabel,
  );

  @override
  void dispose() {
    _value.dispose();
    _label.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    final label = _label.text.trim().isEmpty
        ? OfferDiscount.defaultLabel
        : _label.text.trim();
    Navigator.of(context).pop(
      _percent
          ? OfferDiscount(percent: parsePercent(_value.text)!, label: label)
          : OfferDiscount(amountCents: parseMoney(_value.text)!, label: label),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rabatt auf das Angebot'),
    content: Form(
      key: _form,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(value: true, label: Text('Prozent')),
                ButtonSegment(value: false, label: Text(widget.currency)),
              ],
              selected: {_percent},
              onSelectionChanged: (s) => setState(() {
                _percent = s.first;
                _value.clear();
              }),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _value,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: _percent
                    ? 'Rabatt (%)'
                    : 'Rabatt (${widget.currency})',
                hintText: _percent ? 'z.B. 10' : 'z.B. 50',
              ),
              validator: (v) {
                if (_percent) {
                  final p = parsePercent(v ?? '');
                  return p == null || p <= 0 ? 'Prozent von 0 bis 100' : null;
                }
                final cents = parseMoney(v ?? '');
                return cents == null || cents <= 0
                    ? 'Betrag grösser 0, z.B. 50'
                    : null;
              },
            ),
            TextFormField(
              controller: _label,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Bezeichnung',
                hintText: 'z.B. Rabatt beim Kauf eines Fatbikes',
              ),
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.discount != null)
        TextButton(
          onPressed: () => Navigator.of(context).pop(const OfferDiscount()),
          child: const Text('Entfernen'),
        ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Abbrechen'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Übernehmen')),
    ],
  );
}

/// Lets the user tick repairs from the price list. Returns the chosen ones.
Future<List<RepairPreset>?> showPresetPicker(
  BuildContext context,
  List<RepairPreset> presets, {
  required int hourlyRateCents,
  required String currency,
}) => showModalBottomSheet<List<RepairPreset>>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _PresetPicker(
    presets: presets,
    hourlyRateCents: hourlyRateCents,
    currency: currency,
  ),
);

String presetSummary(RepairPreset p, int hourlyRateCents, String currency) {
  final parts = <String>[
    if (p.isFlat)
      'Pauschale ${formatMoney(p.flatPriceCents, currency)}'
    else if (p.labourMinutes > 0)
      '${p.labourMinutes} Min. Arbeit',
    if (p.partName.isNotEmpty)
      '${p.partName} ${p.partPriceCents > 0 ? formatMoney(p.partPriceCents, currency) : '(Preis fehlt)'}',
  ];
  final total = p
      .toLines(hourlyRateCents)
      .fold<int>(0, (sum, l) => sum + l.totalCents);
  if (total > 0) parts.add('≈ ${formatMoney(total, currency)}');
  return parts.join(' · ');
}

class _PresetPicker extends StatefulWidget {
  const _PresetPicker({
    required this.presets,
    required this.hourlyRateCents,
    required this.currency,
  });

  final List<RepairPreset> presets;
  final int hourlyRateCents;
  final String currency;

  @override
  State<_PresetPicker> createState() => _PresetPickerState();
}

class _PresetPickerState extends State<_PresetPicker> {
  final _selected = <String>{};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final visible = widget.presets
        .where(
          (p) =>
              q.isEmpty ||
              p.name.toLowerCase().contains(q) ||
              p.partName.toLowerCase().contains(q),
        )
        .toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Reparatur suchen',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? const Center(child: Text('Keine Reparatur gefunden'))
                : ListView(
                    controller: controller,
                    children: [
                      for (final p in visible)
                        CheckboxListTile(
                          value: _selected.contains(p.id),
                          onChanged: (v) => setState(
                            () => v == true
                                ? _selected.add(p.id)
                                : _selected.remove(p.id),
                          ),
                          title: Text(p.name),
                          subtitle: Text(
                            presetSummary(
                              p,
                              widget.hourlyRateCents,
                              widget.currency,
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.of(context).pop([
                          for (final p in widget.presets)
                            if (_selected.contains(p.id)) p,
                        ]),
                  icon: const Icon(Icons.add),
                  label: Text(
                    _selected.isEmpty
                        ? 'Reparaturen auswählen'
                        : '${_selected.length} hinzufügen',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Edits or creates a price list entry. Returns null when cancelled.
Future<RepairPreset?> showPresetDialog(
  BuildContext context, {
  RepairPreset? preset,
  required String currency,
}) => showDialog<RepairPreset>(
  context: context,
  builder: (_) => _PresetDialog(preset: preset, currency: currency),
);

class _PresetDialog extends StatefulWidget {
  const _PresetDialog({required this.preset, required this.currency});

  final RepairPreset? preset;
  final String currency;

  @override
  State<_PresetDialog> createState() => _PresetDialogState();
}

class _PresetDialogState extends State<_PresetDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.preset?.name ?? '');
  late final _minutes = TextEditingController(
    text: widget.preset == null ? '30' : '${widget.preset!.labourMinutes}',
  );
  late final _flatPrice = TextEditingController(
    text: moneyInput(widget.preset?.flatPriceCents ?? 0),
  );
  late final _partName = TextEditingController(
    text: widget.preset?.partName ?? '',
  );
  late final _partPrice = TextEditingController(
    text: moneyInput(widget.preset?.partPriceCents ?? 0),
  );

  @override
  void dispose() {
    _name.dispose();
    _minutes.dispose();
    _flatPrice.dispose();
    _partName.dispose();
    _partPrice.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).pop(
      RepairPreset(
        id:
            widget.preset?.id ??
            'preset-${DateTime.now().microsecondsSinceEpoch}',
        name: _name.text.trim(),
        labourMinutes: int.tryParse(_minutes.text.trim()) ?? 0,
        flatPriceCents: parseMoney(_flatPrice.text) ?? 0,
        partName: _partName.text.trim(),
        partPriceCents: parseMoney(_partPrice.text) ?? 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.preset == null ? 'Reparatur hinzufügen' : 'Reparatur'),
    content: Form(
      key: _form,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              autofocus: widget.preset == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Reparatur'),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Namen eingeben' : null,
            ),
            TextFormField(
              controller: _flatPrice,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Pauschalpreis (${widget.currency})',
                helperText: 'Optional, ersetzt Arbeitszeit × Stundensatz',
              ),
              validator: validateMoney,
            ),
            // Labour time only applies without a flat price.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _flatPrice,
              builder: (context, flat, _) {
                final hasFlat = (parseMoney(flat.text) ?? 0) > 0;
                return TextFormField(
                  controller: _minutes,
                  enabled: !hasFlat,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Arbeitszeit (Minuten)',
                    helperText: hasFlat
                        ? 'Entfällt bei Pauschale'
                        : '0 = keine Arbeitsposition',
                  ),
                  validator: (v) {
                    if (hasFlat) return null;
                    final n = int.tryParse((v ?? '').trim());
                    return n == null || n < 0 ? 'Ganze Minuten eingeben' : null;
                  },
                );
              },
            ),
            TextFormField(
              controller: _partName,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Ersatzteil (optional)',
              ),
            ),
            TextFormField(
              controller: _partPrice,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Teilepreis (${widget.currency})',
              ),
              validator: validateMoney,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Abbrechen'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Speichern')),
    ],
  );
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
