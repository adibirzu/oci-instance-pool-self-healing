output "load_balancer_id" {
  value     = local.load_balancer_id
  sensitive = true
}

output "load_balancer_ip" {
  value = local.create_load_balancer ? (
    oci_load_balancer_load_balancer.this[0].ip_address_details[0].ip_address
  ) : ""
  sensitive = true
}

output "backend_set_name" {
  value = local.backend_set_name
}

output "instance_pool_id" {
  value     = local.instance_pool_id
  sensitive = true
}

output "function_application_id" {
  value     = oci_functions_application.this.id
  sensitive = true
}

output "function_id" {
  value     = var.enable_function ? oci_functions_function.remediator[0].id : ""
  sensitive = true
}

output "alarm_id" {
  value     = var.enable_function ? oci_monitoring_alarm.unhealthy_backend[0].id : ""
  sensitive = true
}

output "notification_topic_id" {
  value     = oci_ons_notification_topic.this.id
  sensitive = true
}

output "container_repository_path" {
  value = "${var.region}.ocir.io/${data.oci_objectstorage_namespace.this.namespace}/${oci_artifacts_container_repository.function.display_name}"
}
