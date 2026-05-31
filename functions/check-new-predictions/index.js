const functions = require('@google-cloud/functions-framework');
const { BigQuery } = require('@google-cloud/bigquery');
const { Firestore } = require('@google-cloud/firestore');
const { PubSub } = require('@google-cloud/pubsub');

const bigquery = new BigQuery();
const firestore = new Firestore();
const pubsub = new PubSub();

const PROJECT_ID = process.env.GCP_PROJECT_ID || 'wati-497921';
const BQ_DATASET = process.env.BQ_DATASET || 'iot_dataset';
const PUBSUB_TOPIC = process.env.PUBSUB_TOPIC || 'notifications';
// Threshold: only notify if predicted temp is above this value OR deviation > N degrees
const ALERT_TEMP_THRESHOLD = parseFloat(process.env.ALERT_TEMP_THRESHOLD || '30');
const ALERT_DEVIATION_THRESHOLD = parseFloat(process.env.ALERT_DEVIATION_THRESHOLD || '3');

/**
 * Reads the last processed cursor from Firestore.
 * Returns a TIMESTAMP string or null if not set.
 */
async function getLastCursor() {
  const doc = await firestore.doc('system/prediction-cursor').get();
  if (!doc.exists) return null;
  return doc.data().last_processed_at || null;
}

/**
 * Updates the cursor in Firestore with the latest processed forecast_timestamp.
 */
async function updateCursor(lastTimestamp) {
  await firestore.doc('system/prediction-cursor').set(
    { last_processed_at: lastTimestamp, updated_at: new Date().toISOString() },
    { merge: true }
  );
}

/**
 * Queries BigQuery for predictions newer than the cursor.
 * Also joins with Firestore devices to get user_id per device.
 */
async function fetchNewPredictions(cursor) {
  const whereClause = cursor
    ? `AND p.generated_at > TIMESTAMP('${cursor}')`
    : '';

  const query = `
    SELECT
      p.device_id,
      p.forecast_timestamp,
      p.predicted_temp,
      p.lower_bound,
      p.upper_bound,
      p.generated_at
    FROM \`${PROJECT_ID}.${BQ_DATASET}.predictions_6h\` p
    WHERE p.forecast_timestamp >= CURRENT_TIMESTAMP()
      ${whereClause}
    ORDER BY p.generated_at DESC, p.device_id
    LIMIT 500
  `;

  const [rows] = await bigquery.query({ query });
  return rows;
}

/**
 * Fetches user_id for a device_id from Firestore `devices` collection.
 * Returns null if not found.
 */
async function getUserForDevice(deviceId) {
  const snap = await firestore.collection('devices').doc(deviceId).get();
  if (!snap.exists) return null;
  return snap.data().user_id || null;
}

/**
 * Publishes a notification message to Pub/Sub.
 */
async function publishNotification(payload) {
  const topic = pubsub.topic(PUBSUB_TOPIC);
  const messageBuffer = Buffer.from(JSON.stringify(payload));
  const messageId = await topic.publish(messageBuffer);
  return messageId;
}

functions.http('checkNewPredictions', async (req, res) => {
  try {
    console.log('[check-new-predictions] Starting...');

    // 1. Read cursor from Firestore
    const cursor = await getLastCursor();
    console.log(`[check-new-predictions] Cursor: ${cursor || 'none (first run)'}`);

    // 2. Fetch new predictions from BigQuery
    const predictions = await fetchNewPredictions(cursor);
    console.log(`[check-new-predictions] Found ${predictions.length} new prediction rows`);

    if (predictions.length === 0) {
      return res.status(200).json({ status: 'ok', published: 0, message: 'No new predictions' });
    }

    // 3. Publish relevant predictions (only high-temp alerts or significant events)
    let published = 0;
    let latestGeneratedAt = cursor;

    // Group by device_id to send one message per device with the nearest forecast
    const byDevice = {};
    for (const row of predictions) {
      const did = row.device_id;
      if (!byDevice[did]) byDevice[did] = row;
      // Track latest generated_at for cursor update
      const rowTs = row.generated_at?.value || row.generated_at;
      if (!latestGeneratedAt || rowTs > latestGeneratedAt) {
        latestGeneratedAt = rowTs;
      }
    }

    for (const [deviceId, row] of Object.entries(byDevice)) {
      const predictedTemp = row.predicted_temp;

      // Only publish if temperature exceeds threshold
      if (predictedTemp < ALERT_TEMP_THRESHOLD) {
        console.log(`[check-new-predictions] Device ${deviceId}: ${predictedTemp}°C — below threshold, skip`);
        continue;
      }

      // Look up user for this device
      const userId = await getUserForDevice(deviceId);
      if (!userId) {
        console.log(`[check-new-predictions] Device ${deviceId}: no user found — skip`);
        continue;
      }

      const forecastFor = row.forecast_timestamp?.value || row.forecast_timestamp;

      // Estimate feels_like: simple approximation using upper bound offset
      // When real humidity is available from weather_forecasts this can be improved
      const feelsLike = predictedTemp + (predictedTemp > 28 ? 1.5 : 0);

      const payload = {
        device_id: deviceId,
        predicted_temp: Math.round(predictedTemp * 10) / 10,
        feels_like: Math.round(feelsLike * 10) / 10,
        lower_bound: row.lower_bound,
        upper_bound: row.upper_bound,
        forecast_for: forecastFor,
        user_id: userId,
        generated_at: row.generated_at?.value || row.generated_at,
      };

      const msgId = await publishNotification(payload);
      console.log(`[check-new-predictions] Published message ${msgId} for device ${deviceId}, user ${userId}`);
      published++;
    }

    // 4. Update cursor
    if (latestGeneratedAt && latestGeneratedAt !== cursor) {
      await updateCursor(latestGeneratedAt);
      console.log(`[check-new-predictions] Cursor updated to ${latestGeneratedAt}`);
    }

    return res.status(200).json({
      status: 'ok',
      total_rows: predictions.length,
      devices_processed: Object.keys(byDevice).length,
      published,
    });

  } catch (err) {
    console.error('[check-new-predictions] Error:', err);
    return res.status(500).json({ status: 'error', message: err.message });
  }
});
