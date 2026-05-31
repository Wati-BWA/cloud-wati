"""
Prueba end-to-end del pipeline de predicción y notificaciones.
Ejecuta cada etapa en orden y verifica que no haya errores.

Uso: python scripts/e2e_test_flow.py
Pre-requisito: gcloud auth application-default login
"""
import os
from pathlib import Path
import subprocess
import sys
import time

from dotenv import load_dotenv

# Bypass local 403 Permission Denied issues in Native Mode using harness-key
HARNESS_KEY = "C:/Users/Moises/gcp-harness-key.json"
if os.path.exists(HARNESS_KEY):
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = HARNESS_KEY

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

from google.cloud import bigquery

PROJECT = os.getenv("GCP_PROJECT_ID", "wati-497921")
REGION = os.getenv("GCP_REGION", "us-central1")

bq_client = bigquery.Client(project=PROJECT)

# --- Auto-aprovisionamiento de Infraestructura en BigQuery ---
from google.cloud.exceptions import NotFound
import json

print("\n--- Verificando infraestructura de BigQuery ---")

# 1. Asegurar Dataset
dataset_ref = bq_client.dataset("iot_dataset")
try:
    bq_client.get_dataset(dataset_ref)
    print("Dataset iot_dataset ya existe.")
except NotFound:
    dataset = bigquery.Dataset(dataset_ref)
    dataset.location = REGION
    bq_client.create_dataset(dataset)
    print("[OK] Dataset iot_dataset creado con exito.")

# 2. Asegurar Tabla weather_forecasts
table_ref = dataset_ref.table("weather_forecasts")
try:
    bq_client.get_table(table_ref)
    print("Tabla weather_forecasts ya existe.")
except NotFound:
    schema_path = "scripts/schemas/weather_forecasts.json"
    schema_data = json.load(open(schema_path, encoding="utf-8"))
    schema = [
        bigquery.SchemaField(f["name"], f["type"], mode=f.get("mode", "NULLABLE"))
        for f in schema_data
    ]
    table = bigquery.Table(table_ref, schema=schema)
    table.time_partitioning = bigquery.TimePartitioning(field="forecast_hour")
    bq_client.create_table(table)
    print("[OK] Tabla weather_forecasts creada con exito.")

def run(label, cmd, check=True, shell=(os.name == 'nt')):
    print(f"\n{'-'*60}")
    print(f"  {label}")
    print(f"{'-'*60}")
    result = subprocess.run(cmd, shell=shell, capture_output=False, text=True)
    if check and result.returncode != 0:
        print(f"[FALLO]: {label}")
        sys.exit(result.returncode)
    return result

def run_bq_query(label, filepath_or_query, is_file=True):
    print(f"\n{'-'*60}")
    print(f"  {label}")
    print(f"{'-'*60}")
    if is_file:
        sql = open(filepath_or_query, encoding="utf-8").read()
    else:
        sql = filepath_or_query
    
    query_job = bq_client.query(sql)
    query_job.result() # Wait for query to complete
    print("[OK] Completado con exito en BigQuery")

# 1. Insertar telemetria de prueba
run("1. Insertando telemetria de prueba en Firestore...",
    [sys.executable, "scripts/insert_test_telemetry.py"])

# 2. Ejecutar fetch-weather para obtener pronostico actual
run("2. Invocando fetch-weather (pronostico OpenWeatherMap -> BigQuery)...",
    ["gcloud", "functions", "call", "fetch-weather", f"--region={REGION}",
     "--data", "{}"])

time.sleep(3)

# 3. Crear vista telemetry_enriched
run_bq_query("3. Creando vista telemetry_enriched en BigQuery...",
             "scripts/sql/telemetry_enriched.sql")

# 4. Entrenar modelo ARIMA_PLUS (puede tardar 3-10 min)
print("\n[INFO] Entrenando modelo ARIMA_PLUS (puede tardar hasta 10 min)...")
run_bq_query("4. Entrenando temp_forecast_model...",
             "scripts/sql/train_model.sql")

# 5. Ejecutar ML.FORECAST manualmente
run_bq_query("5. Ejecutando ML.FORECAST -> predictions_6h...",
             "scripts/sql/forecast_6h.sql")

# 6. Verificar predicciones
print(f"\n{'-'*60}")
print("  6. Verificando predicciones en BigQuery...")
print(f"{'-'*60}")
query_job = bq_client.query(
    f"SELECT device_id, forecast_timestamp, ROUND(predicted_temp,2) AS predicted_temp "
    f"FROM `{PROJECT}.iot_dataset.predictions_6h` LIMIT 5"
)
for row in query_job.result():
    print(f"Device: {row.device_id} | Timestamp: {row.forecast_timestamp} | Temp: {row.predicted_temp}°C")

# 7. Invocar check-new-predictions
run("7. Invocando check-new-predictions...",
    ["gcloud", "functions", "call", "check-new-predictions",
     f"--region={REGION}"])

time.sleep(5)

# 8. Publicar mensaje de prueba directo en Pub/Sub
run("8. Publicando mensaje de prueba en topic notifications...",
    ["gcloud", "pubsub", "topics", "publish", "notifications",
     f"--project={PROJECT}",
     '--message={"device_id":"dev-001","predicted_temp":31.5,"feels_like":33.0,'
     '"forecast_for":"2026-05-31T15:00:00Z"}'])

time.sleep(12)

# 9. Leer logs de notification-agent
run("9. Logs recientes de notification-agent...",
    ["gcloud", "functions", "logs", "read", "notification-agent",
     f"--region={REGION}", f"--project={PROJECT}", "--limit=15"],
    check=False)

print(f"\n{'='*60}")
print("  [OK] Prueba end-to-end completada")
print(f"{'='*60}\n")
