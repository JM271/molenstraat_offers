import 'package:flutter/services.dart';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'brand.dart';
import 'format.dart';
import 'models.dart';

final _ink = PdfColor.fromHex('#111111');
final _grey = PdfColor.fromHex('#666666');

String offerFileName(Offer offer) =>
    'Reparaturangebot_${offer.number}.pdf'.replaceAll(RegExp(r'[^\w.-]'), '_');

/// Plain-text version of the offer, for pasting into messages or e-mails.
String offerText(Offer offer, ShopSettings settings) {
  final totals = computeTotals(
    offer.lines,
    vatRate: settings.vatRate,
    pricesIncludeVat: settings.pricesIncludeVat,
  );
  String money(int cents) => formatMoney(cents, settings.currency);
  final b = StringBuffer()
    ..writeln('${settings.companyName} – Reparaturangebot ${offer.number}')
    ..writeln('Datum: ${formatDate(offer.createdAt)}')
    ..writeln('Gültig bis: ${formatDate(offer.validUntil)}');
  if (offer.customerName.isNotEmpty) b.writeln('Kunde: ${offer.customerName}');
  final bike = [
    offer.bikeModel,
    if (offer.frameNumber.isNotEmpty) 'Rahmen-Nr. ${offer.frameNumber}',
  ].where((s) => s.isNotEmpty).join(', ');
  if (bike.isNotEmpty) b.writeln('Fahrrad: $bike');
  if (offer.problem.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Befund: ${offer.problem}');
  }
  b.writeln();
  for (final line in offer.lines) {
    b.writeln(
      '- ${line.description}'
      '${line.sku.isEmpty ? '' : ' (Art.-Nr. ${line.sku})'}: '
      '${formatLineQuantity(line)} × '
      '${money(line.unitPriceCents)} = ${money(line.totalCents)}',
    );
  }
  b.writeln();
  if (totals.vatRate > 0 && !totals.pricesIncludeVat) {
    b
      ..writeln('Zwischensumme: ${money(totals.linesCents)}')
      ..writeln(
        'MwSt ${formatVatRate(totals.vatRate)}%: ${money(totals.vatCents)}',
      );
  }
  b.writeln('Total: ${money(totals.totalCents)}');
  if (totals.vatRate > 0 && totals.pricesIncludeVat) {
    b.writeln(
      'inkl. ${formatVatRate(totals.vatRate)}% MwSt: ${money(totals.vatCents)}',
    );
  }
  if (offer.notes.isNotEmpty) {
    b
      ..writeln()
      ..writeln(offer.notes);
  }
  if (settings.footer.isNotEmpty) {
    b
      ..writeln()
      ..writeln(settings.footer);
  }
  return b.toString().trimRight();
}

