const functions = require('@google-cloud/functions-framework');
const { BigQuery } = require('@google-cloud/bigquery');
const { SecretManagerServiceClient } = require('@google-cloud/secret-manager');

const bigquery = new BigQuery();
const secretManager = new SecretManagerServiceClient();

async function getSecret(secretName) {
  const projectId = process.env.GCP_PROJECT || 'wati-497921';
  const name = `projects/${projectId}/secrets/${secretName}/versions/latest`;
  const [version] = await secretManager.accessSecretVersion({ name });
  return version.payload.data.toString('utf8');
}

functions.http('runPredictions', async (req, res) => {
  try {
    const datasetId = 'iot_telemetry';
    const apiKey = await getSecret('weather-api-key');
    const location = '-17.7833,-63.1821'; // Santa Cruz de la Sierra
    
    // Fetch forecast weather (24 hours)
    const response = await fetch(`https://api.weatherapi.com/v1/forecast.json?key=${apiKey}&q=${location}&days=2`);
    if (!response.ok) {
      throw new Error(`Weather API error: ${response.statusText}`);
    }
    const data = await response.json();
    
    // Extract hourly forecast for the next 24 hours
    const now = new Date();
    const hours = [];
    data.forecast.forecastday.forEach(day => {
      day.hour.forEach(h => {
        const hTime = new Date(h.time);
        if (hTime > now && hTime <= new Date(now.getTime() + 24 * 60 * 60 * 1000)) {
          hours.push(h);
        }
      });
    });

    if (hours.length === 0) {
      return res.status(200).send('No forecast data to predict');
    }

    // Build the query to run ML.PREDICT and insert results
    // We create a CTE with forecast data and cross join with active devices (up to 100 devices)
    let forecastValues = hours.map(h => {
      const d = new Date(h.time);
      return `(TIMESTAMP('${d.toISOString()}'), ${d.getUTCHours()}, ${d.getUTCDay() + 1}, ${h.temp_c}, ${h.humidity}, ${h.temp_c})`;
    }).join(', ');

    // Note: for "estimated_outdoor_temp" we are assuming it's roughly the forecast temp to make a prediction
    const query = `
      INSERT INTO \`${datasetId}.temperature_predictions\` 
      (prediction_hour, device_id, predicted_temp_c, will_increase_6h, created_at)
      
      WITH forecast_data AS (
        SELECT * FROM UNNEST([
          STRUCT<prediction_hour TIMESTAMP, hour_of_day INT64, day_of_week INT64, real_outdoor_temp FLOAT64, humidity FLOAT64, estimated_outdoor_temp FLOAT64>
          ${forecastValues}
        ])
      ),
      active_devices AS (
        SELECT DISTINCT device_id
        FROM \`${datasetId}.raw_telemetry\`
        WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
        LIMIT 100
      ),
      prediction_inputs AS (
        SELECT 
          f.prediction_hour,
          d.device_id,
          f.hour_of_day,
          f.day_of_week,
          f.real_outdoor_temp,
          f.humidity,
          f.estimated_outdoor_temp
        FROM forecast_data f
        CROSS JOIN active_devices d
      ),
      reg_preds AS (
        SELECT * FROM ML.PREDICT(MODEL \`${datasetId}.temp_interior_model\`, (SELECT * FROM prediction_inputs))
      ),
      class_preds AS (
        SELECT * FROM ML.PREDICT(MODEL \`${datasetId}.temp_increase_model\`, (SELECT * FROM prediction_inputs))
      )
      
      SELECT 
        r.prediction_hour,
        r.device_id,
        r.predicted_temp_interior_c AS predicted_temp_c,
        c.predicted_will_increase_6h AS will_increase_6h,
        CURRENT_TIMESTAMP() AS created_at
      FROM reg_preds r
      JOIN class_preds c 
        ON r.prediction_hour = c.prediction_hour AND r.device_id = c.device_id;
    `;

    console.log('Running prediction query...');
    await bigquery.query({ query });
    console.log('Predictions completed and saved.');
    
    res.status(200).send('Predictions run and saved successfully.');
  } catch (error) {
    console.error('Error running predictions:', error);
    res.status(500).send('Internal Server Error');
  }
});
