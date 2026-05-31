# SDD-001-GCP v2.1 — Wati CRE

## Cloud / GCP — Stack Corregido para Free Tier Real

| Campo | Valor |
|---|---|
| Documento | SDD-001-GCP |
| Versión | 2.1 (ajuste a firmware real) |
| Basado en | RFC-001 Wati CRE |
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
│                    GOOGLE CLOUD PROJECT: wati-scz                       │
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
│   (batch/diario) ─NDJSON──► GCS Bucket: wati-497921-iot-esp32-uploads            │
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
│   │  4. refresh-latest     ← Cloud Scheduler (cada 5 min)           │ │
│   │  5. scan-bill          ← HTTP (OCR facturas)                     │ │
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
│   │  Secret Manager    → API keys, tokens (6 secrets gratis)         │ │
│   │  Cloud Scheduler   → 2 jobs gratis (refresh, alertas)            │ │
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
| **Cloud Scheduler** | 3 jobs gratis | 2 jobs (refresh + alertas) | ✅ Dentro |
| **Secret Manager** | 6 secrets activos gratis | ~4 secrets | ✅ Dentro |
| **Cloud Build** | 120 min/día gratis | <15 min por deploy | ✅ Dentro |
| **Looker Studio** | Gratuito conectado a BQ | Admin dashboard | ✅ |
| ~~Cloud SQL~~ | ❌ Sin free tier | Eliminado | — |
| ~~Cloud Memorystore~~ | ❌ Sin free tier | Eliminado | — |

### 2.2 Cálculo detallado de Cloud Functions (el servicio más crítico)

```
5 dispositivos × (86,400s / 30s) = 14,400 invocaciones/día
14,400 × 30 días = 432,000 invocaciones/mes

Free tier: 2,000,000 invocaciones/mes
Uso: 21.6% del free tier ✅

Si escala a 50 dispositivos:
50 × 14,400 = 720,000 × 30 = 21,600,000/mes → excede free tier
→ En ese punto migrar ingest-telemetry a Pub/Sub batching
```

### 2.3 Calculo de Firestore (el otro limite importante)

```
Escrituras por telemetria:
5 ESP32 × 1 escritura/evento (snapshot) × 2,880 lecturas/dia
= 14,400 escrituras/dia

Free tier: 20,000 escrituras/dia → Dentro ✅

Deduplicacion: usar campo `last_seen` del mismo documento (sin coleccion aparte)
```

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

```
HTTP directo → Cloud Function  (cada 30s, datos individuales, real-time)
GCS upload   → Cloud Function  (batch diario o cuando hay problemas de conectividad)

El ESP32 acumula en memoria hasta:
  a) 100 registros, o
  b) 5 minutos sin conexión
y sube el archivo NDJSON al bucket como fallback.
```

### 3.3 Lifecycle rule (evitar costos de storage)

```json
{
  "rule": [{
    "action": { "type": "Delete" },
    "condition": { "age": 7, "matchesPrefix": ["uploads/"] }
  }, {
    "action": { "type": "Delete" },
    "condition": { "age": 30, "matchesPrefix": ["processed/"] }
  }]
}
```

Los datos ya están en BigQuery particionados — el bucket es solo ingesta temporal.

---

## 4. Cloud Functions 2gen — Definicion Completa

### 4.1 Funcion 1: `ingest-telemetry` (HTTP, real-time)

