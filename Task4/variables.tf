variable "yc_token" {
  description = "OAuth token или IAM token"
  type        = string
  sensitive   = true
}

variable "yc_cloud_id" {
  description = "ID облака"
  type        = string
}

variable "yc_folder_id" {
  description = "ID каталога"
  type        = string
}

variable "yc_zone" {
  description = "Зона доступности (например, ru-central1-a)"
  type        = string
  default     = "ru-central1-a"
}

variable "public_subnet_cidr" {
  description = "CIDR для публичной подсети (NAT)"
  default     = ["192.168.10.0/24"]
}

variable "private_subnet_cidr" {
  description = "CIDR для приватной подсети (Приложения)"
  default     = ["192.168.20.0/24"]
}

variable "ubuntu_image_id" {
  description = "ID образа Ubuntu 22.04"
  # Актуальный ID можно найти через 'yc compute image list-public'
  default     = "fd80bm0rh4rkepi5ksdi" 
}