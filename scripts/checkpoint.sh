#!/usr/bin/env bash
# =============================================================================
# harness/checkpoint.sh — Validador de estado de cada fase
# =============================================================================
# Uso:
#   ./harness/checkpoint.sh --fase 1
#   ./harness/checkpoint.sh --fase 2 --final
#   ./harness/checkpoint.sh --all
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONTEXT_FILE="${ROOT_DIR}/context.json"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"

FASE=""
FINAL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --fase)  FASE="$2"; shift ;;
    --final) FINAL=true ;;
    --all)   FASE="all" ;;
  esac
  shift
done

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()   { echo -e "${GREEN}  ✅ $1${RESET}"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}  ❌ $1${RESET}"; FAIL=$((FAIL+1)); }
warn() { echo -e "${YELLOW}  ⚠️  $1${RESET}"; WARN=$((WARN+1)); }
info() { echo -e "${CYAN}  ℹ️  $1${RESET}"; }
h()    { echo -e "\n${BOLD}${BLUE}── $1 ──${RESET}"; }

PASS=0; FAIL=0; WARN=0

# Cargar variables de entorno
export PATH="${ROOT_DIR}/scripts/bin:/mnt/c/Users/Moises/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin:/mnt/c/Users/Moises/AppData/Local/Microsoft/WinGet/Packages/Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe:${PATH}"
[[ -f "${ROOT_DIR}/.env" ]] && source "${ROOT_DIR}/.env"
[[ -f "${ROOT_DIR}/.env.harness" ]] && source "${ROOT_DIR}/.env.harness"
export GCP_PROJECT_ID="${GCP_PROJECT_ID:-iot-pipeline-demo}"
export GCP_REGION="${GCP_REGION:-us-central1}"
export GCS_BUCKET_NAME="${GCS_BUCKET_NAME:-${GCS_BUCKET_IOT:-cloud-wati-iot-raw}}"
export BQ_DATASET="${BQ_DATASET:-iot_telemetry}"
export BQ_RAW_TABLE="${BQ_RAW_TABLE:-raw_telemetry}"
export BQ_ERRORS_TABLE="${BQ_ERRORS_TABLE:-errors}"
export BQ_LATEST_TABLE="${BQ_LATEST_TABLE:-latest_per_device}"
export FIRESTORE_DEVICES_COLLECTION="${FIRESTORE_DEVICES_COLLECTION:-devices}"
export CLOUD_FUNCTION_INGEST="${CLOUD_FUNCTION_INGEST:-ingest-telemetry}"
export CLOUD_FUNCTION_GCS_BATCH="${CLOUD_FUNCTION_GCS_BATCH:-process-gcs-batch}"
export CLOUD_FUNCTION_SCAN_BILL="${CLOUD_FUNCTION_SCAN_BILL:-scan-bill}"
export CLOUD_FUNCTION_REFRESH_LATEST="${CLOUD_FUNCTION_REFRESH_LATEST:-refresh-latest}"
export CLOUD_FUNCTION_RUN_AGENTS="${CLOUD_FUNCTION_RUN_AGENTS:-run-agents}"
export CLOUD_RUN_SERVICE="${CLOUD_RUN_SERVICE:-client-api}"
export SCHEDULER_REFRESH_JOB="${SCHEDULER_REFRESH_JOB:-refresh-latest}"
export SCHEDULER_RUN_AGENTS_JOB="${SCHEDULER_RUN_AGENTS_JOB:-run-agents}"
export SCHEDULER_CLEANUP_JOB="${SCHEDULER_CLEANUP_JOB:-cleanup}"

# ── Check helpers ─────────────────────────────────────────────────────────────
check_cmd() {
  local desc="$1"
  local cmd="$2"
  local expected_grep="${3:-}"
  local output
  if output=$(eval "$cmd" 2>&1); then
    if [[ -n "$expected_grep" ]] && ! echo "$output" | grep -q "$expected_grep"; then
      fail "$desc — output no contiene '$expected_grep'"
      [[ "${VERBOSE:-false}" = true ]] && echo "    Output: $output"
    else
      ok "$desc"
    fi
  else
    fail "$desc — comando falló: $cmd"
  fi
}

check_gcp_resource() {
  local desc="$1"
  local cmd="$2"
  if eval "$cmd" > /dev/null 2>&1; then
    ok "$desc"
  else
    fail "$desc"
  fi
}

# ── Checks por fase ────────────────────────────────────────────────────────────

checkpoint_fase_0() {
  h "Checkpoint Fase 0 — Pre-requisitos"
  check_cmd "gcloud autenticado" \
    "gcloud auth list --filter=status:ACTIVE --format='value(account)'" \
    "@"
  check_cmd "Proyecto configurado" \
    "gcloud config get-value project" \
    "${GCP_PROJECT_ID}"
  check_cmd "Node.js instalado (>= 18)" \
    "node --version" \
    "v1[89]\|v[2-9][0-9]"
  check_cmd "npm instalado" \
    "npm --version" \
    "[0-9]"
  check_cmd "Terraform instalado" \
    "terraform version" \
    "Terraform v"
  check_cmd "gcloud project activo" \
    "gcloud projects describe ${GCP_PROJECT_ID} --format='value(lifecycleState)'" \
    "ACTIVE"
}

