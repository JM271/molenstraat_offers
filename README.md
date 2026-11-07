# Molenstraat Reparaturangebote

Flutter app for writing repair offers (Reparaturangebote) for Molenstraat Fatbikes customers. Android, iPhone and browser from one project.

## Features

- **Angebote**: list of all offers with search (customer, number, frame number, bike, finding) and a status filter: Entwurf, Gesendet, Angenommen, Abgelehnt. Sent offers past their validity date show as *abgelaufen*.
- **Angebot erfassen**: customer, bike model and frame number, finding / customer request, line items, notes and validity date. Offer numbers run per year (`A-2026-001`, …) and are never reused, even after deleting.
- **Positionen**: pick common repairs from the price list (each adds its labour and part lines), or add parts (pieces × price) and labour (minutes × hourly rate) individually. Lines without a price are flagged in red.
- **Teil aus Katalog**: pick a product from the product catalog shared with Spoke: the Molenstraat product list from bexio, 56 products with `MS-…` article numbers (fatbikes, spare parts, accessories) and their sales prices, with a picture where the former supplier catalog had one. Searching for a supplier number (e.g. `OXV8-05`) finds the product. Search by name or article number and filter by category. The product's catalog price is filled in; a different price on an offer applies to that offer only. Products without a price (added in Spoke) get the price stored in `partPrices` if there is one; otherwise they show *Preis fehlt* and the line dialog asks for a price.
- **Gemeinsamer Katalog**: the catalog lives in Firestore (`products`), the same for Spoke and this app. The app bundles the product list only to fill the database on first use; whichever app starts first writes it once (`catalogConfig/state`), so later changes and deletions stick. On start the app also replaces the old demo prices of a stored price list once and adds the service flat rate.
- **Katalogpreise** (Einstellungen): shows how many catalog products have a price and imports a price list pasted as one article number (or supplier number) and price per line (e.g. two columns copied from Excel, or `SKU;Preis`). Prices of catalog products are written into the shared catalog, others into `partPrices`; they apply on every device and in Spoke immediately, without an app update. A price entered on an offer for a product without price is stored in `partPrices` when the offer is saved. The article number appears on the line, in the PDF and in the text export.
- **Rabatte**: a discount in percent on any line, or *Gratis* (100 %) for a part given away, e.g. with a new bike; the offer shows the normal price and *Gratis* or the discount. A discount on the whole offer (*Rabatt auf das Angebot*), in percent or as an amount, with its own label (e.g. *Rabatt beim Kauf eines Fatbikes*); it is deducted before VAT.
- **Totals**: material, labour, total, VAT included or added (configurable).
- **Output**: share the offer as a PDF (A4, with a signature line for the job order), print it or preview it, or copy it as text for WhatsApp/e-mail. Sharing a draft offers to mark it as *Gesendet*.
- **bexio**: *In bexio anlegen* (menu of an offer) creates the saved offer as a quote (Offerte) in bexio. See [bexio](#bexio).
- **Preisliste**: editable list of repairs with labour minutes and an optional part with price. It starts with typical fatbike repairs. The **labour times are rough estimates**: adjust them to the workshop before use. Part prices come from the Molenstraat product list where it has the part (tube, tyre, brake pads, brake disc, chain); the others (gear cable, spoke) have no price until one is entered. Flat rates: CHF 30, 50, 100, 150 and *Service Pauschale: inkl. Anfahrtskosten, Montage, Reparatur.* (CHF 150). A stored price list with the old demo prices gets the list prices (or none); prices changed by hand are kept.
- **Einstellungen**: company name, address, phone, e-mail, hourly rate, VAT rate (default 8.1 %, prices incl. VAT), currency (CHF), validity in days, footer note in the offer.

## Shared database with the Inventory app

The app uses the same Firebase project as the Inventory app (Spoke), `inventory-molenstraat`, and the same accounts:

- **Sign-in**: e-mail and password, the same account as in Spoke. New accounts need approval by an admin in Spoke (**Kontosymbol → Nutzer verwalten**). Editors and admins can use both apps. User management stays in Spoke.
- **Shared data** under `workshops/molenstraat` in Firestore: `offers`, `offerCounters` (offer numbers per year), `offerConfig/settings`, `offerConfig/presets` (price list), `products` (the product catalog shared with Spoke, with prices), `partPrices` (prices of products without catalog price, from the import or from offers) and `bexioOffers` (links to bexio quotes, written only by the Cloud Function). All approved users see the same offers on every device and in the browser.
- **Offer numbers** are reserved in a transaction on the first save, so two devices never hand out the same number. A new offer shows a provisional number until it is saved. Sharing, printing or copying an offer saves it first.
- **Stock** of the Inventory app (`parts`) is shown in the catalog picker and on part lines (`Lager 3 + 1 Auto`, red if fewer than offered). A part is found by its `sku`, its own product number (`productNumber`, e.g. `MS-SP-3009`) or its supplier order number (`orderNumber`). A Molenstraat product also finds parts kept under its supplier number (`supplierSku` in the catalog, e.g. `OXV8-05`), unless Inventory assigned them to another product number; each part counts once. `OXV8-02` belongs to two products in bexio (Controller Dapper and Dapper PRO) and has no supplier link: its stock shows only once the product number is set in Spoke. The offers app never changes stock. Custom catalog products added in Spoke appear in the picker too.
- **Online only**, like Spoke: without a connection, saving fails with a message and nothing is lost on screen. There is no offline cache.

The Firestore rules for these paths live in the **Inventory repository** (`firestore.rules`), because one rule set applies to the whole project. Always deploy the rules from there, from a version that contains the offers section; deploying an older version would lock the offers app out. The Firebase app registrations (Android `com.petehon.molenstraat_offers`, iOS `com.petehon.molenstraatOffers`, web) and their public configuration are in `lib/firebase_config.dart`.

## bexio

*In bexio anlegen* calls the Cloud Function `createBexioOffer` (`functions/`). The function holds the bexio access token. It never reaches the apps, so nobody can read it from the web version or an app file. The function:

1. checks that the caller is an approved user (admin or editor),
2. reads the offer as saved (the app saves it first) and the settings,
3. finds the customer in bexio by e-mail, then mobile or landline number, or creates a new person (last word of the name = last name),
4. creates the quote: bike, frame number and finding as a text above the positions; parts as bexio items (found by article number `MS-…` = bexio *Artikelnummer*), otherwise as free positions; labour in hours, or as 1 × the line total with the minutes in the text when the hours would need more than 2 decimals (20 min); flat rates; line discounts as bexio position discounts and the discount on the offer as a bexio discount position; notes and the footer note of the settings as text below. VAT: the active bexio sales tax with the rate of the settings, prices incl. or excl. VAT as set. bexio assigns its own number (`AN-…`). The title is `Reparaturangebot A-2026-001 – <bike>` and the offer ID is stored as API reference,
5. stores the link in `bexioOffers/{offerId}`: bexio number, or the error.

The offer and the list then show the bexio number, and the list search finds it. Each offer goes over once: a second call returns the existing quote, also if the link could not be saved the first time. Later changes in the app are not sent to bexio; send, change and invoice the quote in bexio. Parts without a bexio item go over as free positions, and the app says how many.

### Set up

1. Firebase project `inventory-molenstraat` on the **Blaze** plan (Cloud Functions need it).
2. Create a Personal Access Token at https://developer.bexio.com/pat (signed in as a bexio user who may create quotes and contacts). **It is valid for 60 days** and grants full access to the bexio company, so keep it nowhere but in the secret.
3. Store it as a secret and deploy the function (from this repository; codebase `offers`, so functions of other codebases are left alone):
   ```sh
   firebase functions:secrets:set BEXIO_TOKEN
   firebase deploy --only functions:offers
   ```
4. Deploy the Firestore rules from the **Inventory repository**, from a version with the `bexioOffers` section (read for members, no writes by apps).

Every 60 days: create a new token and run `firebase functions:secrets:set BEXIO_TOKEN` again (it offers to redeploy the function). Until then, transfers fail with *Der bexio-Zugang ist abgelaufen oder ungültig*. For a token that does not expire, the function would need bexio's OAuth flow (an app registered at developer.bexio.com with refresh token); not built yet.

Without the deployed function the app works as before; *In bexio anlegen* then says the connection is not set up. Until the rules are deployed, bexio numbers do not show.

```sh
cd functions && npm install && npm test   # mapping and transfer against a fake bexio
```

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
| `lib/bexio.dart` | Link of an offer to its bexio quote |
| `functions/` | Cloud Function `createBexioOffer` (bexio API) |

The logo is in `assets/brand/`: `logo.png` (black, app bar and PDF header), `logo_white.png` (for dark backgrounds) and `wheel.png`. The app icons for Android, iOS and web show the wheel in black on white.

The product catalog is the Firestore collection `products` (`sku`, `supplierSku`, `name`, `category`, `imageAsset`, `priceCents` incl. VAT; document ID = encoded upper-case SKU), shared with Spoke. The catalogue lives only in the database; the app bundles no copy, so catalogue changes need no app release. New bexio exports are brought in with `tool/bexio_sync` in the Inventory (Spoke) repo. `test/fixtures/product_catalog.json` is a snapshot of it for the tests. Pictures are in `assets/products/`; entries with an empty `imageAsset` show a placeholder. Stock parts of Spoke are matched by SKU, product number or supplier number; switch old stock to the catalog products in Spoke (**Lager auf Katalog umstellen**). Keep SKUs stable, since prices and stock are keyed by SKU.

Amounts are stored as whole Rappen (`int`) to avoid rounding errors. The PDF uses the bundled Noto Sans font (`assets/fonts`, SIL Open Font License) so umlauts, € and typographic quotes render.

```sh
flutter analyze
flutter test
```
