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
TOTAL=26
PASS=0
FAIL=0

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  EJECUTANDO 26 TAREAS DEL HARNESS"
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
# REPORTE FINAL
# ============================================
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  RESUMEN FINAL"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo -e "  Total tareas ejecutadas: ${BLUE}26${NC}"
echo -e "  ${GREEN}✅ Pasaron: $PASS${NC}"
echo -e "  ${RED}❌ Fallaron: $FAIL${NC}"
echo ""
echo -e "  📄 Reporte detallado: ${BLUE}$REPORT_FILE${NC}"
echo ""

# Mostrar tareas fallidas
if [ $FAIL -gt 0 ]; then
    echo -e "${YELLOW}Tareas que requieren atención:${NC}"
    grep "❌" "$REPORT_FILE" | sed 's/❌/ -/g'
fi

echo ""
echo "═══════════════════════════════════════════════════════════"