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
  labour('Arbeit');

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
  });

  final LineKind kind;
  final String description;

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
  }) => OfferLine(
    kind: kind ?? this.kind,
    description: description ?? this.description,
    quantity: quantity ?? this.quantity,
    unitPriceCents: unitPriceCents ?? this.unitPriceCents,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'description': description,
    'quantity': quantity,
    'unitPriceCents': unitPriceCents,
  };

  factory OfferLine.fromJson(Map<String, dynamic> json) => OfferLine(
    kind: LineKind.parse(json['kind'] as String?),
    description: json['description'] as String? ?? '',
    quantity: (json['quantity'] as num?)?.toDouble() ?? 1,
    unitPriceCents: (json['unitPriceCents'] as num?)?.toInt() ?? 0,
  );
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
    if (line.kind == LineKind.labour) {
      labour += line.totalCents;
    } else {
      parts += line.totalCents;
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
  final String number;
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

/// A reusable repair from the price list: estimated labour plus an optional
/// part. Adding it to an offer creates one labour line and, if [partName] is
/// set, one part line.
class RepairPreset {
  RepairPreset({
    required this.id,
    required this.name,
    this.labourMinutes = 0,
    this.partName = '',
    this.partPriceCents = 0,
  });

  final String id;
  final String name;
  final int labourMinutes;
  final String partName;
  final int partPriceCents;

  List<OfferLine> toLines(int hourlyRateCents) => [
    if (labourMinutes > 0)
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
    'partName': partName,
    'partPriceCents': partPriceCents,
  };

  factory RepairPreset.fromJson(Map<String, dynamic> json) => RepairPreset(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    labourMinutes: (json['labourMinutes'] as num?)?.toInt() ?? 0,
    partName: json['partName'] as String? ?? '',
    partPriceCents: (json['partPriceCents'] as num?)?.toInt() ?? 0,
  );
}

/// Starter price list. Labour times are rough workshop estimates and part
/// prices are left at 0 so they get filled in from real supplier prices.
List<RepairPreset> defaultPresets() {
  var i = 0;
  RepairPreset p(String name, int minutes, [String part = '']) => RepairPreset(
    id: 'preset-${i++}',
    name: name,
    labourMinutes: minutes,
    partName: part,
  );
  return [
    p('Platten beheben, Schlauch ersetzen', 30, 'Fatbike-Schlauch'),
    p('Reifen ersetzen', 30, 'Fatbike-Reifen'),
    p('Bremsbeläge ersetzen (pro Rad)', 20, 'Bremsbeläge'),
    p('Bremsscheibe ersetzen', 15, 'Bremsscheibe'),
    p('Bremse entlüften', 30),
    p('Kette ersetzen', 15, 'Kette'),
    p('Schaltung einstellen', 20),
    p('Schaltzug ersetzen', 30, 'Schaltzug'),
    p('Speiche ersetzen', 30, 'Speiche'),
    p('Laufrad zentrieren', 30),
    p('Licht reparieren', 30),
    p('Elektrik-/Akku-Diagnose', 30),
    p('Service komplett', 90),
  ];
}

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
