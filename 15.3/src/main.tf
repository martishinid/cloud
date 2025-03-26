# 1. Создание бакета Object Storage
resource "yandex_kms_symmetric_key" "bucket_key" {
  name              = "bucket-encryption-key"
  description       = "KMS key for encrypting bucket content"
  default_algorithm = "AES_256"
  rotation_period   = "8760h" # Ротация ключа каждые 365 дней
  
  # Настройки прав доступа
  lifecycle {
    create_before_destroy = true
  }
}
# Создание статического ключа доступа
resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  service_account_id = var.service_account_id
  description        = "static access key for object storage"
}

resource "yandex_storage_bucket" "bucket" {
  bucket    = "${var.bucket_name}-${formatdate("YYYYMMDD-hhmmss", timestamp())}" 
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key

  server_side_encryption_configuration {
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = yandex_kms_symmetric_key.bucket_key.id
      sse_algorithm     = "aws:kms"
    }
    }
  }

  anonymous_access_flags {
    read = true     
    }
}
# Загрузка изображения в бакет
resource "yandex_storage_object" "image" {
  bucket     = yandex_storage_bucket.bucket.bucket
  key        = "yacloud.png"         
  source     = "yacloud.png"         
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
}

resource "yandex_vpc_network" "network" {
  name = "my-network"
}

resource "yandex_vpc_subnet" "public" {
  name           = "public"
  zone           = var.default_zone
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = var.first_cidr
}

