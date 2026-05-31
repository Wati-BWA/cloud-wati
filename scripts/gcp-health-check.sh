#!/bin/bash
# gcp-health-check.sh - Verifica que el entorno GCP está listo

set -e

echo "🔍 Verificando entorno GCP..."

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILED=0

# 1. Verificar gcloud instalado
if command -v gcloud &> /dev/null; then
    echo -e "${GREEN}✅ gcloud encontrado: $(gcloud --version | head -n1)${NC}"
else
    echo -e "${RED}❌ gcloud no instalado${NC}"
    FAILED=$((FAILED+1))
fi

# 2. Verificar autenticación activa
if gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
    ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
    echo -e "${GREEN}✅ Autenticación activa: $ACTIVE_ACCOUNT${NC}"
else
    echo -e "${RED}❌ No hay cuenta autenticada. Ejecutar: gcloud auth login${NC}"
    FAILED=$((FAILED+1))
fi

# 3. Verificar proyecto configurado
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "(unset)" ]; then
    echo -e "${GREEN}✅ Proyecto activo: $PROJECT_ID${NC}"
else
    echo -e "${RED}❌ No hay proyecto configurado. Ejecutar: gcloud config set project PROYECTO-ID${NC}"
    FAILED=$((FAILED+1))
fi

# 4. Verificar cuenta de servicio para despliegue
if [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    echo -e "${GREEN}✅ Credenciales de servicio encontradas en: $GOOGLE_APPLICATION_CREDENTIALS${NC}"
    # Verificar que la clave es válida
    if gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS" --quiet 2>/dev/null; then
        echo -e "${GREEN}✅ Cuenta de servicio válida${NC}"
    else
        echo -e "${RED}❌ La clave de servicio no funciona${NC}"
        FAILED=$((FAILED+1))
    fi
else
    echo -e "${YELLOW}⚠️  Variable GOOGLE_APPLICATION_CREDENTIALS no está configurada o archivo no existe${NC}"
    echo "   El agente usará autenticación de usuario (gcloud auth)"
fi

# 5. Verificar APIs habilitadas
REQUIRED_APIS=("cloudfunctions.googleapis.com" "run.googleapis.com" "bigquery.googleapis.com" "firestore.googleapis.com" "storage.googleapis.com")
for API in "${REQUIRED_APIS[@]}"; do
    if gcloud services list --enabled --filter="config.name=$API" --format="value(config.name)" | grep -q "$API"; then
        echo -e "${GREEN}✅ API habilitada: $API${NC}"
    else
        echo -e "${RED}❌ API no habilitada: $API${NC}"
        echo "   Ejecutar: gcloud services enable $API"
        FAILED=$((FAILED+1))
    fi
done

# 6. Verificar cuotas disponibles (opcional)
echo -e "\n📊 Cuotas actuales (uso vs límite):"
gcloud compute regions describe us-central1 --format="table(quotas.metric, quotas.limit, quotas.usage)" | head -n 5

# Resumen final
echo -e "\n========================================="
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✅✅✅ ENTORNO GCP LISTO PARA DESPLIEGUE ✅✅✅${NC}"
    exit 0
else
    echo -e "${RED}❌❌❌ $FAILED problema(s) encontrado(s). Corregir antes de continuar. ❌❌❌${NC}"
    exit 1
fi