import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';

/// Stock of one SKU in the shared inventory of the Inventory app (Spoke).
class StockLevel {
  const StockLevel({this.workshop = 0, this.car = 0});

  final int workshop;
  final int car;

  int get total => workshop + car;

  StockLevel operator +(StockLevel other) =>
      StockLevel(workshop: workshop + other.workshop, car: car + other.car);
}

String offerNumber(int year, int sequence) =>
    'A-$year-${sequence.toString().padLeft(3, '0')}';

/// Offers, price list, shop settings and own part prices, stored in the
/// Firestore database shared with the Inventory app under
/// `workshops/molenstraat`. That app's stock (`parts`) and custom catalogue
/// products (`catalog`) are only read, never written.
class OfferStore extends ChangeNotifier {
  OfferStore(this.db, this.uid) {
    _listen();
  }

  final FirebaseFirestore db;
  final String uid;

  static const workshopId = 'molenstraat';

  DocumentReference<Map<String, dynamic>> get workshop =>
      db.collection('workshops').doc(workshopId);
  CollectionReference<Map<String, dynamic>> get _offersRef =>
      workshop.collection('offers');
  CollectionReference<Map<String, dynamic>> get _countersRef =>
      workshop.collection('offerCounters');
  DocumentReference<Map<String, dynamic>> get _settingsRef =>
      workshop.collection('offerConfig').doc('settings');
  DocumentReference<Map<String, dynamic>> get _presetsRef =>
      workshop.collection('offerConfig').doc('presets');
  CollectionReference<Map<String, dynamic>> get _partPricesRef =>
      workshop.collection('partPrices');

  final List<Offer> _offers = [];
  List<RepairPreset> _presets = defaultPresets();
  ShopSettings _settings = const ShopSettings();
  final Map<String, int> _partPrices = {};

  /// Inventory parts by document ID, and their IDs by every number they are
  /// known under (SKU, own product number, supplier order number).
  final Map<String, _StockedPart> _stockParts = {};
  final Map<String, Set<String>> _stockPartsByNumber = {};

  /// Supplier number per Molenstraat product SKU, from the catalogue.
  final Map<String, String> _supplierSkus = {};
  final List<CatalogProduct> _customProducts = [];
  final Map<String, int> _lastNumbers = {};

  final _subscriptions = <StreamSubscription<Object?>>[];
  final _waitingFor = <String>{};
  final _loaded = Completer<void>();
  Object? _error;

  List<Offer> get offers => List.unmodifiable(_offers);
  List<RepairPreset> get presets => List.unmodifiable(_presets);
  ShopSettings get settings => _settings;

  /// Products the Inventory app added to the shared catalogue.
  List<CatalogProduct> get customProducts => List.unmodifiable(_customProducts);

  /// True once every collection has delivered its first snapshot.
  bool get isLoaded => _waitingFor.isEmpty;
  Future<void> get loaded => _loaded.future;

  /// Last error of a listener, e.g. missing permission; null when all is well.
  Object? get error => _error;

  /// Encodes any SKU or ID as a safe document ID (same scheme as Inventory).
  static String documentId(String id) =>
      base64Url.encode(utf8.encode(id)).replaceAll('=', '');

  static String _skuKey(String sku) => sku.trim().toUpperCase();

