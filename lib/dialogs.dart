import 'package:flutter/material.dart';

import 'format.dart';
import 'models.dart';

String moneyInput(int cents) =>
    cents <= 0 ? '' : formatMoney(cents, '').replaceAll("'", '');

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

  /// Shown under the price field, e.g. a warning about a demo price.
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

  @override
  void dispose() {
    _description.dispose();
    _quantity.dispose();
    _price.dispose();
    super.dispose();
  }

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
      ),
    );
  }

  String get _sku => widget.line?.sku ?? '';

  @override
  Widget build(BuildContext context) {
    final labour = _kind == LineKind.labour;
    return AlertDialog(
      title: Text(widget.isNew ? 'Position hinzufügen' : 'Position'),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<LineKind>(
                segments: const [
                  ButtonSegment(
                    value: LineKind.part,
                    label: Text('Teil'),
                    icon: Icon(Icons.settings_outlined),
                  ),
                  ButtonSegment(
                    value: LineKind.labour,
                    label: Text('Arbeit'),
                    icon: Icon(Icons.build_outlined),
                  ),
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
                  hintText: labour ? 'z.B. Bremse entlüften' : 'z.B. Kette',
                  helperText: !labour && _sku.isNotEmpty
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
                  labelText: labour ? 'Arbeitszeit (Minuten)' : 'Menge',
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
                      : 'Stückpreis (${widget.currency})',
                  helperText:
                      widget.priceNote ??
                      'Leer lassen, wenn der Preis noch fehlt',
                  helperMaxLines: 2,
                ),
                validator: validateMoney,
                onFieldSubmitted: (_) => _submit(),
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
    if (p.labourMinutes > 0) '${p.labourMinutes} Min. Arbeit',
    if (p.partName.isNotEmpty)
      '${p.partName} ${p.partPriceCents > 0 ? formatMoney(p.partPriceCents, currency) + (p.demoPrice ? ' (Demo)' : '') : '(Preis fehlt)'}',
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
              controller: _minutes,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Arbeitszeit (Minuten)',
                helperText: '0 = keine Arbeitsposition',
              ),
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                return n == null || n < 0 ? 'Ganze Minuten eingeben' : null;
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
