import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';

import 'package:molenstraat_offers/bexio.dart';
import 'package:molenstraat_offers/catalog.dart';
import 'package:molenstraat_offers/dialogs.dart';
import 'package:molenstraat_offers/format.dart';
import 'package:molenstraat_offers/main.dart';
import 'package:molenstraat_offers/models.dart';
import 'package:molenstraat_offers/offer_page.dart';
import 'package:molenstraat_offers/offer_pdf.dart';
import 'package:molenstraat_offers/offer_store.dart';
import 'package:molenstraat_offers/pdf_preview_page.dart';

/// Opens the store like a signed-in member on one device. Several stores on
/// the same [db] behave like several devices.
Future<OfferStore> openStore(
  FakeFirebaseFirestore db, {
  String uid = 'u1',
}) async {
  final store = OfferStore(db, uid);
  // Not via loadCatalog(): its cached future is bound to the test's zone.
  final data = await rootBundle.load(catalogAsset);
  store.useBundledCatalog(parseCatalog(utf8.decode(data.buffer.asUint8List())));
  await store.loaded;
  return store;
}

/// Lets snapshot listeners deliver pending changes.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(resetCatalogCache);

  group('money', () {
    test('formats Swiss style', () {
      expect(formatMoney(123456), "CHF 1'234.56");
      expect(formatMoney(5), 'CHF 0.05');
      expect(formatMoney(100000000, ''), "1'000'000.00");
    });

    test('parses common inputs', () {
      expect(parseMoney('12'), 1200);
      expect(parseMoney('12.5'), 1250);
      expect(parseMoney('12,50'), 1250);
      expect(parseMoney('12.-'), 1200);
      expect(parseMoney("1'234.50"), 123450);
      expect(parseMoney('CHF 9.90'), 990);
      expect(parseMoney('abc'), isNull);
      expect(parseMoney('1.234'), isNull);
      expect(parseMoney('-5'), isNull);
    });
  });

  test('labour time reads as minutes or hours', () {
    expect(formatLabour(20 / 60), '20 Min.');
    expect(formatLabour(1), '1 Std.');
    expect(formatLabour(1.5), '1.5 Std.');
    expect(formatLabour(80 / 60), '1:20 Std.');
  });

  group('totals', () {
    final lines = [
      OfferLine(
        kind: LineKind.part,
        description: 'Kette',
        quantity: 1,
        unitPriceCents: 4990,
      ),
      OfferLine(
        kind: LineKind.labour,
        description: 'Kette ersetzen',
        quantity: 0.25,
        unitPriceCents: 9600,
      ),
    ];

    test('VAT included in prices', () {
      final t = computeTotals(lines, vatRate: 8.1, pricesIncludeVat: true);
      expect(t.partsCents, 4990);
      expect(t.labourCents, 2400);
      expect(t.totalCents, 7390);
      expect(t.vatCents, 554); // 7390 * 8.1 / 108.1
    });

    test('VAT added to prices', () {
      final t = computeTotals(lines, vatRate: 8.1, pricesIncludeVat: false);
      expect(t.vatCents, 599);
      expect(t.totalCents, 7989);
    });

    test('no VAT', () {
      final t = computeTotals(lines, vatRate: 0, pricesIncludeVat: true);
      expect(t.vatCents, 0);
      expect(t.totalCents, 7390);
    });
  });

  test('preset becomes labour and part lines', () {
    final lines = RepairPreset(
      id: 'x',
      name: 'Bremsbeläge ersetzen',
      labourMinutes: 20,
      partName: 'Bremsbeläge',
      partPriceCents: 2500,
    ).toLines(9000);
    expect(lines, hasLength(2));
    expect(lines[0].kind, LineKind.labour);
    expect(lines[0].totalCents, 3000);
    expect(lines[1].totalCents, 2500);
  });

  test('price list uses list prices and has no demo prices', () {
    final presets = defaultPresets();
    // Parts in the Molenstraat product list have their list price.
    final chain = presets.firstWhere((p) => p.partName == 'Kette');
    expect(chain.partPriceCents, 2500);
    expect(presetSummary(chain, 9000, 'CHF'), contains('Kette CHF 25.00'));
    // Others have no price until one is entered.
    final cable = presets.firstWhere((p) => p.partName == 'Schaltzug');
    expect(cable.partPriceCents, 0);
    expect(presetSummary(cable, 9000, 'CHF'), contains('(Preis fehlt)'));
    expect(
      presets.map((p) => presetSummary(p, 9000, 'CHF')).join(),
      isNot(contains('Demo')),
    );
  });

  test('demo prices of a stored price list are replaced or removed', () {
    final stored = [
      {
        'id': 'a',
        'name': 'Kette ersetzen',
        'partName': 'Kette',
        'partPriceCents': 2490,
        'demoPrice': true,
      },
      {
        'id': 'b',
        'name': 'Schaltzug ersetzen',
        'partName': 'Schaltzug',
        'partPriceCents': 690,
        'demoPrice': true,
      },
      {
        'id': 'c',
        'name': 'Speiche ersetzen',
        'partName': 'Speiche',
        'partPriceCents': 450,
      },
    ];
    expect(storedPresetsHaveDemoPrices(stored), isTrue);
    final presets = presetsFromStored(stored);
    expect(presets.map((p) => p.partPriceCents), [2500, 0, 450]);
    expect(
      storedPresetsHaveDemoPrices([for (final p in presets) p.toJson()]),
      isFalse,
    );
  });

  test('flat rates from the price list count as work', () {
    final flats = defaultPresets().where((p) => p.isFlat).toList();
    expect(flats.map((p) => p.flatPriceCents), [
      3000,
      5000,
      10000,
      15000,
      15000,
    ]);
    expect(
      flats.last.name,
      'Service Pauschale: inkl. Anfahrtskosten, Montage, Reparatur.',
    );
    expect(flats.last.toLines(9000).single.totalCents, 15000);
    final small = flats.first;
    expect(RepairPreset.fromJson(small.toJson()).flatPriceCents, 3000);
    expect(
      presetSummary(small, 9000, 'CHF'),
      'Pauschale CHF 30.00 · ≈ CHF 30.00',
    );

    // A flat price replaces labour time × hourly rate.
    final service = RepairPreset(
      id: 's',
      name: 'Service',
      labourMinutes: 90,
      flatPriceCents: 15000,
      partName: 'Kette',
      partPriceCents: 2490,
    );
    final lines = service.toLines(9000);
    expect(lines.map((l) => l.kind), [LineKind.flat, LineKind.part]);
    expect(formatLineQuantity(lines.first), '1');
    final totals = computeTotals(lines, vatRate: 8.1, pricesIncludeVat: true);
    expect(totals.labourCents, 15000);
    expect(totals.partsCents, 2490);
    expect(OfferLine.fromJson(lines.first.toJson()).kind, LineKind.flat);
  });

  group('store', () {
    test('numbers offers per year, also across devices', () async {
      final db = FakeFirebaseFirestore();
      final store = await openStore(db);
      final first = store.newOffer(now: DateTime(2026, 11, 4));
      expect(first.number, 'A-2026-001');
      // Unsaved offers do not use up a number.
      expect(store.newOffer(now: DateTime(2026, 11, 4)).number, 'A-2026-001');

      first.customerName = 'Anna Muster';
      expect((await store.saveOffer(first)).number, 'A-2026-001');
      await settle();
      expect(store.newOffer(now: DateTime(2026, 11, 5)).number, 'A-2026-002');
      expect(store.newOffer(now: DateTime(2027, 1, 2)).number, 'A-2027-001');

      // Saving again keeps the number.
      first.notes = 'Teile bestellt';
      expect((await store.saveOffer(first)).number, 'A-2026-001');

      await store.deleteOffer(first.id);
      await settle();
      // Deleting never hands out the same number again.
      expect(store.newOffer(now: DateTime(2026, 11, 5)).number, 'A-2026-002');

      // Two devices start an offer with the same provisional number; the
      // second one to save gets the next free number.
      final other = await openStore(db, uid: 'u2');
      final mine = store.newOffer(now: DateTime(2026, 11, 6));
      final theirs = other.newOffer(now: DateTime(2026, 11, 6));
      expect(theirs.number, mine.number);
      expect((await store.saveOffer(mine)).number, 'A-2026-002');
      expect((await other.saveOffer(theirs)).number, 'A-2026-003');
      await settle();
      expect(store.offers.map((o) => o.number), ['A-2026-003', 'A-2026-002']);
      expect(store.presets, isNotEmpty);
      final saved = await db
          .doc('workshops/molenstraat/offers/${theirs.id}')
          .get();
      expect(saved.data()!['updatedBy'], 'u2');
    });

    test('settings and price list are shared', () async {
      final db = FakeFirebaseFirestore();
      final store = await openStore(db);
      final other = await openStore(db, uid: 'u2');
      await store.saveSettings(
        store.settings.copyWith(
          address: 'Molenstraat 1',
          hourlyRateCents: 9600,
        ),
      );
      final preset = RepairPreset(id: 'new', name: 'Sattel tauschen');
      await store.savePreset(preset);
      await other.deletePreset('preset-0');
      await settle();
      expect(other.settings.hourlyRateCents, 9600);
      expect(other.presets.map((p) => p.id), contains('new'));
      expect(store.presets.map((p) => p.id), isNot(contains('preset-0')));
      expect(store.presets, hasLength(defaultPresets().length));
    });

    test('reads stock and custom products of the inventory app', () async {
      final db = FakeFirebaseFirestore();
      final parts = db.collection('workshops/molenstraat/parts');
      await parts.doc('a').set({
        'id': 'a',
        'name': 'Chain',
        'sku': 'oxv8-30 ',
        'quantity': 3,
        'carQuantity': 1,
      });
      await parts.doc('b').set({'id': 'b', 'name': 'Rag', 'sku': ''});
      await db.doc('workshops/molenstraat/catalog/x').set({
        'id': 'custom-1',
        'name': 'Spezialschraube',
        'category': 'Other',
        'sku': 'MS-001',
        'imageAsset': '',
      });
      final store = await openStore(db);
      final stock = store.stockFor('OXV8-30')!;
      expect((stock.workshop, stock.car, stock.total), (3, 1, 4));
      expect(stockLabel(stock), 'Lager 3 + 1 Auto');
      expect(store.stockFor('RF-M09'), isNull);
      expect(store.customProducts.single.sku, 'MS-001');
    });

    test('finds stock of Molenstraat products by any part number', () async {
      final db = FakeFirebaseFirestore();
      final parts = db.collection('workshops/molenstraat/parts');
      Future<void> part(String id, Map<String, Object> numbers, int qty) =>
          parts.doc(id).set({
            'id': id,
            'name': id,
            'quantity': qty,
            ...numbers,
          });
      // Saved by the current Inventory app: own number stored.
      await part('switch', {
        'sku': 'OXV8-05',
        'productNumber': 'MS-SP-3009',
        'orderNumber': 'OXV8-05',
      }, 2);
      // Older record: only the supplier SKU.
      await part('disc', {'sku': 'OXV8-17A'}, 5);
      // Created with the own number as SKU.
      await part('seat', {'sku': 'MS-AC-5002', 'orderNumber': '1079SW'}, 1);
      // Supplier code with two products: assigned to one of them by hand.
      await part('ctrl', {
        'sku': 'OXV8-02',
        'productNumber': 'MS-SP-3011',
        'orderNumber': 'OXV8-02',
      }, 4);
      // A supplier part assigned to another own number.
      await part('chain', {'sku': 'OXV8-30', 'productNumber': 'MS-SP-9999'}, 7);
      final store = await openStore(db);

      int? workshop(String sku) => store.stockFor(sku)?.workshop;
      expect(workshop('MS-SP-3009'), 2);
      expect(workshop('OXV8-05'), 2);
      expect(workshop('MS-SP-2005'), 5);
      expect(workshop('OXV8-17A'), 5);
      expect(workshop('MS-AC-5002'), 1);
      expect(workshop('MS-SP-3011'), 4);
      expect(workshop('MS-SP-3004'), isNull);
      expect(workshop('MS-SP-2002'), isNull);
      expect(workshop('OXV8-30'), 7);
    });
  });

  test('PDF and text export', () async {
    final offer = Offer(
      id: '1',
      number: 'A-2026-001',
      createdAt: DateTime(2026, 11, 4),
      validUntil: DateTime(2026, 12, 4),
      customerName: 'Anna Muster',
      bikeModel: 'Fatbike 26"',
      problem: 'Bremse hinten schleift',
      lines: [
        OfferLine(
          kind: LineKind.labour,
          description: 'Bremse entlüften',
          quantity: 0.5,
          unitPriceCents: 9000,
        ),
      ],
    );
    const settings = ShopSettings(
      address: 'Molenstraat 1',
      hourlyRateCents: 9000,
    );
    final bytes = await buildOfferPdf(offer, settings);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final text = offerText(offer, settings);
    expect(text, contains('Reparaturangebot A-2026-001'));
    expect(text, contains('Total: CHF 45.00'));
    expect(text, contains('inkl. 8.1% MwSt: CHF 3.37'));
    expect(offerFileName(offer), 'Reparaturangebot_A-2026-001.pdf');
  });

  testWidgets('create an offer from the price list', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final store = await openStore(FakeFirebaseFirestore());
    await store.saveSettings(
      store.settings.copyWith(address: 'Molenstraat 1', hourlyRateCents: 9000),
    );
    await tester.pumpWidget(OffersApp(store: store));
    expect(
      find.text('Noch keine Angebote.\nMit „Neues Angebot“ starten.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Neues Angebot'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Anna Muster',
    );

    // Scroll the button well clear of the floating "Speichern" button.
    final page = find
        .descendant(
          of: find.byType(OfferPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Aus Preisliste'),
      200,
      scrollable: page,
    );
    await tester.drag(page, const Offset(0, -250));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aus Preisliste'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Reparatur suchen'),
      'entlüften',
    );
    await tester.pump();
    await tester.tap(find.text('Bremse entlüften'));
    await tester.pump();
    await tester.tap(find.text('1 hinzufügen'));
    await tester.pumpAndSettle();

    // 30 minutes at CHF 90.00.
    expect(find.text('CHF 45.00'), findsWidgets);

    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    expect(find.text('Anna Muster'), findsOneWidget);
    expect(find.text('Entwurf'), findsOneWidget);
    expect(store.offers.single.lines.single.description, 'Bremse entlüften');
  });

  testWidgets('leaving with unsaved changes asks first', (tester) async {
    final store = await openStore(FakeFirebaseFirestore());
    await tester.pumpWidget(OffersApp(store: store));
    await tester.tap(find.text('Neues Angebot'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Bob');
    await tester.pump();
    expect(find.byType(OfferPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tester.tap(find.text('Verwerfen'));
    await tester.pumpAndSettle();
    expect(store.offers, isEmpty);
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(OfferPage), findsNothing);
  });

  testWidgets('labour is entered in minutes', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final store = await openStore(FakeFirebaseFirestore());
    await store.saveSettings(store.settings.copyWith(hourlyRateCents: 9600));
    await tester.pumpWidget(OffersApp(store: store));
    await tester.tap(find.text('Neues Angebot'));
    await tester.pumpAndSettle();
    final page = find
        .descendant(
          of: find.byType(OfferPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(find.text('Arbeit'), 200, scrollable: page);
    await tester.drag(page, const Offset(0, -250));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Arbeit'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Beschreibung'),
      'Lenker tauschen',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Arbeitszeit (Minuten)'),
      '20',
    );
    await tester.tap(find.text('Übernehmen'));
    await tester.pumpAndSettle();
    expect(find.text('20 Min. × CHF 96.00'), findsOneWidget);
    expect(find.text('CHF 32.00'), findsWidgets);
  });

  group('catalog', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('bundled catalog loads and its pictures exist', () async {
      // Not via loadCatalog(): its cached future would be bound to this
      // test's zone and never resolve inside the widget test's fake async.
      final data = await rootBundle.load(catalogAsset);
      final products = parseCatalog(utf8.decode(data.buffer.asUint8List()));
      // Only the Molenstraat product list, all with a price.
      expect(products, hasLength(54));
      expect(products.where((p) => !p.sku.startsWith('MS-')), isEmpty);
      expect(products.where((p) => !p.hasListPrice), isEmpty);
      expect(products.map((p) => p.sku).toSet(), hasLength(products.length));
      expect(catalogCategories(products), [
        'Fatbikes',
        'Spare Parts',
        'Accessoires',
      ]);
      for (final p in products.where((p) => p.imageAsset.isNotEmpty)) {
        final data = await rootBundle.load(p.imageAsset);
        expect(data.lengthInBytes, greaterThan(0), reason: p.imageAsset);
      }
      final dapper = products.firstWhere((p) => p.sku == 'MS-V8P-DP001');
      expect(dapper.priceCents, 249000);
      final disc = products.firstWhere((p) => p.sku == 'MS-SP-2005');
      expect(disc.priceCents, 990);
      expect(disc.imageAsset, 'assets/products/oxv8-17a.png');
      // The supplier number finds the product.
      expect(disc.supplierSku, 'OXV8-17A');
      expect(disc.matches('oxv8-17a'), isTrue);
      expect(disc.matches('brake disc'), isTrue);
      expect(products.where((p) => p.matches('OXV8-05')).map((p) => p.sku), [
        'MS-SP-3009',
      ]);
      // The two Mini MS versions can be told apart.
      expect(
        products.where((p) => p.sku == 'MS-FB-MIN001').single.name,
        contains('250W'),
      );
    });

    test('article number is kept on the line and in the exports', () async {
      final line = OfferLine.fromJson(
        OfferLine(
          kind: LineKind.part,
          description: 'V8 battery lock',
          quantity: 1,
          unitPriceCents: 1500,
          sku: 'OXV8-01E',
        ).toJson(),
      );
      expect(line.sku, 'OXV8-01E');
      // Lines saved before the catalog existed have no SKU.
      expect(
        OfferLine.fromJson({'kind': 'part', 'description': 'Kette'}).sku,
        '',
      );
      final offer = Offer(
        id: '1',
        number: 'A-2026-001',
        createdAt: DateTime(2026, 11, 4),
        validUntil: DateTime(2026, 12, 4),
        lines: [line],
      );
      expect(
        offerText(offer, const ShopSettings()),
        contains('- V8 battery lock (Art.-Nr. OXV8-01E): 1 Stk. × CHF 15.00'),
      );
      final bytes = await buildOfferPdf(offer, const ShopSettings());
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('prices in the database fill parts without list price', () async {
      final db = FakeFirebaseFirestore();
      final store = await openStore(db);
      const lock = CatalogProduct(
        sku: 'OXV8-01E',
        name: 'V8 battery lock',
        category: 'Electrics',
      );
      const mirror = CatalogProduct(
        sku: 'RF-M09',
        name: 'Mirror',
        category: 'Cockpit',
      );
      OfferLine part(String sku, int cents) => OfferLine(
        kind: LineKind.part,
        description: sku,
        quantity: 1,
        unitPriceCents: cents,
        sku: sku,
      );
      expect(store.priceFor(lock), 0);

      await store.rememberPartPrices([
        part('OXV8-01E', 1500), // entered on the offer: saved for everyone
        OfferLine(
          kind: LineKind.part,
          description: 'Kette',
          quantity: 1,
          unitPriceCents: 3000,
        ),
      ]);
      final other = await openStore(db, uid: 'u2');
      expect(other.priceFor(lock), 1500);
      expect(other.priceFor(mirror), 0);
      expect(other.savedPartPriceCount, 1);

      // An imported price list applies on every device at once.
      expect(
        await other.importPartPrices({'rf-m09': 2200, 'OXV8-01E': 1500}),
        1,
      );
      await settle();
      expect(store.priceFor(mirror), 2200);
      expect(store.savedPartPriceCount, 2);
    });

    test('the shared catalogue is seeded once from the product list', () async {
      final db = FakeFirebaseFirestore();
      final store = await openStore(db);
      final bundled = store.catalog;
      // Until the database has the catalogue, the bundled list stands in.
      expect(bundled, hasLength(54));
      expect(
        store.priceFor(bundled.firstWhere((p) => p.sku == 'MS-SP-2005')),
        990,
      );

      expect(await store.seedCatalog(bundled), isTrue);
      final other = await openStore(db, uid: 'u2');
      other.useBundledCatalog(const []);
      expect(other.catalog, hasLength(54));
      expect(other.catalog.first.category, 'Fatbikes');
      final disc = other.catalog.firstWhere((p) => p.sku == 'MS-SP-2005');
      expect((disc.priceCents, disc.supplierSku), (990, 'OXV8-17A'));

      // A price changed in the database applies and is not seeded again.
      await db
          .doc(
            'workshops/molenstraat/products/${OfferStore.documentId('MS-SP-2005')}',
          )
          .update({'priceCents': 1100});
      await settle();
      expect(await other.seedCatalog(bundled), isFalse);
      await settle();
      expect(
        other.priceFor(other.catalog.firstWhere((p) => p.sku == 'MS-SP-2005')),
        1100,
      );
    });

    test('a stored price list loses its demo prices once', () async {
      final db = FakeFirebaseFirestore();
      // A stored price list: chain still at the old demo price, tyre
      // changed by hand.
      await db.doc('workshops/molenstraat/offerConfig/presets').set({
        'items': [
          {
            ...RepairPreset(
              id: 'preset-5',
              name: 'Kette ersetzen',
              labourMinutes: 15,
              partName: 'Kette',
              partPriceCents: 2490,
            ).toJson(),
            'demoPrice': true,
          },
          RepairPreset(
            id: 'preset-1',
            name: 'Reifen ersetzen',
            labourMinutes: 30,
            partName: 'Fatbike-Reifen',
            partPriceCents: 7000,
          ).toJson(),
        ],
      });
      final store = await openStore(db);
      await store.migratePresets();
      final stored =
          (await db.doc('workshops/molenstraat/offerConfig/presets').get())
                  .data()!['items']
              as List;
      expect(stored[0]['partPriceCents'], 2500);
      expect(stored[0]['demoPrice'], isNull);
      expect(stored[1]['partPriceCents'], 7000);
      expect(stored[2]['name'], startsWith('Service Pauschale'));
      expect(stored[2]['flatPriceCents'], 15000);
      // Deleting the service flat rate later sticks.
      await store.deletePreset('flat-service');
      await store.migratePresets();
      await settle();
      expect(store.presets.map((p) => p.id), isNot(contains('flat-service')));
    });

    test(
      'imported prices go into the catalogue, offers do not change them',
      () async {
        final db = FakeFirebaseFirestore();
        final store = await openStore(db);
        OfferLine part(String sku, int cents) => OfferLine(
          kind: LineKind.part,
          description: sku,
          quantity: 1,
          unitPriceCents: cents,
          sku: sku,
        );
        await store.rememberPartPrices([
          part('MS-SP-2005', 1200),
          part('RF-M09', 1990),
        ], hasListPrice: store.hasListPrice);
        expect(store.savedPartPrice('MS-SP-2005'), 0);
        expect(store.savedPartPrice('RF-M09'), 1990);

        // By SKU or supplier number; the catalogue is filled first.
        expect(
          await store.importPartPrices({
            'OXV8-17A': 1200,
            'MS-SP-3009': 4500,
            'X-1': 300,
          }),
          2, // MS-SP-3009 already costs 45.00
        );
        await settle();
        final other = await openStore(db, uid: 'u2');
        other.useBundledCatalog(const []);
        expect(other.catalog, hasLength(54));
        expect(
          other.catalog.firstWhere((p) => p.sku == 'MS-SP-2005').priceCents,
          1200,
        );
        expect(other.savedPartPrice('X-1'), 300);
        expect(other.savedPartPrice('OXV8-17A'), 0);
      },
    );

    test('pasted price lists are read from Excel and CSV', () {
      final known = {'OXV8-30', 'RF-M09', 'KD001', 'OXGT-24'};
      final result = parsePriceList(
        'Artikel\tPreis\n'
        'OXV8-30\t24.90\n'
        'rf-m09;19,90\n'
        'KD001\tKENDA tire\tCHF 59.-\n'
        "OXGT-24,1'190.00\n"
        '\n'
        'XX-1\t10\n'
        'KD002\n',
        known,
      );
      expect(result.prices, {
        'OXV8-30': 2490,
        'RF-M09': 1990,
        'KD001': 5900,
        'OXGT-24': 119000,
      });
      expect(result.unknownSkus, ['XX-1']);
      expect(result.invalidLines, ['Artikel\tPreis', 'KD002']);
    });
  });

  testWidgets('add a part from the catalog', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final db = FakeFirebaseFirestore();
    // A product added in the Inventory app, without list price.
    await db.doc('workshops/molenstraat/catalog/x').set({
      'id': 'custom-1',
      'name': 'Spezialschraube',
      'category': 'Other',
      'sku': 'SPZ-1',
      'imageAsset': '',
    });
    final store = await openStore(db);
    await tester.pumpWidget(OffersApp(store: store));

    Future<void> pick(String query, String name) async {
      await tester.tap(find.text('Neues Angebot'));
      await tester.pumpAndSettle();
      final page = find
          .descendant(
            of: find.byType(OfferPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Teil aus Katalog'),
        200,
        scrollable: page,
      );
      await tester.drag(page, const Offset(0, -250));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Teil aus Katalog'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Teil oder Artikelnummer suchen'),
        query,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }

    Future<void> close() async {
      await tester.tap(find.text('Übernehmen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
    }

    const hint = 'Nicht in der Produktliste, bitte Preis eintragen';
    // A product of the list comes with its list price; the supplier number
    // finds it.
    await pick('oxv8-05', '3 in 1 switch');
    expect(find.text('Art.-Nr. MS-SP-3009'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '45.00'), findsOneWidget);
    expect(find.text(hint), findsNothing);
    // A different price applies to this offer only.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Stückpreis (CHF)'),
      '39.00',
    );
    await close();
    expect(store.offers.single.lines.single.unitPriceCents, 3900);
    expect(store.savedPartPrice('MS-SP-3009'), 0);

    // A product without list price asks for a price, which is remembered.
    await pick('spz', 'Spezialschraube');
    expect(find.text(hint), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Stückpreis (CHF)'),
      '12.50',
    );
    await close();
    expect(store.savedPartPrice('SPZ-1'), 1250);

    await pick('spz', 'Spezialschraube');
    expect(find.widgetWithText(TextFormField, '12.50'), findsOneWidget);
    expect(find.text(hint), findsNothing);
  });

  testWidgets('PDF preview saves a new offer first', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final store = await openStore(FakeFirebaseFirestore());
    await tester.pumpWidget(OffersApp(store: store));
    await tester.tap(find.text('Neues Angebot'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Anna');

    await tester.tap(find.byTooltip('PDF-Vorschau'));
    // The preview renders asynchronously; don't wait for it to settle.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(OfferPdfPreviewPage), findsOneWidget);
    expect(find.text('Vorschau A-2026-001'), findsOneWidget);
    expect(store.offers.single.customerName, 'Anna');

    await tester.binding.handlePopRoute();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(OfferPdfPreviewPage), findsNothing);
    // Nothing was shared, so no question about marking it as sent.
    expect(find.text('Als gesendet markieren?'), findsNothing);
    expect(find.byType(OfferPage), findsOneWidget);
  });

  testWidgets('pick one of the usual bike models', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final store = await openStore(FakeFirebaseFirestore());
    await tester.pumpWidget(OffersApp(store: store));
    await tester.tap(find.text('Neues Angebot'));
    await tester.pumpAndSettle();
    final page = find
        .descendant(
          of: find.byType(OfferPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Dapper Pro'),
      200,
      scrollable: page,
    );
    await tester.pumpAndSettle();
    for (final model in bikeModels) {
      expect(find.widgetWithText(ChoiceChip, model), findsOneWidget);
    }

    await tester.tap(find.widgetWithText(ChoiceChip, 'Storm'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Dapper Pro'));
    await tester.pump();
    final modelField = find.widgetWithText(TextField, 'Modell');
    expect(tester.widget<TextField>(modelField).controller!.text, 'Dapper Pro');
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Storm'))
          .selected,
      isFalse,
    );

    // Tapping the selected model clears it; free text still works.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Dapper Pro'));
    await tester.pump();
    expect(tester.widget<TextField>(modelField).controller!.text, '');
    await tester.enterText(modelField, 'Mooi');
    await tester.pump();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Mooi'))
          .selected,
      isTrue,
    );

    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(store.offers.single.bikeModel, 'Mooi');
  });

  testWidgets('add a flat rate to an offer', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final store = await openStore(FakeFirebaseFirestore());
    await tester.pumpWidget(OffersApp(store: store));
    await tester.tap(find.text('Neues Angebot'));
    await tester.pumpAndSettle();
    final page = find
        .descendant(
          of: find.byType(OfferPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.widgetWithText(OutlinedButton, 'Pauschale'),
      200,
      scrollable: page,
    );
    await tester.drag(page, const Offset(0, -250));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Pauschale'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Beschreibung'),
      'Grosse Reparatur',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Pauschalpreis (CHF)'),
      '100',
    );
    await tester.tap(find.text('Übernehmen'));
    await tester.pumpAndSettle();
    expect(find.text('1 × CHF 100.00'), findsOneWidget);
    expect(find.text('CHF 100.00'), findsWidgets);
  });

  testWidgets('import catalog prices in the settings', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final db = FakeFirebaseFirestore();
    await db.doc('workshops/molenstraat/catalog/x').set({
      'id': 'custom-1',
      'name': 'Spezialschraube',
      'category': 'Other',
      'sku': 'SPZ-1',
      'imageAsset': '',
    });
    final store = await openStore(db);
    await tester.pumpWidget(OffersApp(store: store));
    await tester.tap(find.byTooltip('Einstellungen'));
    await tester.pumpAndSettle();
    final page = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Katalogpreise importieren'),
      200,
      scrollable: page,
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        '54 von 54 Katalogprodukten haben einen Preis. Importierte Preise '
        'gelten sofort auf allen Geräten.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Katalogpreise importieren'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'SPZ-1\t12.50\nMS-SP-3009\t40\nOXV8-30\t22.50\nXX-1\t5',
    );
    await tester.pump();
    expect(find.text('3 Preise erkannt'), findsOneWidget);
    expect(
      find.text('1 unbekannte Artikelnummern werden ignoriert: XX-1'),
      findsOneWidget,
    );
    await tester.tap(find.text('3 Preise importieren'));
    await tester.pumpAndSettle();
    expect(find.text('3 Preise gespeichert'), findsOneWidget);
    expect(store.savedPartPrice('SPZ-1'), 1250);
    expect(store.savedPartPrice('MS-SP-3009'), 0);
    int priceOf(String sku) =>
        store.catalog.firstWhere((p) => p.sku == sku).priceCents;
    expect(priceOf('MS-SP-3009'), 4000);
    expect(priceOf('MS-SP-2002'), 2250); // by its supplier number OXV8-30
  });

  group('bexio', () {
    test('reads the link written by the Cloud Function', () {
      final now = DateTime.now();
      final done = BexioLink.fromJson({
        'state': 'done',
        'bexioId': 900,
        'number': 'AN-00042',
        'missingArticles': ['MS-SP-2007'],
      });
      expect(done.isDone, isTrue);
      expect(done.bexioId, 900);
      expect(done.missingArticles, ['MS-SP-2007']);
      final running = BexioLink.fromJson({
        'state': 'pending',
        'startedAt': Timestamp.fromDate(now),
      });
      expect(running.isPending, isTrue);
      // An interrupted transfer may be retried after two minutes.
      final stale = BexioLink.fromJson({
        'state': 'pending',
        'startedAt': Timestamp.fromDate(
          now.subtract(const Duration(minutes: 3)),
        ),
      });
      expect(stale.isPending, isFalse);
      expect(
        BexioLink.fromJson({'state': 'failed', 'error': 'Token abgelaufen'})
            .error,
        'Token abgelaufen',
      );
    });

    testWidgets('shows the bexio number in the list and the offer', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final db = FakeFirebaseFirestore();
      final store = await openStore(db);
      // Transactions need real async, outside the test's fake clock.
      final offer = (await tester.runAsync(() async {
        final offer = await store.saveOffer(
          store.newOffer()..customerName = 'Anna Muster',
        );
        await store.saveOffer(store.newOffer()..customerName = 'Ben');
        await db
            .collection('workshops')
            .doc('molenstraat')
            .collection('bexioOffers')
            .doc(offer.id)
            .set({'state': 'done', 'bexioId': 900, 'number': 'AN-00042'});
        await settle();
        return offer;
      }))!;
      expect(store.bexioLink(offer.id)?.number, 'AN-00042');

      await tester.pumpWidget(OffersApp(store: store));
      await tester.pumpAndSettle();
      expect(find.textContaining('bexio AN-00042'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'AN-00042');
      await tester.pumpAndSettle();
      expect(find.text('Anna Muster'), findsOneWidget);
      expect(find.text('Ben'), findsNothing);

      await tester.tap(find.text('Anna Muster'));
      await tester.pumpAndSettle();
      expect(find.text('bexio AN-00042'), findsOneWidget);
      expect(
        find.text('Änderungen hier werden nicht nach bexio übertragen.'),
        findsOneWidget,
      );
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('bexio-Nr. kopieren'), findsOneWidget);
    });

    testWidgets('offers the transfer for offers not in bexio yet', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final store = await openStore(FakeFirebaseFirestore());
      await tester.pumpWidget(OffersApp(store: store));
      await tester.tap(find.text('Neues Angebot'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('In bexio anlegen'));
      await tester.pumpAndSettle();
      // Saved first, then stopped before bexio: no customer yet.
      expect(store.offers, hasLength(1));
      expect(
        find.text('Bitte zuerst den Namen des Kunden eingeben.'),
        findsOneWidget,
      );
      expect(find.text('In bexio anlegen?'), findsNothing);
    });
  });
}
