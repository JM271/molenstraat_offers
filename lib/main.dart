import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'brand.dart';
import 'firebase_gate.dart';
import 'format.dart';
import 'models.dart';
import 'offer_page.dart';
import 'offer_store.dart';
import 'price_list_page.dart';
import 'settings_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OffersApp());
}

class OffersApp extends StatelessWidget {
  const OffersApp({super.key, this.store});

  /// For tests; without it the app signs in to Firebase first.
  final OfferStore? store;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Molenstraat Reparaturangebote',
    debugShowCheckedModeBanner: false,
    locale: const Locale('de', 'CH'),
    supportedLocales: const [Locale('de', 'CH'), Locale('de')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      // Black and white like the Molenstraat logo; errors stay red.
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.black,
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
      ),
      inputDecorationTheme: const InputDecorationTheme(isDense: true),
    ),
    home: store != null
        ? HomePage(store: store!)
        : FirebaseGate(builder: (store) => HomePage(store: store)),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store});

  final OfferStore store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  OfferStatus? _filter;
  String _query = '';

  OfferStore get store => widget.store;

  void _open(Offer offer) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => OfferPage(store: store, offer: offer),
    ),
  );

  void _push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  bool _matches(Offer o) {
    if (_filter != null && o.status != _filter) return false;
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return [
      o.number,
      o.customerName,
      o.customerPhone,
      o.bikeModel,
      o.frameNumber,
      o.problem,
      store.bexioLink(o.id)?.number ?? '',
    ].any((field) => field.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const BrandLogo(height: 26),
      actions: [
        IconButton(
          tooltip: 'Preisliste',
          icon: const Icon(Icons.list_alt),
          onPressed: () => _push(PriceListPage(store: store)),
        ),
        IconButton(
          tooltip: 'Einstellungen',
          icon: const Icon(Icons.settings),
          onPressed: () => _push(SettingsPage(store: store)),
        ),
        const SignOutButton(),
      ],
    ),
    body: ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (store.error != null && !store.isLoaded) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(cloudError(store.error!)),
            ),
          );
        }
        if (!store.isLoaded) {
          return const Center(child: CircularProgressIndicator());
        }
        final offers = store.offers.where(_matches).toList();
        return CustomScrollView(
          slivers: [
            if (store.error != null)
              SliverToBoxAdapter(
                child: Card(
                  margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(
                    leading: const Icon(Icons.cloud_off),
                    title: Text(cloudError(store.error!)),
                  ),
                ),
              ),
            if (!store.settings.isComplete)
              SliverToBoxAdapter(
                child: Card(
                  margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('Einstellungen vervollständigen'),
                    subtitle: const Text(
                      'Adresse und Stundensatz erscheinen im Angebot.',
                    ),
                    onTap: () => _push(SettingsPage(store: store)),
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Kunde, Nummer, Rahmennummer …',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    for (final status in [null, ...OfferStatus.values])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text(
                            '${status?.label ?? 'Alle'} '
                            '(${store.offers.where((o) => status == null || o.status == status).length})',
                          ),
                          selected: _filter == status,
                          onSelected: (_) => setState(() => _filter = status),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (offers.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      store.offers.isEmpty
                          ? 'Noch keine Angebote.\nMit „Neues Angebot“ starten.'
                          : 'Keine passenden Angebote.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
                sliver: SliverList.builder(
                  itemCount: offers.length,
                  itemBuilder: (context, i) => _OfferCard(
                    offer: offers[i],
                    settings: store.settings,
                    bexioNumber: switch (store.bexioLink(offers[i].id)) {
                      final link? when link.isDone => link.number,
                      _ => '',
                    },
                    onTap: () => _open(offers[i].copy()),
                  ),
                ),
              ),
          ],
        );
      },
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _open(store.newOffer()),
      icon: const Icon(Icons.add),
      label: const Text('Neues Angebot'),
    ),
  );
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.offer,
    required this.settings,
    required this.onTap,
    this.bexioNumber = '',
  });

  final Offer offer;
  final ShopSettings settings;
  final VoidCallback onTap;

  /// Number of the offer's quote in bexio, empty if not transferred.
  final String bexioNumber;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totals = offer.totals(settings);
    final (Color bg, Color fg) = switch (offer.status) {
      OfferStatus.draft => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      OfferStatus.sent => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      OfferStatus.accepted => (scheme.primary, scheme.onPrimary),
      OfferStatus.declined => (scheme.errorContainer, scheme.onErrorContainer),
    };
    final today = DateUtils.dateOnly(DateTime.now());
    final expired =
        offer.status == OfferStatus.sent && offer.validUntil.isBefore(today);
    final subtitle = [
      offer.bikeModel,
      if (offer.frameNumber.isNotEmpty) offer.frameNumber,
    ].where((s) => s.isNotEmpty).join(' · ');

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      offer.customerName.isEmpty
                          ? 'Ohne Kundenname'
                          : offer.customerName,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    formatMoney(totals.totalCents, settings.currency),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              if (subtitle.isNotEmpty) Text(subtitle),
              const SizedBox(height: 6),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      offer.status.label,
                      style: TextStyle(color: fg, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${offer.number} · ${formatDate(offer.createdAt)}'
                      '${bexioNumber.isEmpty ? '' : ' · bexio $bexioNumber'}'
                      '${expired ? ' · abgelaufen' : ''}',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: expired ? scheme.error : null),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