  void _listen() {
    void watch<T>(String name, Stream<T> stream, void Function(T) apply) {
      _waitingFor.add(name);
      _subscriptions.add(
        stream.listen(
          (value) {
            apply(value);
            _error = null;
            if (_waitingFor.remove(name) &&
                _waitingFor.isEmpty &&
                !_loaded.isCompleted) {
              _loaded.complete();
            }
            notifyListeners();
          },
          onError: (Object error) {
            _error = error;
            notifyListeners();
          },
        ),
      );
    }

    watch('offers', _offersRef.snapshots(), (
      QuerySnapshot<Map<String, dynamic>> s,
    ) {
      _offers
        ..clear()
        ..addAll([
          for (final doc in s.docs)
            ?_tryParse(() => Offer.fromJson(doc.data())),
        ])
        ..sort(_newestFirst);
    });
    watch('counters', _countersRef.snapshots(), (
      QuerySnapshot<Map<String, dynamic>> s,
    ) {
      _lastNumbers
        ..clear()
        ..addAll({
          for (final doc in s.docs)
            doc.id: (doc.data()['last'] as num?)?.toInt() ?? 0,
        });
    });
    watch('settings', _settingsRef.snapshots(), (
      DocumentSnapshot<Map<String, dynamic>> s,
    ) {
      final data = s.data();
      _settings = data == null
          ? const ShopSettings()
          : ShopSettings.fromJson(data);
    });
    watch('presets', _presetsRef.snapshots(), (
      DocumentSnapshot<Map<String, dynamic>> s,
    ) {
      _presets = _presetsFrom(s);
    });
    watch('partPrices', _partPricesRef.snapshots(), (
      QuerySnapshot<Map<String, dynamic>> s,
    ) {
      _partPrices
        ..clear()
        ..addAll({
          for (final doc in s.docs)
            if (doc.data()['sku'] case final String sku)
              _skuKey(sku): (doc.data()['priceCents'] as num?)?.toInt() ?? 0,
        });
    });
    watch('parts', workshop.collection('parts').snapshots(), (
      QuerySnapshot<Map<String, dynamic>> s,
    ) {
      _stockParts.clear();
      _stockPartsByNumber.clear();
      for (final doc in s.docs) {
        final data = doc.data();
        String number(String field) =>
            data[field] is String ? _skuKey(data[field] as String) : '';
        final numbers = {
          number('sku'),
          number('productNumber'),
          number('orderNumber'),
        }..remove('');
        if (numbers.isEmpty) continue;
        _stockParts[doc.id] = _StockedPart(
          productNumber: number('productNumber'),
          level: StockLevel(
            workshop: (data['quantity'] as num?)?.toInt() ?? 0,
            car: (data['carQuantity'] as num?)?.toInt() ?? 0,
          ),
        );
        for (final n in numbers) {
          (_stockPartsByNumber[n] ??= {}).add(doc.id);
        }
      }
    });
    watch('catalog', workshop.collection('catalog').snapshots(), (
      QuerySnapshot<Map<String, dynamic>> s,
    ) {
      _customProducts
        ..clear()
        ..addAll([
          for (final doc in s.docs)
            if (_tryParse(() => CatalogProduct.fromJson(doc.data()))
                case final p? when p.sku.isNotEmpty && p.name.isNotEmpty)
              p,
        ]);
    });
  }

  static int _newestFirst(Offer a, Offer b) {
    final byDate = b.createdAt.compareTo(a.createdAt);
    return byDate != 0 ? byDate : b.number.compareTo(a.number);
  }

  static T? _tryParse<T>(T Function() parse) {
    try {
      return parse();
    } catch (_) {
      // Skip malformed documents instead of hiding all others.
      return null;
    }
  }

