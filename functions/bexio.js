// Talks to the bexio REST API (https://docs.bexio.com) and turns an offer of
// the app into a bexio quote ("kb_offer"). The mapping functions are pure so
// they can be tested without bexio.

const API = 'https://api.bexio.com';

/** An error the user can act on, with a German message for the app. */
export class TransferError extends Error {}

/** A failed bexio request. */
export class BexioError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/** bexio wants amounts and prices as strings with at most 6 decimals. */
export function decimal(value) {
  return Number(value).toFixed(6);
}

export function francs(cents) {
  return decimal(cents / 100);
}

/** The date part of an ISO date string as written by the app. */
export function day(iso) {
  const match = /^(\d{4}-\d{2}-\d{2})/.exec(String(iso ?? ''));
  return match ? match[1] : null;
}

/**
 * Splits "Max Muster" into first name "Max" and last name "Muster". bexio
 * calls the last name name_1 (required) and the first name name_2.
 */
export function splitName(name) {
  const parts = String(name ?? '').trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return { name1: '', name2: '' };
  if (parts.length === 1) return { name1: parts[0], name2: '' };
  return { name1: parts.at(-1), name2: parts.slice(0, -1).join(' ') };
}

/** The title carries the offer number, so a transfer can be found again. */
export function offerTitle(offer) {
  const bike = String(offer.bikeModel ?? '').trim();
  return `Reparaturangebot ${offer.number}${bike ? ` – ${bike}` : ''}`;
}

/** Same total as the app: round(quantity × unit price) in cents. */
function lineCents(line) {
  return Math.round(Number(line.quantity ?? 0) * Number(line.unitPriceCents ?? 0));
}

/**
 * Amount and unit price for bexio. Labour is stored in hours, and 20 min
 * would show as "0.333333" on the customer's document and add up to a
 * slightly different total. A quantity with more than 2 decimals therefore
 * goes over as 1 × the line total.
 */
export function amountAndPrice(line) {
  const quantity = Number(line.quantity ?? 0);
  const unitCents = Number(line.unitPriceCents ?? 0);
  const rounded = Math.round(quantity * 100) / 100;
  if (Math.abs(rounded - quantity) < 1e-9 && Math.round(rounded * unitCents) === lineCents(line)) {
    return { amount: decimal(rounded), unitPrice: francs(unitCents), whole: false };
  }
  return { amount: decimal(1), unitPrice: francs(lineCents(line)), whole: true };
}

function minutes(hours) {
  return Math.round(Number(hours) * 60);
}

/** Free text above the positions: bike, frame number and finding. */
export function introText(offer) {
  const rows = [];
  const bike = String(offer.bikeModel ?? '').trim();
  const frame = String(offer.frameNumber ?? '').trim();
  const problem = String(offer.problem ?? '').trim();
  if (bike) rows.push(`Velo: ${bike}`);
  if (frame) rows.push(`Rahmennummer: ${frame}`);
  if (problem) rows.push(`Befund / Kundenwunsch: ${problem}`);
  return rows.join('\n');
}

/**
 * Checks an offer before anything is sent to bexio. Throws a TransferError
 * with a message for the app.
 */
export function checkOffer(offer) {
  if (!String(offer.customerName ?? '').trim()) {
    throw new TransferError('Bitte zuerst den Namen des Kunden eingeben.');
  }
  const lines = Array.isArray(offer.lines) ? offer.lines : [];
  if (lines.length === 0) {
    throw new TransferError('Das Angebot hat keine Positionen.');
  }
  const missing = lines.filter((l) => !(Number(l.unitPriceCents) > 0)).length;
  if (missing > 0) {
    throw new TransferError(
      missing === 1
        ? 'Eine Position hat keinen Preis.'
        : `${missing} Positionen haben keinen Preis.`,
    );
  }
}

/**
 * The positions of the bexio quote.
 *
 * @param {object} offer the offer as stored by the app
 * @param {object} ctx
 * @param {number|null} ctx.taxId sales tax, null if the offer has no VAT
 * @param {Map<string, object>} ctx.articles bexio items by upper-case SKU
 * @param {{piece?: number, hour?: number}} ctx.units bexio unit IDs
 * @param {string} ctx.footer the app's footer note (Einstellungen)
 */
