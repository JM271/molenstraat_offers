import 'models.dart';

/// Formats cents Swiss style: `CHF 1'234.50`.
String formatMoney(int cents, [String currency = 'CHF']) {
  final negative = cents < 0;
  final abs = cents.abs();
  final whole = (abs ~/ 100).toString();
  final buffer = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buffer.write("'");
    buffer.write(whole[i]);
  }
  final fraction = (abs % 100).toString().padLeft(2, '0');
  final amount = '${negative ? '-' : ''}$buffer.$fraction';
  return currency.isEmpty ? amount : '$currency $amount';
}

/// Parses user input such as `12`, `12.5`, `12,50`, `12.-` or `1'234.50`
/// into cents. Returns null for anything that is not a non-negative amount.
int? parseMoney(String input) {
  var text = input.trim().replaceAll("'", '').replaceAll('’', '');
  text = text.replaceAll(RegExp(r'^(CHF|EUR|€)\s*', caseSensitive: false), '');
  if (text.endsWith('.-') || text.endsWith(',-')) {
    text = text.substring(0, text.length - 2);
  }
  text = text.replaceAll(',', '.');
  if (text.isEmpty || !RegExp(r'^\d+(\.\d{0,2})?$').hasMatch(text)) {
    return null;
  }
  final parts = text.split('.');
  final whole = int.parse(parts[0]);
  final fraction = parts.length > 1 ? parts[1].padRight(2, '0') : '00';
  return whole * 100 + int.parse(fraction.isEmpty ? '00' : fraction);
}

/// Parses a positive quantity, accepting a decimal comma.
double? parseQuantity(String input) {
  final value = double.tryParse(input.trim().replaceAll(',', '.'));
  if (value == null || value <= 0 || value.isNaN || value.isInfinite) {
    return null;
  }
  return value;
}

String formatQuantity(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String formatLineQuantity(OfferLine line) => line.kind == LineKind.labour
    ? formatLabour(line.quantity)
    : '${formatQuantity(line.quantity)} Stk.';

/// Labour time for display: `20 Min.`, `2 Std.`, `1.5 Std.` or `1:20 Std.`.
/// Avoids showing rounded decimals such as 0.33 h that do not multiply out.
String formatLabour(double hours) {
  final minutes = (hours * 60).round();
  if ((hours * 60 - minutes).abs() > 0.01) {
    return '${formatQuantity(hours)} Std.';
  }
  if (minutes < 60) return '$minutes Min.';
  if (minutes % 15 == 0) return '${formatQuantity(minutes / 60)} Std.';
  return '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')} Std.';
}

String formatDate(DateTime date) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(date.day)}.${two(date.month)}.${date.year}';
}

String formatVatRate(double rate) =>
    rate == rate.roundToDouble() ? rate.toInt().toString() : rate.toString();
