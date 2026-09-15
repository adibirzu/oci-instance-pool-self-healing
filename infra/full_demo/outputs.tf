output "load_balancer_id" {
  value     = oci_load_balancer_load_balancer.this.id
  sensitive = true
}

output "load_balancer_ip" {
  value     = oci_load_balancer_load_balancer.this.ip_address_details[0].ip_address
  sensitive = true
}

output "instance_pool_ids" {
  value     = { for name, pool in oci_core_instance_pool.service : name => pool.id }
  sensitive = true
}

output "backend_set_names" {
  value = { for name, backend_set in oci_load_balancer_backend_set.service : name => backend_set.name }
}

output "service_ports" {
  value = { for name, service in var.services : name => service.backend_port }
}

output "function_ids" {
  value     = var.external_function_ids
  sensitive = true
}

output "function_config_yaml" {
  description = "Copy one service block into an externally deployed Function's func.yaml after the base stack apply."
  sensitive   = true
  value = {
    for name, service in var.services : name => <<-EOT
      config:
        MODE: "${var.function_mode}"
        SERVICE_NAME: "${name}"
        COMPARTMENT_ID: "${var.compartment_id}"
        LOAD_BALANCER_ID: "${oci_load_balancer_load_balancer.this.id}"
        BACKEND_SET_NAME: "${service.backend_set_name}"
        INSTANCE_POOL_ID: "${oci_core_instance_pool.service[name].id}"
        STATE_TABLE_ID: "${oci_nosql_table.state[name].id}"
        STATE_TABLE_NAME: "${oci_nosql_table.state[name].name}"
        MIN_HEALTHY_BACKENDS: "${service.min_healthy}"
        MAX_REPLACEMENTS_PER_WINDOW: "${service.max_replacements}"
        REPLACEMENT_WINDOW_SECONDS: "${service.replacement_window_secs}"
    EOT
  }
}

output "log_group_id" {
  value     = oci_logging_log_group.this.id
  sensitive = true
}
