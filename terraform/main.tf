terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ──────────────────────────────────────────────
# GCS — Data Lake IoT (SDD v2.1 §3)
# ──────────────────────────────────────────────
resource "google_storage_bucket" "iot_raw" {
  name                        = var.gcs_bucket_iot
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true

  # Lifecycle: uploads/ → 7 días, processed/ → 30 días
  lifecycle_rule {
    condition {
      age            = 7
      matches_prefix = ["uploads/"]
    }
    action { type = "Delete" }
  }

  lifecycle_rule {
    condition {
      age            = 30
      matches_prefix = ["processed/"]
    }
    action { type = "Delete" }
  }
}

resource "google_storage_bucket" "bills_ocr" {
  name                        = var.gcs_bucket_bills
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true

  # Lifecycle: temp/ → 1 día (imágenes OCR)
  lifecycle_rule {
    condition {
      age            = 1
      matches_prefix = ["temp/"]
    }
    action { type = "Delete" }
  }
}

# ──────────────────────────────────────────────
# BigQuery — Dataset + Tablas (SDD v2.1 §5)
# ──────────────────────────────────────────────
resource "google_bigquery_dataset" "iot_telemetry" {
  dataset_id                 = var.bq_dataset
  location                   = "US"
  description                = "IoT telemetry dataset — Wati CRE"
  delete_contents_on_destroy = false
}

# Tabla principal: raw_telemetry (particionada por timestamp, cluster por user+device)
resource "google_bigquery_table" "raw_telemetry" {
  dataset_id          = google_bigquery_dataset.iot_telemetry.dataset_id
  table_id            = "raw_telemetry"
  deletion_protection = false

  time_partitioning {
    type                     = "DAY"
    field                    = "timestamp"
    expiration_ms            = 31536000000 # 365 días
    require_partition_filter = false
  }

  clustering = ["user_id", "device_id"]

  schema = jsonencode([
    { name = "device_id",        type = "STRING",    mode = "REQUIRED" },
    { name = "user_id",          type = "STRING",    mode = "REQUIRED" },
    { name = "timestamp",        type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "temp_interior_c",  type = "FLOAT64",   mode = "NULLABLE" },
    { name = "temp_exterior_c",  type = "FLOAT64",   mode = "NULLABLE" },
    { name = "samples_averaged", type = "INT64",     mode = "NULLABLE" },
    { name = "uptime_s",         type = "INT64",     mode = "NULLABLE" },
    { name = "wifi_rssi_dbm",    type = "INT64",     mode = "NULLABLE" },
    { name = "firmware_version", type = "STRING",    mode = "NULLABLE" },
    { name = "processed_at",     type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "ingest_source",    type = "STRING",    mode = "NULLABLE" }
  ])
}

# Tabla de errores (dead letter)
resource "google_bigquery_table" "errors" {
  dataset_id          = google_bigquery_dataset.iot_telemetry.dataset_id
  table_id            = "errors"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "received_at"
  }

  schema = jsonencode([
    { name = "raw_payload",   type = "STRING",    mode = "NULLABLE" },
    { name = "error_type",    type = "STRING",    mode = "NULLABLE" },
    { name = "error_message", type = "STRING",    mode = "NULLABLE" },
    { name = "file_source",   type = "STRING",    mode = "NULLABLE" },
    { name = "received_at",   type = "TIMESTAMP", mode = "REQUIRED" }
  ])
}

# Tabla de última lectura por dispositivo
resource "google_bigquery_table" "latest_per_device" {
  dataset_id          = google_bigquery_dataset.iot_telemetry.dataset_id
  table_id            = "latest_per_device"
  deletion_protection = false

  schema = jsonencode([
    { name = "device_id",        type = "STRING",    mode = "REQUIRED" },
    { name = "user_id",          type = "STRING",    mode = "NULLABLE" },
    { name = "timestamp",        type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "temp_interior_c",  type = "FLOAT64",   mode = "NULLABLE" },
    { name = "temp_exterior_c",  type = "FLOAT64",   mode = "NULLABLE" },
    { name = "samples_averaged", type = "INT64",     mode = "NULLABLE" },
    { name = "uptime_s",         type = "INT64",     mode = "NULLABLE" },
    { name = "wifi_rssi_dbm",    type = "INT64",     mode = "NULLABLE" },
    { name = "firmware_version", type = "STRING",    mode = "NULLABLE" },
    { name = "updated_at",       type = "TIMESTAMP", mode = "NULLABLE" }
  ])
}

# Tabla de Weather Forecast
resource "google_bigquery_table" "weather_forecast" {
  dataset_id          = google_bigquery_dataset.iot_telemetry.dataset_id
  table_id            = "weather_forecast"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "timestamp"
  }

  schema = jsonencode([
    { name = "timestamp",       type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "temp_c",          type = "FLOAT64",   mode = "NULLABLE" },
    { name = "humidity",        type = "FLOAT64",   mode = "NULLABLE" },
    { name = "feelslike_c",     type = "FLOAT64",   mode = "NULLABLE" },
    { name = "pressure_mb",     type = "FLOAT64",   mode = "NULLABLE" },
    { name = "condition_text",  type = "STRING",    mode = "NULLABLE" }
  ])
}

