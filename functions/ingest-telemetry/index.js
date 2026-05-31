'use strict';

/**
 * Cloud Function 2gen: ingest-telemetry
 * Trigger: HTTPS POST desde ESP32-S3
 * Runtime: Node.js 20 | Memory: 256 MB | Timeout: 60s
 * Región: us-central1
 *
 * Payload esperado (SDD v2.1):
 * {
 *   hardware:    { device_id, firmware_version }
 *   tenant:      { user_id }
 *   telemetry:   { temp_interior_c, temp_exterior_c, samples_averaged }
 *   diagnostics: { uptime_s, wifi_rssi_dbm }
 * }
 * El campo `timestamp` lo asigna esta función al recibir (server-side).
 */

const { BigQuery }   = require('@google-cloud/bigquery');
const { Firestore, FieldValue } = require('@google-cloud/firestore');

const bq        = new BigQuery();
const db        = new Firestore();

const DATASET     = process.env.BQ_DATASET    || 'iot_telemetry';
const RAW_TABLE   = process.env.BQ_RAW_TABLE  || 'raw_telemetry';
const ERR_TABLE   = process.env.BQ_ERRORS_TABLE || 'errors';
const DEVICES_COL = process.env.FIRESTORE_DEVICES_COLLECTION || 'devices';

// ──────────────────────────────────────────────
// Schema validation (sin AJV para free tier)
// ──────────────────────────────────────────────
function validatePayload(body) {
  if (!body || typeof body !== 'object')                        return false;
  if (!body.hardware?.device_id || !body.tenant?.user_id)       return false;
  const t = body.telemetry;
  if (!t) return false;
  if (!isFiniteNum(t.temp_interior_c) || !isFiniteNum(t.temp_exterior_c)) return false;
  return true;
}

function isFiniteNum(v) {
  return typeof v === 'number' && Number.isFinite(v);
}

// ──────────────────────────────────────────────
// Escritura BigQuery (helper)
// ──────────────────────────────────────────────
async function writeToBQ(tableId, rows) {
  await bq.dataset(DATASET).table(tableId).insert(
    Array.isArray(rows) ? rows : [rows]
  );
}

// ──────────────────────────────────────────────
// Trigger de agentes (async, no bloquea respuesta)
// ──────────────────────────────────────────────
async function checkAndTriggerAgents(enriched) {
  const RUN_AGENTS_URL = process.env.RUN_AGENTS_URL;
  if (!RUN_AGENTS_URL) return;

  // Solo dispara si temperatura interior supera umbral (>35°C o <5°C)
  const temp = enriched.temp_interior_c;
  if (temp > 35 || temp < 5) {
    const { default: fetch } = await import('node-fetch').catch(() => ({ default: null }));
    if (!fetch) return;
    await fetch(RUN_AGENTS_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        device_id:      enriched.device_id,
        trigger_reason: temp > 35 ? 'high_temp' : 'low_temp',
      }),
    }).catch(console.error);
  }
}

// ──────────────────────────────────────────────
// Handler principal
// ──────────────────────────────────────────────
exports.ingestTelemetry = async (req, res) => {
  // Solo acepta POST
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }

  const payload = req.body;

  // 1. Validar schema
  if (!validatePayload(payload)) {
    const errRow = {
      raw_payload:   JSON.stringify(payload),
      error_type:    'schema_invalid',
      error_message: 'Payload failed validation',
      file_source:   'http_direct',
      received_at:   new Date().toISOString(),
    };
    await writeToBQ(ERR_TABLE, errRow).catch(console.error);
    return res.status(400).json({ error: 'invalid_payload' });
  }

  const deviceId = payload.hardware.device_id;
  const userId   = payload.tenant.user_id;
  const now      = new Date();

  // 2. Deduplicación por ventana de 25s (ESP32 envía cada 30s)
  const deviceRef = db.collection(DEVICES_COL).doc(deviceId);
  const snap      = await deviceRef.get();

  if (snap.exists) {
    const lastSeen = snap.data().last_seen?.toMillis?.() || 0;
    if (now.getTime() - lastSeen < 25_000) {
      return res.status(200).json({ status: 'deduplicated' });
    }
  }

  // 3. Enriquecer y aplanar para BigQuery (SDD v2.1 schema)
  const ts = now.toISOString();
  const enriched = {
    device_id:        deviceId,
    user_id:          userId,
    timestamp:        ts,
    temp_interior_c:  payload.telemetry.temp_interior_c,
    temp_exterior_c:  payload.telemetry.temp_exterior_c,
    samples_averaged: payload.telemetry.samples_averaged ?? null,
    uptime_s:         payload.diagnostics?.uptime_s       ?? null,
    wifi_rssi_dbm:    payload.diagnostics?.wifi_rssi_dbm  ?? null,
    firmware_version: payload.hardware.firmware_version   ?? null,
    processed_at:     ts,
    ingest_source:    'http_direct',
  };

  // 4. Escribir en BigQuery
  await writeToBQ(RAW_TABLE, enriched);

  // 5. Actualizar snapshot Firestore (1 escritura, incluye dedup timestamp)
  await deviceRef.set({
    user_id:          userId,
    temp_interior_c:  enriched.temp_interior_c,
    temp_exterior_c:  enriched.temp_exterior_c,
    samples_averaged: enriched.samples_averaged,
    uptime_s:         enriched.uptime_s,
    wifi_rssi_dbm:    enriched.wifi_rssi_dbm,
    firmware_version: enriched.firmware_version,
    last_seen:        FieldValue.serverTimestamp(),
  }, { merge: true });

  // 6. Disparar agentes si hay condiciones (async, no bloquea)
  checkAndTriggerAgents(enriched).catch(console.error);

  return res.status(202).json({ status: 'accepted', device_id: deviceId });
};
