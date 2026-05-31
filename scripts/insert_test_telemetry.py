"""
Inserta telemetría de prueba en la colección `telemetry` de Firestore
para simular datos de sensores de temperatura interior/exterior.
Uso: python scripts/insert_test_telemetry.py
"""
import os
from pathlib import Path

from dotenv import load_dotenv
from google.cloud import firestore
import random
from datetime import datetime, timedelta, timezone

# Bypass local 403 Permission Denied issues in Native Mode using harness-key
HARNESS_KEY = "C:/Users/Moises/gcp-harness-key.json"
if os.path.exists(HARNESS_KEY):
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = HARNESS_KEY

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

project_id = os.getenv("GCP_PROJECT_ID", "wati-497921")
db = firestore.Client(project=project_id)

DEVICES = ["dev-001", "dev-002", "dev-003", "dev-004"]
now = datetime.now(timezone.utc)

batch = db.batch()
count = 0

# --- NUEVO: Registrar dispositivos de prueba en Firestore ---
devices_batch = db.batch()
for device in DEVICES:
    dev_ref = db.collection("devices").document(device)
    devices_batch.set(dev_ref, {
        "device_id": device,
        "device_name": f"Sensor de Prueba {device[-3:]}",
        "user_id": "test-user-123",
        "fcmToken": "test-fcm-token-abc",
        "fcm_token": "test-fcm-token-abc",
        "updated_at": now
    }, merge=True)
devices_batch.commit()
print(f"[OK] Dispositivos de prueba registrados en coleccion 'devices' de Firestore")

for device in DEVICES:
    # 24 registros hourly (simula 1 día de lecturas)
    for i in range(24):
        ts = now - timedelta(hours=24 - i)
        doc_ref = db.collection("telemetry").document()
        batch.set(doc_ref, {
            "device_id": device,
            "timestamp": ts,
            "temp_in":   round(random.uniform(22, 34), 1),
            "temp_out":  round(random.uniform(18, 38), 1),
        })
        count += 1

batch.commit()
print(f"[OK] Telemetria de prueba insertada: {count} registros para {len(DEVICES)} dispositivos en Firestore")

# --- NUEVO: Insertar telemetria historica de 72 horas en BigQuery ---
from google.cloud import bigquery
bq_client = bigquery.Client(project=project_id)
table_id = f"{project_id}.iot_telemetry.raw_telemetry"

print("Insertando datos historicos en BigQuery raw_telemetry (72 horas)...")
bq_rows = []
for device in DEVICES:
    for i in range(72):
        ts = now - timedelta(hours=72 - i)
        bq_rows.append({
            "device_id": device,
            "event_timestamp": ts.isoformat(),
            "temperature_celsius": round(random.uniform(22.0, 32.0), 2)
        })

# Insertar en lotes en BigQuery
errors = bq_client.insert_rows_json(table_id, bq_rows)
if errors:
    print(f"[FALLO BQ]: {errors}")
else:
    print(f"[OK] Telemetria de prueba BigQuery: {len(bq_rows)} registros insertados en raw_telemetry")
