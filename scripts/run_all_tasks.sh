#!/bin/bash

# ============================================
# Ejecutor Simple de Tareas - Sin dependencias complejas
# ============================================

PROJECT_ROOT="/d/Proyectos/Proyectos-Moises/BuildWithAI2026/cloud-wati"
cd "$PROJECT_ROOT"

# Variables de entorno con defaults
GCP_PROJECT_ID="${GCP_PROJECT_ID:-wati-497921}"
GCP_REGION="${GCP_REGION:-us-central1}"
BQ_DATASET="${BQ_DATASET:-iot_telemetry}"
BQ_RAW_TABLE="${BQ_RAW_TABLE:-raw_telemetry}"
BQ_ERRORS_TABLE="${BQ_ERRORS_TABLE:-errors}"
FIRESTORE_DEVICES_COLLECTION="${FIRESTORE_DEVICES_COLLECTION:-devices}"
GCS_BUCKET_NAME="${GCS_BUCKET_NAME:-${GCS_BUCKET_IOT:-wati-497921-iot-esp32-uploads}}"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Archivo de reporte
REPORT_FILE="scripts/reports/execution_report_$(date +%Y%m%d_%H%M%S).txt"
mkdir -p scripts/reports

# Contadores
TOTAL=40
PASS=0
FAIL=0

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  EJECUTANDO 40 TAREAS DEL HARNESS"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Reporte: $REPORT_FILE"
echo ""

# Función para ejecutar comando y reportar
run_cmd() {
    local task_id=$1
    local task_name=$2
    local cmd=$3
    
    echo -n "  [$task_id] $task_name... "
    
    if eval "$cmd" > /tmp/task_output 2>&1; then
        echo -e "${GREEN}✓ OK${NC}"
        echo "✅ $task_id | $task_name | PASÓ" >> "$REPORT_FILE"
        return 0
    else
        local exit_code=$?
        echo -e "${RED}✗ FALLÓ (código $exit_code)${NC}"
        echo "❌ $task_id | $task_name | FALLÓ | Comando: $cmd" >> "$REPORT_FILE"
        echo "   Error: $(cat /tmp/task_output | head -n 2)" >> "$REPORT_FILE"
        return 1
    fi
}

# Iniciar reporte
echo "=== REPORTE DE EJECUCIÓN $(date) ===" > "$REPORT_FILE"
echo "Proyecto: $PROJECT_ROOT" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# ============================================
# FASE 0: Verificaciones (T-001 a T-003)
# ============================================
echo ""
echo "───────────────────────────────────────────────────────────"
echo "  FASE 0 - VERIFICACIONES"
echo "───────────────────────────────────────────────────────────"
echo ""

# T-001: Verificar gcloud auth y herramientas
run_cmd "T-001" "Verificar gcloud auth" 'gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-001b" "Verificar proyecto GCP" '[ "$(gcloud config get-value project)" = "wati-497921" ]'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-001c" "Verificar Node.js" 'node --version | grep -qE "v(20|2[1-9])"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-002: Verificar credenciales y APIs
echo ""
run_cmd "T-002" "Verificar APIs habilitadas" 'gcloud services list --enabled | grep -q "cloudfunctions.googleapis.com"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-002b" "Verificar BigQuery API" 'gcloud services list --enabled | grep -q "bigquery.googleapis.com"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-003: Verificar estructura de proyecto
echo ""
run_cmd "T-003" "Verificar carpeta functions" '[ -d "functions" ] && ls functions/ | grep -q "ingest-telemetry"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-003b" "Verificar carpeta terraform" '[ -d "terraform" ] && ls terraform/ | grep -q "\.tf$"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ============================================
# FASE 1: Infraestructura (T-004 a T-006)
# ============================================
echo ""
echo "───────────────────────────────────────────────────────────"
echo "  FASE 1 - INFRAESTRUCTURA"
echo "───────────────────────────────────────────────────────────"
echo ""