  static List<RepairPreset> _presetsFrom(
    DocumentSnapshot<Map<String, dynamic>> s,
  ) {
    final items = s.data()?['items'];
    if (items is! List) return defaultPresets();
    return presetsFromStored(items);
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  /// Lets [stockFor] find Molenstraat products that the Inventory app keeps
  /// under their supplier number.
  void useCatalog(Iterable<CatalogProduct> catalog) {
    _supplierSkus
      ..clear()
      ..addAll({
        for (final p in catalog)
          if (p.supplierSku.isNotEmpty) _skuKey(p.sku): _skuKey(p.supplierSku),
      });
    notifyListeners();
  }

  /// Stock of a SKU in the Inventory app, null if it is not stocked there.
  /// A part counts if the SKU is its SKU, own product number or supplier
  /// order number. For a Molenstraat product, parts under its supplier
  /// number count too, unless the Inventory app assigned them to another
  /// product number. Each part counts once.
  StockLevel? stockFor(String sku) {
    final key = _skuKey(sku);
    final ids = {...?_stockPartsByNumber[key]};
    final supplier = _supplierSkus[key];
    if (supplier != null) {
      for (final id in _stockPartsByNumber[supplier] ?? const <String>{}) {
        final assigned = _stockParts[id]!.productNumber;
        if (assigned.isEmpty || assigned == supplier || assigned == key) {
          ids.add(id);
        }
      }
    }
    if (ids.isEmpty) return null;
    return ids.map((id) => _stockParts[id]!.level).reduce((a, b) => a + b);
  }

  /// Creates an unsaved offer. Its number is provisional: saving reserves the
  /// next free number, which may differ if someone else saved one meanwhile.
  Offer newOffer({DateTime? now}) {
    final date = now ?? DateTime.now();
    final next = (_lastNumbers['${date.year}'] ?? 0) + 1;
    return Offer(
      id: '${date.microsecondsSinceEpoch}-${uid.hashCode.toRadixString(36)}',
      number: offerNumber(date.year, next),
      createdAt: date,
      validUntil: DateTime(
        date.year,
        date.month,
        date.day,
      ).add(Duration(days: _settings.validityDays)),
    );
  }

  /// Saves the offer and returns what was stored. A new offer gets the next
  /// number of its year in the same transaction, so numbers are never
  /// handed out twice, even with several devices.
  Future<Offer> saveOffer(Offer offer) {
    final ref = _offersRef.doc(offer.id);
    final counterRef = _countersRef.doc('${offer.createdAt.year}');
    return db.runTransaction((tx) async {
      final existing = await tx.get(ref);
      final saved = offer.copy();
      if (existing.exists) {
        saved.number = existing.data()?['number'] as String? ?? saved.number;
      } else {
        final counter = await tx.get(counterRef);
        final next = ((counter.data()?['last'] as num?)?.toInt() ?? 0) + 1;
        saved.number = offerNumber(offer.createdAt.year, next);
        tx.set(counterRef, {'last': next});
      }
      tx.set(ref, {
        ...saved.toJson(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': uid,
      });
      return saved;
    });
  }

  Future<void> deleteOffer(String id) => _offersRef.doc(id).delete();

  Future<void> saveSettings(ShopSettings settings) =>
      _settingsRef.set(settings.toJson());

  Future<void> savePreset(RepairPreset preset) => _updatePresets((presets) {
    final index = presets.indexWhere((p) => p.id == preset.id);
    if (index >= 0) {
      presets[index] = preset;
    } else {
      presets.add(preset);
    }
  });

  Future<void> deletePreset(String id) =>
      _updatePresets((presets) => presets.removeWhere((p) => p.id == id));

  /// Read-modify-write so concurrent edits on other devices are not lost.
  Future<void> _updatePresets(void Function(List<RepairPreset>) change) =>
      db.runTransaction((tx) async {
        final presets = _presetsFrom(await tx.get(_presetsRef));
        change(presets);
        tx.set(_presetsRef, {
          'items': [for (final p in presets) p.toJson()],
        });
      });

  /// Price of a catalogue part stored in the shared database (imported or
  /// remembered from an offer), 0 if there is none.
  int savedPartPrice(String sku) => _partPrices[_skuKey(sku)] ?? 0;

  /// Number of SKUs with a price in the shared database.
  int get savedPartPriceCount => _partPrices.length;

  /// Price to offer for a catalogue part: the list price of the Molenstraat
  /// product list, otherwise the price in the shared database, 0 if there is
  /// none.
  int priceFor(CatalogProduct product) =>
      product.hasListPrice ? product.priceCents : savedPartPrice(product.sku);

  /// Saves prices of catalogue parts used in an offer to the shared
  /// database, so every device fills them in next time. Parts with a list
  /// price ([hasListPrice]) keep it: a price changed on the offer applies to
  /// that offer only. Lines without SKU or without price are ignored.
  Future<void> rememberPartPrices(
    Iterable<OfferLine> lines, {
    bool Function(String sku) hasListPrice = _never,
  }) => _writePartPrices({
    for (final line in lines)
      if (line.kind == LineKind.part &&
          line.sku.isNotEmpty &&
          line.unitPriceCents > 0 &&
          !hasListPrice(line.sku))
        _skuKey(line.sku): line.unitPriceCents,
  });

  /// Imports a price list (SKU → price in cents) into the shared database.
  /// Returns how many prices changed.
  Future<int> importPartPrices(Map<String, int> prices) => _writePartPrices({
    for (final MapEntry(:key, :value) in prices.entries)
      if (value > 0) _skuKey(key): value,
  });

  static bool _never(String sku) => false;

  /// Writes the prices of the Molenstraat product list into the shared
  /// database: every list product's price in `partPrices`, and a stored
  /// price list without the old demo part prices (see [presetsFromStored])
  /// and with the [servicePreset]. The price list is only updated while it
  /// still has demo prices, so entries deleted later stay deleted.
  /// Only what differs is written, so this is cheap to run on every start.
  /// Returns how many part prices changed.
  Future<int> syncListPrices(Iterable<CatalogProduct> catalog) async {
    await loaded;
    final changed = await _writePartPrices({
      for (final p in catalog)
        if (p.hasListPrice) _skuKey(p.sku): p.priceCents,
    });
    final stored = (await _presetsRef.get()).data()?['items'];
    if (stored is List && storedPresetsHaveDemoPrices(stored)) {
      // _presetsFrom replaces the demo prices; writing back stores that.
      await _updatePresets((presets) {
        final service = servicePreset();
        if (!presets.any((p) => p.id == service.id)) presets.add(service);
      });
    }
    return changed;
  }

  Future<int> _writePartPrices(Map<String, int> prices) async {
    final changed = {
      for (final MapEntry(:key, :value) in prices.entries)
        if (key.isNotEmpty && _partPrices[key] != value) key: value,
    };
    if (changed.isEmpty) return 0;
    // Firestore allows at most 500 writes per batch.
    final entries = changed.entries.toList();
    for (var i = 0; i < entries.length; i += 400) {
      final batch = db.batch();
      for (final e in entries.skip(i).take(400)) {
        batch.set(_partPricesRef.doc(documentId(e.key)), {
          'sku': e.key,
          'priceCents': e.value,
        });
      }
      await batch.commit();
    }
    _partPrices.addAll(changed);
    notifyListeners();
    return changed.length;
  }
}

class _StockedPart {
  const _StockedPart({required this.productNumber, required this.level});

  /// Own product number stored by the Inventory app, empty if none.
  final String productNumber;
  final StockLevel level;
}
