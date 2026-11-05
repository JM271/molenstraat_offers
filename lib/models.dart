/// Data model for repair offers. Amounts are stored in cents (Rappen) so that
/// totals never suffer from floating point rounding.
library;

enum OfferStatus {
  draft('Entwurf'),
  sent('Gesendet'),
  accepted('Angenommen'),
  declined('Abgelehnt');

  const OfferStatus(this.label);
  final String label;

  static OfferStatus parse(String? name) => OfferStatus.values.firstWhere(
    (s) => s.name == name,
    orElse: () => OfferStatus.draft,
  );
}

enum LineKind {
  part('Teil'),
  labour('Arbeit'),

  /// Work at a fixed price, independent of time and hourly rate.
  flat('Pauschale');

  const LineKind(this.label);
  final String label;

  static LineKind parse(String? name) => LineKind.values.firstWhere(
    (k) => k.name == name,
    orElse: () => LineKind.part,
  );
}

class OfferLine {
  OfferLine({
    required this.kind,
    required this.description,
    required this.quantity,
    required this.unitPriceCents,
    this.sku = '',
  });

  final LineKind kind;
  final String description;

  /// Article number when the part comes from the product catalog.
  final String sku;

  /// Pieces for parts, hours for labour.
  final double quantity;
  final int unitPriceCents;

  int get totalCents => (quantity * unitPriceCents).round();

  bool get missingPrice => unitPriceCents <= 0;

  OfferLine copyWith({
    LineKind? kind,
    String? description,
    double? quantity,
    int? unitPriceCents,
    String? sku,
  }) => OfferLine(
    kind: kind ?? this.kind,
    description: description ?? this.description,
    quantity: quantity ?? this.quantity,
    unitPriceCents: unitPriceCents ?? this.unitPriceCents,
    sku: sku ?? this.sku,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'description': description,
    'quantity': quantity,
    'unitPriceCents': unitPriceCents,
    if (sku.isNotEmpty) 'sku': sku,
  };

  factory OfferLine.fromJson(Map<String, dynamic> json) => OfferLine(
    kind: LineKind.parse(json['kind'] as String?),
    description: json['description'] as String? ?? '',
    quantity: (json['quantity'] as num?)?.toDouble() ?? 1,
    unitPriceCents: (json['unitPriceCents'] as num?)?.toInt() ?? 0,
    sku: json['sku'] as String? ?? '',
  );
}

/// A part from the bundled supplier catalog (`assets/product_catalog.json`).
/// Prices the user enters that differ from [priceCents] are remembered per
/// SKU in the store and take precedence.
class CatalogProduct {
  const CatalogProduct({
    required this.sku,
    required this.name,
    required this.category,
    this.imageAsset = '',
    this.priceCents = 0,
    this.supplierSku = '',
  });

  final String sku;
  final String name;
  final String category;

  /// Empty when the catalog has no picture for this part.
  final String imageAsset;

  /// Sales price incl. VAT from the Molenstraat product list (bexio export),
  /// 0 if the product is not in the list.
  final int priceCents;

  /// Supplier article number of a Molenstraat product (bexio "Code produit
  /// (fournisseur)"), empty if unknown or shared by several products. The
  /// supplier part itself is not listed separately; searching for this
  /// number finds the product, and the Inventory app may keep the product's
  /// stock under it.
  final String supplierSku;

  /// True for products with a price in the Molenstraat product list: it is
  /// the current sales price and wins over stored prices.
  bool get hasListPrice => priceCents > 0;

  factory CatalogProduct.fromJson(Map<String, dynamic> json) => CatalogProduct(
    sku: (json['sku'] as String? ?? '').trim(),
    name: (json['name'] as String? ?? '').trim(),
    category: (json['category'] as String? ?? '').trim(),
    imageAsset: (json['imageAsset'] as String? ?? '').trim(),
    priceCents: (json['priceCents'] as num?)?.toInt() ?? 0,
    supplierSku: (json['supplierSku'] as String? ?? '').trim(),
  );

  /// The product as stored in the shared catalogue (`products`).
  Map<String, dynamic> toJson() => {
    'sku': sku.trim().toUpperCase(),
    'name': name,
    'category': category,
    'supplierSku': supplierSku,
    'imageAsset': imageAsset,
    'priceCents': priceCents,
  };