```javascript
// Trigger: HTTPS POST desde ESP32
// Runtime: Node.js 20, región: us-central1
// Memory: 256 MB, Timeout: 60s, Min instances: 0

exports.ingestTelemetry = async (req, res) => {
  const payload = req.body;

  // 1. Validar schema (AJV)
  const valid = validateSchema(payload);
  if (!valid) {
    await writeToBigQuery('errors', {
      raw_payload: JSON.stringify(payload),
      error_type: 'schema_invalid',
      error_message: null,
      file_source: 'http_direct',
      received_at: new Date().toISOString(),
    });
    return res.status(400).json({ error: 'invalid_payload' });
  }

  const deviceId = payload.hardware.device_id;
  const userId = payload.tenant.user_id;
  const now = new Date();

  // 2. Deduplicacion con Firestore (campo last_seen)
  const deviceRef = db.collection('devices').doc(deviceId);
  const snap = await deviceRef.get();

  if (snap.exists) {
    const lastSeen = snap.data().last_seen?.toMillis() || 0;
    if (now.getTime() - lastSeen < 25000) { // 25s window (ESP32 envia cada 30s)
      return res.status(200).json({ status: 'deduplicated' });
    }
  }

  // 3. Enriquecer y aplanar datos para BigQuery
  const enriched = {
    device_id: deviceId,
    user_id: userId,
    timestamp: now.toISOString(),
    temp_interior_c: payload.telemetry.temp_interior_c,
    temp_exterior_c: payload.telemetry.temp_exterior_c,
    samples_averaged: payload.telemetry.samples_averaged,
    uptime_s: payload.diagnostics.uptime_s,
    wifi_rssi_dbm: payload.diagnostics.wifi_rssi_dbm,
    firmware_version: payload.hardware.firmware_version,
    processed_at: new Date().toISOString(),
    ingest_source: 'http_direct',
  };

  // 4. Escribir en BigQuery (1 operacion)
  await writeToBigQuery('raw_telemetry', enriched);

  // 5. Actualizar Firestore snapshot (1 escritura, incluye dedup timestamp)
  await deviceRef.set({
    user_id: userId,
    temp_interior_c: payload.telemetry.temp_interior_c,
    temp_exterior_c: payload.telemetry.temp_exterior_c,
    samples_averaged: payload.telemetry.samples_averaged,
    uptime_s: payload.diagnostics.uptime_s,
    wifi_rssi_dbm: payload.diagnostics.wifi_rssi_dbm,
    firmware_version: payload.hardware.firmware_version,
    last_seen: FieldValue.serverTimestamp(),
  }, { merge: true });

  // 6. Disparar agentes si hay condiciones (async, no bloquea respuesta)
  checkAndTriggerAgents(enriched).catch(console.error);

  return res.status(202).json({ status: 'accepted' });
};
```

### 4.2 Funcion 2: `process-gcs-batch` (GCS trigger)

```javascript
// Trigger: OBJECT_FINALIZE en bucket cloud-wati-iot-raw, prefix uploads/
// Runtime: Node.js 20
// Memory: 512 MB, Timeout: 540s (procesa batches de hasta 100 registros)

exports.processGcsBatch = async (cloudevent) => {
  const { bucket, name } = cloudevent.data;
  
  const file = storage.bucket(bucket).file(name);
  const [content] = await file.download();
  
  // Parsear NDJSON
  const lines = content.toString().split('\n').filter(Boolean);
  const batch = lines.slice(0, 100); // máx 100 por invocación
  
  const valid = [], errors = [];
  
  for (const line of batch) {
    try {
      const record = JSON.parse(line);
      if (validateSchema(record)) {
        const now = new Date().toISOString();
        valid.push({
          device_id: record.hardware.device_id,
          user_id: record.tenant.user_id,
          timestamp: now,
          temp_interior_c: record.telemetry.temp_interior_c,
          temp_exterior_c: record.telemetry.temp_exterior_c,
          samples_averaged: record.telemetry.samples_averaged,
          uptime_s: record.diagnostics.uptime_s,
          wifi_rssi_dbm: record.diagnostics.wifi_rssi_dbm,
          firmware_version: record.hardware.firmware_version,
          processed_at: now,
          ingest_source: 'gcs_batch',
        });
      } else {
        errors.push({
          raw_payload: line,
          error_type: 'schema_invalid',
          error_message: null,
          file_source: name,
          received_at: new Date().toISOString(),
        });
      }
    } catch (e) {
      errors.push({
        raw_payload: line,
        error_type: 'json_parse_error',
        error_message: String(e),
        file_source: name,
        received_at: new Date().toISOString(),
      });
    }
  }
  
  // Escritura en batch a BigQuery (una sola operación)
  if (valid.length)  await bqTable('raw_telemetry').insert(valid);
  if (errors.length) await bqTable('errors').insert(errors);
  
  // Mover archivo a /processed (no eliminar, lifecycle rule lo maneja)
  await file.move(name.replace('uploads/', 'processed/'));
};
```