# Security Group для веб-серверов
resource "yandex_vpc_security_group" "sg" {
  name        = "web-sg"
  network_id  = yandex_vpc_network.network.id

  ingress {
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Instance Group с LAMP
resource "yandex_compute_instance_group" "lamp_group" {
  name               = "lamp-group"
  service_account_id = var.service_account_id

  # Конфигурация шаблона ВМ
  instance_template {
    platform_id = "standard-v3"
    resources {
      cores  = var.vm_cores
      memory = var.vm_memory
    }
   
    # Использование LAMP образа
    boot_disk {
      initialize_params {
        image_id = "fd827b91d99psvq5fjit"
      }
    }
    
    # Настройка сети
    network_interface {
      network_id         = yandex_vpc_network.network.id
      subnet_ids         = [yandex_vpc_subnet.public.id]
      security_group_ids = [yandex_vpc_security_group.sg.id]
      nat                = true
    }

    # Метаданные с пользовательским скриптом
    metadata = {
      ssh-keys = "ubuntu:${file("~/.ssh/id_ed25519.pub")}"
      user-data = <<-EOT
        #!/bin/bash
        echo '<html><body><img src="https://storage.yandexcloud.net/${yandex_storage_bucket.bucket.bucket}/${yandex_storage_object.image.key}"></body></html>' > /var/www/html/index.html
        EOT
    }
  }

  # Настройки масштабирования
  scale_policy {
    fixed_scale {
      size = var.scale_count
    }
  }
  # Зоны доступности для размещения ресурсов
  allocation_policy {
    zones = [var.default_zone]
  }

  # Стратегия развертывания, обновления и масштабирования ресурсов
  deploy_policy {
    max_unavailable = 1
    max_expansion   = 0
  }

  # Проверка состояния ВМ
  health_check {
    interval = 30
    timeout  = 5
    http_options {
      port = 80
      path = "/"
    }
  }
    load_balancer {
        target_group_name = "lamp-group"
    }
}


# 3. Сетевой баллансировщик
resource "yandex_lb_network_load_balancer" "nlb" {
  name = "network-lb"

  listener {
    name = "http-listener"
    port = 80
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_compute_instance_group.lamp_group.load_balancer[0].target_group_id

    healthcheck {
      name = "http"
      interval = 2
      timeout = 1
      unhealthy_threshold = 2
      healthy_threshold = 5
      http_options {
        port = 80
        path = "/"
      }
    }
  }
}

# 4. Application Load Balancer

# Целевая группа для балансировщика нагрузки. Содержит список целевых экземпляров,
# на которые будет распределяться трафик. Группа автоматически обновляется при изменении состава instance group.
resource "yandex_alb_target_group" "application-balancer" {
  name = "app-target-group"

  # Динамическое создание таргетов на основе экземпляров в группе lamp_group
  dynamic "target" {
    # Итерация по всем экземплярам в compute instance group
    for_each = yandex_compute_instance_group.lamp_group.instances
    content {
      # Использование общей подсети для всех экземпляров
      subnet_id  = yandex_vpc_subnet.public.id
      # Получение внутреннего IP-адреса экземпляра из network interface
      ip_address = target.value.network_interface[0].ip_address
    }
  }

  # Явное указание зависимости для корректной последовательности создания ресурсов
  depends_on = [
    yandex_compute_instance_group.lamp_group
  ]
}

# Бэкенд группа определяет параметры балансировки трафика и проверки состояния инстансов
resource "yandex_alb_backend_group" "backend-group" {
  name                     = "backend-balancer"
  
  # Включение привязки сессии к IP-адресу клиента для сохранения состояния
  session_affinity {
    connection {
      source_ip = true
    }
  }

  # Конфигурация HTTP-бэкенда
  http_backend {
    name                   = "http-backend"
    weight                 = 1  # Вес для балансировки (при наличии нескольких бэкендов)
    port                   = 80 # Порт целевых инстансов
    
    # Связь с целевой группой
    target_group_ids       = [yandex_alb_target_group.application-balancer.id]
    
    # Конфигурация балансировки нагрузки
    load_balancing_config {
      panic_threshold      = 90 # Порог для перехода в аварийный режим (% недоступных бэкендов)
    }    
    
    # Настройки проверки инстансов
    healthcheck {
      timeout              = "10s"    # Максимальное время ожидания ответа
      interval             = "2s"     # Интервал между проверками
      healthy_threshold    = 10       # Число успешных проверок для признания работоспособности
      unhealthy_threshold  = 15       # Число неудачных проверок для признания неработоспособности
      http_healthcheck {
        path               = "/"     # URL для проверки здоровья
      }
    }
  }

  # Зависимость от создания целевой группы
  depends_on = [
    yandex_alb_target_group.application-balancer
  ]
}

# HTTP-роутер для управления маршрутизацией запросов
resource "yandex_alb_http_router" "http-router" {
  name          = "http-router"
  labels        = {
    tf-label    = "tf-label-value"  # Пример пользовательской метки
    empty-label = ""                # Пустая метка
  }
}

# Виртуальный хост для обработки входящих запросов
resource "yandex_alb_virtual_host" "my-virtual-host" {
  name                    = "virtual-host"
  http_router_id          = yandex_alb_http_router.http-router.id
  
  # Правило маршрутизации для всех HTTP-запросов
  route {
    name                  = "route-http"
    http_route {
      http_route_action {
        backend_group_id  = yandex_alb_backend_group.backend-group.id  # Связь с бэкенд-группой
        timeout           = "60s"  # Таймаут обработки запроса
      }
    }
  }

  # Зависимость от создания бэкенд-группы
  depends_on = [
    yandex_alb_backend_group.backend-group
  ]
}

# Основной ресурс Application Load Balancer
resource "yandex_alb_load_balancer" "application-balancer" {
  name        = "app-balancer"
  network_id  = yandex_vpc_network.network.id  # Идентификатор облачной сети

  # Политика распределения ресурсов балансировщика
  allocation_policy {
    location {
      zone_id   = var.default_zone          # Зона доступности
      subnet_id = yandex_vpc_subnet.public.id  # Рабочая подсеть
    }
  }

  # Конфигурация обработчика входящих запросов
  listener {
    name = "listener"
    endpoint {
      address {
        external_ipv4_address {}  # Автоматическое выделение публичного IPv4
      }
      ports = [ 80 ]  # Прослушивание HTTP-порта
    }
    http {
      handler {
        http_router_id = yandex_alb_http_router.http-router.id  # Привязка HTTP-роутера
      }
    }
  }

  # Зависимость от создания HTTP-роутера
  depends_on = [
    yandex_alb_http_router.http-router
  ] 
}