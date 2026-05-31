const functions = require('@google-cloud/functions-framework');
const { BigQuery } = require('@google-cloud/bigquery');

const bigquery = new BigQuery();

const PROJECT_ID = process.env.GCP_PROJECT_ID || 'wati-497921';
const BQ_DATASET = process.env.BQ_DATASET || 'iot_dataset';
// Location is injected as env var by Cloud Function deploy; fallback = Santa Cruz de la Sierra
const DEFAULT_LOCATION = process.env.LOCATION || '-17.7833,-63.1821';

/**
 * Fetches the 48-hour hourly forecast from WeatherAPI.com and inserts
 * each hourly row into BigQuery table `weather_forecasts`.
 *
 * The API key is injected by Secret Manager via --set-secrets=WEATHER_API_KEY=...
 */
functions.http('fetchWeather', async (req, res) => {
  try {
    const apiKey = process.env.WEATHER_API_KEY;
    if (!apiKey) {
      throw new Error('WEATHER_API_KEY env var not set — check Secret Manager binding');
    }

    const location = req.body?.location || DEFAULT_LOCATION;
    const fetchedAt = BigQuery.timestamp(new Date());

    // WeatherAPI: forecast for 2 days → gives 48 hourly entries
    const url = `https://api.weatherapi.com/v1/forecast.json?key=${apiKey}&q=${location}&days=2&aqi=no&alerts=no`;
    const response = await fetch(url);

    if (!response.ok) {
      throw new Error(`WeatherAPI error ${response.status}: ${response.statusText}`);
    }

    const data = await response.json();
    const locationName = data.location?.name || location;

    // Build rows for BigQuery — one row per forecast hour
    const rows = [];
    for (const forecastDay of data.forecast.forecastday) {
      for (const hour of forecastDay.hour) {
        const forecastHour = BigQuery.timestamp(new Date(hour.time_epoch * 1000));
        rows.push({
          forecast_hour: forecastHour,
          location: locationName,
          temp_c: hour.temp_c,
          humidity: hour.humidity,
          feelslike_c: hour.feelslike_c,
          wind_kph: hour.wind_kph,
          condition_text: hour.condition?.text || '',
          fetched_at: fetchedAt,
        });
      }
    }

    if (rows.length === 0) {
      console.warn('[fetch-weather] No hourly data returned from WeatherAPI');
      return res.status(200).json({ status: 'ok', rows_inserted: 0 });
    }

    // Insert into BigQuery (streaming insert)
    const dataset = bigquery.dataset(BQ_DATASET);
    const table = dataset.table('weather_forecasts');
    await table.insert(rows, { skipInvalidRows: false, ignoreUnknownValues: false });

    console.log(`[fetch-weather] Inserted ${rows.length} hourly forecast rows for ${locationName}`);
    return res.status(200).json({
      status: 'ok',
      location: locationName,
      rows_inserted: rows.length,
      fetched_at: new Date().toISOString(),
    });

  } catch (err) {
    console.error('[fetch-weather] Error:', err);
    return res.status(500).json({ status: 'error', message: err.message });
  }
});
