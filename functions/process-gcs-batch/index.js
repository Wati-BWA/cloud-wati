'use strict';

/**
 * Cloud Function 2gen: process-gcs-batch
 * Trigger: OBJECT_FINALIZE en bucket cloud-wati-iot-raw, prefix uploads/
 * Runtime: Node.js 20 | Memory: 512 MB | Timeout: 540s
 *
 * Procesa archivos NDJSON subidos por el ESP32 como fallback de conectividad.
 * El timestamp lo asigna esta función (server-side, no el dispositivo).
 * Procesa máximo 100 líneas por invocación (límite por diseño SDD v2.1).
 * Mueve el archivo de uploads/ → processed/ al terminar.
 */

const { BigQuery }  = require('@google-cloud/bigquery');
const { Firestore, FieldValue } = require('@google-cloud/firestore');
const { Storage }   = require('@google-cloud/storage');

const bq        = new BigQuery();
const db        = new Firestore();
const storage   = new Storage();

const DATASET     = process.env.BQ_DATASET    || 'iot_telemetry';
const RAW_TABLE   = process.env.BQ_RAW_TABLE  || 'raw_telemetry';
const ERR_TABLE   = process.env.BQ_ERRORS_TABLE || 'errors';
const DEVICES_COL = process.env.FIRESTORE_DEVICES_COLLECTION || 'devices';
const MAX_ROWS    = 100;

// ──────────────────────────────────────────────
// Validación de registro individual
// ──────────────────────────────────────────────
function validateRecord(record) {
  if (!record || typeof record !== 'object')               return false;
  if (!record.hardware?.device_id || !record.tenant?.user_id) return false;
  const t = record.telemetry;
  if (!t) return false;
  if (!isFiniteNum(t.temp_interior_c) || !isFiniteNum(t.temp_exterior_c)) return false;
  return true;
}

function isFiniteNum(v) {
  return typeof v === 'number' && Number.isFinite(v);
}

// ──────────────────────────────────────────────
// Handler principal (CloudEvent)
// ──────────────────────────────────────────────
exports.processGcsBatch = async (cloudevent) => {
  const bucket = cloudevent.data.bucket;
  const name   = cloudevent.data.name;

  // Solo procesar archivos en prefix uploads/
  if (!name.startsWith('uploads/') || !name.endsWith('.ndjson')) {
    console.log(`Skipping non-target file: ${name}`);
    return;
  }

  console.log(`Processing: gs://${bucket}/${name}`);

  // Descargar archivo NDJSON
  const file = storage.bucket(bucket).file(name);
  const [content] = await file.download();

  // Parsear líneas (máx 100)
  const lines = content.toString('utf8')
    .split('\n')
    .map(l => l.trim())
    .filter(Boolean)
    .slice(0, MAX_ROWS);

  if (lines.length === 0) {
    console.log('Empty file, skipping.');
    await file.move(name.replace('uploads/', 'processed/'));
    return;
  }

  const validRows  = [];
  const errorRows  = [];
  const now = new Date().toISOString();

  for (const line of lines) {
    try {
      const record = JSON.parse(line);
      if (!validateRecord(record)) {
        throw new Error('Schema validation failed');
      }

      validRows.push({
        device_id:        record.hardware.device_id,
        user_id:          record.tenant.user_id,
        timestamp:        now,                             // server-side timestamp
        temp_interior_c:  record.telemetry.temp_interior_c,
        temp_exterior_c:  record.telemetry.temp_exterior_c,
        samples_averaged: record.telemetry.samples_averaged ?? null,
        uptime_s:         record.diagnostics?.uptime_s     ?? null,
        wifi_rssi_dbm:    record.diagnostics?.wifi_rssi_dbm ?? null,
        firmware_version: record.hardware.firmware_version ?? null,
        processed_at:     now,
        ingest_source:    'gcs_batch',
      });
    } catch (err) {
      errorRows.push({
        raw_payload:   line,
        error_type:    err.message === 'Schema validation failed' ? 'schema_invalid' : 'json_parse_error',
        error_message: err.message,
        file_source:   name,
        received_at:   now,
      });
    }
  }

  // Escritura en batch a BigQuery (una sola operación por tabla)
  const writes = [];
  if (validRows.length > 0) {
    writes.push(bq.dataset(DATASET).table(RAW_TABLE).insert(validRows));

    // Actualizar Firestore snapshot para cada dispositivo (último registro ganador)
    const byDevice = {};
    for (const row of validRows) {
      byDevice[row.device_id] = row;
    }
    for (const [deviceId, row] of Object.entries(byDevice)) {
      writes.push(
        db.collection(DEVICES_COL).doc(deviceId).set({
          user_id:          row.user_id,
          temp_interior_c:  row.temp_interior_c,
          temp_exterior_c:  row.temp_exterior_c,
          samples_averaged: row.samples_averaged,
          uptime_s:         row.uptime_s,
          wifi_rssi_dbm:    row.wifi_rssi_dbm,
          firmware_version: row.firmware_version,
          last_seen:        FieldValue.serverTimestamp(),
        }, { merge: true })
      );
    }
  }

  if (errorRows.length > 0) {
    writes.push(bq.dataset(DATASET).table(ERR_TABLE).insert(errorRows));
  }

  await Promise.all(writes);

  // Mover archivo a /processed (lifecycle rule lo eliminará en 30 días)
  await file.move(name.replace('uploads/', 'processed/'));

  console.log(`Done: ${validRows.length} valid, ${errorRows.length} errors. File moved to processed/.`);
};
