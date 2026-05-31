import functions_framework
import requests
import os
from google.cloud import bigquery
from datetime import datetime

@functions_framework.http
def fetch_weather(request):
    """
    Fetches the 48-hour hourly forecast from OpenWeatherMap and inserts
    each hour into BigQuery table `iot_dataset.weather_forecasts`.
    API key injected via OPENWEATHER_API_KEY env var (Secret Manager binding).
    """
    api_key = os.environ.get("OPENWEATHER_API_KEY")
    if not api_key:
        return "OPENWEATHER_API_KEY not configured", 500

    lat, lon = -17.7893, -63.1862  # Santa Cruz de la Sierra, Bolivia
    url = (
        f"https://api.openweathermap.org/data/2.5/forecast"
        f"?lat={lat}&lon={lon}&appid={api_key}&units=metric&cnt=48"
    )

    resp = requests.get(url, timeout=10)
    resp.raise_for_status()
    data = resp.json()

    rows = []
    for entry in data.get("list", []):
        dt = datetime.utcfromtimestamp(entry["dt"])
        rows.append({
            "forecast_hour": dt.strftime("%Y-%m-%dT%H:%M:%S"),
            "temp":     round(entry["main"]["temp"], 2),
            "humidity": int(entry["main"]["humidity"]),
        })

    if not rows:
        return "No forecast data received", 200

    client = bigquery.Client()
    table_id = "wati-497921.iot_dataset.weather_forecasts"
    errors = client.insert_rows_json(table_id, rows)

    if errors:
        print(f"BigQuery insert errors: {errors}")
        return f"Insert errors: {errors}", 500

    print(f"Insertados {len(rows)} pronósticos horarios")
    return f"OK: {len(rows)} rows inserted", 200
