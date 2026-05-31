# IMPLEMENTATION PLAN v3 — IoT Pipeline GCP (HTTP + GCS Batch)

> Generado para cumplir Master_Prompt.md (Fases 0–7) y SDD v2.1
> Este plan usa tasks_v3/task_T-###.yaml y deja los artefactos previos intactos.

---

## Vision General

Pipeline IoT para ESP32-S3 con ingest HTTP cada 30s y fallback por GCS (NDJSON). El backend asigna timestamp server-side, escribe a BigQuery y actualiza Firestore, con API en Cloud Run y funciones auxiliares.

```
ESP32 (HTTP) -> Cloud Function ingest-telemetry -> BigQuery raw_telemetry
                                   |            -> Firestore devices/{id}
ESP32 (NDJSON) -> GCS uploads/ -> Cloud Function process-gcs-batch -> BigQuery

React Web Admin (Firebase Hosting) -> Firestore / Cloud Run API
Cloud Run API (Firebase Auth) -> /api/devices
Cloud Scheduler -> temp-alerts-job, fetch-weather-job, run-predictions-job
```

---

## Fases (orden estricto)

| Fase | Nombre | Tareas |
|------|--------|--------|
| 0 | Pre-requisitos y entorno local | T-001, T-002, T-003 |
| 1 | Infraestructura base (Terraform) | T-004, T-005, T-006 |
| 2 | Cloud Function ingest-telemetry (HTTP) | T-007, T-008, T-009 |
| 3 | Cloud Function process-gcs-batch (GCS) | T-010, T-011, T-012 |
| 4 | Cloud Run API + Firebase Auth | T-013, T-014 |
| 5 | Funciones auxiliares + Scheduler | T-015, T-016, T-017 |
| 6 | Validacion end-to-end | T-018, T-019 |
| 7 | Monitoreo y free tier | T-020, T-021, T-022 |
| 8 | Machine Learning y WeatherAPI | T-023... |

---

## Variables y Convenciones Canónicas

> **Fuente de verdad:** Esta sección es la referencia única para todas las variables del proyecto.

### Variables de entorno (tabla canónica)

| Variable de entorno | Valor |
|---------------------|-------|
| `GCP_PROJECT_ID` | `wati-497921` |
| `GCP_REGION` | `us-central1` |
| `GCS_BUCKET_IOT` | `wati-497921-iot-esp32-uploads` |
| `GCS_BUCKET_BILLS` | `wati-497921-bills-ocr` |
| `BQ_DATASET` | `iot_telemetry` |
| `BQ_RAW_TABLE` | `raw_telemetry` |
| `BQ_ERRORS_TABLE` | `errors` |
| `BQ_LATEST_TABLE` | `latest_per_device` |
| `FIRESTORE_DATABASE` | `(default)` |
| `FIRESTORE_DEVICES_COLLECTION` | `devices` |
| `CLOUD_RUN_SERVICE` | `cloud-wati` |

### Cloud Functions (nombres canónicos)

| Variable | Nombre de función | Trigger | Fase |
|----------|------------------|---------|------|
| `CLOUD_FUNCTION_INGEST` | `ingest-telemetry` | HTTP | Fase 2 |
| `CLOUD_FUNCTION_GCS_BATCH` | `process-gcs-batch` | GCS OBJECT_FINALIZE | Fase 3 |
| `CLOUD_FUNCTION_SCAN_BILL` | `scan-bill` | HTTP (auth) | Fase 5 |
| `CLOUD_FUNCTION_REFRESH_LATEST` | `refresh-latest` | HTTP | Fase 5 |
| `CLOUD_FUNCTION_RUN_AGENTS` | `run-agents` | HTTP interno | Fase 5 |
| `CLOUD_FUNCTION_FETCH_WEATHER` | `fetch-weather` | HTTP (Scheduler) | Fase ML (8) |
| `CLOUD_FUNCTION_TRAIN_MODELS` | `train-models` | HTTP (Scheduler) | Fase ML (8) |
| `CLOUD_FUNCTION_RUN_PREDICTIONS` | `run-predictions` | HTTP (Scheduler) | Fase ML (8) |

### Cloud Scheduler Jobs (max 3 en free tier)

| Job | Función | Schedule (UTC) | Payload | Slot |
|-----|---------|---------------|---------|------|
| `temp-alerts-job` | `run-agents` | `0 */1 * * *` (cada 1h) | `{"trigger": "scheduled_check"}` | 1/3 |
| `fetch-weather-job` | `fetch-weather` | `0 * * * *` (cada 1h) | `{}` | 2/3 |
| `run-predictions-job` | `run-predictions` | `0 */6 * * *` (cada 6h) | `{}` | 3/3 |

### BigQuery — Tablas

