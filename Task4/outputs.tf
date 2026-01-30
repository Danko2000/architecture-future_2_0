output "vpc_id" {
  value = yandex_vpc_network.future_vpc.id
}

output "airflow_internal_ip" {
  description = "Internal IP of Airflow Server (access via VPN/Bastion)"
  value       = yandex_compute_instance.airflow.network_interface.0.ip_address
}

output "clickhouse_internal_ip" {
  description = "Internal IP of ClickHouse Server"
  value       = yandex_compute_instance.clickhouse.network_interface.0.ip_address
}

output "s3_bucket_name" {
  value = yandex_storage_bucket.data_lake.bucket
}

output "s3_access_key" {
  value     = yandex_iam_service_account_static_access_key.s3_keys.access_key
  sensitive = true
}

output "s3_secret_key" {
  value     = yandex_iam_service_account_static_access_key.s3_keys.secret_key
  sensitive = true
}