export function buildPositions(offer, { taxId, articles, units = {}, footer = '' }) {
  const positions = [];
  const intro = introText(offer);
  if (intro) positions.push({ type: 'KbPositionText', text: intro, show_pos_nr: false });

  for (const line of offer.lines) {
    const kind = line.kind ?? 'part';
    const { amount, unitPrice, whole } = amountAndPrice(line);
    let text = String(line.description ?? '').trim() || (kind === 'part' ? 'Teil' : 'Arbeit');
    if (kind === 'labour' && whole) text += ` (${minutes(line.quantity)} Min.)`;
    const position = { amount, unit_price: unitPrice, text };
    const lineDiscount = Math.min(Math.max(Number(line.discountPercent ?? 0), 0), 100);
    if (lineDiscount > 0) position.discount_in_percent = decimal(lineDiscount);
    if (taxId != null) position.tax_id = taxId;
    const unit = kind === 'labour' && !whole ? units.hour : units.piece;
    if (unit != null) position.unit_id = unit;

    const sku = String(line.sku ?? '').trim().toUpperCase();
    const article = kind === 'part' && sku ? articles.get(sku) : undefined;
    if (article) {
      positions.push({ type: 'KbPositionArticle', article_id: article.id, ...position });
    } else {
      positions.push({ type: 'KbPositionCustom', ...position });
    }
  }

  const discount = offerDiscount(offer);
  if (discount) positions.push(discount);

  const notes = String(offer.notes ?? '').trim();
  if (notes) positions.push({ type: 'KbPositionText', text: `Bemerkungen: ${notes}`, show_pos_nr: false });
  const note = String(footer ?? '').trim();
  if (note) positions.push({ type: 'KbPositionText', text: note, show_pos_nr: false });
  return positions;
}

/**
 * The discount on the whole offer as a bexio discount position, null if
 * there is none. bexio applies it to the sum of the positions above it.
 */
export function offerDiscount(offer) {
  const d = offer.discount;
  if (!d) return null;
  const percent = Number(d.percent ?? 0);
  const cents = Number(d.amountCents ?? 0);
  const text = String(d.label ?? '').trim() || 'Rabatt';
  if (percent > 0) {
    return { type: 'KbPositionDiscount', text, is_percentual: true, value: decimal(Math.min(percent, 100)) };
  }
  if (cents > 0) {
    return { type: 'KbPositionDiscount', text, is_percentual: false, value: francs(cents) };
  }
  return null;
}

/** The request body for POST /2.0/kb_offer. */
export function buildQuote(offer, settings, { contactId, userId, taxId, articles, units }) {
  const vatRate = Number(settings.vatRate ?? 8.1);
  const quote = {
    title: offerTitle(offer),
    contact_id: contactId,
    user_id: userId,
    // 0 = with VAT; mwst_is_net says whether the prices already contain it.
    // 2 = exempt from VAT.
    mwst_type: vatRate > 0 ? 0 : 2,
    mwst_is_net: vatRate > 0 ? settings.pricesIncludeVat === false : false,
    api_reference: offer.id,
    positions: buildPositions(offer, {
      taxId: vatRate > 0 ? taxId : null,
      articles,
      units,
      footer: settings.footer,
    }),
  };
  const from = day(offer.createdAt);
  const until = day(offer.validUntil);
  if (from) quote.is_valid_from = from;
  if (until) quote.is_valid_until = until;
  return quote;
}

/** Picks the active sales tax with the app's VAT rate. */
export function pickTax(taxes, rate) {
  const matching = taxes.filter(
    (t) => t.type === 'sales_tax' && t.is_active !== false && Math.abs(Number(t.value) - rate) < 0.001,
  );
  // Prefer the normal turnover tax ("UN81") over special codes.
  matching.sort((a, b) => Number(!/^UN/i.test(a.code ?? '')) - Number(!/^UN/i.test(b.code ?? '')));
  return matching[0] ?? null;
}

/** Finds a unit by any of the given names, ignoring case and dots. */
export function pickUnit(units, names) {
  const wanted = names.map((n) => n.toLowerCase());
  const unit = units.find((u) => wanted.includes(String(u.name ?? '').toLowerCase().replace(/\.$/, '')));
  return unit?.id;
}

/** A minimal bexio client: just the calls the transfer needs. */
export class Bexio {
  constructor(token, fetchImpl = fetch) {
    this.token = token;
    this.fetch = fetchImpl;
  }

