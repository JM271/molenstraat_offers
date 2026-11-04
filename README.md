# Molenstraat Reparaturangebote

Flutter app for writing repair offers (Reparaturangebote) for Molenstraat Fatbikes customers. Android, iPhone and browser from one project.

## Features

- **Angebote**: list of all offers with search (customer, number, frame number, bike, finding) and a status filter: Entwurf, Gesendet, Angenommen, Abgelehnt. Sent offers past their validity date show as *abgelaufen*.
- **Angebot erfassen**: customer, bike model and frame number, finding / customer request, line items, notes and validity date. Offer numbers run per year (`A-2026-001`, …) and are never reused, even after deleting.
- **Positionen**: pick common repairs from the price list (each adds its labour and part lines), or add parts (pieces × price) and labour (minutes × hourly rate) individually. Lines without a price are flagged in red.
- **Teil aus Katalog**: pick a part from the bundled supplier catalog (243 parts with article number, category and picture). Search by name or article number and filter by category. The catalog price is filled in. **All catalog prices are currently demo prices** (rough estimates, flagged in the picker and the line dialog) until the real prices are delivered. A price you change on an offer is remembered per article number when the offer is saved and used instead of the catalog price; setting it back to the catalog price drops the override. The article number appears on the line, in the PDF and in the text export.
- **Totals**: material, labour, total, VAT included or added (configurable).
- **Output**: share the offer as a PDF (A4, with a signature line for the job order), print it or preview it, or copy it as text for WhatsApp/e-mail. Sharing a draft offers to mark it as *Gesendet*.
- **Preisliste**: editable list of repairs with labour minutes and an optional part with price. It starts with typical fatbike repairs. The **labour times are rough estimates and part prices are empty**: adjust both to the workshop before use.
- **Einstellungen**: company name, address, phone, e-mail, hourly rate, VAT rate (default 8.1 %, prices incl. VAT), currency (CHF), validity in days, footer note in the offer.

## Shared database with the Inventory app

The app uses the same Firebase project as the Inventory app (Spoke), `inventory-molenstraat`, and the same accounts:

- **Sign-in**: e-mail and password, the same account as in Spoke. New accounts need approval by an admin in Spoke (**Kontosymbol → Nutzer verwalten**). Editors and admins can use both apps. User management stays in Spoke.
- **Shared data** under `workshops/molenstraat` in Firestore: `offers`, `offerCounters` (offer numbers per year), `offerConfig/settings`, `offerConfig/presets` (price list) and `partPrices` (own part prices). All approved users see the same offers on every device and in the browser.
- **Offer numbers** are reserved in a transaction on the first save, so two devices never hand out the same number. A new offer shows a provisional number until it is saved. Sharing, printing or copying an offer saves it first.
- **Stock** of the Inventory app (`parts`) is shown in the catalog picker and on part lines (`Lager 3 + 1 Auto`, red if fewer than offered). The offers app never changes stock. Custom catalog products added in Spoke appear in the picker too.
- **Online only**, like Spoke: without a connection, saving fails with a message and nothing is lost on screen. There is no offline cache.

The Firestore rules for these paths live in the **Inventory repository** (`firestore.rules`), because one rule set applies to the whole project. Always deploy the rules from there, from a version that contains the offers section; deploying an older version would lock the offers app out. The Firebase app registrations (Android `com.petehon.molenstraat_offers`, iOS `com.petehon.molenstraatOffers`, web) and their public configuration are in `lib/firebase_config.dart`.

## Run

```sh
flutter pub get
flutter run                 # connected phone
flutter run -d chrome       # browser
```

Sign in with your Spoke account. Before the first offer, open **Einstellungen** and enter the address and hourly rate. Then open **Preisliste** and fill in your times and part prices.

## Development

| File | Content |
| --- | --- |
| `lib/main.dart` | App, offer list |
| `lib/offer_page.dart` | Offer editor |
| `lib/dialogs.dart` | Line, price list and confirmation dialogs |
| `lib/models.dart` | Offer, lines, totals/VAT, price list, settings |
| `lib/offer_store.dart` | Firestore data access, offer numbering, stock |
| `lib/firebase_gate.dart` | Sign-in, approval check, error messages |
| `lib/firebase_config.dart` | Public Firebase app configuration |
| `lib/offer_pdf.dart` | PDF and text export |
| `lib/catalog.dart` | Product catalog loading, catalog picker, thumbnails |
| `lib/brand.dart` | Logo widget and logo asset paths |
| `lib/format.dart` | Money (`CHF 1'234.50`), date and quantity formats |

The logo is in `assets/brand/`: `logo.png` (black, app bar and PDF header), `logo_white.png` (for dark backgrounds) and `wheel.png`. The app icons for Android, iOS and web show the wheel in black on white.

The product catalog lives in `assets/product_catalog.json` (`sku`, `name`, `category`, `imageAsset`, `page`, `priceCents` incl. VAT, `demoPrice`) with pictures in `assets/products/`. Entries with an empty `imageAsset` show a placeholder. For real prices, set `priceCents` and remove `demoPrice` (or set it to `false`). Keep SKUs stable, since remembered prices are keyed by SKU.

Amounts are stored as whole Rappen (`int`) to avoid rounding errors. The PDF uses the bundled Noto Sans font (`assets/fonts`, SIL Open Font License) so umlauts, € and typographic quotes render.

```sh
flutter analyze
flutter test
```
