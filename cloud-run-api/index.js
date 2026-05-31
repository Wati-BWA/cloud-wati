'use strict';

/**
 * Cloud Run: cloud-wati (Node.js 20 + Express)
 * Región: us-central1 | Memory: 256 MB | Min instances: 0 | Concurrency: 80
 *
 * Endpoints:
 *   GET  /health
 *   GET  /api/devices/:user_id              → lista de dispositivos del usuario
 *   GET  /api/devices/:device_id/latest     → último dato (desde Firestore)
 *   GET  /api/devices/:device_id/history    → histórico 24-168h (desde BigQuery)
 *
 * Autenticación:
 *   - Flutter app: Firebase ID Token (Bearer)
 *   - B2B / Admin: API Key en header X-API-Key
 */

const express     = require('express');
const cors        = require('cors');
const helmet      = require('helmet');
const morgan      = require('morgan');
const compression = require('compression');
const admin       = require('firebase-admin');
const { BigQuery }  = require('@google-cloud/bigquery');
const { Firestore } = require('@google-cloud/firestore');

// ──────────────────────────────────────────────
// Inicialización
// ──────────────────────────────────────────────
const app = express();
const bq  = new BigQuery();
const db  = new Firestore();

const PROJECT     = process.env.GCP_PROJECT_ID;
const DATASET     = process.env.BQ_DATASET   || 'iot_telemetry';
const RAW_TABLE   = process.env.BQ_RAW_TABLE || 'raw_telemetry';
const DEVICES_COL = process.env.FIRESTORE_DEVICES_COLLECTION || 'devices';

let adminInitialized = false;
function initAdmin() {
  if (!adminInitialized) {
    admin.initializeApp();
    adminInitialized = true;
  }
}

// ──────────────────────────────────────────────
// Middleware
// ──────────────────────────────────────────────
app.use(helmet());
app.use(compression());
app.use(cors({ origin: '*' }));
app.use(morgan('combined'));
app.use(express.json({ limit: '1mb' }));

// ──────────────────────────────────────────────
// Auth middleware (Firebase ID Token ó API Key)
// ──────────────────────────────────────────────
async function authMiddleware(req, res, next) {
  // Dev bypass
  if (process.env.BYPASS_AUTH) {
    req.uid = req.headers['x-user-id'] || 'dev-user';
    return next();
  }

  initAdmin();

  // Intentar Firebase ID Token
  const authHeader = req.headers.authorization || '';
  if (authHeader.startsWith('Bearer ')) {
    const token = authHeader.replace('Bearer ', '');
    try {
      const decoded = await admin.auth().verifyIdToken(token);
      req.uid = decoded.uid;
      return next();
    } catch {
      // continuar a verificar API Key
    }
  }

  // B2B: API Key en Firestore api_keys
  const apiKey = req.headers['x-api-key'];
  if (apiKey) {
    const snap = await db.collection('api_keys')
      .where('key_hash', '==', apiKey)
      .limit(1)
      .get();
    if (!snap.empty) {
      req.uid = snap.docs[0].data().label || 'api-key-user';
      return next();
    }
  }

  return res.status(401).json({ error: 'unauthorized' });
}

// ──────────────────────────────────────────────
// Routes
// ──────────────────────────────────────────────

// Health check (sin auth)
app.get('/health', (_, res) => res.json({ ok: true, version: '2.1' }));

// GET /api/devices/:user_id — Lista dispositivos del usuario
app.get('/api/devices/:user_id', authMiddleware, async (req, res) => {
  const userId = req.params.user_id;

  // Verificar que el token pertenece al mismo usuario (o es admin)
  if (req.uid !== userId && req.uid !== 'api-key-user') {
    return res.status(403).json({ error: 'forbidden' });
  }

  try {
    const snap = await db.collection(DEVICES_COL)
      .where('user_id', '==', userId)
      .limit(100)
      .get();

    const devices = snap.docs.map(d => ({ device_id: d.id, ...d.data() }));
    return res.json({ count: devices.length, devices });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: err.message });
  }
});

// GET /api/devices/:device_id/latest — Último dato desde Firestore
app.get('/api/devices/:device_id/latest', authMiddleware, async (req, res) => {
  const deviceId = req.params.device_id;

  try {
    const doc = await db.collection(DEVICES_COL).doc(deviceId).get();
    if (!doc.exists) return res.status(404).json({ error: 'device_not_found' });

    const data = doc.data();

    // Verificar acceso: el dispositivo debe pertenecer al usuario autenticado
    if (data.user_id !== req.uid && req.uid !== 'api-key-user') {
      return res.status(403).json({ error: 'forbidden' });
    }

    return res.json({ device_id: deviceId, ...data });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: err.message });
  }
});