  async request(method, path, body, retry = true) {
    const response = await this.fetch(`${API}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${this.token}`,
        Accept: 'application/json',
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (response.status === 429 && retry) {
      const wait = Math.min(Number(response.headers.get('RateLimit-Reset')) || 5, 15);
      await new Promise((resolve) => setTimeout(resolve, wait * 1000));
      return this.request(method, path, body, false);
    }
    const text = await response.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = text;
    }
    if (!response.ok) {
      const message = (data && (data.message || data.error)) || response.statusText;
      throw new BexioError(response.status, `${method} ${path}: ${response.status} ${message}`);
    }
    return data;
  }

  search(path, field, value, criteria = '=') {
    return this.request('POST', `${path}/search?limit=20`, [{ field, value, criteria }]);
  }

  async userId() {
    return (await this.request('GET', '/3.0/users/me')).id;
  }

  async salesTax(rate, date) {
    const taxes = await this.request('GET', `/3.0/taxes?types=sales_tax&scope=active&date=${date}`);
    return pickTax(taxes ?? [], rate);
  }

  async units() {
    const units = (await this.request('GET', '/2.0/unit')) ?? [];
    return {
      piece: pickUnit(units, ['stk', 'stück', 'pce', 'pièce']),
      hour: pickUnit(units, ['h', 'std', 'stunde', 'stunden', 'heure']),
    };
  }

  /** bexio items for the given SKUs (Artikelnummer = intern_code). */
  async articles(skus) {
    const found = new Map();
    for (const sku of new Set(skus)) {
      const items = (await this.search('/2.0/article', 'intern_code', sku)) ?? [];
      const item = items.find((i) => String(i.intern_code ?? '').toUpperCase() === sku);
      if (item) found.set(sku, item);
    }
    return found;
  }

  /** An existing contact with the customer's e-mail or phone number. */
  async findContact({ email, phone }) {
    const tries = [];
    if (email) tries.push(['mail', email]);
    if (phone) tries.push(['phone_mobile', phone], ['phone_fixed', phone]);
    for (const [field, value] of tries) {
      const contacts = (await this.search('/2.0/contact', field, value)) ?? [];
      if (contacts.length > 0) return contacts[0];
    }
    return null;
  }

  async createContact({ name, email, phone, userId }) {
    const { name1, name2 } = splitName(name);
    const contact = {
      contact_type_id: 2, // person
      name_1: name1,
      user_id: userId,
      owner_id: userId,
    };
    if (name2) contact.name_2 = name2;
    if (email) contact.mail = email;
    if (phone) contact.phone_mobile = phone;
    return this.request('POST', '/2.0/contact', contact);
  }

  /** A quote made earlier for this offer, e.g. if saving the link failed. */
  async findQuote(offer) {
    const quotes = (await this.search('/2.0/kb_offer', 'title', offer.number, 'like')) ?? [];
    return quotes.find((q) => q.api_reference === offer.id) ?? null;
  }

  createQuote(quote) {
    return this.request('POST', '/2.0/kb_offer', quote);
  }
}

/**
 * Creates the bexio quote for an offer: finds or creates the contact, looks
 * up the items by SKU and the sales tax, and posts the quote. Returns the
 * quote and the contact ID.
 */
export async function transferOffer(bexio, offer, settings, today) {
  checkOffer(offer);
  const existing = await bexio.findQuote(offer);
  if (existing) return { quote: existing, contactId: existing.contact_id, reused: true };

  const vatRate = Number(settings.vatRate ?? 8.1);
  const userId = await bexio.userId();
  let taxId = null;
  if (vatRate > 0) {
    const tax = await bexio.salesTax(vatRate, today);
    if (!tax) {
      throw new TransferError(`In bexio gibt es keinen aktiven MWST-Satz von ${vatRate} %.`);
    }
    taxId = tax.id;
  }
  const units = await bexio.units();
  const skus = offer.lines
    .filter((l) => (l.kind ?? 'part') === 'part' && String(l.sku ?? '').trim())
    .map((l) => String(l.sku).trim().toUpperCase());
  const articles = await bexio.articles(skus);

  const email = String(offer.customerEmail ?? '').trim();
  const phone = String(offer.customerPhone ?? '').trim();
  const contact =
    (await bexio.findContact({ email, phone })) ??
    (await bexio.createContact({ name: offer.customerName, email, phone, userId }));

  const quote = await bexio.createQuote(
    buildQuote(offer, settings, { contactId: contact.id, userId, taxId, articles, units }),
  );
  return {
    quote,
    contactId: contact.id,
    reused: false,
    missingArticles: [...new Set(skus)].filter((s) => !articles.has(s)),
  };
}
