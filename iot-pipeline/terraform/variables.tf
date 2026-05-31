variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "gcs_bucket_name" {
  type = string
}

variable "bq_dataset" {
  type    = string
  default = "iot_telemetry"
}

variable "bq_raw_table" {
  type    = string
  default = "raw_telemetry"
}

variable "bq_errors_table" {
  type    = string
  default = "errors"
}

variable "bq_latest_table" {
  type    = string
  default = "latest_per_device"
}
