# SDD-001-GCP v2.1 — Wati

## Cloud / GCP — Stack Corregido para Free Tier Real

| Campo | Valor |
|---|---|
| Documento | SDD-001-GCP |
| Versión | 2.1 (ajuste a firmware real) |
| Basado en | RFC-001 Wati |
| Stack principal | Cloud Functions 2gen · GCS · Firestore · BigQuery · Gemini API · Cloud Vision · Cloud Run |
| Objetivo | MVP demo-ready 100% free tier |

---

## CAMBIOS RESPECTO A v2.0

| Componente v2.0 | Decisión v2.1 | Razón |
|---|---|---|
| Sensores (PZEM, PIR, IR, OLED) | ❌ **Eliminado** | Firmware real solo DS18B20 (temperatura) |
| Payload plano con `timestamp` | ✅ **Anidado sin timestamp** | El backend asigna `timestamp` al recibir |
| BLE provisioning | ❌ **Eliminado** | WiFi hardcodeado en firmware |
| NTP en dispositivo | ❌ **Eliminado** | No se envian timestamps desde el ESP32 |
| Comandos IR (`pending_commands`) | ❌ **Eliminado** | No hay actuadores en MVP |

---

## 1. Arquitectura v2.1

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    GOOGLE CLOUD PROJECT: wati-497921                    │
│                                                                         │
│   ESP32-S3                                                              │
│   (cada 30s) ──HTTPS POST──► Cloud Function 2gen: ingest-telemetry     │
│                              (Node.js 20, trigger HTTP)                 │
│                                    │                                    │
│                          ┌─────────┴──────────┐                        │
│                          │                    │                        │
│                    Firestore              BigQuery                      │
│                    devices/{id}           iot_telemetry.raw_telemetry   │
│                    (snapshot RT)          (particionado por fecha)      │
│                          │                    │                        │
│                          │              iot_telemetry.errors            │
│                          │              (dead letter)                   │
│                          │                                              │
│   ESP32-S3                                                              │
│   (batch/diario) ─NDJSON──► GCS Bucket: wati-497921-iot-esp32-uploads   │
│                              uploads/{user_id}/{date}/{device}.ndjson   │
│                                    │                                    │
│                              Cloud Function 2gen: process-gcs-batch     │
│                              (trigger: OBJECT_FINALIZE)                 │
│                                    │                                    │
│                              BigQuery (raw + errors)                    │
│                                                                         │
│   ┌──────────────────────────────────────────────────────────────────┐ │
│   │  Cloud Functions 2gen (Node.js 20)                               │ │
│   │  1. ingest-telemetry   ← HTTP trigger (ESP32 directo)            │ │
│   │  2. process-gcs-batch  ← GCS trigger OBJECT_FINALIZE            │ │
│   │  3. run-agents         ← HTTP/Pub/Sub (orquesta Gemini)          │ │
│   │  4. scan-bill          ← HTTP (OCR facturas)                     │ │
│   │  5. fetch-weather      ← HTTP trigger (Cloud Scheduler)          │ │
│   │  6. train-models       ← HTTP trigger (Cloud Scheduler)          │ │
│   │  7. run-predictions    ← HTTP trigger (Cloud Scheduler)          │ │
│   └──────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│   Flutter App ─JWT──► Cloud Run (Node.js/Express): cloud-wati         │
│                        GET /api/devices/:user_id                        │
│                        GET /api/devices/:device_id/latest               │
│                        GET /api/devices/:device_id/history              │
│                              │                                          │
│                     Firestore (snapshot) + BigQuery (historico)         │
│                                                                         │
│   Admin/Operador ──► Looker Studio (conectado a BigQuery, sin costo)   │
│                                                                         │
│   ┌──────────────────────────────────────────────────────────────────┐ │
│   │  Servicios de soporte                                            │ │
│   │  Firebase Auth     → usuarios Flutter (Google Sign-In)           │ │
│   │  Firebase FCM      → push notifications al móvil                 │ │
│   │  Cloud Vision API  → OCR facturas CRE (1,000 req/mes gratis)    │ │
│   │  Vertex AI Gemini  → agentes IA (free tier disponible)           │ │
│   │  Secret Manager    → API keys, tokens                              │ │
│   │  Cloud Scheduler   → 3 jobs gratis (alertas, weather, predics)   │ │
│   │  Cloud Build       → CI/CD (120 min/día gratis)                  │ │
│   └──────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Payload IoT (ESP32 → ingest-telemetry)

```json
{
  "hardware": { "device_id": "TBOT-SCZ-00142", "firmware_version": "1.0.7" },
  "tenant": { "user_id": "uid_abc" },
  "telemetry": { "temp_interior_c": 24.5, "temp_exterior_c": 29.5, "samples_averaged": 3 },
  "diagnostics": { "uptime_s": 3600, "wifi_rssi_dbm": -65 }
}
```

- `timestamp` **no se envia** desde el ESP32; lo asigna la Cloud Function al recibir.
- `temp_exterior_c` es simulada en firmware como `temp_interior_c + 5`.

---

## 2. Free Tier — Limites y Calculo Real

### 2.1 Tabla de servicios en uso

