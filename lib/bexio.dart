import 'package:cloud_firestore/cloud_firestore.dart';

/// Link between an offer and its quote in bexio, written only by the Cloud
/// Function `createBexioOffer` (`functions/`) to
/// `workshops/molenstraat/bexioOffers/{offerId}`.
class BexioLink {
  const BexioLink({
    required this.state,
    this.bexioId,
    this.number = '',
    this.error = '',
    this.missingArticles = const [],
    this.startedAt,
  });

  /// `pending`, `done` or `failed`.
  final String state;
  final int? bexioId;

  /// bexio document number, e.g. `AN-00042`.
  final String number;

  /// Message for the user when the last transfer failed.
  final String error;

  /// SKUs of the offer that bexio has no item for; they went over as free
  /// positions.
  final List<String> missingArticles;
  final DateTime? startedAt;

  bool get isDone => state == 'done';
  bool get isFailed => state == 'failed';

  /// A transfer that started less than two minutes ago and has not finished.
  /// Older ones were interrupted and may be retried, as in the function.
  bool get isPending =>
      state == 'pending' &&
      startedAt != null &&
      DateTime.now().difference(startedAt!) < const Duration(minutes: 2);

  factory BexioLink.fromJson(Map<String, dynamic> json) => BexioLink(
    state: json['state'] as String? ?? '',
    bexioId: (json['bexioId'] as num?)?.toInt(),
    number: json['number'] as String? ?? '',
    error: json['error'] as String? ?? '',
    missingArticles: [
      for (final sku in (json['missingArticles'] as List? ?? const []))
        if (sku is String) sku,
    ],
    startedAt: (json['startedAt'] as Timestamp?)?.toDate(),
  );
}

/// What the function returned for a transfer.
class BexioTransfer {
  const BexioTransfer({
    required this.number,
    this.existing = false,
    this.missingArticles = const [],
  });

  final String number;

  /// True if the offer had been transferred before.
  final bool existing;
  final List<String> missingArticles;

  factory BexioTransfer.fromJson(Map<String, dynamic> json) => BexioTransfer(
    number: json['number'] as String? ?? '',
    existing: json['existing'] as bool? ?? false,
    missingArticles: [
      for (final sku in (json['missingArticles'] as List? ?? const []))
        if (sku is String) sku,
    ],
  );
}
