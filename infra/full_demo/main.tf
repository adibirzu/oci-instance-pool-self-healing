data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "oracle_linux" {
  compartment_id           = var.compartment_id
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

locals {
  backend_ports = toset([for service in values(var.services) : tostring(service.backend_port)])
  state_names = {
    for name, _service in var.services : name => "${replace(var.name_prefix, "-", "_")}_${name}_state"
  }
  function_matching_rule = var.enable_function ? "ANY {${join(", ", [
    for function in values(oci_functions_function.remediator) : "resource.id = '${function.id}'"
  ])}}" : "ALL {resource.type = 'fnfunc', resource.compartment.id = '${var.compartment_id}'}"
}

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.name_prefix}-vcn"
  dns_label      = "shealthdemo"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-nat"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-private-routes"
  freeform_tags  = var.freeform_tags
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this.id
  }
}

resource "oci_core_subnet" "load_balancer" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = cidrsubnet(var.vcn_cidr, 8, 10)
  display_name               = "${var.name_prefix}-lb-subnet"
  dns_label                  = "lb"
  prohibit_public_ip_on_vnic = true
  freeform_tags              = var.freeform_tags
}

resource "oci_core_subnet" "backend" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = cidrsubnet(var.vcn_cidr, 8, 20)
  display_name               = "${var.name_prefix}-backend-subnet"
  dns_label                  = "backend"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  freeform_tags              = var.freeform_tags
}

resource "oci_core_subnet" "function" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = cidrsubnet(var.vcn_cidr, 8, 30)
  display_name               = "${var.name_prefix}-function-subnet"
  dns_label                  = "functions"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  freeform_tags              = var.freeform_tags
}