| Servicio | Free Tier | Uso estimado (MVP ~5 dispositivos) | Estado |
|---|---|---|---|
| **Cloud Functions 2gen** | 2M invocaciones/mes, 400K GB-seg | ~432K inv/mes (30s × 5 ESP32) | ✅ Dentro |
| **GCS** | 5 GB storage, 5K ops/mes Standard | <1 GB, <1K ops (batch diario) | ✅ Dentro |
| **BigQuery storage** | 10 GB activo/mes | <1 GB estimado primer mes | ✅ Dentro |
| **BigQuery queries** | 1 TB/mes | <20 GB (consultas acotadas) | ✅ Dentro |
| **Firestore** | 1 GB storage, 50K lecturas/dia, 20K escrituras/dia | ~14.4K escrituras/dia (5 ESP32 × 30s) | ✅ Dentro |
| **Cloud Run** | 2M req/mes, 360K GB-seg | <50K req/mes (API Flutter) | ✅ Dentro |
| **Cloud Vision** | 1,000 unidades/mes | <100 (OCR facturas) | ✅ Dentro |
| **Firebase Auth** | Sin límite en free tier | N/A | ✅ |
| **Firebase FCM** | Sin límite en free tier | N/A | ✅ |
| **Cloud Scheduler** | 3 jobs gratis | 3 jobs (alertas, openweather, predict) | ✅ Dentro |
| **Secret Manager** | 6 secrets activos gratis | ~4 secrets | ✅ Dentro |
| **Cloud Build** | 120 min/día gratis | <15 min por deploy | ✅ Dentro |
| **Looker Studio** | Gratuito conectado a BQ | Admin dashboard | ✅ |

---

## 3. GCS — Data Lake IoT

### 3.1 Estructura del bucket

```
Bucket: wati-497921-iot-esp32-uploads
├── uploads/
│   └── {user_id}/
│       └── {YYYY-MM-DD}/
│           └── {device_id}_{timestamp}.ndjson   ← newline-delimited JSON
└── processed/
    └── {YYYY-MM-DD}/
        └── {device_id}_{timestamp}.ndjson        ← archivos procesados (movidos)
```

### 3.2 Cuando usa el ESP32 GCS vs HTTP directo

HTTP directo → Cloud Function  (cada 30s, datos individuales, real-time)
GCS upload   → Cloud Function  (batch diario o cuando hay problemas de conectividad)

El ESP32 acumula en memoria hasta:
  a) 100 registros, o
  b) 5 minutos sin conexión
y sube el archivo NDJSON al bucket como fallback.

---

## 4. Cloud Functions 2gen — Definicion Completa

- `ingest-telemetry`: Trigger HTTP directo desde los ESP32.
- `process-gcs-batch`: Trigger GCS cuando se suben NDJSON con atrasos.
- `scan-bill`: HTTP (para procesar facturas CRE vía OCR).
- `run-agents`: Trigger HTTP de cron scheduler para alertas.
- `fetch-weather`: Trigger HTTP de cron scheduler, inserta a BQ tabla weather_forecast.
- `train-models`: Trigger HTTP que usa BQ ML para predecir modelo.
- `run-predictions`: Trigger HTTP de cron scheduler para evaluar predicciones de temperatura.

---

## 5. BigQuery — Esquema v2.1

La estructura y los schemas se aplican desde Terraform y se utilizan tanto en las APIs como en los pipelines. Para variables exactas ver `docs/design.md`.

---

## 6. Firestore — Estructura Consolidada v2.1

Consolidada en `devices/{device_id}` para guardar el estado RT sin la necesidad de un cache por separado.
Ver `docs/design.md` para detalle de colecciones de Firebase.

---

## 7. Cloud Run — API de Usuario

Cloud Run en v2.1 solo maneja la API de usuario Flutter. La ingesta y el OCR son Cloud Functions. Esto reduce el tráfico de Cloud Run y lo mantiene en el free tier.

**Endpoints:**
```
GET  /api/devices/:user_id
GET  /api/devices/:device_id/latest
GET  /api/devices/:device_id/history
```

---

## 8. Seguridad v2.1

- Tráfico HTTP directo se valida con tokens secretos (Secret Manager).
- Cloud Run validado con JWT Bearer Token (Firebase Auth).
- Cloud Scheduler interactúa a través de OIDC tokens garantizando que sólo GCP puede invocar las funciones cron.

---

## 9. CI/CD — Cloud Build

`cloudbuild.yaml` gestiona el deploy de la API y de las Functions asegurando consistencia continua desde la rama principal.

---

## 10. Por qué esta arquitectura entra en free tier

**Cloud Functions 2gen vs Cloud Run para ingesta:** Una Cloud Function sin mínimo de instancias tiene cold start aceptable para IoT, a costo free tier constante. GCS es altamente confiable para colas temporales en fallback. BigQuery gestiona queries limitadas al día, prestando ML Training (BigQuery ML) sin costos por el bajo volumen.

---

*— SDD-001-GCP v2.1 —*
*Wati · Build With AI 2026 · Santa Cruz de la Sierra, Bolivia*
*Revisado: 31 mayo 2026 | Próxima revisión: post Demo Day 31 mayo 2026*