# Molenstraat Reparaturangebote

Flutter app for writing repair offers (Reparaturangebote) for Molenstraat Fatbikes customers. Android, iPhone and browser from one project.

## Features

- **Angebote**: list of all offers with search (customer, number, frame number, bike, finding) and a status filter: Entwurf, Gesendet, Angenommen, Abgelehnt. Sent offers past their validity date show as *abgelaufen*.
- **Angebot erfassen**: customer, bike model and frame number, finding / customer request, line items, notes and validity date. Offer numbers run per year (`A-2026-001`, …) and are never reused, even after deleting.
- **Positionen**: pick common repairs from the price list (each adds its labour and part lines), or add parts (pieces × price) and labour (minutes × hourly rate) individually. Lines without a price are flagged in red.
- **Totals**: material, labour, total, VAT included or added (configurable).
- **Output**: share the offer as a PDF (A4, with a signature line for the job order), print it or preview it, or copy it as text for WhatsApp/e-mail. Sharing a draft offers to mark it as *Gesendet*.
- **Preisliste**: editable list of repairs with labour minutes and an optional part with price. It starts with typical fatbike repairs. The **labour times are rough estimates and part prices are empty**: adjust both to the workshop before use.
- **Einstellungen**: company name, address, phone, e-mail, hourly rate, VAT rate (default 8.1 %, prices incl. VAT), currency (CHF), validity in days, footer note in the offer.

Data stays on the device (`shared_preferences`); there is no account or cloud sync. Uninstalling the app or clearing its data deletes all offers.

## Run

```sh
flutter pub get
flutter run                 # connected phone
flutter run -d chrome       # browser
```

Before the first offer, open **Einstellungen** and enter the address and hourly rate. Then open **Preisliste** and fill in your times and part prices.

## Development

| File | Content |
| --- | --- |
| `lib/main.dart` | App, offer list |
| `lib/offer_page.dart` | Offer editor |
| `lib/dialogs.dart` | Line, price list and confirmation dialogs |
| `lib/models.dart` | Offer, lines, totals/VAT, price list, settings |
| `lib/offer_store.dart` | Local storage and offer numbering |
| `lib/offer_pdf.dart` | PDF and text export |
| `lib/format.dart` | Money (`CHF 1'234.50`), date and quantity formats |

Amounts are stored as whole Rappen (`int`) to avoid rounding errors. The PDF uses the bundled Noto Sans font (`assets/fonts`, SIL Open Font License) so umlauts, € and typographic quotes render.

```sh
flutter analyze
flutter test
```