// GET /api/devices/:device_id/history — Histórico desde BigQuery
app.get('/api/devices/:device_id/history', authMiddleware, async (req, res) => {
  if (!PROJECT) {
    return res.status(500).json({ error: 'GCP_PROJECT_ID not set' });
  }

  const deviceId = req.params.device_id;
  const hours    = Math.min(parseInt(req.query.hours  || '24',  10), 168);   // máx 7 días
  const limit    = Math.min(parseInt(req.query.limit  || '100', 10), 2880);  // máx 24h a 30s

  const query = `
    SELECT
      device_id,
      user_id,
      timestamp,
      temp_interior_c,
      temp_exterior_c,
      samples_averaged,
      uptime_s,
      wifi_rssi_dbm,
      firmware_version,
      ingest_source
    FROM \`${PROJECT}.${DATASET}.${RAW_TABLE}\`
    WHERE device_id = @device_id
      AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL @hours HOUR)
      AND DATE(timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
    ORDER BY timestamp DESC
    LIMIT @limit
  `;

  try {
    const [rows] = await bq.query({
      query,
      params: { device_id: deviceId, hours, limit },
      location: 'US',
    });
    return res.json({ device_id: deviceId, hours, count: rows.length, data: rows });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: err.message });
  }
});

// GET /api/predictions/:device_id/latest — Última predicción disponible
app.get('/api/predictions/:device_id/latest', authMiddleware, async (req, res) => {
  if (!PROJECT) {
    return res.status(500).json({ error: 'GCP_PROJECT_ID not set' });
  }
  
  const deviceId = req.params.device_id;
  
  try {
    // Verificar propiedad del dispositivo en Firestore
    const doc = await db.collection(DEVICES_COL).doc(deviceId).get();
    if (!doc.exists) return res.status(404).json({ error: 'device_not_found' });
    if (doc.data().user_id !== req.uid && req.uid !== 'api-key-user') {
      return res.status(403).json({ error: 'forbidden' });
    }

    const query = `
      SELECT prediction_hour, predicted_temp_c, will_increase_6h, created_at
      FROM \`${PROJECT}.${DATASET}.temperature_predictions\`
      WHERE device_id = @device_id
      ORDER BY created_at DESC, prediction_hour ASC
      LIMIT 1
    `;
    const [rows] = await bq.query({
      query,
      params: { device_id: deviceId },
      location: 'US',
    });
    
    return res.json({ device_id: deviceId, prediction: rows.length > 0 ? rows[0] : null });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: err.message });
  }
});

// GET /api/predictions/:device_id/today — Predicciones para las próximas 24 horas
app.get('/api/predictions/:device_id/today', authMiddleware, async (req, res) => {
  if (!PROJECT) {
    return res.status(500).json({ error: 'GCP_PROJECT_ID not set' });
  }
  
  const deviceId = req.params.device_id;
  
  try {
    // Verificar propiedad del dispositivo
    const doc = await db.collection(DEVICES_COL).doc(deviceId).get();
    if (!doc.exists) return res.status(404).json({ error: 'device_not_found' });
    if (doc.data().user_id !== req.uid && req.uid !== 'api-key-user') {
      return res.status(403).json({ error: 'forbidden' });
    }

    // Obtenemos predicciones donde la hora esté en el futuro próximo (24h)
    const query = `
      SELECT prediction_hour, predicted_temp_c, will_increase_6h, created_at
      FROM \`${PROJECT}.${DATASET}.temperature_predictions\`
      WHERE device_id = @device_id
        AND prediction_hour >= CURRENT_TIMESTAMP()
        AND prediction_hour <= TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
      ORDER BY prediction_hour ASC
      LIMIT 24
    `;
    const [rows] = await bq.query({
      query,
      params: { device_id: deviceId },
      location: 'US',
    });
    
    return res.json({ device_id: deviceId, count: rows.length, predictions: rows });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: err.message });
  }
});

// 404 handler
app.use((_, res) => res.status(404).json({ error: 'not_found' }));

// Error handler global
app.use((err, req, res, _next) => {
  console.error(err);
  res.status(500).json({ error: err.message });
});

// ──────────────────────────────────────────────
// Start server
// ──────────────────────────────────────────────
const PORT = process.env.PORT || 8080;
app.listen(PORT, () => console.log(`cloud-wati API listening on :${PORT}`));

module.exports = app;
