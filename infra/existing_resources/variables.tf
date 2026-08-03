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

variable "public_subnet_id" {
  type      = string
  default   = ""
  sensitive = true
}

variable "private_subnet_id" {
  type      = string
  sensitive = true
}

variable "existing_load_balancer_id" {
  type      = string
  default   = ""
  sensitive = true
}

variable "existing_instance_pool_id" {
  description = "Existing pool to monitor without importing or owning it. Requires existing_load_balancer_id and existing_backend_set_name."
  type        = string
  default     = ""
  sensitive   = true
}

variable "existing_backend_set_name" {
  description = "Backend set already attached to the existing instance pool."
  type        = string
  default     = ""
}

variable "name_prefix" {
  type    = string
  default = "oci-self-healing"
}

variable "backend_port" {
  type    = number
  default = 8080
}

variable "listener_port" {
  type    = number
  default = 80
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

variable "pool_initial_size" {
  type    = number
  default = 2
}

variable "pool_min_size" {
  type    = number
  default = 2
}

variable "pool_max_size" {
  type    = number
  default = 3
}

variable "autoscaling_cooldown_seconds" {
  type    = number
  default = 300
  validation {
    condition     = var.autoscaling_cooldown_seconds >= 60
    error_message = "autoscaling_cooldown_seconds must be at least 60."
  }
}

variable "operations_email" {
  description = "Optional ONS EMAIL endpoint. Keep the real address in protected runtime input, never in committed tfvars."
  type        = string
  default     = ""
  sensitive   = true
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

variable "min_healthy_backends" {
  type    = number
  default = 1
}

variable "max_replacements_per_window" {
  type    = number
  default = 2
}

variable "replacement_window_seconds" {
  type    = number
  default = 1800
}

variable "alarm_pending_duration" {
  type    = string
  default = "PT3M"
}

variable "freeform_tags" {
  type = map(string)
  default = {
    project   = "oci-instance-pool-self-healing"
    component = "self_healing"
  }
}
