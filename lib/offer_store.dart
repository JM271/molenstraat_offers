import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Keeps offers, the repair price list and shop settings on the device.
class OfferStore extends ChangeNotifier {
  OfferStore._(this._prefs);

  static const _offersKey = 'offers_v1';
  static const _settingsKey = 'settings_v1';
  static const _presetsKey = 'presets_v1';
  static const _counterKey = 'offer_counter_v1';
  static const _partPricesKey = 'part_prices_v1';

  final SharedPreferences _prefs;
  final List<Offer> _offers = [];
  final List<RepairPreset> _presets = [];
  final Map<String, int> _partPrices = {};
  ShopSettings _settings = const ShopSettings();

  static Future<OfferStore> load() async {
    final store = OfferStore._(await SharedPreferences.getInstance());
    store._read();
    return store;
  }

  List<Offer> get offers => List.unmodifiable(_offers);
  List<RepairPreset> get presets => List.unmodifiable(_presets);
  ShopSettings get settings => _settings;

  /// Price the user set for a catalog part instead of the catalog price,
  /// 0 if there is none.
  int partPriceOverride(String sku) => _partPrices[sku] ?? 0;

  /// Price to offer for a catalog part: the user's own price if set,
  /// otherwise the catalog price.
  int priceFor(CatalogProduct product) {
    final own = partPriceOverride(product.sku);
    return own > 0 ? own : product.priceCents;
  }

  void _read() {
    final offers = _prefs.getString(_offersKey);
    if (offers != null) {
      _offers.addAll(
        (jsonDecode(offers) as List).map(
          (row) => Offer.fromJson(Map<String, dynamic>.from(row as Map)),
        ),
      );
    }
    final settings = _prefs.getString(_settingsKey);
    if (settings != null) {
      _settings = ShopSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(settings) as Map),
      );
    }
    final presets = _prefs.getString(_presetsKey);
    _presets.addAll(
      presets == null
          ? defaultPresets()
          : (jsonDecode(presets) as List).map(
              (row) =>
                  RepairPreset.fromJson(Map<String, dynamic>.from(row as Map)),
            ),
    );
    final partPrices = _prefs.getString(_partPricesKey);
    if (partPrices != null) {
      _partPrices.addAll(
        Map<String, dynamic>.from(jsonDecode(partPrices) as Map)
            .map((k, v) => MapEntry(k, (v as num).toInt())),
      );
    }
    _sortOffers();
  }

  void _sortOffers() =>
      _offers.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Creates an unsaved offer with the next number, e.g. `A-2026-007`.
  /// The number is only reserved once the offer is saved.
  Offer newOffer({DateTime? now}) {
    final date = now ?? DateTime.now();
    final counters = _counters();
    final next = (counters['${date.year}'] ?? 0) + 1;
    return Offer(
      id: '${date.microsecondsSinceEpoch}',
      number: 'A-${date.year}-${next.toString().padLeft(3, '0')}',
      createdAt: date,
      validUntil: DateTime(
        date.year,
        date.month,
        date.day,
      ).add(Duration(days: _settings.validityDays)),
    );
  }

  Map<String, int> _counters() {
    final raw = _prefs.getString(_counterKey);
    if (raw == null) return {};
    return Map<String, dynamic>.from(jsonDecode(raw) as Map)
        .map((k, v) => MapEntry(k, (v as num).toInt()));
  }

  Future<void> saveOffer(Offer offer) async {
    final index = _offers.indexWhere((o) => o.id == offer.id);
    if (index >= 0) {
      _offers[index] = offer;
    } else {
      _offers.add(offer);
      final counters = _counters();
      final year = '${offer.createdAt.year}';
      final used = int.tryParse(offer.number.split('-').last) ?? 0;
      if (used > (counters[year] ?? 0)) {
        counters[year] = used;
        await _prefs.setString(_counterKey, jsonEncode(counters));
      }
    }
    _sortOffers();
    await _writeOffers();
    notifyListeners();
  }

  Future<void> deleteOffer(String id) async {
    _offers.removeWhere((o) => o.id == id);
    await _writeOffers();
    notifyListeners();
  }

  Future<void> _writeOffers() => _prefs.setString(
    _offersKey,
    jsonEncode(_offers.map((o) => o.toJson()).toList()),
  );

  Future<void> saveSettings(ShopSettings settings) async {
    _settings = settings;
    await _prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
    notifyListeners();
  }

  Future<void> savePreset(RepairPreset preset) async {
    final index = _presets.indexWhere((p) => p.id == preset.id);
    if (index >= 0) {
      _presets[index] = preset;
    } else {
      _presets.add(preset);
    }
    await _writePresets();
    notifyListeners();
  }

  Future<void> deletePreset(String id) async {
    _presets.removeWhere((p) => p.id == id);
    await _writePresets();
    notifyListeners();
  }

  Future<void> _writePresets() => _prefs.setString(
    _presetsKey,
    jsonEncode(_presets.map((p) => p.toJson()).toList()),
  );

  /// Remembers prices of catalog parts that differ from the catalog, so the
  /// next offer fills them in. A price equal to the catalog price clears the
  /// override, so a later catalog update takes effect. Lines without SKU or
  /// without price are ignored.
  Future<void> rememberPartPrices(
    Iterable<OfferLine> lines, {
    required int Function(String sku) catalogPriceOf,
  }) async {
    var changed = false;
    for (final line in lines) {
      if (line.kind != LineKind.part || line.sku.isEmpty) continue;
      final price = line.unitPriceCents;
      if (price <= 0) continue;
      if (price == catalogPriceOf(line.sku)) {
        changed |= _partPrices.remove(line.sku) != null;
      } else if (_partPrices[line.sku] != price) {
        _partPrices[line.sku] = price;
        changed = true;
      }
    }
    if (!changed) return;
    await _prefs.setString(_partPricesKey, jsonEncode(_partPrices));
    notifyListeners();
  }
}
