variable "tenancy_ocid" {
  type      = string
  sensitive = true
}

variable "compartment_id" {
  type      = string
  sensitive = true
}

variable "region" {
  type = string
}

variable "config_file_profile" {
  type    = string
  default = "DEFAULT"
}

variable "auth_mode" {
  type    = string
  default = "APIKey"
}

variable "name_prefix" {
  type    = string
  default = "self-healing-demo"
}

variable "vcn_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "allowed_client_cidr" {
  description = "Internal source CIDR allowed to reach the private test listeners."
  type        = string
  default     = "10.0.0.0/8"
}

variable "instance_shape" {
  type    = string
  default = "VM.Standard.E5.Flex"
}

variable "instance_ocpus" {
  type    = number
  default = 1
}

variable "instance_memory_gbs" {
  type    = number
  default = 2
}

variable "enable_function" {
  type    = bool
  default = false
}

variable "function_image" {
  type    = string
  default = ""
}

variable "function_image_digest" {
  type    = string
  default = ""
}

variable "function_mode" {
  type    = string
  default = "observe"
  validation {
    condition     = contains(["observe", "remediate"], var.function_mode)
    error_message = "function_mode must be observe or remediate."
  }
}

variable "operations_email" {
  description = "Optional ONS EMAIL endpoint supplied only through protected runtime input."
  type        = string
  default     = ""
  sensitive   = true
}

variable "log_retention_days" {
  description = "Retention for Function and Load Balancer service logs. OCI Logging accepts 30-day increments."
  type        = number
  default     = 30
  validation {
    condition     = contains([30, 60, 90, 120, 150, 180], var.log_retention_days)
    error_message = "log_retention_days must be a supported 30-day increment from 30 through 180."
  }
}

variable "services" {
  description = "Independent synthetic services created by the test stack."
  type = map(object({
    backend_set_name        = string
    backend_port            = number
    health_path             = string
    min_size                = number
    initial_size            = number
    max_size                = number
    cooldown_seconds        = number
    min_healthy             = number
    max_replacements        = number
    replacement_window_secs = number
    capacity_reservation    = string
  }))
  default = {
    atlas = {
      backend_set_name = "synthetic_atlas_backends", backend_port = 7100, health_path = "/healthz"
      min_size         = 2, initial_size = 3, max_size = 5, cooldown_seconds = 300
      min_healthy      = 2, max_replacements = 2, replacement_window_secs = 1800, capacity_reservation = "none"
    }
    birch = {
      backend_set_name = "synthetic_birch_backends", backend_port = 3100, health_path = "/healthz"
      min_size         = 2, initial_size = 2, max_size = 4, cooldown_seconds = 420
      min_healthy      = 1, max_replacements = 1, replacement_window_secs = 1800, capacity_reservation = "none"
    }
    cedar = {
      backend_set_name = "synthetic_cedar_backends", backend_port = 2100, health_path = "/healthz"
      min_size         = 2, initial_size = 3, max_size = 6, cooldown_seconds = 300
      min_healthy      = 2, max_replacements = 2, replacement_window_secs = 1800, capacity_reservation = "none"
    }
    delta = {
      backend_set_name = "synthetic_delta_backends", backend_port = 9100, health_path = "/healthz"
      min_size         = 2, initial_size = 2, max_size = 3, cooldown_seconds = 600
      min_healthy      = 1, max_replacements = 1, replacement_window_secs = 1800, capacity_reservation = "none"
    }
    ember = {
      backend_set_name = "synthetic_ember_backends", backend_port = 7200, health_path = "/healthz"
      min_size         = 2, initial_size = 2, max_size = 5, cooldown_seconds = 300
      min_healthy      = 1, max_replacements = 2, replacement_window_secs = 1800, capacity_reservation = "none"
    }
    fjord = {
      backend_set_name = "synthetic_fjord_backends", backend_port = 4100, health_path = "/healthz"
      min_size         = 2, initial_size = 2, max_size = 4, cooldown_seconds = 480
      min_healthy      = 1, max_replacements = 1, replacement_window_secs = 1800, capacity_reservation = "none"
    }
    grove = {
      backend_set_name = "synthetic_grove_backends", backend_port = 6100, health_path = "/healthz"
      min_size         = 2, initial_size = 2, max_size = 3, cooldown_seconds = 600
      min_healthy      = 1, max_replacements = 1, replacement_window_secs = 3600, capacity_reservation = "none"
    }
  }

  validation {
    condition = alltrue([
      for service in values(var.services) :
      service.min_size >= 2 &&
      service.min_size <= service.initial_size &&
      service.initial_size <= service.max_size &&
      service.min_healthy < service.initial_size &&
      service.backend_port > 0 && service.backend_port <= 65535 &&
      service.capacity_reservation == "none"
    ])
    error_message = "Every service must have a valid port, min >= 2, min <= initial <= max, min_healthy < initial, and no capacity reservation for this disposable test."
  }
}

variable "freeform_tags" {
  type = map(string)
  default = {
    project   = "synthetic-self-healing-test"
    component = "self_healing"
    data      = "non-customer"
  }
}
