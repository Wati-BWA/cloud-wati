const functions = require('@google-cloud/functions-framework');
const { BigQuery } = require('@google-cloud/bigquery');

const bigquery = new BigQuery();

functions.http('trainModels', async (req, res) => {
  try {
    const datasetId = 'iot_telemetry';
    
    // Create or Replace Linear Regression model
    // Limits to 100k rows to stay within Free Tier limits.
    const queryRegression = `
      CREATE OR REPLACE MODEL \`${datasetId}.temp_interior_model\`
      OPTIONS(model_type='linear_reg', input_label_cols=['temp_interior_c']) AS
      SELECT
        t.telemetry.temp_interior_c,
        EXTRACT(HOUR FROM t.timestamp) AS hour_of_day,
        EXTRACT(DAYOFWEEK FROM t.timestamp) AS day_of_week,
        w.temp_c AS real_outdoor_temp,
        w.humidity AS humidity,
        t.telemetry.temp_exterior_c AS estimated_outdoor_temp
      FROM \`${datasetId}.raw_telemetry\` t
      JOIN \`${datasetId}.weather_forecast\` w
        ON TIMESTAMP_TRUNC(t.timestamp, HOUR) = TIMESTAMP_TRUNC(w.timestamp, HOUR)
      WHERE t.timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
      LIMIT 100000;
    `;

    // Create or Replace Logistic Regression model (binary classifier)
    // To predict if temperature will increase > 0.5C in the next 6 hours
    const queryClassification = `
      CREATE OR REPLACE MODEL \`${datasetId}.temp_increase_model\`
      OPTIONS(model_type='logistic_reg', input_label_cols=['will_increase_6h']) AS
      WITH future_temps AS (
        SELECT 
          device_id, 
          timestamp, 
          telemetry.temp_interior_c,
          LEAD(telemetry.temp_interior_c, 6) OVER (PARTITION BY device_id ORDER BY timestamp ASC) AS future_temp
        FROM \`${datasetId}.raw_telemetry\`
        WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
      )
      SELECT
        IF(f.future_temp - f.temp_interior_c > 0.5, TRUE, FALSE) AS will_increase_6h,
        EXTRACT(HOUR FROM t.timestamp) AS hour_of_day,
        EXTRACT(DAYOFWEEK FROM t.timestamp) AS day_of_week,
        w.temp_c AS real_outdoor_temp,
        w.humidity AS humidity,
        t.telemetry.temp_exterior_c AS estimated_outdoor_temp
      FROM \`${datasetId}.raw_telemetry\` t
      JOIN \`${datasetId}.weather_forecast\` w
        ON TIMESTAMP_TRUNC(t.timestamp, HOUR) = TIMESTAMP_TRUNC(w.timestamp, HOUR)
      JOIN future_temps f 
        ON t.device_id = f.device_id AND t.timestamp = f.timestamp
      WHERE f.future_temp IS NOT NULL
      LIMIT 100000;
    `;

    console.log('Starting regression model training...');
    await bigquery.query({ query: queryRegression });
    
    console.log('Starting classification model training...');
    await bigquery.query({ query: queryClassification });

    console.log('Model training completed.');
    res.status(200).send('Model training successfully initiated/completed.');
  } catch (error) {
    console.error('Error training models:', error);
    res.status(500).send('Internal Server Error');
  }
});
