import 'package:flutter/material.dart';

import 'dialogs.dart';
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
    if (result != null) await store.savePreset(result);
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
                onDismissed: (_) => store.deletePreset(presets[i].id),
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
