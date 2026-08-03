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
  value     = { for name, function in oci_functions_function.remediator : name => function.id }
  sensitive = true
}

output "container_repository_path" {
  value = "${var.region}.ocir.io/${data.oci_objectstorage_namespace.this.namespace}/${oci_artifacts_container_repository.function.display_name}"
}

output "log_group_id" {
  value     = oci_logging_log_group.this.id
  sensitive = true
}