  CatalogProduct withPrice(int cents) => CatalogProduct(
    sku: sku,
    name: name,
    category: category,
    imageAsset: imageAsset,
    priceCents: cents,
    supplierSku: supplierSku,
  );

  bool matches(String query) {
    final q = query.toLowerCase();
    return sku.toLowerCase().contains(q) ||
        supplierSku.toLowerCase().contains(q) ||
        name.toLowerCase().contains(q);
  }
}

class OfferTotals {
  const OfferTotals({
    required this.partsCents,
    required this.labourCents,
    required this.totalCents,
    required this.vatCents,
    required this.vatRate,
    required this.pricesIncludeVat,
  });

  final int partsCents;
  final int labourCents;

  /// Amount the customer pays.
  final int totalCents;

  /// VAT contained in (or added to) the total.
  final int vatCents;
  final double vatRate;
  final bool pricesIncludeVat;

  /// Sum of the lines before VAT is added (equals [totalCents] when prices
  /// already include VAT).
  int get linesCents => partsCents + labourCents;
}

OfferTotals computeTotals(
  List<OfferLine> lines, {
  required double vatRate,
  required bool pricesIncludeVat,
}) {
  var parts = 0;
  var labour = 0;
  for (final line in lines) {
    // Flat rates are work, so they count as labour.
    if (line.kind == LineKind.part) {
      parts += line.totalCents;
    } else {
      labour += line.totalCents;
    }
  }
  final sum = parts + labour;
  if (vatRate <= 0) {
    return OfferTotals(
      partsCents: parts,
      labourCents: labour,
      totalCents: sum,
      vatCents: 0,
      vatRate: 0,
      pricesIncludeVat: pricesIncludeVat,
    );
  }
  final int vat;
  final int total;
  if (pricesIncludeVat) {
    vat = (sum * vatRate / (100 + vatRate)).round();
    total = sum;
  } else {
    vat = (sum * vatRate / 100).round();
    total = sum + vat;
  }
  return OfferTotals(
    partsCents: parts,
    labourCents: labour,
    totalCents: total,
    vatCents: vat,
    vatRate: vatRate,
    pricesIncludeVat: pricesIncludeVat,
  );
}

class Offer {
  Offer({
    required this.id,
    required this.number,
    required this.createdAt,
    required this.validUntil,
    this.status = OfferStatus.draft,
    this.customerName = '',
    this.customerPhone = '',
    this.customerEmail = '',
    this.bikeModel = '',
    this.frameNumber = '',
    this.problem = '',
    this.notes = '',
    List<OfferLine>? lines,
  }) : lines = lines ?? [];

  final String id;

  /// Provisional until the first save, which reserves the next free number.
  String number;
  final DateTime createdAt;
  DateTime validUntil;
  OfferStatus status;
  String customerName;
  String customerPhone;
  String customerEmail;
  String bikeModel;
  String frameNumber;
  String problem;
  String notes;
  List<OfferLine> lines;

  Offer copy() => Offer.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    'id': id,
    'number': number,
    'createdAt': createdAt.toIso8601String(),
    'validUntil': validUntil.toIso8601String(),
    'status': status.name,
    'customerName': customerName,
    'customerPhone': customerPhone,
    'customerEmail': customerEmail,
    'bikeModel': bikeModel,
    'frameNumber': frameNumber,
    'problem': problem,
    'notes': notes,
    'lines': lines.map((l) => l.toJson()).toList(),
  };

  factory Offer.fromJson(Map<String, dynamic> json) => Offer(
    id: json['id'] as String,
    number: json['number'] as String? ?? '',
    createdAt: DateTime.parse(json['createdAt'] as String),
    validUntil: DateTime.parse(json['validUntil'] as String),
    status: OfferStatus.parse(json['status'] as String?),
    customerName: json['customerName'] as String? ?? '',
    customerPhone: json['customerPhone'] as String? ?? '',
    customerEmail: json['customerEmail'] as String? ?? '',
    bikeModel: json['bikeModel'] as String? ?? '',
    frameNumber: json['frameNumber'] as String? ?? '',
    problem: json['problem'] as String? ?? '',
    notes: json['notes'] as String? ?? '',
    lines: [
      for (final row in (json['lines'] as List? ?? const []))
        OfferLine.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
  );
}