### 4.3 Funcion 3: `refresh-latest` (Cloud Scheduler, cada 5 min)

```javascript
// Trigger: Cloud Scheduler HTTP
// Actualiza tabla latest_per_device con MERGE desde BigQuery

exports.refreshLatest = async (req, res) => {
  const query = `
    MERGE iot_telemetry.latest_per_device T
    USING (
      SELECT *
      FROM (
        SELECT *,
          ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY timestamp DESC) AS rn
        FROM iot_telemetry.raw_telemetry
        WHERE DATE(timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)
      )
      WHERE rn = 1
    ) S
    ON T.device_id = S.device_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
  `;
  
  const [job] = await bigquery.createQueryJob({ query });
  await job.getQueryResults();
  
  res.status(200).json({ status: 'refreshed' });
};
```

### 4.4 Funcion 4: `scan-bill` (HTTP, OCR facturas)

```javascript
// Migrado desde Cloud Run — es una función puntual, no necesita servidor permanente
// Trigger: HTTPS POST desde Flutter (con Firebase Auth JWT)
// Memory: 512 MB, Timeout: 60s

exports.scanBill = async (req, res) => {
  // 1. Subir a GCS temporal (lifecycle 1h)
  const imageBytes = req.body; // buffer
  const blobName = `temp/${uuidv4()}.jpg`;
  await storage.bucket('cloud-wati-bills-ocr').file(blobName).save(imageBytes);
  
  // 2. Cloud Vision API
  const [result] = await visionClient.documentTextDetection(
    `gs://cloud-wati-bills-ocr/${blobName}`
  );
  const text = result.fullTextAnnotation.text;
  
  // 3. Eliminar imagen inmediatamente
  await storage.bucket('cloud-wati-bills-ocr').file(blobName).delete();
  
  // 4. Parser regex para facturas CRE Bolivia
  const extracted = parseCREBill(text);
  
  // 5. Guardar en Firestore (colección bills/{uid})
  await db.collection('bills').doc(req.headers['x-user-id']).collection('history')
    .add({ ...extracted, scanned_at: FieldValue.serverTimestamp() });
  
  res.status(200).json(extracted);
};
```

### 4.5 Funcion 5: `run-agents` (HTTP interno)

```javascript
// Llamada internamente por ingest-telemetry cuando se detectan condiciones
// No expuesta al ESP32 directamente
// Ejecuta el orquestador LangGraph → Gemini 1.5 Flash

exports.runAgents = async (req, res) => {
  const { device_id, trigger_reason } = req.body;
  
  // Leer contexto desde Firestore (1 lectura)
  const deviceSnap = await db.collection('devices').doc(device_id).get();
  const deviceData = deviceSnap.data();
  
  // Llamar a Gemini 1.5 Flash con el prompt del SchedulerAgent
  const recommendation = await callSchedulerAgent(deviceData);

  // Solo alertas informativas (sin comandos a dispositivos)
  if (recommendation.notification.priority !== 'LOW') {
    await sendFCMNotification(deviceData.fcm_token, recommendation.notification);
    await db.collection('devices').doc(device_id)
      .collection('notifications').add({
        type: recommendation.notification.type,
        title: recommendation.notification.title,
        created_at: FieldValue.serverTimestamp(),
      });
  }
  
  res.status(200).json({ status: 'agents_executed' });
};
```

---

## 5. BigQuery — Esquema v2.1

```sql
-- Dataset: iot_telemetry (región: us-central1)

-- Tabla principal (particionada + clustering)
CREATE TABLE iot_telemetry.raw_telemetry (
  device_id        STRING    NOT NULL,
  user_id          STRING    NOT NULL,
  timestamp        TIMESTAMP NOT NULL,
  temp_interior_c  FLOAT64,
  temp_exterior_c  FLOAT64,
  samples_averaged INT64,
  uptime_s         INT64,
  wifi_rssi_dbm    INT64,
  firmware_version STRING,
  processed_at     TIMESTAMP,
  ingest_source    STRING      -- 'http_direct' | 'gcs_batch'
)
PARTITION BY DATE(timestamp)
CLUSTER BY user_id, device_id
OPTIONS (
  partition_expiration_days = 365,   -- datos del año, sin costo de storage excesivo
  require_partition_filter = false
);

