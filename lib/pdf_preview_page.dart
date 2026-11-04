import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'models.dart';
import 'offer_pdf.dart';

/// Full-screen preview of the offer PDF with print and share actions.
/// Pops with true if the PDF was shared.
class OfferPdfPreviewPage extends StatefulWidget {
  const OfferPdfPreviewPage({
    super.key,
    required this.offer,
    required this.settings,
  });

  final Offer offer;
  final ShopSettings settings;

  @override
  State<OfferPdfPreviewPage> createState() => _OfferPdfPreviewPageState();
}

class _OfferPdfPreviewPageState extends State<OfferPdfPreviewPage> {
  bool _shared = false;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) Navigator.of(context).pop(_shared);
    },
    child: Scaffold(
      appBar: AppBar(title: Text('Vorschau ${widget.offer.number}')),
      body: PdfPreview(
        build: (_) => buildOfferPdf(widget.offer, widget.settings),
        pdfFileName: offerFileName(widget.offer),
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        onShared: (_) => _shared = true,
        onError: (_, _) => const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Die PDF-Vorschau konnte nicht geladen werden. Im Browser '
              'braucht sie eine Internetverbindung. „PDF teilen“ funktioniert '
              'trotzdem.',
            ),
          ),
        ),
      ),
    ),
  );
}
