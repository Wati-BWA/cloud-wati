-- Entrena el modelo ARIMA_PLUS usando la vista telemetry_enriched
-- Horizonte: 6 horas, una serie por device_id
-- Covariables: temperatura exterior y humedad del pronóstico
CREATE OR REPLACE MODEL `wati-497921.iot_dataset.temp_forecast_model`
OPTIONS(
  MODEL_TYPE      = 'ARIMA_PLUS',
  TIME_SERIES_TIMESTAMP_COL = 'timestamp',
  TIME_SERIES_DATA_COL      = 'temperature_in',
  TIME_SERIES_ID_COL        = 'device_id',
  HORIZON         = 6,
  AUTO_ARIMA      = TRUE,
  DATA_FREQUENCY  = 'HOURLY',
  DECOMPOSE_TIME_SERIES = TRUE
) AS
SELECT
  timestamp,
  device_id,
  temperature_in
FROM `wati-497921.iot_dataset.telemetry_enriched`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND temperature_in IS NOT NULL