resource "oci_core_network_security_group" "load_balancer" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-lb-nsg"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_network_security_group" "backend" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-backend-nsg"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_network_security_group" "function" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-function-nsg"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_network_security_group_security_rule" "listener_ingress" {
  for_each                  = var.services
  network_security_group_id = oci_core_network_security_group.load_balancer.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.allowed_client_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Internal synthetic ${each.key} listener"
  tcp_options {
    destination_port_range {
      min = each.value.backend_port
      max = each.value.backend_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_backend_egress" {
  for_each                  = var.services
  network_security_group_id = oci_core_network_security_group.load_balancer.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.backend.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Synthetic ${each.key} traffic and health checks"
  tcp_options {
    destination_port_range {
      min = each.value.backend_port
      max = each.value.backend_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "backend_ingress" {
  for_each                  = var.services
  network_security_group_id = oci_core_network_security_group.backend.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.load_balancer.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Synthetic ${each.key} from private LB"
  tcp_options {
    destination_port_range {
      min = each.value.backend_port
      max = each.value.backend_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "backend_egress" {
  network_security_group_id = oci_core_network_security_group.backend.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Package and OCI service egress through NAT"
}

resource "oci_core_network_security_group_security_rule" "function_egress" {
  network_security_group_id = oci_core_network_security_group.function.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "OCI service API egress through NAT"
}

resource "oci_load_balancer_load_balancer" "this" {
  compartment_id             = var.compartment_id
  display_name               = "${var.name_prefix}-lb"
  shape                      = "flexible"
  subnet_ids                 = [oci_core_subnet.load_balancer.id]
  network_security_group_ids = [oci_core_network_security_group.load_balancer.id]
  is_private                 = true
  freeform_tags              = var.freeform_tags
  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 10
  }
}

resource "oci_load_balancer_backend_set" "service" {
  for_each         = var.services
  load_balancer_id = oci_load_balancer_load_balancer.this.id
  name             = each.value.backend_set_name
  policy           = "ROUND_ROBIN"
  health_checker {
    protocol            = "HTTP"
    port                = each.value.backend_port
    url_path            = each.value.health_path
    return_code         = 200
    interval_ms         = 10000
    timeout_in_millis   = 3000
    retries             = 3
    response_body_regex = ".*healthy.*"
  }
}

resource "oci_load_balancer_listener" "service" {
  for_each                 = var.services
  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "${replace(var.name_prefix, "-", "_")}_${each.key}_http"
  default_backend_set_name = oci_load_balancer_backend_set.service[each.key].name
  port                     = each.value.backend_port
  protocol                 = "HTTP"
}

resource "oci_core_instance_configuration" "service" {
  for_each       = var.services
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-${each.key}-configuration"
  freeform_tags  = merge(var.freeform_tags, { service = each.key })
  lifecycle {
    create_before_destroy = true
  }
  instance_details {
    instance_type = "compute"
    launch_details {
      compartment_id = var.compartment_id
      shape          = var.instance_shape
      display_name   = "${var.name_prefix}-${each.key}-backend"
      freeform_tags  = merge(var.freeform_tags, { service = each.key, volume_policy = "disposable" })
      metadata = {
        user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
          service_name = each.key
          backend_port = each.value.backend_port
        }))
      }
      shape_config {
        ocpus         = var.instance_ocpus
        memory_in_gbs = var.instance_memory_gbs
      }
      source_details {
        source_type = "image"
        image_id    = data.oci_core_images.oracle_linux.images[0].id
      }
      create_vnic_details {
        assign_public_ip = false
        subnet_id        = oci_core_subnet.backend.id
        nsg_ids          = [oci_core_network_security_group.backend.id]
      }
      agent_config {
        are_all_plugins_disabled = false
        is_management_disabled   = false
        is_monitoring_disabled   = false
        plugins_config {
          name          = "Compute Instance Run Command"
          desired_state = "ENABLED"
        }
      }
    }
  }
}

resource "oci_core_instance_pool" "service" {
  for_each                  = var.services
  compartment_id            = var.compartment_id
  display_name              = "${var.name_prefix}-${each.key}-pool"
  instance_configuration_id = oci_core_instance_configuration.service[each.key].id
  size                      = each.value.initial_size
  freeform_tags             = merge(var.freeform_tags, { service = each.key })
  placement_configurations {
    availability_domain = data.oci_identity_availability_domains.this.availability_domains[0].name
    primary_subnet_id   = oci_core_subnet.backend.id
  }
  load_balancers {
    load_balancer_id = oci_load_balancer_load_balancer.this.id
    backend_set_name = oci_load_balancer_backend_set.service[each.key].name
    port             = each.value.backend_port
    vnic_selection   = "PrimaryVnic"
  }
  depends_on = [oci_load_balancer_listener.service]
}

resource "oci_autoscaling_auto_scaling_configuration" "service" {
  for_each             = var.services
  compartment_id       = var.compartment_id
  display_name         = "${var.name_prefix}-${each.key}-autoscaling"
  cool_down_in_seconds = each.value.cooldown_seconds
  is_enabled           = true
  freeform_tags        = merge(var.freeform_tags, { service = each.key })
  auto_scaling_resources {
    id   = oci_core_instance_pool.service[each.key].id
    type = "instancePool"
  }
  policies {
    display_name = "${var.name_prefix}-${each.key}-cpu-policy"
    policy_type  = "threshold"
    is_enabled   = true
    capacity {
      initial = each.value.initial_size
      min     = each.value.min_size
      max     = each.value.max_size
    }
    rules {
      display_name = "scale-out"
      action {
        type  = "CHANGE_COUNT_BY"
        value = 1
      }
      metric {
        metric_source    = "COMPUTE_AGENT"
        metric_type      = "CPU_UTILIZATION"
        pending_duration = "PT3M"
        threshold {
          operator = "GT"
          value    = 70
        }
      }
    }
    rules {
      display_name = "scale-in"
      action {
        type  = "CHANGE_COUNT_BY"
        value = -1
      }
      metric {
        metric_source    = "COMPUTE_AGENT"
        metric_type      = "CPU_UTILIZATION"
        pending_duration = "PT3M"
        threshold {
          operator = "LT"
          value    = 20
        }
      }
    }
  }
}

resource "oci_artifacts_container_repository" "function" {
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}/health-remediator"
  is_immutable   = false
  is_public      = false
  freeform_tags  = var.freeform_tags
}

resource "oci_functions_application" "this" {
  compartment_id             = var.compartment_id
  display_name               = "${var.name_prefix}-functions"
  subnet_ids                 = [oci_core_subnet.function.id]
  network_security_group_ids = [oci_core_network_security_group.function.id]
  shape                      = "GENERIC_X86"
  freeform_tags              = var.freeform_tags
}

resource "oci_nosql_table" "state" {
  for_each       = var.services
  compartment_id = var.compartment_id
  name           = local.state_names[each.key]
  ddl_statement  = "CREATE TABLE ${local.state_names[each.key]} (event_key STRING, created_epoch LONG, pool_id STRING, backend_name STRING, action STRING, detail STRING, PRIMARY KEY(SHARD(event_key)))"
  freeform_tags  = merge(var.freeform_tags, { service = each.key })
  table_limits {
    capacity_mode      = "ON_DEMAND"
    max_read_units     = 0
    max_write_units    = 0
    max_storage_in_gbs = 1
  }
}

resource "oci_ons_notification_topic" "service" {
  for_each       = var.services
  compartment_id = var.compartment_id
  name           = "${var.name_prefix}-${each.key}-notifications"
  description    = "Synthetic ${each.key} backend health and remediation"
  freeform_tags  = merge(var.freeform_tags, { service = each.key })
}

resource "oci_functions_function" "remediator" {
  for_each           = var.enable_function ? var.services : {}
  application_id     = oci_functions_application.this.id
  display_name       = "${var.name_prefix}-${each.key}-health-remediator"
  image              = var.function_image
  image_digest       = var.function_image_digest != "" ? var.function_image_digest : null
  memory_in_mbs      = 512
  timeout_in_seconds = 120
  freeform_tags      = merge(var.freeform_tags, { service = each.key })
  config = {
    MODE                        = var.function_mode
    SERVICE_NAME                = each.key
    COMPARTMENT_ID              = var.compartment_id
    LOAD_BALANCER_ID            = oci_load_balancer_load_balancer.this.id
    BACKEND_SET_NAME            = each.value.backend_set_name
    INSTANCE_POOL_ID            = oci_core_instance_pool.service[each.key].id
    STATE_TABLE_ID              = oci_nosql_table.state[each.key].id
    STATE_TABLE_NAME            = oci_nosql_table.state[each.key].name
    STATUS_TOPIC_ID             = oci_ons_notification_topic.service[each.key].id
    MIN_HEALTHY_BACKENDS        = tostring(each.value.min_healthy)
    MAX_REPLACEMENTS_PER_WINDOW = tostring(each.value.max_replacements)
    REPLACEMENT_WINDOW_SECONDS  = tostring(each.value.replacement_window_secs)
  }
}

resource "oci_identity_dynamic_group" "function" {
  count          = var.enable_function ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${replace(var.name_prefix, "-", "_")}_function_dg"
  description    = "Exact synthetic health remediation Functions"
  matching_rule  = local.function_matching_rule
}

resource "oci_identity_policy" "function" {
  count          = var.enable_function ? 1 : 0
  compartment_id = var.compartment_id
  name           = "${replace(var.name_prefix, "-", "_")}_function_policy"
  description    = "Synthetic self-healing Function permissions"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to read load-balancers in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to manage instance-pools in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to manage instances in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to use vnics in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to use subnets in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to read nosql-tables in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to use nosql-rows in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to use ons-topics in compartment id ${var.compartment_id}",
  ]
}

resource "oci_ons_subscription" "function" {
  for_each       = var.enable_function ? var.services : {}
  compartment_id = var.compartment_id
  topic_id       = oci_ons_notification_topic.service[each.key].id
  protocol       = "ORACLE_FUNCTIONS"
  endpoint       = oci_functions_function.remediator[each.key].id
  depends_on     = [oci_identity_policy.function]
}

resource "oci_ons_subscription" "email" {
  for_each       = var.operations_email != "" ? var.services : {}
  compartment_id = var.compartment_id
  topic_id       = oci_ons_notification_topic.service[each.key].id
  protocol       = "EMAIL"
  endpoint       = var.operations_email
}

resource "oci_monitoring_alarm" "unhealthy_backend" {
  for_each              = var.enable_function ? var.services : {}
  compartment_id        = var.compartment_id
  metric_compartment_id = var.compartment_id
  display_name          = "${var.name_prefix}-${each.key}-unhealthy-backend"
  namespace             = "oci_lbaas"
  query                 = "unhealthyBackendServers[1m]{resourceId = \"${oci_load_balancer_load_balancer.this.id}\", backendSetName = \"${each.value.backend_set_name}\"}.max() > 0"
  severity              = "CRITICAL"
  destinations          = [oci_ons_notification_topic.service[each.key].id]
  is_enabled            = true
  pending_duration      = "PT3M"
  body                  = "Synthetic backend remains unhealthy; Function will revalidate before action."
  freeform_tags         = merge(var.freeform_tags, { service = each.key })
  depends_on            = [oci_ons_subscription.function]
}

resource "oci_logging_log_group" "this" {
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-logs"
  description    = "Synthetic self-healing Function and Load Balancer logs"
  freeform_tags  = var.freeform_tags
}

resource "oci_logging_log" "function" {
  count              = var.enable_function ? 1 : 0
  display_name       = "${var.name_prefix}-function-invocations"
  log_group_id       = oci_logging_log_group.this.id
  log_type           = "SERVICE"
  is_enabled         = true
  retention_duration = var.log_retention_days
  configuration {
    compartment_id = var.compartment_id
    source {
      category    = "invoke"
      resource    = oci_functions_application.this.id
      service     = "functions"
      source_type = "OCISERVICE"
    }
  }
}

resource "oci_logging_log" "load_balancer_access" {
  display_name       = "${var.name_prefix}-lb-access"
  log_group_id       = oci_logging_log_group.this.id
  log_type           = "SERVICE"
  is_enabled         = true
  retention_duration = var.log_retention_days
  configuration {
    compartment_id = var.compartment_id
    source {
      category    = "access"
      resource    = oci_load_balancer_load_balancer.this.id
      service     = "loadbalancer"
      source_type = "OCISERVICE"
    }
  }
}

resource "oci_logging_log" "load_balancer_error" {
  display_name       = "${var.name_prefix}-lb-error"
  log_group_id       = oci_logging_log_group.this.id
  log_type           = "SERVICE"
  is_enabled         = true
  retention_duration = var.log_retention_days
  configuration {
    compartment_id = var.compartment_id
    source {
      category    = "error"
      resource    = oci_load_balancer_load_balancer.this.id
      service     = "loadbalancer"
      source_type = "OCISERVICE"
    }
  }
}
