-- Genera predicciones a 6 horas usando ML.FORECAST y guarda en predictions_6h
-- Este query es ejecutado por la Scheduled Query de BigQuery cada hora
CREATE OR REPLACE TABLE `wati-497921.iot_dataset.predictions_6h` AS
SELECT
  device_id,
  forecast_timestamp,
  forecast_value                      AS predicted_temp,
  prediction_interval_lower_bound     AS lower_bound,
  prediction_interval_upper_bound     AS upper_bound,
  0.9                                 AS confidence_level,
  CURRENT_TIMESTAMP()                 AS generated_at
FROM ML.FORECAST(
  MODEL `wati-497921.iot_dataset.temp_forecast_model`,
  STRUCT(6 AS horizon, 0.9 AS confidence_level)
)
