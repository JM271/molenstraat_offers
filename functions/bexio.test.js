import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  Bexio,
  BexioError,
  TransferError,
  amountAndPrice,
  buildQuote,
  pickTax,
  splitName,
  transferOffer,
} from './bexio.js';

const offer = {
  id: '1762430000000000-abc',
  number: 'A-2026-014',
  createdAt: '2026-11-06T10:15:00.000',
  validUntil: '2026-12-06T00:00:00.000',
  customerName: 'Anna Maria Muster',
  customerPhone: '079 123 45 67',
  customerEmail: 'anna@example.ch',
  bikeModel: 'Dapper PRO',
  frameNumber: 'FR-123',
  problem: 'Bremse hinten schleift',
  notes: '',
  lines: [
    { kind: 'part', description: 'Brake pad for hydraulic disc (pair)', quantity: 2, unitPriceCents: 2500, sku: 'ms-sp-2007' },
    { kind: 'part', description: 'Kabelbinder', quantity: 1, unitPriceCents: 500 },
    { kind: 'labour', description: 'Bremse einstellen', quantity: 0.5, unitPriceCents: 9000 },
    { kind: 'labour', description: 'Beläge wechseln', quantity: 20 / 60, unitPriceCents: 9000 },
    { kind: 'flat', description: 'Service Pauschale', quantity: 1, unitPriceCents: 15000 },
  ],
};
const settings = { vatRate: 8.1, pricesIncludeVat: true, footer: 'Sichtprüfung.' };

test('splits names into last name (name_1) and first names (name_2)', () => {
  assert.deepEqual(splitName('Anna Maria Muster'), { name1: 'Muster', name2: 'Anna Maria' });
  assert.deepEqual(splitName('  Muster '), { name1: 'Muster', name2: '' });
});

test('keeps the app total when labour hours have many decimals', () => {
  assert.deepEqual(amountAndPrice({ quantity: 0.5, unitPriceCents: 9000 }), {
    amount: '0.500000', unitPrice: '90.000000', whole: false,
  });
  // 20 min × CHF 90 = CHF 30.00 in the app; 0.333333 × 90 would be 29.99997.
  assert.deepEqual(amountAndPrice({ quantity: 20 / 60, unitPriceCents: 9000 }), {
    amount: '1.000000', unitPrice: '30.000000', whole: true,
  });
});

test('builds the quote with items, free positions and VAT', () => {
  const quote = buildQuote(offer, settings, {
    contactId: 7,
    userId: 1,
    taxId: 28,
    articles: new Map([['MS-SP-2007', { id: 55 }]]),
    units: { piece: 3, hour: 4 },
  });
  assert.equal(quote.title, 'Reparaturangebot A-2026-014 – Dapper PRO');
  assert.equal(quote.mwst_type, 0);
  assert.equal(quote.mwst_is_net, false);
  assert.equal(quote.api_reference, offer.id);
  assert.equal(quote.is_valid_from, '2026-11-06');
  assert.equal(quote.is_valid_until, '2026-12-06');
  const [intro, pads, ties, adjust, swap, flat, footer] = quote.positions;
  assert.equal(intro.type, 'KbPositionText');
  assert.match(intro.text, /Rahmennummer: FR-123/);
  assert.deepEqual(pads, {
    type: 'KbPositionArticle', article_id: 55, amount: '2.000000', unit_price: '25.000000',
    text: 'Brake pad for hydraulic disc (pair)', tax_id: 28, unit_id: 3,
  });
  assert.equal(ties.type, 'KbPositionCustom');
  assert.equal(adjust.unit_id, 4);
  assert.equal(swap.text, 'Beläge wechseln (20 Min.)');
  assert.equal(swap.unit_id, 3);
  assert.equal(flat.unit_price, '150.000000');
  assert.deepEqual(footer, { type: 'KbPositionText', text: 'Sichtprüfung.', show_pos_nr: false });
});

test('adds VAT on top when prices exclude it, none when the rate is 0', () => {
  const ctx = { contactId: 1, userId: 1, taxId: 28, articles: new Map() };
  assert.equal(buildQuote(offer, { ...settings, pricesIncludeVat: false }, ctx).mwst_is_net, true);
  const exempt = buildQuote(offer, { ...settings, vatRate: 0 }, ctx);
  assert.equal(exempt.mwst_type, 2);
  assert.ok(exempt.positions.every((p) => p.tax_id === undefined));
});

