'use strict';

/**
 * Cloud Function 2gen: scan-bill
 * Trigger: HTTPS POST desde Flutter (con Firebase Auth JWT)
 * Runtime: Node.js 20 | Memory: 512 MB | Timeout: 60s
 *
 * Flujo:
 * 1. Verifica Firebase ID Token en Authorization header
 * 2. Sube imagen a GCS temporal (cloud-wati-bills-ocr/temp/)
 * 3. Llama a Cloud Vision documentTextDetection
 * 4. Elimina imagen inmediatamente (privacidad)
 * 5. Parsea texto con regex para facturas CRE Bolivia
 * 6. Guarda resultado en Firestore bills/{uid}/history
 */

const { Firestore, FieldValue } = require('@google-cloud/firestore');
const { Storage }  = require('@google-cloud/storage');
const vision       = require('@google-cloud/vision');
const admin        = require('firebase-admin');
const { v4: uuidv4 } = require('uuid');

let adminInitialized = false;
function initAdmin() {
  if (!adminInitialized) {
    admin.initializeApp();
    adminInitialized = true;
  }
}

const db           = new Firestore();
const storage      = new Storage();
const visionClient = new vision.ImageAnnotatorClient();

const BILLS_BUCKET = process.env.BILLS_BUCKET || 'cloud-wati-bills-ocr';

// ──────────────────────────────────────────────
// Parser regex — Facturas CRE Bolivia
// ──────────────────────────────────────────────
function parseCREBill(text) {
  const result = {
    period:     null,
    kwh:        null,
    total_bs:   null,
    category:   null,
    raw_text:   text.substring(0, 2000), // primeros 2000 chars para debug
  };

  // Período de facturación (ej: "MAYO 2026", "Mayo/2026", "05/2026")
  const periodMatch = text.match(
    /(?:periodo|período|mes|period)[:\s]+([A-Za-záéíóúÁÉÍÓÚ]+[\s\/\-]+20\d{2})/i
  );
  if (periodMatch) result.period = periodMatch[1].trim();

  // Consumo en kWh (ej: "CONSUMO 412 kWh", "412.3 kWh")
  const kwhMatch = text.match(/(\d{1,4}(?:[.,]\d{1,2})?)\s*k[Ww][Hh]/);
  if (kwhMatch) result.kwh = parseFloat(kwhMatch[1].replace(',', '.'));

  // Total en Bolivianos (ej: "TOTAL Bs. 287.50", "Total: 287,50")
  const totalMatch = text.match(/total[:\s]+(?:bs\.?\s*)?(\d{1,6}(?:[.,]\d{1,2})?)/i);
  if (totalMatch) result.total_bs = parseFloat(totalMatch[1].replace(',', '.'));

  // Categoría (ej: "DOMICILIARIA", "COMERCIAL", "INDUSTRIAL")
  const catMatch = text.match(/\b(domiciliaria|comercial|industrial|general)\b/i);
  if (catMatch) result.category = catMatch[1].toLowerCase();

  return result;
}

// ──────────────────────────────────────────────
// Handler principal
// ──────────────────────────────────────────────
exports.scanBill = async (req, res) => {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }

  // 1. Verificar Firebase Auth token
  let uid;
  if (!process.env.BYPASS_AUTH) {
    initAdmin();
    const authHeader = req.headers.authorization || '';
    if (!authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'missing_token' });
    }
    try {
      const decoded = await admin.auth().verifyIdToken(authHeader.replace('Bearer ', ''));
      uid = decoded.uid;
    } catch {
      return res.status(401).json({ error: 'invalid_token' });
    }
  } else {
    uid = req.headers['x-user-id'] || 'dev-user';
  }

  // 2. Recibir imagen (raw buffer)
  const imageBuffer = req.rawBody || req.body;
  if (!imageBuffer || imageBuffer.length === 0) {
    return res.status(400).json({ error: 'empty_body' });
  }

  const blobName = `temp/${uuidv4()}.jpg`;
  const bucket   = storage.bucket(BILLS_BUCKET);

  try {
    // 3. Subir imagen a GCS temporal
    await bucket.file(blobName).save(imageBuffer, {
      metadata: { contentType: 'image/jpeg' },
    });

    // 4. Cloud Vision OCR
    const [visionResult] = await visionClient.documentTextDetection(
      `gs://${BILLS_BUCKET}/${blobName}`
    );
    const fullText = visionResult.fullTextAnnotation?.text || '';

    // 5. Eliminar imagen inmediatamente (privacidad)
    await bucket.file(blobName).delete().catch(console.error);

    // 6. Parsear factura CRE
    const extracted = parseCREBill(fullText);

    // 7. Guardar en Firestore
    await db.collection('bills').doc(uid)
      .collection('history')
      .add({ ...extracted, scanned_at: FieldValue.serverTimestamp() });

    return res.status(200).json(extracted);
  } catch (err) {
    // Limpiar imagen en caso de error
    await bucket.file(blobName).delete().catch(() => {});
    console.error('scan-bill error:', err);
    return res.status(500).json({ error: err.message });
  }
};