checkpoint_fase_1() {
  h "Checkpoint Fase 1 — Infraestructura Terraform"
  check_gcp_resource "GCS bucket existe" \
    "gsutil ls gs://${GCS_BUCKET_NAME}/"
  check_gcp_resource "BigQuery dataset existe" \
    "bq ls --project_id=${GCP_PROJECT_ID} | grep ${BQ_DATASET}"
  check_gcp_resource "BigQuery tabla raw_telemetry existe" \
    "bq show --project_id=${GCP_PROJECT_ID} ${BQ_DATASET}.${BQ_RAW_TABLE}"
  check_gcp_resource "BigQuery tabla errors existe" \
    "bq show --project_id=${GCP_PROJECT_ID} ${BQ_DATASET}.${BQ_ERRORS_TABLE}"
  check_gcp_resource "Service account ingest-function-sa existe" \
    "gcloud iam service-accounts describe ingest-function-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  check_gcp_resource "Service account client-api-sa existe" \
    "gcloud iam service-accounts describe client-api-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  check_cmd "Schema BigQuery raw_telemetry (3 campos)" \
    "bq show --format=json --project_id=${GCP_PROJECT_ID} ${BQ_DATASET}.${BQ_RAW_TABLE} | node -e \"const fs=require('fs');const s=JSON.parse(fs.readFileSync(0,'utf8'));console.log((s.schema&&s.schema.fields?s.schema.fields.length:0));\"" \
    "3"
}

checkpoint_fase_2() {
  h "Checkpoint Fase 2 — Cloud Function"
  check_cmd "Cloud Function ingest existe y está ACTIVE" \
    "gcloud functions describe ${CLOUD_FUNCTION_INGEST} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(state)'" \
    "ACTIVE"
  check_cmd "Cloud Function ingest es HTTP" \
    "gcloud functions describe ${CLOUD_FUNCTION_INGEST} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(serviceConfig.uri)'" \
    "https://"
  check_cmd "Cloud Function ingest runtime Node.js 20" \
    "gcloud functions describe ${CLOUD_FUNCTION_INGEST} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(runtime)'" \
    "nodejs20"
}

checkpoint_fase_3() {
  h "Checkpoint Fase 3 — Cloud Function GCS Batch"
  check_cmd "Cloud Function batch existe y está ACTIVE" \
    "gcloud functions describe ${CLOUD_FUNCTION_GCS_BATCH} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(state)'" \
    "ACTIVE"
  check_cmd "Cloud Function batch trigger GCS configurado" \
    "gcloud functions describe ${CLOUD_FUNCTION_GCS_BATCH} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(eventTrigger.eventType)'" \
    "storage.object"
  check_cmd "Cloud Function batch runtime Node.js 20" \
    "gcloud functions describe ${CLOUD_FUNCTION_GCS_BATCH} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(runtime)'" \
    "nodejs20"
}

checkpoint_fase_4() {
  h "Checkpoint Fase 4 — Cloud Run API"
  check_cmd "Cloud Run service existe" \
    "gcloud run services describe ${CLOUD_RUN_SERVICE} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(status.conditions[0].status)'" \
    "True"
  local CLOUD_RUN_URL
  CLOUD_RUN_URL=$(gcloud run services describe "${CLOUD_RUN_SERVICE}" \
    --region="${GCP_REGION}" --project="${GCP_PROJECT_ID}" \
    --format='value(status.url)' 2>/dev/null || echo "")
  if [[ -n "$CLOUD_RUN_URL" ]]; then
    check_cmd "API /health retorna 200" \
      "curl -s -o /dev/null -w '%{http_code}' ${CLOUD_RUN_URL}/health" \
      "200"
    check_cmd "API /api/devices requiere auth" \
      "curl -s -o /dev/null -w '%{http_code}' ${CLOUD_RUN_URL}/api/devices" \
      "401\|403"
  else
    fail "No se pudo obtener URL de Cloud Run"
  fi
}

checkpoint_fase_5() {
  h "Checkpoint Fase 5 — Funciones Auxiliares + Scheduler"
  check_cmd "Cloud Function scan-bill ACTIVE" \
    "gcloud functions describe ${CLOUD_FUNCTION_SCAN_BILL} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(state)'" \
    "ACTIVE"
  check_cmd "Cloud Function refresh-latest ACTIVE" \
    "gcloud functions describe ${CLOUD_FUNCTION_REFRESH_LATEST} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(state)'" \
    "ACTIVE"
  check_cmd "Cloud Function run-agents ACTIVE" \
    "gcloud functions describe ${CLOUD_FUNCTION_RUN_AGENTS} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(state)'" \
    "ACTIVE"
  check_cmd "Scheduler refresh-latest ENABLED" \
    "gcloud scheduler jobs describe ${SCHEDULER_REFRESH_JOB} --location=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(state)'" \
    "ENABLED"
  check_cmd "Scheduler run-agents ENABLED" \
    "gcloud scheduler jobs describe ${SCHEDULER_RUN_AGENTS_JOB} --location=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(state)'" \
    "ENABLED"
  check_cmd "Scheduler cleanup ENABLED" \
    "gcloud scheduler jobs describe ${SCHEDULER_CLEANUP_JOB} --location=${GCP_REGION} --project=${GCP_PROJECT_ID} --format='value(state)'" \
    "ENABLED"
  check_cmd "BigQuery tabla latest_per_device existe" \
    "bq show --project_id=${GCP_PROJECT_ID} ${BQ_DATASET}.${BQ_LATEST_TABLE}" \
    ""
}

