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

functions.http('fetchWeather', async (req, res) => {
  try {
    const apiKey = await getSecret('weather-api-key');
    const location = '-17.7833,-63.1821'; // Santa Cruz de la Sierra
    
    // Fetch current weather
    const response = await fetch(`https://api.weatherapi.com/v1/current.json?key=${apiKey}&q=${location}`);
    if (!response.ok) {
      throw new Error(`Weather API error: ${response.statusText}`);
    }
    const data = await response.json();
    
    const weatherRecord = {
      timestamp: BigQuery.timestamp(new Date()),
      temp_c: data.current.temp_c,
      humidity: data.current.humidity,
      feelslike_c: data.current.feelslike_c,
      pressure_mb: data.current.pressure_mb,
      condition_text: data.current.condition.text
    };

    // Insert into BigQuery
    const dataset = bigquery.dataset('iot_telemetry');
    const table = dataset.table('weather_forecast');
    
    await table.insert([weatherRecord]);
    
    console.log(`Weather data fetched and stored: ${JSON.stringify(weatherRecord)}`);
    res.status(200).send('Success');
  } catch (error) {
    console.error('Error fetching weather:', error);
    res.status(500).send('Internal Server Error');
  }
});
