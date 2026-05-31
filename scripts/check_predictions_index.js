const { BigQuery } = require('@google-cloud/bigquery');
const { PubSub }   = require('@google-cloud/pubsub');

const bigquery = new BigQuery();
const pubsub   = new PubSub();
const topic    = pubsub.topic('notifications');

const PROJECT_ID = process.env.PROJECT_ID || 'wati-497921';
// Umbral: solo notificar si la predicción supera este valor en °C
const ALERT_THRESHOLD = parseFloat(process.env.ALERT_TEMP_THRESHOLD || '28');

/**
 * HTTP Cloud Function que lee las predicciones recientes de BigQuery
 * y publica un mensaje en Pub/Sub por cada dispositivo con temp > umbral.
 *
 * El campo user_id se resuelve en notification-agent desde Firestore,
 * aquí solo reenviamos el device_id para mantener este handler liviano.
 */
exports.checkNewPredictions = async (req, res) => {
  try {
    const query = `
      SELECT
        device_id,
        forecast_timestamp,
        predicted_temp,
        lower_bound,
        upper_bound
      FROM \`${PROJECT_ID}.iot_dataset.predictions_6h\`
      WHERE generated_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 65 MINUTE)
        AND forecast_timestamp BETWEEN CURRENT_TIMESTAMP()
          AND TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
        AND predicted_temp >= ${ALERT_THRESHOLD}
      ORDER BY device_id, forecast_timestamp
    `;

    const [rows] = await bigquery.query({ query });
    console.log(`[check-new-predictions] ${rows.length} predicciones encontradas (umbral ${ALERT_THRESHOLD}°C)`);

    if (rows.length === 0) {
      return res.status(200).send(`No hay predicciones por encima de ${ALERT_THRESHOLD}°C`);
    }

    // Una notificación por device (la más próxima en el tiempo)
    const byDevice = {};
    for (const row of rows) {
      if (!byDevice[row.device_id]) byDevice[row.device_id] = row;
    }

    let published = 0;
    for (const [deviceId, row] of Object.entries(byDevice)) {
      const forecastTs = row.forecast_timestamp?.value || row.forecast_timestamp;
      const msg = {
        device_id:     deviceId,
        predicted_temp: Math.round(row.predicted_temp * 10) / 10,
        // feels_like: estimación simple hasta que se integre humedad real
        feels_like: Math.round((row.predicted_temp + (row.predicted_temp > 28 ? 1.5 : 0)) * 10) / 10,
        forecast_for:  forecastTs,
      };

      await topic.publishMessage({ json: msg });
      console.log(`[check-new-predictions] Publicado: ${JSON.stringify(msg)}`);
      published++;
    }

    res.status(200).send(`Publicados ${published} mensajes en Pub/Sub`);
  } catch (err) {
    console.error('[check-new-predictions] Error:', err);
    res.status(500).send('Internal Server Error');
  }
};