/// A reusable repair from the price list: estimated labour or a flat price,
/// plus an optional part. Adding it to an offer creates one labour line (or
/// one flat-rate line if [flatPriceCents] is set) and, if [partName] is set,
/// one part line.
class RepairPreset {
  RepairPreset({
    required this.id,
    required this.name,
    this.labourMinutes = 0,
    this.flatPriceCents = 0,
    this.partName = '',
    this.partPriceCents = 0,
  });

  final String id;
  final String name;
  final int labourMinutes;

  /// Fixed price for the work; when set, it replaces labour time × rate.
  final int flatPriceCents;
  final String partName;

  /// 0 while the part has no price yet.
  final int partPriceCents;

  bool get isFlat => flatPriceCents > 0;

  List<OfferLine> toLines(int hourlyRateCents) => [
    if (isFlat)
      OfferLine(
        kind: LineKind.flat,
        description: name,
        quantity: 1,
        unitPriceCents: flatPriceCents,
      )
    else if (labourMinutes > 0)
      OfferLine(
        kind: LineKind.labour,
        description: name,
        quantity: labourMinutes / 60,
        unitPriceCents: hourlyRateCents,
      ),
    if (partName.trim().isNotEmpty)
      OfferLine(
        kind: LineKind.part,
        description: partName.trim(),
        quantity: 1,
        unitPriceCents: partPriceCents,
      ),
  ];

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'labourMinutes': labourMinutes,
    if (isFlat) 'flatPriceCents': flatPriceCents,
    'partName': partName,
    'partPriceCents': partPriceCents,
  };

  factory RepairPreset.fromJson(Map<String, dynamic> json) => RepairPreset(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    labourMinutes: (json['labourMinutes'] as num?)?.toInt() ?? 0,
    flatPriceCents: (json['flatPriceCents'] as num?)?.toInt() ?? 0,
    partName: json['partName'] as String? ?? '',
    partPriceCents: (json['partPriceCents'] as num?)?.toInt() ?? 0,
  );
}

/// Starter price list. Labour times are rough workshop estimates. Part
/// prices (CHF incl. VAT) come from the Molenstraat product list; parts not
/// in the list have no price until one is entered.
List<RepairPreset> defaultPresets() {
  var i = 0;
  RepairPreset p(
    String name,
    int minutes, [
    String part = '',
    int partPriceCents = 0,
  ]) => RepairPreset(
    id: 'preset-${i++}',
    name: name,
    labourMinutes: minutes,
    partName: part,
    partPriceCents: partPriceCents,
  );
  return [
    p('Platten beheben, Schlauch ersetzen', 30, 'Fatbike-Schlauch', 2200),
    p('Reifen ersetzen', 30, 'Fatbike-Reifen', 6500),
    p('Bremsbeläge ersetzen (pro Rad)', 20, 'Bremsbeläge (Paar)', 750),
    p('Bremsscheibe ersetzen', 15, 'Bremsscheibe', 990),
    p('Bremse entlüften', 30),
    p('Kette ersetzen', 15, 'Kette', 2500),
    p('Schaltung einstellen', 20),
    p('Schaltzug ersetzen', 30, 'Schaltzug'),
    p('Speiche ersetzen', 30, 'Speiche'),
    p('Laufrad zentrieren', 30),
    p('Licht reparieren', 30),
    p('Elektrik-/Akku-Diagnose', 30),
    p('Service komplett', 90),
    for (final (name, chf) in [
      ('Kleine Reparatur', 30),
      ('Mittlere Reparatur', 50),
      ('Grosse Reparatur', 100),
      ('Umfangreiche Reparatur', 150),
    ])
      RepairPreset(id: 'flat-$chf', name: name, flatPriceCents: chf * 100),
    servicePreset(),
  ];
}

/// Flat rate for a service on site, CHF 150.
RepairPreset servicePreset() => RepairPreset(
  id: 'flat-service',
  name: 'Service Pauschale: inkl. Anfahrtskosten, Montage, Reparatur.',
  flatPriceCents: 15000,
);

/// Part prices of the first starter price list, replaced by the prices of
/// the Molenstraat product list: old part name and demo price → new part
/// name and price.
const _listPricedParts = {
  ('Fatbike-Schlauch', 1490): ('Fatbike-Schlauch', 2200),
  ('Fatbike-Reifen', 5990): ('Fatbike-Reifen', 6500),
  ('Bremsbeläge', 1490): ('Bremsbeläge (Paar)', 750),
  ('Bremsscheibe', 2490): ('Bremsscheibe', 990),
  ('Kette', 2490): ('Kette', 2500),
};

