# cloud-wati — IoT Pipeline GCP

> **Build With AI 2026 · Wati · Santa Cruz de la Sierra, Bolivia**

Pipeline IoT para ESP32-S3 con arquitectura 100% free tier en GCP.

## Arquitectura (SDD v2.1)

```
ESP32 (HTTP 30s) ──► ingest-telemetry ──► BigQuery raw_telemetry
                                      ──► Firestore devices/{id}
                                      └──► run-agents (async, si temp > 35°C)

ESP32 (NDJSON fallback) ──► GCS wati-497921-iot-esp32-uploads/uploads/
                        └──► process-gcs-batch ──► BigQuery

Cloud Scheduler ──► temp-alerts-job (cada 1h)     ──► run-agents
              ├──► fetch-weather-job (cada 1h)   ──► fetch-weather
              └──► run-predictions-job (cada 6h) ──► run-predictions

React Web Admin ──► Firebase Hosting ──► Firestore (auth, users, devices)
                         └──► Cloud Run API (queries pesadas a BQ)

Flutter ──► Cloud Run API ──► Firestore (latest)
                         └──► BigQuery (history)

Flutter ──► scan-bill ──► Cloud Vision OCR ──► Firestore bills/{uid}
```

## Estructura del proyecto

```
cloud-wati/
├── functions/
│   ├── fetch-weather/      # HTTP trigger Scheduler, OpenWeather API
│   ├── ingest-telemetry/   # HTTP trigger ESP32 (Node.js 20)
│   ├── process-gcs-batch/  # GCS trigger OBJECT_FINALIZE
│   ├── run-agents/         # HTTP interno, Gemini 1.5 Pro (Mejor razonamiento)
│   ├── run-predictions/    # HTTP trigger Scheduler, BQ ML
│   ├── scan-bill/          # HTTP trigger OCR facturas CRE
│   └── train-models/       # HTTP trigger Scheduler, BQ ML
├── cloud-run-api/          # Express API + Dockerfile
├── terraform/              # GCS, BigQuery, Firestore, IAM
├── spec/                   # JSON Schema, OpenAPI
├── scripts/                # generadores y utilidades
├── tasks/                  # Harness tasks
├── skills/                 # Harness skills
├── cloudbuild.yaml         # CI/CD Cloud Build
├── gcp-health-check.sh     # Verificación de entorno
├── run.sh                  # Harness principal
├── checkpoint.sh           # Verificación por fase
├── rollback.sh             # Rollback por fase
├── context.json            # Estado de ejecución (runtime)
└── .env.harness            # Variables de entorno (plantilla)
```

## Quickstart

### Pre-requisitos

```bash
gcloud auth login
gcloud config set project wati-497921
gcloud auth application-default login
```

### Verificar entorno

```bash
bash gcp-health-check.sh
```

### Ejecutar plan completo (Harness)

```bash
# En Windows: usar Git Bash o WSL
source .env.harness
bash run.sh
```

### Terraform (Fase 1)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

### Generación de Datos de Prueba

```bash
# Simular ESP32 (reemplazar URL con la del deploy)
curl -X POST https://us-central1-wati-497921.cloudfunctions.net/ingest-telemetry \
  -H 'Content-Type: application/json' \
  -d '{
    "hardware":    {"device_id":"TBOT-SCZ-00142","firmware_version":"1.0.7"},
    "tenant":      {"user_id":"uid_test"},
    "telemetry":   {"temp_interior_c":24.5,"temp_exterior_c":29.5,"samples_averaged":3},
    "diagnostics": {"uptime_s":3600,"wifi_rssi_dbm":-65}
  }'
```

## Free Tier Status

| Servicio | Límite | Uso estimado (5 ESP32) |
|---|---|---|
| Cloud Functions 2gen | 2M inv/mes | 432K (21.6%) ✅ |
| BigQuery storage | 10 GB | < 1 GB ✅ |
| BigQuery queries | 1 TB/mes | < 20 GB ✅ |
| Firestore | 20K escrituras/día | 14.4K ✅ |
| GCS | 5 GB | < 1 GB ✅ |
| Cloud Run | 2M req/mes | < 50K ✅ |
| Cloud Vision | 1K unidades/mes | < 100 ✅ |
| Cloud Scheduler | 3 jobs | 3 jobs ✅ |

## Machine Learning y Weather (Fase 8)

El pipeline incluye agentes de Gemini, un cron para traer datos meteorológicos desde OpenWeather, entrenamiento de modelos en BigQuery ML y un cron de inferencias para proyectar temperaturas. Las predicciones y umbrales están automatizadas por completo utilizando la capacidad gratuita de BigQuery ML.

*Consolidado v3.0 · Revisado: 31 mayo 2026*