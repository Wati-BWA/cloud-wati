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

Cloud Run API (Firebase Auth) -> /api/devices
Cloud Scheduler -> refresh-latest, run-agents, cleanup
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

---

## Variables de entorno (referencia)

```bash
export GCP_PROJECT_ID="wati-497921"
export GCP_REGION="us-central1"
export GCS_BUCKET_NAME="wati-497921-iot-esp32-uploads"
export BQ_DATASET="iot_telemetry"
export BQ_RAW_TABLE="raw_telemetry"
export BQ_ERRORS_TABLE="errors"
export BQ_LATEST_TABLE="latest_per_device"
export FIRESTORE_DEVICES_COLLECTION="devices"
export CLOUD_FUNCTION_INGEST="ingest-telemetry"
export CLOUD_FUNCTION_GCS_BATCH="process-gcs-batch"
export CLOUD_FUNCTION_SCAN_BILL="scan-bill"
export CLOUD_FUNCTION_REFRESH_LATEST="refresh-latest"
export CLOUD_FUNCTION_RUN_AGENTS="run-agents"
export CLOUD_RUN_SERVICE="client-api"
export SCHEDULER_REFRESH_JOB="refresh-latest"
export SCHEDULER_RUN_AGENTS_JOB="run-agents"
export SCHEDULER_CLEANUP_JOB="cleanup"
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
- Scheduler con tres jobs: refresh-latest, run-agents, cleanup.
- E2E: HTTP directo + NDJSON a GCS generan filas en BigQuery.

---

Generado por Harness Engineer (v3)
