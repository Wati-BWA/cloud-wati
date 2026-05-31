variable "project_id" {
  type        = string
  description = "GCP Project ID"
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "GCP region"
}

variable "gcs_bucket_iot" {
  type        = string
  default     = "cloud-wati-iot-raw"
  description = "Bucket GCS para uploads NDJSON del ESP32"
}

variable "gcs_bucket_bills" {
  type        = string
  default     = "cloud-wati-bills-ocr"
  description = "Bucket GCS temporal para OCR de facturas CRE"
}

variable "bq_dataset" {
  type        = string
  default     = "iot_telemetry"
  description = "Dataset BigQuery para telemetría"
}