-- Dead letter / errores
CREATE TABLE iot_telemetry.errors (
  raw_payload   STRING,
  error_type    STRING,
  error_message STRING,
  file_source   STRING,
  received_at   TIMESTAMP
)
PARTITION BY DATE(received_at);

-- Tabla de última lectura por dispositivo (actualizada por refresh-latest)
CREATE TABLE iot_telemetry.latest_per_device (
  device_id        STRING,
  user_id          STRING,
  timestamp        TIMESTAMP,
  temp_interior_c  FLOAT64,
  temp_exterior_c  FLOAT64,
  samples_averaged INT64,
  uptime_s         INT64,
  wifi_rssi_dbm    INT64,
  firmware_version STRING,
  updated_at       TIMESTAMP
);

-- Query tipo: promedio diario de temperatura interior
SELECT
  DATE(timestamp) AS day,
  AVG(temp_interior_c) AS avg_temp_interior_c,
  AVG(temp_exterior_c) AS avg_temp_exterior_c
FROM iot_telemetry.raw_telemetry
WHERE device_id = @device_id
  AND DATE(timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
GROUP BY day
ORDER BY day;

-- Query tipo: historico 24h (acotado, no explota 1TB free tier)
SELECT timestamp, temp_interior_c, temp_exterior_c, wifi_rssi_dbm
FROM iot_telemetry.raw_telemetry
WHERE device_id = @device_id
  AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
  AND DATE(timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY) -- usa particion
ORDER BY timestamp DESC
LIMIT 2880; -- maximo 24h a 30s/lectura
```

---

## 6. Firestore — Estructura Consolidada v2.1

```
Firestore DB: (default)  ← base de datos por defecto en proyecto wati-497921
│
├── users/
│   └── {uid}/                         ← Firebase Auth UID
│       ├── name:          "Juan Pérez"
│       ├── email:         "juan@gmail.com"
│       ├── plan:          "freemium"
│       └── fcm_token:     "..."
│
├── devices/
│   └── {device_id}/                   ← "TBOT-SCZ-00142"
│       ├── user_id:             "uid_abc"
│       ├── firmware_version:    "1.0.7"
│       │
│       │  ← snapshot en tiempo real (escrito por ingest-telemetry)
│       ├── temp_interior_c:     24.5
│       ├── temp_exterior_c:     29.5
│       ├── samples_averaged:    3
│       ├── uptime_s:            3600
│       ├── wifi_rssi_dbm:       -65
│       ├── last_seen:           Timestamp   ← tambien sirve para deduplicacion
│       │
│       └── notifications/       ← subcoleccion (ultimas 20)
│           └── {notif_id}/
│               ├── type:        "temp_alert"
│               ├── title:       "Alerta de temperatura"
│               └── created_at:  Timestamp
│
├── bills/
│   └── {uid}/
│       └── history/             ← subcolección
│           └── {bill_id}/
│               ├── period:      "Mayo 2026"
│               ├── kwh:         412.3
│               ├── total_bs:    287.50
│               ├── category:    "domiciliaria"
│               └── scanned_at:  Timestamp
│
└── api_keys/
  └── {key_id}/
    ├── key_hash:  "..."
    ├── label:     "integrador-x"
    └── created_at: Timestamp
```

> **Nota:** `device_cache` como coleccion separada **no es necesaria** en Wati porque el snapshot real-time ya vive en `devices/{device_id}`. Usar el mismo documento evita una escritura adicional y mantiene el conteo dentro del free tier.

---

## 7. Cloud Run — API de Usuario

### 7.1 Responsabilidades (acotadas)

Cloud Run en v2.1 **solo maneja la API de usuario Flutter**. La ingesta y el OCR son Cloud Functions. Esto reduce el trafico de Cloud Run y lo mantiene en el free tier.

```
Cloud Run: cloud-wati (Node.js 20 + Express)
Región: us-central1
Memory: 256 MB
Min instances: 0  ← cold start aceptable para app móvil (no IoT)
Concurrency: 80
```

### 7.2 Endpoints

```
GET  /api/devices/:user_id              → lista de dispositivos del usuario
GET  /api/devices/:device_id/latest     → último dato (desde Firestore cache)
GET  /api/devices/:device_id/history    → histórico 24-168h (desde BigQuery)
```

> `POST /api/bill/scan` **se elimina de Cloud Run** y pasa a ser la Cloud Function `scan-bill`. Razón: el OCR es puntual y de larga latencia, no necesita estar en un servidor permanente.

### 7.3 Autenticación

```javascript
// Middleware: Firebase ID Token (usuarios Flutter)
// Más robusto que API Key simple para una app de usuario final

const verifyFirebaseToken = async (req, res, next) => {
  const token = req.headers.authorization?.split('Bearer ')[1];
  if (!token) return res.status(401).json({ error: 'no_token' });
  
  try {
    req.user = await admin.auth().verifyIdToken(token);
    next();
  } catch {
    res.status(401).json({ error: 'invalid_token' });
  }
};

// Para clientes B2B (integradores que consumen la API):
// API Key en header X-API-Key, comparada contra Firestore colección api_keys
```

---

## 8. Seguridad v2.1

```
ESP32-S3
  │ device_secret (flasheado, guardado en Secret Manager)
  │ HTTPS POST con header X-Device-Token a Cloud Function ingest-telemetry
  ▼
Cloud Function (valida token contra Secret Manager → procesa)
  │ Sin exposición a internet de BigQuery/Firestore directamente
  ▼
BigQuery + Firestore
  │ Acceso solo desde Cloud Functions y Cloud Run (Service Account con roles mínimos)
  │ roles: bigquery.dataEditor, datastore.user, storage.objectViewer

Flutter App
  │ Firebase Auth (Google Sign-In)
  │ JWT Bearer Token
  ▼
Cloud Run (API de usuario)
  │ Verifica Firebase ID Token en cada request
  │ Firestore Security Rules: user solo lee sus propios devices

Admin/Looker Studio
  │ BigQuery conectado directamente
  │ IAM: rol bigquery.dataViewer acotado al dataset iot_telemetry
```

---

## 9. CI/CD — Cloud Build

```yaml
# cloudbuild.yaml — Deploy de todas las Cloud Functions + Cloud Run
steps:
  # Función 1: ingest-telemetry
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    args:
      - gcloud functions deploy ingest-telemetry
      - --gen2
      - --runtime=nodejs20
      - --region=us-central1
      - --trigger-http
      - --allow-unauthenticated
      - --memory=256MB
      - --timeout=60s
      - --source=./functions/ingest-telemetry
      - --set-secrets=DEVICE_SECRET=device-secret:latest

  # Función 2: process-gcs-batch
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    args:
      - gcloud functions deploy process-gcs-batch
      - --gen2
      - --runtime=nodejs20
      - --region=us-central1
      - --trigger-event-filters="type=google.cloud.storage.object.v1.finalized"
      - --trigger-event-filters="bucket=cloud-wati-iot-raw"
      - --memory=512MB
      - --timeout=540s
      - --source=./functions/process-gcs-batch

  # Función 3: scan-bill
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    args:
      - gcloud functions deploy scan-bill
      - --gen2
      - --runtime=nodejs20
      - --region=us-central1
      - --trigger-http
      - --memory=512MB
      - --timeout=60s
      - --source=./functions/scan-bill

  # Función 4: refresh-latest (Cloud Scheduler la invoca)
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    args:
      - gcloud functions deploy refresh-latest
      - --gen2
      - --runtime=nodejs20
      - --region=us-central1
      - --trigger-http
      - --memory=256MB
      - --timeout=120s
      - --source=./functions/refresh-latest

  # Función 5: run-agents
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    args:
      - gcloud functions deploy run-agents
      - --gen2
      - --runtime=nodejs20
      - --region=us-central1
      - --trigger-http
      - --no-allow-unauthenticated
      - --memory=512MB
      - --timeout=120s
      - --set-secrets=GEMINI_API_KEY=gemini-key:latest

  # Cloud Run: API de usuario
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', 'gcr.io/wati-scz/cloud-wati:$COMMIT_SHA', './cloud-run-api']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'gcr.io/wati-scz/cloud-wati:$COMMIT_SHA']
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    args:
      - gcloud run deploy cloud-wati
      - --image=gcr.io/wati-scz/cloud-wati:$COMMIT_SHA
      - --region=us-central1
      - --platform=managed
      - --memory=256Mi
      - --min-instances=0
      - --allow-unauthenticated
      - --set-secrets=GEMINI_API_KEY=gemini-key:latest

# Trigger: push a branch main → deploy automático (~5 min)
```

---

## 10. Cloud Scheduler — 2 Jobs Gratuitos

| Job | Trigger | Función | Frecuencia |
|---|---|---|---|
| `refresh-latest-job` | HTTP → `refresh-latest` | Actualiza `latest_per_device` en BQ | Cada 5 min |
| `temp-alerts-job` | HTTP → `run-agents` (modo alert) | Revisa temperaturas altas o bajas | Cada 1 hora |

---

## 11. Estructura del Proyecto

```
cloud-wati-gcp/
├── functions/
│   ├── ingest-telemetry/
│   │   ├── index.js
│   │   └── package.json
│   ├── process-gcs-batch/
│   │   ├── index.js
│   │   └── package.json
│   ├── scan-bill/
│   │   ├── index.js
│   │   └── package.json
│   ├── refresh-latest/
│   │   ├── index.js
│   │   └── package.json
│   └── run-agents/
│       ├── index.js          ← LangGraph + Gemini 1.5 Flash
│       └── package.json
├── cloud-run-api/
│   ├── index.js              ← Express + Firebase Auth middleware
│   ├── package.json
│   └── Dockerfile
├── spec/
│   ├── telemetry-schema.json ← AJV schema para validación
│   ├── api-openapi.yaml      ← OpenAPI 3.0
│   └── free-tier-limits.yaml ← límites y métricas
├── terraform/
│   └── main.tf               ← GCS, BQ, Firestore índices, IAM, Scheduler
├── scripts/
│   ├── deploy.sh
│   └── generate-test-data.js ← genera NDJSON de prueba
├── cloudbuild.yaml
└── README.md
```

---

## 12. Por que esta arquitectura entra en free tier

**Cloud Functions 2gen vs Cloud Run para ingesta:** Una Cloud Function sin mínimo de instancias tiene cold start de ~1-2s, aceptable para un ESP32 que tolera hasta 5s de respuesta. Cloud Run con `min-instances=0` tiene cold starts de 3-8s que pueden hacer fallar el ACK del dispositivo. Para IoT, función directa es más confiable y gratuita.

**GCS como data lake IoT:** Los 5 GB gratuitos son más que suficientes cuando los archivos tienen lifecycle de 7 días. BigQuery recibe los datos limpios y particionados, GCS es solo el canal de entrada resiliente para cuando hay problemas de conectividad en el ESP32.

**Firestore como unica base de datos:** Eliminar Cloud SQL ahorra $7-10/mes y simplifica el stack. Firestore maneja bien documentos de estado de dispositivo con el patron `devices/{device_id}` que ya usaba la v1.0. El snapshot real-time es exactamente el caso de uso para el que Firestore fue disenado.

**BigQuery como warehouse:** Las queries están acotadas con filtros de partición (`DATE(timestamp)`) en todos los casos de uso, lo que garantiza que nunca se escanee más de 1-2 días de datos por query, manteniéndose lejos del límite de 1 TB/mes.

---

*— SDD-001-GCP v2.1 —*
*Wati CRE · Build With AI 2026 · Santa Cruz de la Sierra, Bolivia*
*Revisado: 30 mayo 2026 | Próxima revisión: post Demo Day 31 mayo 2026*
