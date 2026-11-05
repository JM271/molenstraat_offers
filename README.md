# Molenstraat Reparaturangebote

Flutter app for writing repair offers (Reparaturangebote) for Molenstraat Fatbikes customers. Android, iPhone and browser from one project.

## Features

- **Angebote**: list of all offers with search (customer, number, frame number, bike, finding) and a status filter: Entwurf, Gesendet, Angenommen, Abgelehnt. Sent offers past their validity date show as *abgelaufen*.
- **Angebot erfassen**: customer, bike model and frame number, finding / customer request, line items, notes and validity date. Offer numbers run per year (`A-2026-001`, …) and are never reused, even after deleting.
- **Positionen**: pick common repairs from the price list (each adds its labour and part lines), or add parts (pieces × price) and labour (minutes × hourly rate) individually. Lines without a price are flagged in red.
- **Teil aus Katalog**: pick a product from the bundled catalog: the Molenstraat product list from bexio (54 products with `MS-…` article numbers: fatbikes, spare parts, accessories, with their sales prices) followed by the supplier catalog (225 more parts with article number, category and picture). Each part is listed once: a supplier part that is a Molenstraat product appears only as that product, and searching for the supplier number finds it. Exception: `OXV8-02` belongs to two products (Controller Dapper and Dapper PRO) and stays listed itself. Search by name or article number and filter by category. The part's price is filled in. Products from the Molenstraat list, and the supplier parts they are bought as, always get their **list price**. The Excel prices are the current prices; there are no demo prices. Other parts get the price stored in the shared database if there is one; otherwise they show *Preis fehlt* and the line dialog asks for a price.
- **Listenpreise in der Datenbank**: on every start the app writes the list prices into the shared database (`partPrices`) where they differ, and, while a stored price list still has the old demo part prices, replaces them (list price or no price) and adds the service flat rate. Only differences are written. A list price changed on an offer applies to that offer only; the import skips list products and says so.
- **Katalogpreise** (Einstellungen): shows how many catalog parts have a list price, a stored price or no price yet, and imports a price list pasted as one article number and price per line (e.g. two columns copied from Excel, or `SKU;Preis`). Imported prices apply on every device immediately, without an app update. A price entered on an offer for a part without list price is stored the same way when the offer is saved. The article number appears on the line, in the PDF and in the text export.
- **Totals**: material, labour, total, VAT included or added (configurable).
- **Output**: share the offer as a PDF (A4, with a signature line for the job order), print it or preview it, or copy it as text for WhatsApp/e-mail. Sharing a draft offers to mark it as *Gesendet*.
- **Preisliste**: editable list of repairs with labour minutes and an optional part with price. It starts with typical fatbike repairs. The **labour times are rough estimates**: adjust them to the workshop before use. Part prices come from the Molenstraat product list where it has the part (tube, tyre, brake pads, brake disc, chain); the others (gear cable, spoke) have no price until one is entered. Flat rates: CHF 30, 50, 100, 150 and *Service Pauschale: inkl. Anfahrtskosten, Montage, Reparatur.* (CHF 150). A stored price list with the old demo prices gets the list prices (or none); prices changed by hand are kept.
- **Einstellungen**: company name, address, phone, e-mail, hourly rate, VAT rate (default 8.1 %, prices incl. VAT), currency (CHF), validity in days, footer note in the offer.

## Shared database with the Inventory app

The app uses the same Firebase project as the Inventory app (Spoke), `inventory-molenstraat`, and the same accounts:

- **Sign-in**: e-mail and password, the same account as in Spoke. New accounts need approval by an admin in Spoke (**Kontosymbol → Nutzer verwalten**). Editors and admins can use both apps. User management stays in Spoke.
- **Shared data** under `workshops/molenstraat` in Firestore: `offers`, `offerCounters` (offer numbers per year), `offerConfig/settings`, `offerConfig/presets` (price list) and `partPrices` (catalog prices per article number, from the import or from offers). All approved users see the same offers on every device and in the browser.
- **Offer numbers** are reserved in a transaction on the first save, so two devices never hand out the same number. A new offer shows a provisional number until it is saved. Sharing, printing or copying an offer saves it first.
- **Stock** of the Inventory app (`parts`) is shown in the catalog picker and on part lines (`Lager 3 + 1 Auto`, red if fewer than offered). A part is found by its `sku`, its own product number (`productNumber`, e.g. `MS-SP-3009`) or its supplier order number (`orderNumber`). A Molenstraat product also finds parts kept under its supplier number (`supplierSku` in the catalog, e.g. `OXV8-05`), unless Inventory assigned them to another product number; each part counts once. `OXV8-02` belongs to two products in bexio and has no supplier link: assign the product number in Spoke. The offers app never changes stock. Custom catalog products added in Spoke appear in the picker too.
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

The product catalog lives in `assets/product_catalog.json` (`sku`, `supplierSku`, `name`, `category`, `imageAsset`, `page` of the supplier catalog, `priceCents` incl. VAT, only for products in the Molenstraat list) with pictures in `assets/products/`. Entries with an empty `imageAsset` show a placeholder. The Molenstraat products come first, taken from a bexio product export (code, name, main group as category, sales price); a product whose supplier code is in the supplier catalog uses that part's picture, and that supplier part is removed from the catalog. List prices win over stored prices and are synced into the database on start (`OfferStore.syncListPrices`); to change one, change it in bexio, export again and update the catalog. All other parts have no bundled price; their price comes from the database (Einstellungen → Katalogpreise importieren, or entered on an offer). Keep SKUs stable, since stored prices are keyed by SKU.

Amounts are stored as whole Rappen (`int`) to avoid rounding errors. The PDF uses the bundled Noto Sans font (`assets/fonts`, SIL Open Font License) so umlauts, € and typographic quotes render.

```sh
flutter analyze
flutter test
```
