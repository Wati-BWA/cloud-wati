#!/usr/bin/env bash
# =============================================================================
# harness/rollback.sh — Rollback y cleanup de recursos GCP
# =============================================================================
# Uso:
#   ./harness/rollback.sh --all              # Destruir TODO
#   ./harness/rollback.sh --fase 2           # Rollback de la fase 2
#   ./harness/rollback.sh --task T-006       # Rollback de una tarea
#   ./harness/rollback.sh --dry-run --all    # Ver qué se eliminaría
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOGFILE="${LOG_DIR}/rollback_$(date +%Y%m%d_%H%M%S).log"

DRY_RUN=false
MODE=""
TARGET=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true ;;
    --all)     MODE="all" ;;
    --fase)    MODE="fase"; TARGET="$2"; shift ;;
    --task)    MODE="task"; TARGET="$2"; shift ;;
  esac
  shift
done

log()     { echo -e "$1" | tee -a "$LOGFILE"; }
success() { log "${GREEN}✅ $1${RESET}"; }
error()   { log "${RED}❌ $1${RESET}"; }
warn()    { log "${YELLOW}⚠️  $1${RESET}"; }
info()    { log "${CYAN}ℹ️  $1${RESET}"; }

run_cmd() {
  local desc="$1"
  local cmd="$2"
  log "  → $desc"
  if [[ "$DRY_RUN" = true ]]; then
    warn "  [DRY-RUN] Ejecutaría: $cmd"
    return 0
  fi
  if eval "$cmd" 2>&1 | tee -a "$LOGFILE"; then
    success "  $desc — OK"
  else
    warn "  $desc — falló (puede ya estar eliminado)"
  fi
}

# ── Cargar variables ───────────────────────────────────────────────────────────
[[ -f "${ROOT_DIR}/.env" ]] && source "${ROOT_DIR}/.env"
export GCP_PROJECT_ID="${GCP_PROJECT_ID:-iot-pipeline-demo}"
export GCP_REGION="${GCP_REGION:-us-central1}"
export GCS_BUCKET_NAME="${GCS_BUCKET_NAME:-cloud-wati-iot-raw}"
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

# ── Rollbacks por componente ───────────────────────────────────────────────────

rollback_scheduler() {
  log "\n${BOLD}── Rollback: Cloud Scheduler ──${RESET}"
  run_cmd "Eliminar scheduler job refresh-latest" \
    "gcloud scheduler jobs delete ${SCHEDULER_REFRESH_JOB} --location=${GCP_REGION} --project=${GCP_PROJECT_ID} --quiet 2>/dev/null || true"
  run_cmd "Eliminar scheduler job run-agents" \
    "gcloud scheduler jobs delete ${SCHEDULER_RUN_AGENTS_JOB} --location=${GCP_REGION} --project=${GCP_PROJECT_ID} --quiet 2>/dev/null || true"
  run_cmd "Eliminar scheduler job cleanup" \
    "gcloud scheduler jobs delete ${SCHEDULER_CLEANUP_JOB} --location=${GCP_REGION} --project=${GCP_PROJECT_ID} --quiet 2>/dev/null || true"
  run_cmd "Eliminar tabla latest_per_device" \
    "bq rm -f --project_id=${GCP_PROJECT_ID} ${BQ_DATASET}.${BQ_LATEST_TABLE} 2>/dev/null || true"
}

rollback_cloud_run() {
  log "\n${BOLD}── Rollback: Cloud Run ──${RESET}"
  run_cmd "Eliminar Cloud Run service" \
    "gcloud run services delete ${CLOUD_RUN_SERVICE} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --quiet 2>/dev/null || true"
}

rollback_cloud_function() {
  log "\n${BOLD}── Rollback: Cloud Function ──${RESET}"
  run_cmd "Eliminar Cloud Function ingest-telemetry" \
    "gcloud functions delete ${CLOUD_FUNCTION_INGEST} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --quiet 2>/dev/null || true"
  run_cmd "Eliminar Cloud Function process-gcs-batch" \
    "gcloud functions delete ${CLOUD_FUNCTION_GCS_BATCH} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --quiet 2>/dev/null || true"
  run_cmd "Eliminar Cloud Function scan-bill" \
    "gcloud functions delete ${CLOUD_FUNCTION_SCAN_BILL} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --quiet 2>/dev/null || true"
  run_cmd "Eliminar Cloud Function refresh-latest" \
    "gcloud functions delete ${CLOUD_FUNCTION_REFRESH_LATEST} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --quiet 2>/dev/null || true"
  run_cmd "Eliminar Cloud Function run-agents" \
    "gcloud functions delete ${CLOUD_FUNCTION_RUN_AGENTS} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} --quiet 2>/dev/null || true"
}