checkpoint_fase_6() {
  h "Checkpoint Fase 6 — Validacion E2E"
  check_cmd "BigQuery tiene datos de devices simulados" \
    "bq query --use_legacy_sql=false --format=csv --project_id=${GCP_PROJECT_ID} 'SELECT COUNT(DISTINCT device_id) FROM \`${GCP_PROJECT_ID}.${BQ_DATASET}.${BQ_RAW_TABLE}\` WHERE device_id LIKE \"device-sim-%\"' 2>/dev/null | tail -1" \
    "[1-9]"
  check_cmd "Firestore tiene documentos en devices" \
    "gcloud firestore documents list 'projects/${GCP_PROJECT_ID}/databases/(default)/documents/${FIRESTORE_DEVICES_COLLECTION}' --project=${GCP_PROJECT_ID} 2>&1 | grep -c 'name:'" \
    "[1-9]"
}

checkpoint_fase_7() {
  h "Checkpoint Fase 7 — Monitoreo y Free Tier"
  local ERROR_COUNT
  ERROR_COUNT=$(gcloud logging read \
    "resource.type=cloud_function AND severity=ERROR" \
    --project="${GCP_PROJECT_ID}" \
    --limit=100 \
    --freshness="1h" \
    --format='value(timestamp)' 2>/dev/null | wc -l || echo "0")
  if [[ "$ERROR_COUNT" -eq 0 ]]; then
    ok "Sin errores criticos en Cloud Function logs (ultima hora)"
  else
    warn "Cloud Function tiene ${ERROR_COUNT} error(es) en la ultima hora — revisar logs"
  fi
}

# ── Generar reporte checkpoint ─────────────────────────────────────────────────
generate_report() {
  local fase="$1"
  local report_file="${SCRIPT_DIR}/logs/checkpoint_fase${fase}_$(date +%Y%m%d_%H%M%S).md"

  cat > "$report_file" << REOF
# Checkpoint Report — Fase ${fase}
**Fecha:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Proyecto:** ${GCP_PROJECT_ID}
**Región:** ${GCP_REGION}

## Resultados

| Métrica | Valor |
|---------|-------|
| ✅ Pasados | ${PASS} |
| ❌ Fallidos | ${FAIL} |
| ⚠️ Advertencias | ${WARN} |
| **Total** | $((PASS + FAIL + WARN)) |

## Estado: $([ $FAIL -eq 0 ] && echo "✅ PASSED" || echo "❌ FAILED")

## Contexto Actual
\`\`\`json
$(cat "${CONTEXT_FILE}" 2>/dev/null || echo "{}")
\`\`\`
REOF
  echo ""
  info "Reporte guardado: $report_file"
}

# ── MAIN ───────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}"
echo "╔══════════════════════════════════════╗"
echo "║   IoT Pipeline — Checkpoint         ║"
echo "║   Fase: ${FASE:-all}                        ║"
echo "╚══════════════════════════════════════╝"
echo -e "${RESET}"

case "${FASE}" in
  0)   checkpoint_fase_0 ;;
  1)   checkpoint_fase_0; checkpoint_fase_1 ;;
  2)   checkpoint_fase_1; checkpoint_fase_2 ;;
  3)   checkpoint_fase_2; checkpoint_fase_3 ;;
  4)   checkpoint_fase_3; checkpoint_fase_4 ;;
  5)   checkpoint_fase_4; checkpoint_fase_5 ;;
  6)   checkpoint_fase_5; checkpoint_fase_6 ;;
  7|all)
    checkpoint_fase_0
    checkpoint_fase_1
    checkpoint_fase_2
    checkpoint_fase_3
    checkpoint_fase_4
    checkpoint_fase_5
    checkpoint_fase_6
    checkpoint_fase_7
    ;;
  *)
    echo "Uso: $0 --fase [0-7] [--final]"
    exit 1
    ;;
esac

echo ""
echo -e "${BOLD}─────────────────────────────────────${RESET}"
echo -e "  ${GREEN}Pasados: ${PASS}${RESET}  ${RED}Fallidos: ${FAIL}${RESET}  ${YELLOW}Advertencias: ${WARN}${RESET}"
echo -e "${BOLD}─────────────────────────────────────${RESET}"

generate_report "${FASE}"

if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}${BOLD}Checkpoint FALLIDO — ${FAIL} check(s) fallaron${RESET}"
  exit 1
else
  echo -e "${GREEN}${BOLD}Checkpoint PASADO ✅${RESET}"
  exit 0
fi