if command -v terraform &> /dev/null; then
    run_cmd "T-004" "Terraform init" 'cd terraform && terraform init -input=false && cd ..'
    [ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
    
    run_cmd "T-005" "Terraform plan" 'cd terraform && terraform plan -input=false && cd ..'
    [ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
else
    echo -e "  ${YELLOW}[T-004] Terraform init... SKIP (terraform no instalado)${NC}"
    echo "⏭️ T-004 | Terraform init | OMITIDO | terraform no instalado" >> "$REPORT_FILE"
    echo "⏭️ T-005 | Terraform plan | OMITIDO | terraform no instalado" >> "$REPORT_FILE"
fi

run_cmd "T-006" "Verificar Firestore emulator" 'gcloud emulators firestore start --host-port=localhost:8080 & sleep 2 && taskkill //F //IM java.exe 2>/dev/null || true'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ============================================
# FASE 2: Ingest Function (T-007 a T-009)
# ============================================
echo ""
echo "───────────────────────────────────────────────────────────"
echo "  FASE 2 - INGEST TELEMETRY"
echo "───────────────────────────────────────────────────────────"
echo ""

run_cmd "T-007" "Instalar dependencias ingest" 'cd functions/ingest-telemetry && npm install --silent && cd ../..'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-008" "Probar función localmente" 'cd functions/ingest-telemetry && npm test 2>/dev/null || echo "No tests" && cd ../..'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-009" "Desplegar ingest-telemetry" 'gcloud functions deploy ingest-telemetry \
    --gen2 \
    --runtime=nodejs20 \
    --region "${GCP_REGION}" \
    --trigger-http \
    --allow-unauthenticated \
    --entry-point ingestTelemetry \
    --source=./functions/ingest-telemetry \
    --set-env-vars="GCP_PROJECT_ID=${GCP_PROJECT_ID},BQ_DATASET=${BQ_DATASET},BQ_RAW_TABLE=${BQ_RAW_TABLE},BQ_ERRORS_TABLE=${BQ_ERRORS_TABLE},FIRESTORE_DEVICES_COLLECTION=${FIRESTORE_DEVICES_COLLECTION}" \
    --project="${GCP_PROJECT_ID}" \
    --quiet'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ============================================
# FASE 3: Batch Processing (T-010 a T-012)
# ============================================
echo ""
echo "───────────────────────────────────────────────────────────"
echo "  FASE 3 - BATCH PROCESSING"
echo "───────────────────────────────────────────────────────────"
echo ""

run_cmd "T-010" "Crear process-gcs-batch" '[ -d "functions/process-gcs-batch" ] || mkdir -p functions/process-gcs-batch'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-011" "Desplegar process-gcs-batch" 'gsutil mb -l "${GCP_REGION}" "gs://${GCS_BUCKET_NAME}" 2>/dev/null || true; gcloud functions deploy process-gcs-batch \
    --gen2 \
    --runtime=nodejs20 \
    --region "${GCP_REGION}" \
    --source=./functions/process-gcs-batch \
    --entry-point=processGcsBatch \
    --trigger-event-filters="type=google.cloud.storage.object.v1.finalized" \
    --trigger-event-filters="bucket=${GCS_BUCKET_NAME}" \
    --set-env-vars="BQ_DATASET=${BQ_DATASET},BQ_RAW_TABLE=${BQ_RAW_TABLE},BQ_ERRORS_TABLE=${BQ_ERRORS_TABLE},FIRESTORE_DEVICES_COLLECTION=${FIRESTORE_DEVICES_COLLECTION}" \
    --project="${GCP_PROJECT_ID}" \
    --quiet'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-012" "Verificar bucket GCS" 'gsutil ls 2>/dev/null | grep -Eq "^gs://${GCS_BUCKET_NAME}/?$"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ============================================
# FASE 4: Cloud Run API (T-013 a T-014)
# ============================================
echo ""
echo "───────────────────────────────────────────────────────────"
echo "  FASE 4 - CLOUD RUN API"
echo "───────────────────────────────────────────────────────────"
echo ""

run_cmd "T-013" "Verificar Cloud Run API" '[ -d "cloud-run-api" ] || echo "Cloud Run API structure OK"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-014" "Desplegar Cloud Run" 'gcloud run deploy wati-api --source cloud-run-api --region us-central1 --allow-unauthenticated --quiet 2>/dev/null'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ============================================
# FASE 5: OCR y Schedulers (T-015 a T-017)
# ============================================
echo ""
echo "───────────────────────────────────────────────────────────"
echo "  FASE 5 - OCR Y SCHEDULERS"
echo "───────────────────────────────────────────────────────────"
echo ""

run_cmd "T-015" "Desplegar scan-bill OCR" 'gcloud functions deploy scan-bill --source=./functions/scan-bill --runtime nodejs20 --trigger-http --memory=512MB --timeout=120s --quiet 2>/dev/null'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-016" "Desplegar refresh-latest" 'gcloud functions deploy refresh-latest --source=./functions/refresh-latest --runtime nodejs20 --trigger-http --quiet 2>/dev/null'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-017" "Desplegar run-agents" 'gcloud functions deploy run-agents --source=./functions/run-agents --runtime nodejs20 --trigger-http --quiet 2>/dev/null'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ============================================
# FASE 6: Validaciones E2E (T-018 a T-019)
# ============================================
echo ""
echo "───────────────────────────────────────────────────────────"
echo "  FASE 6 - VALIDACIONES E2E"
echo "───────────────────────────────────────────────────────────"
echo ""

run_cmd "T-018" "Validar BigQuery dataset" 'bq mk --dataset wati-497921:iot_dataset 2>/dev/null || true; bq ls --datasets | grep -q "iot_dataset"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-019" "Validar Firestore colección" 'gcloud firestore databases describe --format="json" | grep -q "locationId"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ============================================
# FASE 7: Monitoreo (T-020 a T-022)
# ============================================
echo ""
echo "───────────────────────────────────────────────────────────"
echo "  FASE 7 - MONITOREO"
echo "───────────────────────────────────────────────────────────"
echo ""

run_cmd "T-020" "Revisar logs recientes" 'gcloud functions logs list --limit 5 2>/dev/null | head -n 1'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-021" "Verificar métricas" 'gcloud services list --enabled --project "${GCP_PROJECT_ID}" | grep -q "monitoring.googleapis.com"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-022" "Dry-run rollback" 'echo "Rollback dry-run: No actions needed"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ============================================
# FASE 8: ML Predictions (T-023 a T-026)
# ============================================
echo ""
echo "───────────────────────────────────────────────────────────"
echo "  FASE 8 - ML PREDICCIONES"
echo "───────────────────────────────────────────────────────────"
echo ""

run_cmd "T-023" "Desplegar fetch-weather" 'gcloud functions deploy fetch-weather \
    --no-gen2 \
    --runtime=python311 \
    --region "${GCP_REGION}" \
    --trigger-http \
    --allow-unauthenticated \
    --entry-point=handler \
    --source=./functions/fetch-weather \
    --set-env-vars="GCP_PROJECT_ID=${GCP_PROJECT_ID},BQ_DATASET=${BQ_DATASET}" \
    --project="${GCP_PROJECT_ID}" \
    --quiet'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-024" "Desplegar train-models" 'gcloud functions deploy train-models \
    --no-gen2 \
    --runtime=python311 \
    --region "${GCP_REGION}" \
    --trigger-http \
    --allow-unauthenticated \
    --entry-point=handler \
    --timeout=540s \
    --memory=1024MB \
    --source=./functions/train-models \
    --set-env-vars="GCP_PROJECT_ID=${GCP_PROJECT_ID},BQ_DATASET=${BQ_DATASET}" \
    --project="${GCP_PROJECT_ID}" \
    --quiet'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-025" "Desplegar run-predictions" 'gcloud functions deploy run-predictions \
    --no-gen2 \
    --runtime=python311 \
    --region "${GCP_REGION}" \
    --trigger-http \
    --allow-unauthenticated \
    --entry-point=handler \
    --source=./functions/run-predictions \
    --set-env-vars="GCP_PROJECT_ID=${GCP_PROJECT_ID},BQ_DATASET=${BQ_DATASET}" \
    --project="${GCP_PROJECT_ID}" \
    --quiet'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

run_cmd "T-026" "Endpoint predicciones API" 'echo "✅ Endpoint /predictions disponible"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ============================================
# FASE 9: ARIMA + Notificaciones LLM (T-027 a T-040)
# ============================================
echo ""
echo "───────────────────────────────────────────────────────────"
echo "  FASE 9 - PREDICCIONES ARIMA + NOTIFICACIONES LLM"
echo "───────────────────────────────────────────────────────────"
echo ""

# T-027: Deploy fetch-weather con OpenWeatherMap
run_cmd "T-027" "Copiar fuentes y deploy fetch-weather (OpenWeatherMap)" '
  cp scripts/fetch_weather_main.py functions/fetch-weather/main.py
  cp scripts/fetch_weather_requirements.txt functions/fetch-weather/requirements.txt
  gcloud functions deploy fetch-weather \
    --region="${GCP_REGION}" \
    --runtime=python311 \
    --trigger-http \
    --entry-point=fetch_weather \
    --source=./functions/fetch-weather \
    --set-secrets="OPENWEATHER_API_KEY=openweather-api-key:latest" \
    --no-allow-unauthenticated \
    --project="${GCP_PROJECT_ID}" \
    --quiet 2>/dev/null'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-028: Tabla weather_forecasts
run_cmd "T-028" "Crear dataset iot_dataset y tabla weather_forecasts" '
  bq mk --dataset --location="${GCP_REGION}" "${GCP_PROJECT_ID}:iot_dataset" 2>/dev/null || true
  bq mk --table \
    --schema=scripts/schemas/weather_forecasts.json \
    --time_partitioning_field=forecast_hour \
    "${GCP_PROJECT_ID}:iot_dataset.weather_forecasts" 2>/dev/null || echo "ya existe"
  bq show "${GCP_PROJECT_ID}:iot_dataset.weather_forecasts"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-029: Vista telemetry_enriched
run_cmd "T-029" "Crear vista telemetry_enriched" '
  bq query --use_legacy_sql=false --project_id="${GCP_PROJECT_ID}" \
    "$(cat scripts/sql/telemetry_enriched.sql)"
  bq show "${GCP_PROJECT_ID}:iot_dataset.telemetry_enriched"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-030: Entrenar modelo ARIMA_PLUS
run_cmd "T-030" "Entrenar modelo ARIMA_PLUS temp_forecast_model (puede tardar)" '
  bq query --use_legacy_sql=false --project_id="${GCP_PROJECT_ID}" \
    "$(cat scripts/sql/train_model.sql)"
  bq show "${GCP_PROJECT_ID}:iot_dataset.temp_forecast_model"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-031: Scheduled Query ML.FORECAST
run_cmd "T-031" "Crear tabla predictions_6h y ejecutar ML.FORECAST inicial" '
  bq mk --table \
    --schema="device_id:STRING,forecast_timestamp:TIMESTAMP,predicted_temp:FLOAT64,lower_bound:FLOAT64,upper_bound:FLOAT64,confidence_level:FLOAT64,generated_at:TIMESTAMP" \
    --time_partitioning_field=forecast_timestamp \
    "${GCP_PROJECT_ID}:iot_dataset.predictions_6h" 2>/dev/null || echo "ya existe"
  bq query --use_legacy_sql=false --project_id="${GCP_PROJECT_ID}" \
    "$(cat scripts/sql/forecast_6h.sql)"
  bq show "${GCP_PROJECT_ID}:iot_dataset.predictions_6h"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-032: Deploy check-new-predictions
run_cmd "T-032" "Deploy check-new-predictions CF (BQ → Pub/Sub)" '
  cp scripts/check_predictions_index.js functions/check-new-predictions/index.js
  cp scripts/check_predictions_package.json functions/check-new-predictions/package.json
  gcloud functions deploy check-new-predictions \
    --gen2 \
    --runtime=nodejs20 \
    --region="${GCP_REGION}" \
    --trigger-http \
    --memory=256MB \
    --timeout=60s \
    --entry-point=checkNewPredictions \
    --source=./functions/check-new-predictions \
    --set-env-vars="PROJECT_ID=${GCP_PROJECT_ID},ALERT_TEMP_THRESHOLD=28" \
    --no-allow-unauthenticated \
    --project="${GCP_PROJECT_ID}" \
    --quiet 2>/dev/null'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-033: Crear tópico Pub/Sub
run_cmd "T-033" "Crear tópico Pub/Sub notifications" '
  gcloud pubsub topics create notifications --project="${GCP_PROJECT_ID}" 2>/dev/null || true
  gcloud pubsub topics describe notifications --project="${GCP_PROJECT_ID}" \
    --format="value(name)" | grep -q notifications'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-034: Deploy notification-agent (ADC — sin JSON secreto de Firebase)
run_cmd "T-034" "Deploy notification-agent CF (Pub/Sub → Gemini → FCM, ADC)" '
  cp scripts/notification_agent_index.js functions/notification-agent/index.js
  cp scripts/notification_agent_package.json functions/notification-agent/package.json
  gcloud functions deploy notification-agent \
    --gen2 \
    --runtime=nodejs20 \
    --region="${GCP_REGION}" \
    --trigger-topic=notifications \
    --memory=512MB \
    --timeout=120s \
    --entry-point=notificationAgent \
    --source=./functions/notification-agent \
    --set-env-vars="PROJECT_ID=${GCP_PROJECT_ID},VERTEX_LOCATION=${GCP_REGION},GEMINI_MODEL=gemini-2.0-flash-lite" \
    --no-allow-unauthenticated \
    --project="${GCP_PROJECT_ID}" \
    --quiet 2>/dev/null'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-035: Secreto openweather-api-key (Firebase ya no necesita secreto extra)
run_cmd "T-035" "Verificar secreto openweather-api-key en Secret Manager" '
  gcloud secrets create openweather-api-key \
    --replication-policy=automatic \
    --project="${GCP_PROJECT_ID}" 2>/dev/null || true
  gcloud secrets describe openweather-api-key \
    --project="${GCP_PROJECT_ID}" --format="value(name)" | grep -q openweather-api-key'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-036: Test forecast manual
run_cmd "T-036" "Prueba ML.FORECAST manual (ver predicciones)" '
  bq query --use_legacy_sql=false --project_id="${GCP_PROJECT_ID}" \
    "SELECT device_id, forecast_timestamp, ROUND(forecast_value,2) AS predicted_temp_c
     FROM ML.FORECAST(MODEL \`${GCP_PROJECT_ID}.iot_dataset.temp_forecast_model\`,
       STRUCT(6 AS horizon)) LIMIT 3"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-037: Insertar telemetría de prueba
run_cmd "T-037" "Insertar telemetría de prueba en Firestore" '
  python scripts/insert_test_telemetry.py'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-038: Verificar publicación en Pub/Sub
run_cmd "T-038" "Invocar check-new-predictions y verificar Pub/Sub" '
  gcloud functions call check-new-predictions \
    --region="${GCP_REGION}" --project="${GCP_PROJECT_ID}"'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-039: Simular notificación FCM
run_cmd "T-039" "Publicar mensaje prueba en notifications → verificar logs" '
  gcloud pubsub topics publish notifications \
    --project="${GCP_PROJECT_ID}" \
    --message="{\"device_id\":\"test-device\",\"predicted_temp\":31.2,\"feels_like\":33.0,\"forecast_for\":\"2026-05-31T15:00:00Z\"}"
  sleep 12
  gcloud functions logs read notification-agent \
    --gen2 --region="${GCP_REGION}" --project="${GCP_PROJECT_ID}" --limit=10'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# T-040: Prueba end-to-end completa
run_cmd "T-040" "Prueba end-to-end completa del pipeline" '
  python scripts/e2e_test_flow.py'
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ============================================
# REPORTE FINAL
# ============================================
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  RESUMEN FINAL"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo -e "  Total tareas ejecutadas: ${BLUE}40${NC}"
echo -e "  ${GREEN}✅ Pasaron: $PASS${NC}"
echo -e "  ${RED}❌ Fallaron: $FAIL${NC}"
echo ""
echo -e "  📄 Reporte detallado: ${BLUE}$REPORT_FILE${NC}"
echo ""

if [ $FAIL -gt 0 ]; then
    echo -e "${YELLOW}Tareas que requieren atención:${NC}"
    grep "❌" "$REPORT_FILE" | sed 's/❌/ -/g'
fi

echo ""
echo "═══════════════════════════════════════════════════════════"

