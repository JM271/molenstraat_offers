// Cloud Functions of the offers app, deployed as the codebase "offers" into
// the Firebase project shared with Spoke (inventory-molenstraat).

import { initializeApp } from 'firebase-admin/app';
import { FieldValue, Timestamp, getFirestore } from 'firebase-admin/firestore';
import { logger } from 'firebase-functions';
import { defineSecret } from 'firebase-functions/params';
import { HttpsError, onCall } from 'firebase-functions/v2/https';

import { Bexio, BexioError, TransferError, transferOffer } from './bexio.js';

initializeApp();

/** bexio access token, set with `firebase functions:secrets:set BEXIO_TOKEN`. */
const bexioToken = defineSecret('BEXIO_TOKEN');

const PENDING_MS = 2 * 60 * 1000;

function today() {
  // Swiss date, so a transfer just after midnight uses the right day.
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Zurich' }).format(new Date());
}

/**
 * Creates a bexio quote for a saved offer and stores the link in
 * `workshops/molenstraat/bexioOffers/{offerId}`. Only approved users of the
 * workshop (admin, editor) may call it. Calling it again for the same offer
 * returns the existing quote instead of creating a second one.
 */
export const createBexioOffer = onCall(
  { region: 'europe-west6', secrets: [bexioToken], timeoutSeconds: 120, maxInstances: 2 },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError('unauthenticated', 'Bitte anmelden.');
    const offerId = request.data?.offerId;
    if (typeof offerId !== 'string' || !/^[A-Za-z0-9_-]{1,100}$/.test(offerId)) {
      throw new HttpsError('invalid-argument', 'Ungültiges Angebot.');
    }

    const db = getFirestore();
    const workshop = db.collection('workshops').doc('molenstraat');
    const member = await workshop.collection('members').doc(uid).get();
    if (!['admin', 'editor'].includes(member.get('role'))) {
      throw new HttpsError('permission-denied', 'Keine Berechtigung.');
    }

    const offerRef = workshop.collection('offers').doc(offerId);
    const linkRef = workshop.collection('bexioOffers').doc(offerId);

    // Claim the transfer, so a double tap or a second device cannot create
    // two quotes for the same offer.
    const claim = await db.runTransaction(async (tx) => {
      const link = await tx.get(linkRef);
      const state = link.get('state');
      if (state === 'done') return { done: link.data() };
      const started = link.get('startedAt');
      if (state === 'pending' && started instanceof Timestamp && Date.now() - started.toMillis() < PENDING_MS) {
        return { busy: true };
      }
      tx.set(linkRef, { state: 'pending', startedAt: FieldValue.serverTimestamp(), startedBy: uid });
      return {};
    });
    if (claim.done) return { id: claim.done.bexioId, number: claim.done.number, existing: true };
    if (claim.busy) {
      throw new HttpsError('aborted', 'Das Angebot wird gerade an bexio übertragen.');
    }

    try {
      const [offerSnap, settingsSnap] = await Promise.all([
        offerRef.get(),
        workshop.collection('offerConfig').doc('settings').get(),
      ]);
      if (!offerSnap.exists) throw new TransferError('Bitte das Angebot zuerst speichern.');
      const offer = offerSnap.data();
      const settings = settingsSnap.data() ?? {};

      const result = await transferOffer(new Bexio(bexioToken.value()), offer, settings, today());
      const link = {
        state: 'done',
        bexioId: result.quote.id,
        number: result.quote.document_nr ?? '',
        contactId: result.contactId ?? null,
        offerNumber: offer.number,
        missingArticles: result.missingArticles ?? [],
        createdAt: FieldValue.serverTimestamp(),
        createdBy: uid,
      };
      await linkRef.set(link);
      logger.info('bexio quote created', { offerId, bexioId: link.bexioId, reused: result.reused });
      return { id: link.bexioId, number: link.number, missingArticles: link.missingArticles };
    } catch (error) {
      const message = userMessage(error);
      logger.error('bexio transfer failed', { offerId, error: String(error?.message ?? error) });
      await linkRef.set({
        state: 'failed',
        error: message,
        failedAt: FieldValue.serverTimestamp(),
        failedBy: uid,
      });
      throw new HttpsError(error instanceof TransferError ? 'failed-precondition' : 'internal', message);
    }
  },
);

function userMessage(error) {
  if (error instanceof TransferError) return error.message;
  if (error instanceof BexioError) {
    if (error.status === 401) {
      return 'Der bexio-Zugang ist abgelaufen oder ungültig. Bitte ein neues Token hinterlegen.';
    }
    if (error.status === 403) return 'Dem bexio-Zugang fehlt die Berechtigung dafür.';
    if (error.status === 422) return `bexio hat das Angebot abgelehnt: ${error.message}`;
    if (error.status === 429) return 'bexio ist gerade ausgelastet. Bitte in einer Minute erneut versuchen.';
    return `bexio-Fehler (${error.status}). Bitte erneut versuchen.`;
  }
  return 'Übertragung an bexio fehlgeschlagen. Bitte erneut versuchen.';
}
