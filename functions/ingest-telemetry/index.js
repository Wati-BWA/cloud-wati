const { BigQuery } = require('@google-cloud/bigquery');
const { Firestore } = require('@google-cloud/firestore');

const bq = new BigQuery();
const fs = new Firestore();

const dataset = process.env.BQ_DATASET || 'iot_telemetry';
const rawTable = process.env.BQ_RAW_TABLE || 'raw_telemetry';
const errorsTable = process.env.BQ_ERRORS_TABLE || 'errors';
const devicesCollection = process.env.FIRESTORE_DEVICES_COLLECTION || 'devices';

function isNumber(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

exports.ingestTelemetry = async (req, res) => {
  try {
    const { device_id, temperature_celsius } = req.body || {};
    if (!device_id || !isNumber(temperature_celsius)) {
      return res.status(400).json({ error: 'Invalid payload' });
    }

    const eventTimestamp = new Date().toISOString();

    if (process.env.DRY_RUN_LOCAL === '1') {
      return res.status(200).json({ ok: true, device_id, event_timestamp: eventTimestamp });
    }

    await bq.dataset(dataset).table(rawTable).insert([
      { device_id, temperature_celsius, event_timestamp: eventTimestamp }
    ]);

    await fs.collection(devicesCollection).doc(device_id).set({
      temperature_celsius,
      event_timestamp: eventTimestamp,
      last_seen: eventTimestamp
    }, { merge: true });

    res.status(200).json({ ok: true, device_id, event_timestamp: eventTimestamp });
  } catch (err) {
    try {
      await bq.dataset(dataset).table(errorsTable).insert([
        {
          error_time: new Date().toISOString(),
          source: 'ingest-telemetry',
          payload: req.body || null,
          error_message: err.message
        }
      ]);
    } catch (_) {
      // Best effort error logging.
    }
    res.status(500).json({ error: err.message });
  }
};
