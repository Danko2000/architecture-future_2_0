terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  # Если используете статический ключ (key.json), раскомментируйте строку ниже и закомментируйте token
  # service_account_key_file = file("key.json")
  token     = var.yc_token
  cloud_id  = var.yc_cloud_id
  folder_id = var.yc_folder_id
  zone      = var.yc_zone
}

# ==========================================
# 1. Сеть и Безопасность (Networking)
# ==========================================

# Основная сеть (VPC)
resource "yandex_vpc_network" "future_vpc" {
  name = "future-vpc"
}

# --- Public Zone (для NAT) ---
resource "yandex_vpc_subnet" "public" {
  name           = "public-subnet-dmz"
  zone           = var.yc_zone
  network_id     = yandex_vpc_network.future_vpc.id
  v4_cidr_blocks = var.public_subnet_cidr
}

# NAT Gateway (Шлюз для выхода в интернет)
resource "yandex_vpc_gateway" "nat_gateway" {
  name = "future-nat-gw"
  shared_egress_gateway {}
}

# Таблица маршрутизации для приватной сети
# Весь трафик 0.0.0.0/0 направляем в NAT Gateway
resource "yandex_vpc_route_table" "private_rt" {
  network_id = yandex_vpc_network.future_vpc.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat_gateway.id
  }
}

# --- Private Zone (Приложения) ---
resource "yandex_vpc_subnet" "private" {
  name           = "private-subnet-app"
  zone           = var.yc_zone
  network_id     = yandex_vpc_network.future_vpc.id
  v4_cidr_blocks = var.private_subnet_cidr
  
  # Привязываем таблицу маршрутизации, чтобы трафик шел через NAT
  route_table_id = yandex_vpc_route_table.private_rt.id
}

# Группы безопасности (Security Groups)
resource "yandex_vpc_security_group" "app_sg" {
  name        = "app-security-group"
  network_id  = yandex_vpc_network.future_vpc.id

  # Входящий трафик внутри сети разрешен (Airflow <-> ClickHouse)
  ingress {
    protocol          = "ANY"
    description       = "Internal communication"
    v4_cidr_blocks    = concat(var.public_subnet_cidr, var.private_subnet_cidr)
  }

  # SSH доступ (в идеале только через VPN/Bastion, здесь открыт для сети)
  ingress {
    protocol       = "TCP"
    description    = "SSH"
    v4_cidr_blocks = ["0.0.0.0/0"] # В реальном проекте ограничить VPN IP!
    port           = 22
  }
  
  # Исходящий трафик - разрешен весь (через NAT)
  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==========================================
# 2. Вычислительные ресурсы (Compute)
# ==========================================

# VM: Airflow Server (Аналог t3.medium: 2 vCPU, 4GB RAM)
resource "yandex_compute_instance" "airflow" {
  name        = "airflow-server"
  platform_id = "standard-v3" # Intel Ice Lake
  zone        = var.yc_zone

  resources {
    cores  = 2
    memory = 4
    core_fraction = 50 # Burstable performance (как серия T в AWS)
  }

  boot_disk {
    initialize_params {
      image_id = var.ubuntu_image_id
      size     = 20
      type     = "network-hdd"
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.private.id
    nat                = false # Нет публичного IP!
    security_group_ids = [yandex_vpc_security_group.app_sg.id]
  }

  metadata = {
    # Убедитесь, что файл id_rsa.pub лежит рядом
    ssh-keys = "ubuntu:${file("id_rsa.pub")}"
  }
}

# VM: ClickHouse Server (Аналог m5.large: 2 vCPU, 8GB RAM + Fast Disk)
resource "yandex_compute_instance" "clickhouse" {
  name        = "clickhouse-server"
  platform_id = "standard-v3"
  zone        = var.yc_zone

  resources {
    cores  = 2
    memory = 8
    core_fraction = 100 # Гарантированная производительность 100%
  }

  boot_disk {
    initialize_params {
      image_id = var.ubuntu_image_id
      size     = 20
      type     = "network-ssd" # Быстрый диск для системы
    }
  }

  # Дополнительный диск для данных (Аналог io2)
  secondary_disk {
    disk_id = yandex_compute_disk.clickhouse_data.id
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.private.id
    nat                = false # Нет публичного IP!
    security_group_ids = [yandex_vpc_security_group.app_sg.id]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("id_rsa.pub")}"
  }
}

# Отдельный быстрый диск для ClickHouse
resource "yandex_compute_disk" "clickhouse_data" {
  name = "clickhouse-data-disk"
  type = "network-ssd" # Высокий IOPS
  zone = var.yc_zone
  size = 50 # GB
}

# ==========================================
# 3. Хранилище (Storage / S3)
# ==========================================

# Сервисный аккаунт для управления бакетом
resource "yandex_iam_service_account" "s3_sa" {
  name = "s3-manager-sa"
}

# Выдача прав на создание бакетов
resource "yandex_resourcemanager_folder_iam_member" "s3_editor" {
  folder_id = var.yc_folder_id
  role      = "storage.editor"
  member    = "serviceAccount:${yandex_iam_service_account.s3_sa.id}"
}

# Статические ключи доступа для работы с S3
resource "yandex_iam_service_account_static_access_key" "s3_keys" {
  service_account_id = yandex_iam_service_account.s3_sa.id
}

# Бакет (Data Lake)
resource "yandex_storage_bucket" "data_lake" {
  bucket     = "future-datalake-${substr(md5(var.yc_folder_id), 0, 8)}" # Уникальное имя
  access_key = yandex_iam_service_account_static_access_key.s3_keys.access_key
  secret_key = yandex_iam_service_account_static_access_key.s3_keys.secret_key

  depends_on = [yandex_resourcemanager_folder_iam_member.s3_editor]
}

# Структура папок (имитация через пустые объекты)
resource "yandex_storage_object" "folder_raw" {
  bucket     = yandex_storage_bucket.data_lake.id
  access_key = yandex_iam_service_account_static_access_key.s3_keys.access_key
  secret_key = yandex_iam_service_account_static_access_key.s3_keys.secret_key
  key        = "raw/"
  content    = "placeholder"
}

resource "yandex_storage_object" "folder_silver" {
  bucket     = yandex_storage_bucket.data_lake.id
  access_key = yandex_iam_service_account_static_access_key.s3_keys.access_key
  secret_key = yandex_iam_service_account_static_access_key.s3_keys.secret_key
  key        = "silver/"
  content    = "placeholder"
}