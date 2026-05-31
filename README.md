# cloud-wati — IoT Pipeline GCP

> **Build With AI 2026 · Wati CRE · Santa Cruz de la Sierra, Bolivia**

Pipeline IoT para ESP32-S3 con arquitectura 100% free tier en GCP.

## Arquitectura (SDD v2.1)

```
ESP32 (HTTP 30s) ──► ingest-telemetry ──► BigQuery raw_telemetry
                                      ──► Firestore devices/{id}
                                      └──► run-agents (async, si temp > 35°C)

ESP32 (NDJSON fallback) ──► GCS wati-497921-iot-esp32-uploads/uploads/
                        └──► process-gcs-batch ──► BigQuery

Cloud Scheduler ──► refresh-latest (cada 5 min) ──► latest_per_device
              └──► run-agents (cada 1h, alertas)

Flutter ──► Cloud Run API ──► Firestore (latest)
                         └──► BigQuery (history)

Flutter ──► scan-bill ──► Cloud Vision OCR ──► Firestore bills/{uid}
```

## Estructura del proyecto

```
cloud-wati/
├── functions/
│   ├── ingest-telemetry/   # HTTP trigger ESP32 (Node.js 20)
│   ├── process-gcs-batch/  # GCS trigger OBJECT_FINALIZE
│   ├── scan-bill/          # HTTP trigger OCR facturas CRE
│   ├── refresh-latest/     # HTTP trigger Cloud Scheduler
│   └── run-agents/         # HTTP interno, Gemini 1.5 Flash
├── cloud-run-api/          # Express API + Dockerfile
├── terraform/              # GCS, BigQuery, Firestore, IAM
├── spec/                   # JSON Schema, OpenAPI
├── scripts/                # generate-test-data.js
├── tasks/                  # Harness tasks T-001..T-022
├── skills/                 # Harness skills SK-001..SK-010
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

### Solo una fase

```bash
bash run.sh --from-fase 2   # Desde fase 2
bash run.sh --task T-007    # Una sola tarea
bash run.sh --dry-run       # Validar sin ejecutar
```

### Terraform (Fase 1)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars con tu project_id
terraform init
terraform plan
terraform apply
```

### Deploy manual (sin Cloud Build)

```bash
# Función ingest-telemetry
gcloud functions deploy ingest-telemetry \
  --gen2 --runtime=nodejs20 --region=us-central1 \
  --trigger-http --allow-unauthenticated \
  --memory=256MB --timeout=60s \
  --source=./functions/ingest-telemetry \
  --set-env-vars=GCP_PROJECT_ID=wati-497921,BQ_DATASET=iot_telemetry,BQ_RAW_TABLE=raw_telemetry,BQ_ERRORS_TABLE=errors,FIRESTORE_DEVICES_COLLECTION=devices
```

### Test rápido

```bash
# Simular ESP32 (reemplazar URL con la del deploy)
curl -X POST https://INGEST_FUNCTION_URL \
  -H 'Content-Type: application/json' \
  -d '{
    "hardware":    {"device_id":"TBOT-SCZ-00142","firmware_version":"1.0.7"},
    "tenant":      {"user_id":"uid_test"},
    "telemetry":   {"temp_interior_c":24.5,"temp_exterior_c":29.5,"samples_averaged":3},
    "diagnostics": {"uptime_s":3600,"wifi_rssi_dbm":-65}
  }'

# Generar datos de prueba NDJSON
node scripts/generate-test-data.js --count 10 --device TBOT-SCZ-00142 > /tmp/test.ndjson
gsutil cp /tmp/test.ndjson gs://wati-497921-iot-esp32-uploads/uploads/uid_test/$(date +%Y-%m-%d)/test.ndjson
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
| Cloud Scheduler | 3 jobs | 2 jobs ✅ |

---

## Integración con WeatherAPI y Predicciones de BQ ML (Fase 7)

### Obtener API Key de WeatherAPI
Para obtener los pronósticos meteorológicos de Santa Cruz de la Sierra:
1. Regístrate en [WeatherAPI.com](https://www.weatherapi.com/).
2. Genera una API Key gratuita (Free tier = 1M de llamadas al mes).
3. Guárdala en Google Cloud Secret Manager bajo el nombre `weather-api-key`:
   ```bash
   echo -n "TU_API_KEY" | gcloud secrets create weather-api-key \
       --data-file=- \
       --project=wati-497921
   ```

### Dashboard de Predicciones en Looker Studio
Para visualizar las predicciones de temperatura (incremento > 0.5°C o predicciones continuas):
1. Ingresa a [Looker Studio](https://lookerstudio.google.com/).
2. Crea una nueva fuente de datos ("Data Source") conectada a **BigQuery**.
3. Selecciona tu proyecto (`wati-497921`), el dataset `iot_telemetry` y la tabla `temperature_predictions`.
4. Utiliza los campos `prediction_hour` como eje X (tiempo), `predicted_temp_c` como métrica de temperatura estimada, y `will_increase_6h` (booleano) para resaltar momentos de riesgo de alta temperatura interior.

*SDD-001-GCP v2.1 · Revisado: 30 mayo 2026 · Demo Day: 31 mayo 2026*