# Tabla de predicciones de temperatura
resource "google_bigquery_table" "temperature_predictions" {
  dataset_id          = google_bigquery_dataset.iot_telemetry.dataset_id
  table_id            = "temperature_predictions"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "created_at"
  }

  schema = jsonencode([
    { name = "prediction_hour", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "device_id",       type = "STRING",    mode = "REQUIRED" },
    { name = "predicted_temp_c",type = "FLOAT64",   mode = "NULLABLE" },
    { name = "will_increase_6h",type = "BOOLEAN",   mode = "NULLABLE" },
    { name = "created_at",      type = "TIMESTAMP", mode = "REQUIRED" }
  ])
}

# ──────────────────────────────────────────────
# Firestore — Database (SDD v2.1 §6)
# ──────────────────────────────────────────────
resource "google_firestore_database" "default" {
  name        = "(default)"
  location_id = "nam5"
  type        = "FIRESTORE_NATIVE"

  # Evita destrucción accidental en terraform destroy
  lifecycle {
    prevent_destroy = true
  }
}

# ──────────────────────────────────────────────
# Service Accounts (SDD v2.1 §8)
# ──────────────────────────────────────────────
resource "google_service_account" "function_sa" {
  account_id   = "ingest-function-sa"
  display_name = "IoT Functions Service Account"
  description  = "Usado por todas las Cloud Functions para BigQuery, Firestore, GCS"
}

resource "google_service_account" "run_sa" {
  account_id   = "client-api-sa"
  display_name = "Cloud Run API Service Account"
  description  = "Usado por el Cloud Run para BigQuery y Firestore"
}

# ──────────────────────────────────────────────
# IAM — Roles mínimos (principio de mínimo privilegio)
# ──────────────────────────────────────────────

# Functions → GCS: leer y escribir en bucket iot-raw
resource "google_storage_bucket_iam_member" "function_gcs_reader" {
  bucket = google_storage_bucket.iot_raw.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_storage_bucket_iam_member" "function_gcs_writer" {
  bucket = google_storage_bucket.iot_raw.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_storage_bucket_iam_member" "function_bills_writer" {
  bucket = google_storage_bucket.bills_ocr.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.function_sa.email}"
}

# Functions → BigQuery: editor del dataset
resource "google_bigquery_dataset_iam_member" "function_bq_writer" {
  dataset_id = google_bigquery_dataset.iot_telemetry.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_project_iam_member" "function_bq_job" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

# Functions → Firestore
resource "google_project_iam_member" "function_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

# Cloud Run → BigQuery: solo lectura
resource "google_bigquery_dataset_iam_member" "run_bq_reader" {
  dataset_id = google_bigquery_dataset.iot_telemetry.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.run_sa.email}"
}

resource "google_project_iam_member" "run_bq_job" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.run_sa.email}"
}

# Cloud Run → Firestore
resource "google_project_iam_member" "run_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.run_sa.email}"
}

# Functions → Secret Manager
resource "google_project_iam_member" "function_secret_manager" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

# ──────────────────────────────────────────────
# Cloud Scheduler Jobs (SDD v2.1 §10)
# ──────────────────────────────────────────────
resource "google_cloud_scheduler_job" "fetch_weather_job" {
  name        = "fetch-weather-job"
  description = "Fetch weather forecast every hour"
  schedule    = "0 * * * *"
  time_zone   = "UTC"
  region      = var.region

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-${var.project_id}.cloudfunctions.net/fetch-weather"
    oidc_token {
      service_account_email = google_service_account.function_sa.email
    }
  }
}

resource "google_cloud_scheduler_job" "train_models_job" {
  name        = "train-models-job"
  description = "Train BQ ML temperature models every 24 hours"
  schedule    = "0 0 * * *"
  time_zone   = "UTC"
  region      = var.region

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-${var.project_id}.cloudfunctions.net/train-models"
    oidc_token {
      service_account_email = google_service_account.function_sa.email
    }
  }
}

resource "google_cloud_scheduler_job" "run_predictions_job" {
  name        = "run-predictions-job"
  description = "Run temperature predictions every 6 hours"
  schedule    = "0 0,6,12,18 * * *"
  time_zone   = "UTC"
  region      = var.region

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-${var.project_id}.cloudfunctions.net/run-predictions"
    oidc_token {
      service_account_email = google_service_account.function_sa.email
    }
  }
}

# ──────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────
output "bucket_iot_raw"       { value = google_storage_bucket.iot_raw.name }
output "bucket_bills_ocr"     { value = google_storage_bucket.bills_ocr.name }
output "bq_dataset"           { value = google_bigquery_dataset.iot_telemetry.dataset_id }
output "function_sa_email"    { value = google_service_account.function_sa.email }
output "run_sa_email"         { value = google_service_account.run_sa.email }
