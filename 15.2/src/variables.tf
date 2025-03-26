###cloud vars
variable "token" {
  type        = string
  description = "OAuth-token; https://cloud.yandex.ru/docs/iam/concepts/authorization/oauth-token"
}

variable "cloud_id" {
  type        = string
  description = "https://cloud.yandex.ru/docs/resource-manager/operations/cloud/get-id"
}

variable "folder_id" {
  type        = string
  description = "https://cloud.yandex.ru/docs/resource-manager/operations/folder/get-id"
}

variable "default_zone" {
  type        = string
  default     = "ru-central1-a"
  description = "https://cloud.yandex.ru/docs/overview/concepts/geo-scope"
}
variable "first_cidr" {
  type        = list(string)
  default     = ["192.168.10.0/24"]
  description = "https://cloud.yandex.ru/docs/vpc/operations/subnet-create"
}

variable "service_account_id" {
  type        = string
}

variable "platform" {
  type        = string
  default     = "standard-v3"
  description = "WM Platform"
}

variable "backet_name" {
  default = "martid"
}

variable "vm_cores" {
  type = number
  default = 2
  description = "Processor cores"
}

variable "vm_memory" {
  type = number
  default = 4
  description = "Memory"
}

variable "scale_count" {
  type = number
  default = 3
  description = "Scale count"
}