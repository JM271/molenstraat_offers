import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';

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

  test('price list starts with flagged demo part prices', () {
    final presets = defaultPresets();
    final withPart = presets.where((p) => p.partName.isNotEmpty);
    expect(withPart, isNotEmpty);
    expect(withPart.every((p) => p.partPriceCents > 0 && p.demoPrice), isTrue);
    expect(presets.where((p) => p.partName.isEmpty && p.demoPrice), isEmpty);
    final chain = presets.firstWhere((p) => p.partName == 'Kette');
    expect(RepairPreset.fromJson(chain.toJson()).demoPrice, isTrue);
    expect(presetSummary(chain, 9000, 'CHF'), contains('CHF 24.90 (Demo)'));
    // An edited entry (saved without the flag) counts as checked.
    final edited = RepairPreset.fromJson(
      {...chain.toJson()}..remove('demoPrice'),
    );
    expect(presetSummary(edited, 9000, 'CHF'), isNot(contains('Demo')));
  });

  test('flat rates from the price list count as work', () {
    final flats = defaultPresets().where((p) => p.isFlat).toList();
    expect(flats.map((p) => p.flatPriceCents), [3000, 5000, 10000, 15000]);
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
      expect(products, hasLength(243));
      expect(products.map((p) => p.sku).toSet(), hasLength(products.length));
      expect(catalogCategories(products), contains('Brakes'));
      for (final p in products.where((p) => p.imageAsset.isNotEmpty)) {
        final data = await rootBundle.load(p.imageAsset);
        expect(data.lengthInBytes, greaterThan(0), reason: p.imageAsset);
      }
      // Every part has a (for now: demo) price.
      expect(products.where((p) => p.priceCents <= 0), isEmpty);
      final mirror = products.firstWhere((p) => p.sku == 'RF-M09');
      expect(mirror.priceCents, 2490);
      expect(mirror.demoPrice, isTrue);
      expect(mirror.matches('rf-m'), isTrue);
      expect(mirror.matches('mirror'), isTrue);
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

    test('prices in the database replace demo prices', () async {
      final db = FakeFirebaseFirestore();
      final store = await openStore(db);
      const lock = CatalogProduct(
        sku: 'OXV8-01E',
        name: 'V8 battery lock',
        category: 'Electrics',
        priceCents: 1990,
        demoPrice: true,
      );
      const mirror = CatalogProduct(
        sku: 'RF-M09',
        name: 'Mirror',
        category: 'Cockpit',
        priceCents: 2490,
        demoPrice: true,
      );
      int catalogPriceOf(String sku) => switch (sku) {
        'OXV8-01E' => 1990,
        'RF-M09' => 2490,
        _ => 0,
      };
      OfferLine part(String sku, int cents) => OfferLine(
        kind: LineKind.part,
        description: sku,
        quantity: 1,
        unitPriceCents: cents,
        sku: sku,
      );
      expect(store.priceFor(lock), 1990);
      expect(store.isDemoPrice(lock), isTrue);

      await store.rememberPartPrices([
        part('OXV8-01E', 1500), // changed: saved for everyone
        part('RF-M09', 2490), // unchanged demo price: stays demo
        OfferLine(
          kind: LineKind.part,
          description: 'Kette',
          quantity: 1,
          unitPriceCents: 3000,
        ),
      ], catalogPriceOf: catalogPriceOf);
      final other = await openStore(db, uid: 'u2');
      expect(other.priceFor(lock), 1500);
      expect(other.isDemoPrice(lock), isFalse);
      expect(other.savedPartPrice('RF-M09'), 0);
      expect(other.isDemoPrice(mirror), isTrue);

      // An imported price list applies on every device at once.
      expect(
        await other.importPartPrices({'rf-m09': 2200, 'OXV8-01E': 1500}),
        1,
      );
      await settle();
      expect(store.priceFor(mirror), 2200);
      expect(store.isDemoPrice(mirror), isFalse);
      expect(store.savedPartPriceCount, 2);

      // A saved price is kept, even if it equals the old demo price.
      await store.rememberPartPrices([
        part('OXV8-01E', 1990),
      ], catalogPriceOf: catalogPriceOf);
      await settle();
      expect(other.savedPartPrice('OXV8-01E'), 1990);
    });

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
    final store = await openStore(FakeFirebaseFirestore());
    await tester.pumpWidget(OffersApp(store: store));

    Future<void> pickMirror() async {
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
      await tester.tap(find.widgetWithText(ChoiceChip, 'Cockpit'));
      await tester.enterText(
        find.widgetWithText(TextField, 'Teil oder Artikelnummer suchen'),
        'rf-m09',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('rearview mirror'));
      await tester.pumpAndSettle();
      expect(find.text('Art.-Nr. RF-M09'), findsOneWidget);
    }

    // The catalog's demo price is filled in and flagged.
    await pickMirror();
    expect(find.widgetWithText(TextFormField, '24.90'), findsOneWidget);
    expect(
      find.text('Demopreis aus dem Katalog, bitte prüfen'),
      findsOneWidget,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Stückpreis (CHF)'),
      '19.90',
    );
    await tester.tap(find.text('Übernehmen'));
    await tester.pumpAndSettle();
    expect(find.text('Art.-Nr. RF-M09 · 1 Stk. × CHF 19.90'), findsOneWidget);
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(store.offers.single.lines.single.sku, 'RF-M09');

    // The next offer fills in the own price, without the demo warning.
    await pickMirror();
    expect(find.widgetWithText(TextFormField, '19.90'), findsOneWidget);
    expect(find.text('Demopreis aus dem Katalog, bitte prüfen'), findsNothing);
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
    final store = await openStore(FakeFirebaseFirestore());
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
        '0 von 243 Katalogteilen haben einen gespeicherten Preis. '
        '243 zeigen noch Demopreise.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Katalogpreise importieren'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'RF-M09\t19.90\nOXV8-30\t22.50\nXX-1\t5',
    );
    await tester.pump();
    expect(find.text('2 Preise erkannt'), findsOneWidget);
    await tester.tap(find.text('2 Preise importieren'));
    await tester.pumpAndSettle();
    expect(find.text('2 Preise gespeichert'), findsOneWidget);
    expect(store.savedPartPrice('RF-M09'), 1990);
    expect(
      find.text(
        '2 von 243 Katalogteilen haben einen gespeicherten Preis. '
        '241 zeigen noch Demopreise.',
      ),
      findsOneWidget,
    );
  });
}