/// Reads a stored price list and drops the demo prices of the first starter
/// price list: parts in the Molenstraat product list get the list price,
/// other demo prices (still flagged `demoPrice`) are removed. Prices
/// entered by hand are kept.
List<RepairPreset> presetsFromStored(List<Object?> items) => [
  for (final row in items)
    _presetFromStored(Map<String, dynamic>.from(row as Map)),
];

/// True if a stored price list still has demo prices that
/// [presetsFromStored] replaces or removes.
bool storedPresetsHaveDemoPrices(List<Object?> items) => items.any((row) {
  final json = Map<String, dynamic>.from(row as Map);
  final p = RepairPreset.fromJson(json);
  return json['demoPrice'] == true ||
      _listPricedParts.containsKey((p.partName, p.partPriceCents));
});

RepairPreset _presetFromStored(Map<String, dynamic> json) {
  final p = RepairPreset.fromJson(json);
  final listed = _listPricedParts[(p.partName, p.partPriceCents)];
  if (listed == null && json['demoPrice'] != true) return p;
  return RepairPreset(
    id: p.id,
    name: p.name,
    labourMinutes: p.labourMinutes,
    flatPriceCents: p.flatPriceCents,
    partName: listed?.$1 ?? p.partName,
    partPriceCents: listed?.$2 ?? 0,
  );
}

/// Molenstraat's usual bike models, offered as quick picks in the editor.
const bikeModels = ['Mooi', 'Dapper Pro', 'Mini MS', 'Storm'];

class ShopSettings {
  const ShopSettings({
    this.companyName = 'Molenstraat Fatbikes',
    this.address = '',
    this.phone = '',
    this.email = '',
    this.hourlyRateCents = 0,
    this.vatRate = 8.1,
    this.pricesIncludeVat = true,
    this.validityDays = 30,
    this.currency = 'CHF',
    this.footer =
        'Dieses Angebot basiert auf einer Sichtprüfung. Zeigen sich bei der '
        'Reparatur weitere Schäden, melden wir uns vor zusätzlichen Arbeiten.',
  });

  final String companyName;
  final String address;
  final String phone;
  final String email;
  final int hourlyRateCents;
  final double vatRate;
  final bool pricesIncludeVat;
  final int validityDays;
  final String currency;
  final String footer;

  bool get isComplete => hourlyRateCents > 0 && address.trim().isNotEmpty;

  ShopSettings copyWith({
    String? companyName,
    String? address,
    String? phone,
    String? email,
    int? hourlyRateCents,
    double? vatRate,
    bool? pricesIncludeVat,
    int? validityDays,
    String? currency,
    String? footer,
  }) => ShopSettings(
    companyName: companyName ?? this.companyName,
    address: address ?? this.address,
    phone: phone ?? this.phone,
    email: email ?? this.email,
    hourlyRateCents: hourlyRateCents ?? this.hourlyRateCents,
    vatRate: vatRate ?? this.vatRate,
    pricesIncludeVat: pricesIncludeVat ?? this.pricesIncludeVat,
    validityDays: validityDays ?? this.validityDays,
    currency: currency ?? this.currency,
    footer: footer ?? this.footer,
  );

  Map<String, dynamic> toJson() => {
    'companyName': companyName,
    'address': address,
    'phone': phone,
    'email': email,
    'hourlyRateCents': hourlyRateCents,
    'vatRate': vatRate,
    'pricesIncludeVat': pricesIncludeVat,
    'validityDays': validityDays,
    'currency': currency,
    'footer': footer,
  };

  factory ShopSettings.fromJson(Map<String, dynamic> json) {
    const d = ShopSettings();
    return ShopSettings(
      companyName: json['companyName'] as String? ?? d.companyName,
      address: json['address'] as String? ?? d.address,
      phone: json['phone'] as String? ?? d.phone,
      email: json['email'] as String? ?? d.email,
      hourlyRateCents:
          (json['hourlyRateCents'] as num?)?.toInt() ?? d.hourlyRateCents,
      vatRate: (json['vatRate'] as num?)?.toDouble() ?? d.vatRate,
      pricesIncludeVat: json['pricesIncludeVat'] as bool? ?? d.pricesIncludeVat,
      validityDays: (json['validityDays'] as num?)?.toInt() ?? d.validityDays,
      currency: json['currency'] as String? ?? d.currency,
      footer: json['footer'] as String? ?? d.footer,
    );
  }
}
