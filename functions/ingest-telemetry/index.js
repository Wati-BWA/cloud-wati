const { BigQuery } = require('@google-cloud/bigquery');
const { Firestore } = require('@google-cloud/firestore');

const bq = new BigQuery();
const firestore = new Firestore();

const dataset = process.env.BQ_DATASET || 'iot_telemetry';
const rawTable = process.env.BQ_RAW_TABLE || 'raw_telemetry';
const errorsTable = process.env.BQ_ERRORS_TABLE || 'errors';
const devicesCollection = process.env.FIRESTORE_DEVICES_COLLECTION || 'devices';

function isNumber(value) {
    return typeof value === 'number' && Number.isFinite(value);
}

function toNumber(value) {
    if (isNumber(value)) {
        return value;
    }
    if (typeof value === 'string' && value.trim() !== '') {
        const parsed = Number(value);
        return Number.isFinite(parsed) ? parsed : null;
    }
    return null;
}

exports.ingestTelemetry = async (req, res) => {
    try {
        if (req.method !== 'POST') {
            return res.status(405).json({ error: 'Method not allowed' });
        }

        const body = req.body || {};

        // Accept both flat payloads and nested ESP32 payload
        const device_id = body.device_id || (body.hardware && body.hardware.device_id);
        const firmware_version = (body.hardware && body.hardware.firmware_version) || null;
        const user_id = (body.tenant && body.tenant.user_id) || null;

        const telemetry = body.telemetry || {};
        const temp_interior_c = toNumber(isNumber(body.value) ? body.value : telemetry.temp_interior_c);
        const temp_exterior_c = toNumber(telemetry.temp_exterior_c);
        const samples_averaged = telemetry.samples_averaged;

        const diagnostics = body.diagnostics || {};
        const uptime_s = diagnostics.uptime_s;
        const wifi_rssi_dbm = diagnostics.wifi_rssi_dbm;

        if (!device_id || temp_interior_c === null) {
            return res.status(400).json({ error: 'Missing required fields: device_id and numeric temperature (temp_interior_c or value)' });
        }

        const receivedAt = new Date();
        const eventTimestamp = receivedAt.toISOString();

        // Write history to BigQuery (append) using canonical schema
        const row = {
            device_id: String(device_id),
            temperature_celsius: temp_interior_c,
            event_timestamp: eventTimestamp
        };

        try {
            await bq.dataset(dataset).table(rawTable).insert([row]);
        } catch (err) {
            console.error('BigQuery insert error:', err);
            // Attempt to write simplified error to errors table
            try {
                await bq.dataset(dataset).table(errorsTable).insert([
                    {
                        raw_payload: body ? JSON.stringify(body) : null,
                        error_type: 'bigquery_insert',
                        error_message: err && (err.message || String(err)) || null,
                        file_source: null,
                        received_at: eventTimestamp
                    }
                ]);
            } catch (logErr) {
                console.error('Failed to write error to BigQuery errors table:', logErr);
            }
            return res.status(500).json({ error: 'BigQuery insert failed' });
        }

        // Update snapshot in Firestore (devices/{device_id})
        try {
            const deviceDoc = firestore.collection(devicesCollection).doc(String(device_id));
            await deviceDoc.set({
                user_id: user_id || null,
                firmware_version: firmware_version || null,
                last_seen: eventTimestamp,
                last_telemetry: {
                    temp_interior_c: temp_interior_c,
                    temp_exterior_c: temp_exterior_c,
                    samples_averaged: Number.isInteger(samples_averaged) ? samples_averaged : null
                },
                diagnostics: {
                    uptime_s: isNumber(uptime_s) ? uptime_s : null,
                    wifi_rssi_dbm: isNumber(wifi_rssi_dbm) ? wifi_rssi_dbm : null
                }
            }, { merge: true });
        } catch (err) {
            console.error('Firestore update error:', err);
            // Not fatal for ingestion; continue
        }

        return res.status(200).json({ ok: true, device_id, received_at: eventTimestamp });
    } catch (err) {
        console.error('ingestTelemetry unexpected error:', err);
        return res.status(500).json({ error: err && (err.message || String(err)) || 'unknown error' });
    }
};
