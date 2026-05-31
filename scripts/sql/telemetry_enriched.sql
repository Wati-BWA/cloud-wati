-- Vista que une telemetria de sensores con el pronostico meteorologico
-- Los datos de temperatura vienen de iot_telemetry.raw_telemetry (event_timestamp, temperature_celsius)
-- Los pronosticos vienen de iot_dataset.weather_forecasts (OpenWeatherMap)
CREATE OR REPLACE VIEW `wati-497921.iot_dataset.telemetry_enriched` AS
SELECT
  t.device_id,
  TIMESTAMP_TRUNC(t.event_timestamp, HOUR) AS timestamp,
  AVG(t.temperature_celsius)   AS temperature_in,
  AVG(w.temp)                  AS temperature_out,
  AVG(w.temp)                  AS weather_temp,
  AVG(w.humidity)              AS weather_humidity
FROM `wati-497921.iot_telemetry.raw_telemetry` t
LEFT JOIN `wati-497921.iot_dataset.weather_forecasts` w
  ON TIMESTAMP_TRUNC(t.event_timestamp, HOUR) = w.forecast_hour
WHERE t.event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
GROUP BY
  t.device_id,
  TIMESTAMP_TRUNC(t.event_timestamp, HOUR)