| Tabla | Dataset | Propósito | Partición |
|-------|---------|-----------|-----------|
| `raw_telemetry` | `iot_telemetry` | Datos crudos de ESP32 | `DATE(timestamp)` |
| `errors` | `iot_telemetry` | Payloads inválidos / dead letter | `DATE(received_at)` |
| `latest_per_device` | `iot_telemetry` | Última lectura por dispositivo | — |
| `weather_forecast` | `iot_telemetry` | Datos meteorológicos externos | `DATE(fetch_time)` |
| `temperature_predictions` | `iot_telemetry` | Predicciones BQ ML | `DATE(prediction_hour)` |

### Firestore — Colecciones

| Colección | Path | Descripción |
|-----------|------|-------------|
| `users` | `users/{uid}` | Perfil usuario (Firebase Auth UID) |
| `devices` | `devices/{device_id}` | Snapshot RT + deduplicación |
| `devices/notifications` | `devices/{device_id}/notifications/{id}` | Últimas 20 alertas |
| `bills` | `bills/{uid}/history/{bill_id}` | Historial OCR facturas CRE |
| `api_keys` | `api_keys/{key_id}` | Claves B2B integradores |

### Secret Manager

| Nombre del secreto | Contenido | Usado por |
|-------------------|-----------|-----------|
| `device-secret` | Token de autenticación ESP32 | `ingest-telemetry` |
| `gemini-key` | Gemini API key (Vertex AI) | `run-agents`, `cloud-wati` |
| `vision-api-key` | Cloud Vision API key | `scan-bill` |
| `weather-api-key` | WeatherAPI.com (u OpenWeather) key | `fetch-weather` |

### Dispositivos de referencia (testing)

| device_id | Descripción |
|-----------|-------------|
| `TBOT-SCZ-00142` | Dispositivo de prueba principal |

---

## Archivo `.env.harness` — Template Completo

```bash
# Copiar a .env y completar
export GCP_PROJECT_ID="wati-497921"
export GCP_REGION="us-central1"
export GCS_BUCKET_IOT="wati-497921-iot-esp32-uploads"
export GCS_BUCKET_BILLS="wati-497921-bills-ocr"
export BQ_DATASET="iot_telemetry"
export BQ_RAW_TABLE="raw_telemetry"
export BQ_ERRORS_TABLE="errors"
export BQ_LATEST_TABLE="latest_per_device"
export FIRESTORE_DEVICES_COLLECTION="devices"
export CLOUD_RUN_SERVICE="cloud-wati"
export CLOUD_FUNCTION_INGEST="ingest-telemetry"
export CLOUD_FUNCTION_GCS_BATCH="process-gcs-batch"
export CLOUD_FUNCTION_SCAN_BILL="scan-bill"
export CLOUD_FUNCTION_REFRESH_LATEST="refresh-latest"
export CLOUD_FUNCTION_RUN_AGENTS="run-agents"
export CLOUD_FUNCTION_FETCH_WEATHER="fetch-weather"
export CLOUD_FUNCTION_TRAIN_MODELS="train-models"
export CLOUD_FUNCTION_RUN_PREDICTIONS="run-predictions"
export SCHEDULER_RUN_AGENTS_JOB="temp-alerts-job"
export SCHEDULER_FETCH_WEATHER_JOB="fetch-weather-job"
export SCHEDULER_PREDICTIONS_JOB="run-predictions-job"
```

---

## Harness

```bash
./run.sh                    # Ejecutar todo
./run.sh --from-fase 2      # Desde fase 2
./run.sh --task T-007       # Ejecutar una tarea
./run.sh --dry-run          # Validar sin ejecutar
./checkpoint.sh --fase 4    # Verificar fase 4
./rollback.sh --fase 3      # Rollback fase 3
```

---

## Notas de context.json

- Se inicializa en Fase 0.
- Se actualiza solo al final de cada fase.
- Estructura alineada a Master_Prompt.md con variables, funciones y test_results.

---

## Arbol de dependencias

```
T-001 -> T-002 -> T-003 -> T-004 -> T-005 -> T-006
                                  -> T-007 -> T-008 -> T-009
                                             -> T-010 -> T-011 -> T-012
                                                        -> T-013 -> T-014
                                                                   -> T-015 -> T-016 -> T-017
                                                                              -> T-018 -> T-019
                                                                                         -> T-020 -> T-021 -> T-022
```

---

## Validaciones clave

- Ingest HTTP valida payload: device_id + temperature_celsius.
- BigQuery raw_telemetry schema: device_id, temperature_celsius, event_timestamp.
- Firestore devices/{id} actualizado con ultima telemetria.
- Cloud Run API protegida con Firebase Auth.
- React Web Admin desplegado en Firebase Hosting comunicándose con Firestore.
- Scheduler con tres jobs: run-agents, fetch-weather, run-predictions.
- E2E: HTTP directo + NDJSON a GCS generan filas en BigQuery.

---

Generado por Harness Engineer (v3)