Future<Uint8List> buildOfferPdf(Offer offer, ShopSettings settings) async {
  final totals = computeTotals(
    offer.lines,
    vatRate: settings.vatRate,
    pricesIncludeVat: settings.pricesIncludeVat,
  );
  String money(int cents) => formatMoney(cents, settings.currency);
  final logo = pw.MemoryImage(
    (await rootBundle.load(logoAsset)).buffer.asUint8List(),
  );
  // The logo already reads "Molenstraat Fatbikes"; only a different company
  // name (e.g. the legal entity) is printed underneath.
  final showCompanyName =
      settings.companyName.trim().isNotEmpty &&
      settings.companyName.trim().toLowerCase() != 'molenstraat fatbikes';
  // Noto Sans covers umlauts, €, dashes and typographic quotes, which the
  // built-in PDF fonts cannot render.
  final doc = pw.Document(
    title: 'Reparaturangebot ${offer.number}',
    author: settings.companyName,
    theme: pw.ThemeData.withFont(
      base: pw.Font.ttf(
        await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
      ),
      bold: pw.Font.ttf(
        await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'),
      ),
    ),
  );

  pw.Widget label(String text) => pw.Text(
    text.toUpperCase(),
    style: pw.TextStyle(fontSize: 8, color: _grey, letterSpacing: 0.6),
  );

  pw.Widget infoBlock(String title, List<String> rows) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      label(title),
      pw.SizedBox(height: 3),
      for (final row in rows.where((r) => r.trim().isNotEmpty))
        pw.Text(row, style: const pw.TextStyle(fontSize: 10)),
    ],
  );

  pw.Widget sumRow(String name, String value, {bool bold = false}) => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.end,
    children: [
      pw.SizedBox(
        width: 160,
        child: pw.Text(
          name,
          style: pw.TextStyle(
            fontSize: bold ? 12 : 10,
            fontWeight: bold ? pw.FontWeight.bold : null,
          ),
        ),
      ),
      pw.SizedBox(
        width: 100,
        child: pw.Text(
          value,
          textAlign: pw.TextAlign.right,
          style: pw.TextStyle(
            fontSize: bold ? 12 : 10,
            fontWeight: bold ? pw.FontWeight.bold : null,
          ),
        ),
      ),
    ],
  );

  final cellStyle = const pw.TextStyle(fontSize: 9.5);
  final headerStyle = pw.TextStyle(
    fontSize: 9,
    fontWeight: pw.FontWeight.bold,
    color: PdfColors.white,
  );

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 36),
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          '${offer.number} · Seite ${context.pageNumber}/${context.pagesCount}',
          style: pw.TextStyle(fontSize: 8, color: _grey),
        ),
      ),
      build: (context) => [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Image(logo, height: 30),
                  pw.SizedBox(height: 8),
                  if (showCompanyName)
                    pw.Text(
                      settings.companyName,
                      style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  for (final row in [
                    ...settings.address.split('\n'),
                    settings.phone,
                    settings.email,
                  ].where((r) => r.trim().isNotEmpty))
                    pw.Text(
                      row,
                      style: pw.TextStyle(fontSize: 9, color: _grey),
                    ),
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  'Reparaturangebot',
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  'Nr. ${offer.number}',
                  style: const pw.TextStyle(fontSize: 10),
                ),
                pw.Text(
                  'Datum: ${formatDate(offer.createdAt)}',
                  style: const pw.TextStyle(fontSize: 10),
                ),
                pw.Text(
                  'Gültig bis: ${formatDate(offer.validUntil)}',
                  style: const pw.TextStyle(fontSize: 10),
                ),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 14),
        pw.Divider(color: _ink, thickness: 1.2),
        pw.SizedBox(height: 10),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: infoBlock('Kunde', [
                offer.customerName,
                offer.customerPhone,
                offer.customerEmail,
              ]),
            ),
            pw.Expanded(
              child: infoBlock('Fahrrad', [
                offer.bikeModel,
                if (offer.frameNumber.isNotEmpty)
                  'Rahmen-Nr. ${offer.frameNumber}',
              ]),
            ),
          ],
        ),
        if (offer.problem.trim().isNotEmpty) ...[
          pw.SizedBox(height: 12),
          infoBlock('Befund / Auftrag', [offer.problem]),
        ],
        pw.SizedBox(height: 16),
        pw.TableHelper.fromTextArray(
          headers: ['Pos.', 'Beschreibung', 'Menge', 'Einzelpreis', 'Betrag'],
          data: [
            for (var i = 0; i < offer.lines.length; i++)
              [
                '${i + 1}',
                '${offer.lines[i].kind.label}: ${offer.lines[i].description}'
                    '${offer.lines[i].sku.isEmpty ? '' : '\nArt.-Nr. ${offer.lines[i].sku}'}',
                formatLineQuantity(offer.lines[i]),
                money(offer.lines[i].unitPriceCents),
                money(offer.lines[i].totalCents),
              ],
          ],
          headerStyle: headerStyle,
          headerDecoration: pw.BoxDecoration(color: _ink),
          cellStyle: cellStyle,
          cellPadding: const pw.EdgeInsets.symmetric(
            horizontal: 5,
            vertical: 4,
          ),
          columnWidths: {
            0: const pw.FixedColumnWidth(28),
            1: const pw.FlexColumnWidth(),
            2: const pw.FixedColumnWidth(52),
            3: const pw.FixedColumnWidth(76),
            4: const pw.FixedColumnWidth(76),
          },
          cellAlignments: {
            0: pw.Alignment.centerLeft,
            1: pw.Alignment.centerLeft,
            2: pw.Alignment.centerRight,
            3: pw.Alignment.centerRight,
            4: pw.Alignment.centerRight,
          },
          border: null,
          rowDecoration: const pw.BoxDecoration(
            border: pw.Border(
              bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
            ),
          ),
        ),
        pw.SizedBox(height: 10),
        if (totals.partsCents > 0 && totals.labourCents > 0) ...[
          sumRow('Material', money(totals.partsCents)),
          sumRow('Arbeit', money(totals.labourCents)),
        ],
        if (totals.vatRate > 0 && !totals.pricesIncludeVat) ...[
          sumRow('Zwischensumme', money(totals.linesCents)),
          sumRow(
            'MwSt ${formatVatRate(totals.vatRate)}%',
            money(totals.vatCents),
          ),
        ],
        pw.SizedBox(height: 4),
        sumRow('Total', money(totals.totalCents), bold: true),
        if (totals.vatRate > 0 && totals.pricesIncludeVat)
          sumRow(
            'inkl. ${formatVatRate(totals.vatRate)}% MwSt',
            money(totals.vatCents),
          ),
        if (offer.notes.trim().isNotEmpty) ...[
          pw.SizedBox(height: 16),
          infoBlock('Bemerkungen', [offer.notes]),
        ],
        if (settings.footer.trim().isNotEmpty) ...[
          pw.SizedBox(height: 16),
          pw.Text(
            settings.footer,
            style: pw.TextStyle(fontSize: 9, color: _grey),
          ),
        ],
        pw.SizedBox(height: 36),
        pw.Row(
          children: [
            pw.Expanded(child: _signatureLine('Ort, Datum')),
            pw.SizedBox(width: 30),
            pw.Expanded(
              child: _signatureLine('Auftrag erteilt (Unterschrift)'),
            ),
          ],
        ),
      ],
    ),
  );
  return doc.save();
}

pw.Widget _signatureLine(String caption) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.start,
  children: [
    pw.Container(height: 0.6, color: PdfColors.grey600),
    pw.SizedBox(height: 3),
    pw.Text(caption, style: pw.TextStyle(fontSize: 8, color: _grey)),
  ],
);
