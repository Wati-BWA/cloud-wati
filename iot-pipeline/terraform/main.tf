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

resource "google_storage_bucket" "iot_uploads" {
  name                        = var.gcs_bucket_name
  location                    = upper(var.region)
  force_destroy               = false
  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age            = 7
      matches_prefix = ["uploads/"]
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age            = 30
      matches_prefix = ["processed/"]
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_bigquery_dataset" "iot_telemetry" {
  dataset_id                 = var.bq_dataset
  location                   = "US"
  description                = "IoT telemetry data"
  delete_contents_on_destroy = false
}

resource "google_bigquery_table" "raw_telemetry" {
  dataset_id          = google_bigquery_dataset.iot_telemetry.dataset_id
  table_id            = var.bq_raw_table
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "event_timestamp"
  }

  clustering = ["device_id"]

  schema = jsonencode([
    { name = "device_id", type = "STRING", mode = "REQUIRED" },
    { name = "temperature_celsius", type = "FLOAT", mode = "REQUIRED" },
    { name = "event_timestamp", type = "TIMESTAMP", mode = "REQUIRED" }
  ])
}

resource "google_bigquery_table" "errors" {
  dataset_id          = google_bigquery_dataset.iot_telemetry.dataset_id
  table_id            = var.bq_errors_table
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "error_time"
  }

  schema = jsonencode([
    { name = "error_time", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "source", type = "STRING", mode = "REQUIRED" },
    { name = "payload", type = "JSON", mode = "NULLABLE" },
    { name = "error_message", type = "STRING", mode = "REQUIRED" }
  ])
}

resource "google_bigquery_table" "latest_per_device" {
  dataset_id          = google_bigquery_dataset.iot_telemetry.dataset_id
  table_id            = var.bq_latest_table
  deletion_protection = false

  schema = jsonencode([
    { name = "device_id", type = "STRING", mode = "REQUIRED" },
    { name = "temperature_celsius", type = "FLOAT", mode = "REQUIRED" },
    { name = "event_timestamp", type = "TIMESTAMP", mode = "REQUIRED" }
  ])
}

resource "google_service_account" "function_sa" {
  account_id   = "ingest-function-sa"
  display_name = "IoT Ingest Function Service Account"
}

resource "google_service_account" "run_sa" {
  account_id   = "client-api-sa"
  display_name = "IoT Client API Service Account"
}

resource "google_storage_bucket_iam_member" "function_gcs_reader" {
  bucket = google_storage_bucket.iot_uploads.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_storage_bucket_iam_member" "function_gcs_writer" {
  bucket = google_storage_bucket.iot_uploads.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_bigquery_dataset_iam_member" "function_bq_writer" {
  dataset_id = google_bigquery_dataset.iot_telemetry.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_project_iam_member" "function_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_bigquery_dataset_iam_member" "run_bq_reader" {
  dataset_id = google_bigquery_dataset.iot_telemetry.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.run_sa.email}"
}

resource "google_project_iam_member" "run_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.run_sa.email}"
}

output "bucket_name" {
  value = google_storage_bucket.iot_uploads.name
}

output "bq_dataset" {
  value = google_bigquery_dataset.iot_telemetry.dataset_id
}

output "function_sa_email" {
  value = google_service_account.function_sa.email
}

output "run_sa_email" {
  value = google_service_account.run_sa.email
}
