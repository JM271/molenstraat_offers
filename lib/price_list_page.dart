import 'package:flutter/material.dart';

import 'dialogs.dart';
import 'firebase_gate.dart';
import 'offer_store.dart';

class PriceListPage extends StatelessWidget {
  const PriceListPage({super.key, required this.store});

  final OfferStore store;

  Future<void> _edit(BuildContext context, [int? index]) async {
    final preset = index == null ? null : store.presets[index];
    final result = await showPresetDialog(
      context,
      preset: preset,
      currency: store.settings.currency,
    );
    if (result == null || !context.mounted) return;
    await _guard(context, () => store.savePreset(result));
  }

  /// Runs a write to the shared database and reports a failure.
  Future<void> _guard(
    BuildContext context,
    Future<void> Function() write,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await write();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(cloudError(e))));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Preisliste')),
    body: ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final presets = store.presets;
        final s = store.settings;
        return ListView(
          padding: const EdgeInsets.only(bottom: 100),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Häufige Reparaturen mit Arbeitszeit und Ersatzteil. '
                'Die Arbeitszeiten sind Richtwerte – an die eigene Werkstatt '
                'anpassen und Teilepreise eintragen.',
              ),
            ),
            if (presets.any((p) => p.demoPrice))
              Container(
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Teilepreise mit „(Demo)“ sind Demopreise und nicht '
                  'verbindlich. Beim Bearbeiten und Speichern einer Reparatur '
                  'gilt ihr Preis als geprüft.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            if (presets.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('Die Preisliste ist leer.')),
              ),
            for (var i = 0; i < presets.length; i++)
              Dismissible(
                key: ValueKey(presets[i].id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Theme.of(context).colorScheme.errorContainer,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 24),
                  child: const Icon(Icons.delete_outline),
                ),
                confirmDismiss: (_) => confirm(
                  context,
                  title: 'Reparatur löschen?',
                  message: '„${presets[i].name}“ aus der Preisliste entfernen?',
                  action: 'Löschen',
                ),
                onDismissed: (_) =>
                    _guard(context, () => store.deletePreset(presets[i].id)),
                child: ListTile(
                  title: Text(presets[i].name),
                  subtitle: Text(
                    presetSummary(presets[i], s.hourlyRateCents, s.currency),
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => _edit(context, i),
                ),
              ),
          ],
        );
      },
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _edit(context),
      icon: const Icon(Icons.add),
      label: const Text('Reparatur'),
    ),
  );
}
