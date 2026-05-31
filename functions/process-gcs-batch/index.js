const { BigQuery } = require('@google-cloud/bigquery');
const { Firestore } = require('@google-cloud/firestore');
const { Storage } = require('@google-cloud/storage');
const fs = require('fs');

const bq = new BigQuery();
const firestore = new Firestore();
const storage = new Storage();

const dataset = process.env.BQ_DATASET || 'iot_telemetry';
const rawTable = process.env.BQ_RAW_TABLE || 'raw_telemetry';
const errorsTable = process.env.BQ_ERRORS_TABLE || 'errors';
const devicesCollection = process.env.FIRESTORE_DEVICES_COLLECTION || 'devices';

function isNumber(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

async function processLine(line, source) {
  const payload = JSON.parse(line);
  const { device_id, temperature_celsius } = payload || {};
  if (!device_id || !isNumber(temperature_celsius)) {
    throw new Error('Invalid payload');
  }
  const eventTimestamp = new Date().toISOString();
  await bq.dataset(dataset).table(rawTable).insert([
    { device_id, temperature_celsius, event_timestamp: eventTimestamp }
  ]);
  await firestore.collection(devicesCollection).doc(device_id).set({
    temperature_celsius,
    event_timestamp: eventTimestamp,
    last_seen: eventTimestamp
  }, { merge: true });
  return { device_id, event_timestamp: eventTimestamp, source };
}

exports.processGcsBatch = async (event) => {
  const bucketName = event.bucket;
  const fileName = event.name;
  let data = '';

  if (process.env.DRY_RUN_LOCAL === '1') {
    data = fs.readFileSync(process.env.LOCAL_NDJSON_FILE, 'utf8');
  } else {
    const file = storage.bucket(bucketName).file(fileName);
    data = (await file.download())[0].toString('utf8');
  }

  const lines = data.split('\n').map(l => l.trim()).filter(Boolean);
  for (const line of lines) {
    try {
      await processLine(line, fileName || 'local');
    } catch (err) {
      await bq.dataset(dataset).table(errorsTable).insert([
        {
          error_time: new Date().toISOString(),
          source: 'process-gcs-batch',
          payload: line,
          error_message: err.message
        }
      ]);
    }
  }
};