rollback_terraform() {
  log "\n${BOLD}── Rollback: Infraestructura Terraform ──${RESET}"
  warn "CUIDADO: Esto eliminará GCS bucket, BigQuery dataset, Firestore y service accounts"
  if [[ "$DRY_RUN" = false ]]; then
    echo -e "${RED}${BOLD}¿Estás seguro? Escribe 'DESTRUIR' para confirmar:${RESET}"
    read -r confirm
    if [[ "$confirm" != "DESTRUIR" ]]; then
      warn "Rollback de Terraform cancelado."
      return 0
    fi
  fi
  if [[ -d "${ROOT_DIR}/iot-pipeline/terraform" ]]; then
    run_cmd "terraform destroy" \
      "cd ${ROOT_DIR}/iot-pipeline/terraform && terraform destroy -auto-approve"
  else
    warn "Directorio terraform no encontrado. Limpieza manual:"
    info "  gsutil rm -r gs://${GCS_BUCKET_NAME}/"
    info "  bq rm -r -f --project_id=${GCP_PROJECT_ID} ${BQ_DATASET}"
    info "  gcloud iam service-accounts delete ingest-function-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --quiet"
    info "  gcloud iam service-accounts delete client-api-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --quiet"
  fi
}

rollback_test_data() {
  log "\n${BOLD}── Rollback: Datos de prueba ──${RESET}"
  run_cmd "Eliminar datos de prueba de BigQuery" \
    "bq query --use_legacy_sql=false --project_id=${GCP_PROJECT_ID} \"DELETE FROM \\\`${GCP_PROJECT_ID}.${BQ_DATASET}.${BQ_RAW_TABLE}\\\` WHERE device_id LIKE 'device-%'\" 2>/dev/null || true"
  run_cmd "Eliminar archivos de prueba de GCS" \
    "gsutil -m rm gs://${GCS_BUCKET_NAME}/test/* 2>/dev/null || true"
  run_cmd "Eliminar datos simulados de GCS" \
    "gsutil -m rm -r gs://${GCS_BUCKET_NAME}/uploads/device-sim-* 2>/dev/null || true"
}

update_context_rollback() {
  if command -v python3 &>/dev/null && [[ -f "${ROOT_DIR}/context.json" ]]; then
    python3 - "${ROOT_DIR}/context.json" "$1" << 'PYEOF'
import json, sys
f, fase = sys.argv[1], int(sys.argv[2])
with open(f) as fp: ctx = json.load(fp)
# Remove tasks from this phase onwards
task_map = {
  0: ['T-001','T-002','T-003'],
  1: ['T-004','T-005','T-006'],
  2: ['T-007','T-008','T-009'],
  3: ['T-010','T-011','T-012'],
  4: ['T-013','T-014'],
  5: ['T-015','T-016','T-017'],
  6: ['T-018','T-019'],
  7: ['T-020','T-021','T-022']
}
tasks_to_remove = []
for f_num in range(fase, 8):
    tasks_to_remove.extend(task_map.get(f_num, []))
ctx['completed_tasks'] = [t for t in ctx.get('completed_tasks', []) if t not in tasks_to_remove]
ctx['current_phase'] = f'Fase {fase}'
with open(f, 'w') as fp: json.dump(ctx, fp, indent=2)
PYEOF
  fi
}

# ── MAIN ───────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${RED}"
echo "╔══════════════════════════════════════╗"
echo "║   IoT Pipeline — ROLLBACK           ║"
echo "╚══════════════════════════════════════╝"
echo -e "${RESET}"
[[ "$DRY_RUN" = true ]] && warn "MODO DRY-RUN — No se ejecutarán cambios reales"

case "$MODE" in
  all)
    rollback_test_data
    rollback_scheduler
    rollback_cloud_run
    rollback_cloud_function
    rollback_terraform
    update_context_rollback 0
    ;;
  fase)
    case "$TARGET" in
      2|3|5) rollback_cloud_function; update_context_rollback 2 ;;
      4) rollback_cloud_run; update_context_rollback 4 ;;
      6) rollback_test_data; update_context_rollback 6 ;;
      7) rollback_test_data; update_context_rollback 7 ;;
      1) rollback_terraform; update_context_rollback 1 ;;
      *) warn "Fase no reconocida: $TARGET" ;;
    esac
    ;;
  task)
    case "$TARGET" in
      T-004) rollback_terraform ;;
      T-008|T-011|T-012|T-015) rollback_cloud_function ;;
      T-016|T-017)
        rollback_cloud_function
        rollback_scheduler
        ;;
      T-014) rollback_cloud_run ;;
      T-018|T-019) rollback_test_data ;;
      *) warn "Rollback de tarea $TARGET no definido. Ver task YAML para instrucciones manuales." ;;
    esac
    ;;
  *)
    echo "Uso: $0 [--all | --fase N | --task T-XXX] [--dry-run]"
    exit 1
    ;;
esac

success "Rollback completado. Log: $LOGFILE"