test('picks the normal 8.1 % sales tax', () => {
  const taxes = [
    { id: 1, code: 'UN77', value: 7.7, type: 'sales_tax', is_active: true },
    { id: 2, code: 'XY81', value: 8.1, type: 'sales_tax', is_active: true },
    { id: 3, code: 'UN81', value: 8.1, type: 'sales_tax', is_active: true },
  ];
  assert.equal(pickTax(taxes, 8.1).id, 3);
  assert.equal(pickTax(taxes, 2.6), null);
});

/** A fake bexio that answers the calls of a transfer. */
function fakeBexio({ contacts = [], quotes = [], articles = [], status } = {}) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    const path = url.replace('https://api.bexio.com', '');
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ method: init.method, path, body });
    const reply = (data, code = 200) => new Response(JSON.stringify(data), { status: code });
    if (status) return reply({ message: 'nope' }, status);
    if (path === '/3.0/users/me') return reply({ id: 1 });
    if (path.startsWith('/3.0/taxes')) return reply([{ id: 28, code: 'UN81', value: 8.1, type: 'sales_tax' }]);
    if (path === '/2.0/unit') return reply([{ id: 3, name: 'Stk.' }, { id: 4, name: 'h' }]);
    if (path.startsWith('/2.0/article/search')) {
      return reply(articles.filter((a) => a.intern_code === body[0].value));
    }
    if (path.startsWith('/2.0/contact/search')) {
      return reply(contacts.filter((c) => c[body[0].field] === body[0].value));
    }
    if (path.startsWith('/2.0/kb_offer/search')) return reply(quotes);
    if (path === '/2.0/contact') return reply({ id: 77, ...body }, 201);
    if (path === '/2.0/kb_offer') return reply({ id: 900, document_nr: 'AN-00042', ...body }, 201);
    return reply({ message: 'unexpected' }, 404);
  };
  return { bexio: new Bexio('token', fetchImpl), calls };
}

test('creates contact and quote when the customer is new', async () => {
  const { bexio, calls } = fakeBexio({ articles: [{ id: 55, intern_code: 'MS-SP-2007' }] });
  const result = await transferOffer(bexio, offer, settings, '2026-11-06');
  assert.equal(result.quote.document_nr, 'AN-00042');
  assert.equal(result.contactId, 77);
  assert.deepEqual(result.missingArticles, []);
  const contact = calls.find((c) => c.path === '/2.0/contact').body;
  assert.deepEqual(contact, {
    contact_type_id: 2, name_1: 'Muster', name_2: 'Anna Maria', user_id: 1, owner_id: 1,
    mail: 'anna@example.ch', phone_mobile: '079 123 45 67',
  });
  assert.equal(calls.find((c) => c.path === '/2.0/kb_offer').body.contact_id, 77);
  assert.ok(calls.every((c) => c.path !== '/2.0/kb_offer' || c.method === 'POST'));
});

test('reuses a contact found by e-mail and reports items missing in bexio', async () => {
  const { bexio, calls } = fakeBexio({ contacts: [{ id: 12, mail: 'anna@example.ch' }] });
  const result = await transferOffer(bexio, offer, settings, '2026-11-06');
  assert.equal(result.contactId, 12);
  assert.deepEqual(result.missingArticles, ['MS-SP-2007']);
  assert.ok(!calls.some((c) => c.path === '/2.0/contact'));
  const pads = calls.find((c) => c.path === '/2.0/kb_offer').body.positions[1];
  assert.equal(pads.type, 'KbPositionCustom');
});

test('does not create a second quote for the same offer', async () => {
  const { bexio, calls } = fakeBexio({
    quotes: [{ id: 900, document_nr: 'AN-00042', api_reference: offer.id, contact_id: 12 }],
  });
  const result = await transferOffer(bexio, offer, settings, '2026-11-06');
  assert.equal(result.reused, true);
  assert.equal(result.quote.id, 900);
  assert.ok(!calls.some((c) => c.path === '/2.0/kb_offer'));
});

test('refuses offers without customer or prices before calling bexio', async () => {
  const { bexio, calls } = fakeBexio();
  await assert.rejects(transferOffer(bexio, { ...offer, customerName: ' ' }, settings, '2026-11-06'), TransferError);
  await assert.rejects(
    transferOffer(bexio, { ...offer, lines: [{ ...offer.lines[0], unitPriceCents: 0 }] }, settings, '2026-11-06'),
    /keinen Preis/,
  );
  assert.equal(calls.length, 0);
});

test('reports bexio errors with their status', async () => {
  const { bexio } = fakeBexio({ status: 401 });
  await assert.rejects(transferOffer(bexio, offer, settings, '2026-11-06'), (e) => e instanceof BexioError && e.status === 401);
});
