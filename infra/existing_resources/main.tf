data "oci_identity_availability_domains" "this" {
  count          = local.create_instance_pool ? 1 : 0
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "oracle_linux" {
  count                    = local.create_instance_pool ? 1 : 0
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
  # Dependency-only by design. Use full_demo when the toolkit must own compute
  # or Load Balancer resources for a disposable test environment.
  create_instance_pool     = false
  create_load_balancer     = false
  create_backend_set       = false
  load_balancer_id         = var.existing_load_balancer_id
  instance_pool_id         = var.existing_instance_pool_id
  managed_backend_set_name = "${replace(var.name_prefix, "-", "_")}_backends"
  backend_set_name         = var.existing_backend_set_name
  listener_name            = "${replace(var.name_prefix, "-", "_")}_http"
  state_table_name         = "${replace(var.name_prefix, "-", "_")}_state"
}

check "existing_resources_are_complete" {
  assert {
    condition = alltrue([
      var.existing_instance_pool_id != "",
      var.existing_load_balancer_id != "",
      var.existing_backend_set_name != "",
    ])
    error_message = "existing_resources requires an existing instance pool, load balancer, and backend set; use full_demo for newly owned resources."
  }
}

resource "oci_core_network_security_group" "backend" {
  count          = local.create_instance_pool ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = data.oci_core_subnet.private.vcn_id
  display_name   = "${var.name_prefix}-backend-nsg"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_network_security_group" "load_balancer" {
  count          = local.create_load_balancer ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = data.oci_core_subnet.private.vcn_id
  display_name   = "${var.name_prefix}-lb-nsg"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_network_security_group" "function" {
  compartment_id = var.compartment_id
  vcn_id         = data.oci_core_subnet.private.vcn_id
  display_name   = "${var.name_prefix}-function-nsg"
  freeform_tags  = var.freeform_tags
}

data "oci_core_subnet" "private" {
  subnet_id = var.private_subnet_id
}

resource "oci_core_network_security_group_security_rule" "private_listener" {
  count                     = local.create_load_balancer ? 1 : 0
  network_security_group_id = oci_core_network_security_group.load_balancer[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = data.oci_core_subnet.private.cidr_block
  source_type               = "CIDR_BLOCK"
  description               = "Private Self-Healing listener"
  tcp_options {
    destination_port_range {
      min = var.listener_port
      max = var.listener_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_egress" {
  count                     = local.create_load_balancer && local.create_instance_pool ? 1 : 0
  network_security_group_id = oci_core_network_security_group.load_balancer[0].id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.backend[0].id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "LB health checks and traffic to Self-Healing backends"
  tcp_options {
    destination_port_range {
      min = var.backend_port
      max = var.backend_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "backend_ingress" {
  count                     = local.create_load_balancer && local.create_instance_pool ? 1 : 0
  network_security_group_id = oci_core_network_security_group.backend[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.load_balancer[0].id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Self-Healing traffic from the dedicated LB"
  tcp_options {
    destination_port_range {
      min = var.backend_port
      max = var.backend_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "backend_egress" {
  count                     = local.create_instance_pool ? 1 : 0
  network_security_group_id = oci_core_network_security_group.backend[0].id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "OS and OCI service egress"
}

resource "oci_core_network_security_group_security_rule" "function_egress" {
  network_security_group_id = oci_core_network_security_group.function.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "OCI service API egress"
}

resource "oci_load_balancer_load_balancer" "this" {
  count                      = local.create_load_balancer ? 1 : 0
  compartment_id             = var.compartment_id
  display_name               = "${var.name_prefix}-lb"
  shape                      = "flexible"
  subnet_ids                 = [var.private_subnet_id]
  network_security_group_ids = [oci_core_network_security_group.load_balancer[0].id]
  is_private                 = true
  freeform_tags              = var.freeform_tags

  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 10
  }
}

resource "oci_load_balancer_backend_set" "this" {
  count            = local.create_backend_set ? 1 : 0
  load_balancer_id = local.load_balancer_id
  name             = local.managed_backend_set_name
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol            = "HTTP"
    port                = var.backend_port
    url_path            = "/healthz"
    return_code         = 200
    interval_ms         = 10000
    timeout_in_millis   = 3000
    retries             = 3
    response_body_regex = ".*healthy.*"
  }
}

resource "oci_load_balancer_listener" "this" {
  count                    = local.create_backend_set ? 1 : 0
  load_balancer_id         = local.load_balancer_id
  name                     = local.listener_name
  default_backend_set_name = oci_load_balancer_backend_set.this[0].name
  port                     = var.listener_port
  protocol                 = "HTTP"
}

resource "oci_core_instance_configuration" "this" {
  count          = local.create_instance_pool ? 1 : 0
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-configuration"
  freeform_tags  = var.freeform_tags

  lifecycle {
    create_before_destroy = true
  }

  instance_details {
    instance_type = "compute"
    launch_details {
      compartment_id = var.compartment_id
      shape          = var.instance_shape
      display_name   = "${var.name_prefix}-backend"
      freeform_tags  = var.freeform_tags
      metadata = {
        user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
          backend_port = var.backend_port
        }))
      }
      shape_config {
        ocpus         = var.instance_ocpus
        memory_in_gbs = var.instance_memory_gbs
      }
      source_details {
        source_type = "image"
        image_id    = data.oci_core_images.oracle_linux[0].images[0].id
      }
      create_vnic_details {
        assign_public_ip = false
        subnet_id        = var.private_subnet_id
        nsg_ids          = [oci_core_network_security_group.backend[0].id]
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

resource "oci_core_instance_pool" "this" {
  count                     = local.create_instance_pool ? 1 : 0
  compartment_id            = var.compartment_id
  display_name              = "${var.name_prefix}-pool"
  instance_configuration_id = oci_core_instance_configuration.this[0].id
  size                      = var.pool_initial_size
  freeform_tags             = var.freeform_tags

  placement_configurations {
    availability_domain = data.oci_identity_availability_domains.this[0].availability_domains[0].name
    primary_subnet_id   = var.private_subnet_id
  }

  load_balancers {
    load_balancer_id = local.load_balancer_id
    backend_set_name = local.backend_set_name
    port             = var.backend_port
    vnic_selection   = "PrimaryVnic"
  }

  depends_on = [oci_load_balancer_listener.this]
}

resource "oci_autoscaling_auto_scaling_configuration" "this" {
  count                = local.create_instance_pool ? 1 : 0
  compartment_id       = var.compartment_id
  display_name         = "${var.name_prefix}-autoscaling"
  cool_down_in_seconds = var.autoscaling_cooldown_seconds
  is_enabled           = true
  freeform_tags        = var.freeform_tags

  auto_scaling_resources {
    id   = oci_core_instance_pool.this[0].id
    type = "instancePool"
  }

  policies {
    display_name = "${var.name_prefix}-cpu-policy"
    policy_type  = "threshold"
    is_enabled   = true
    capacity {
      initial = var.pool_initial_size
      min     = var.pool_min_size
      max     = var.pool_max_size
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

resource "oci_ons_notification_topic" "this" {
  compartment_id = var.compartment_id
  name           = "${var.name_prefix}-notifications"
  description    = "Self-Healing backend health alarms and remediation status"
  freeform_tags  = var.freeform_tags
}

resource "oci_nosql_table" "state" {
  compartment_id = var.compartment_id
  name           = local.state_table_name
  ddl_statement  = "CREATE TABLE ${local.state_table_name} (event_key STRING, created_epoch LONG, pool_id STRING, backend_name STRING, action STRING, detail STRING, PRIMARY KEY(SHARD(event_key)))"
  freeform_tags  = var.freeform_tags
  table_limits {
    capacity_mode      = "ON_DEMAND"
    max_read_units     = 0
    max_write_units    = 0
    max_storage_in_gbs = 1
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
  subnet_ids                 = [var.private_subnet_id]
  network_security_group_ids = [oci_core_network_security_group.function.id]
  shape                      = "GENERIC_X86"
  freeform_tags              = var.freeform_tags
}

resource "oci_functions_function" "remediator" {
  count              = var.enable_function ? 1 : 0
  application_id     = oci_functions_application.this.id
  display_name       = "${var.name_prefix}-health-remediator"
  image              = var.function_image
  image_digest       = var.function_image_digest != "" ? var.function_image_digest : null
  memory_in_mbs      = 512
  timeout_in_seconds = 120
  freeform_tags      = var.freeform_tags
  config = {
    MODE                        = var.function_mode
    COMPARTMENT_ID              = var.compartment_id
    LOAD_BALANCER_ID            = local.load_balancer_id
    BACKEND_SET_NAME            = local.backend_set_name
    INSTANCE_POOL_ID            = local.instance_pool_id
    STATE_TABLE_ID              = oci_nosql_table.state.id
    STATE_TABLE_NAME            = oci_nosql_table.state.name
    STATUS_TOPIC_ID             = oci_ons_notification_topic.this.id
    MIN_HEALTHY_BACKENDS        = tostring(var.min_healthy_backends)
    MAX_REPLACEMENTS_PER_WINDOW = tostring(var.max_replacements_per_window)
    REPLACEMENT_WINDOW_SECONDS  = tostring(var.replacement_window_seconds)
  }
}

resource "oci_identity_dynamic_group" "function" {
  count          = var.enable_function ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${replace(var.name_prefix, "-", "_")}_function_dg"
  description    = "Exact Self-Healing health remediation Function"
  matching_rule  = "ALL {resource.type = 'fnfunc', resource.id = '${oci_functions_function.remediator[0].id}'}"
}

resource "oci_identity_policy" "function" {
  count          = var.enable_function ? 1 : 0
  compartment_id = var.compartment_id
  name           = "${replace(var.name_prefix, "-", "_")}_function_policy"
  description    = "Least-privilege Self-Healing health remediation permissions"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to read load-balancers in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to manage instance-pools in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to manage instances in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to use vnics in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to use subnets in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to manage volume-attachments in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to use volumes in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to read nosql-tables in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to use nosql-rows in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.function[0].name} to use ons-topics in compartment id ${var.compartment_id}",
  ]
}

resource "oci_ons_subscription" "function" {
  # Contract: protocol = "ORACLE_FUNCTIONS"
  count          = var.enable_function ? 1 : 0
  compartment_id = var.compartment_id
  topic_id       = oci_ons_notification_topic.this.id
  protocol       = "ORACLE_FUNCTIONS"
  endpoint       = oci_functions_function.remediator[0].id
  depends_on     = [oci_identity_policy.function]
}

resource "oci_ons_subscription" "email" {
  count          = var.operations_email != "" ? 1 : 0
  compartment_id = var.compartment_id
  topic_id       = oci_ons_notification_topic.this.id
  protocol       = "EMAIL"
  endpoint       = var.operations_email
}

resource "oci_monitoring_alarm" "unhealthy_backend" {
  count                 = var.enable_function ? 1 : 0
  compartment_id        = var.compartment_id
  metric_compartment_id = var.compartment_id
  display_name          = "${var.name_prefix}-unhealthy-backend"
  namespace             = "oci_lbaas"
  query                 = "unhealthyBackendServers[1m]{resourceId = \"${local.load_balancer_id}\", backendSetName = \"${local.backend_set_name}\"}.max() > 0"
  severity              = "CRITICAL"
  destinations          = [oci_ons_notification_topic.this.id]
  is_enabled            = true
  pending_duration      = var.alarm_pending_duration
  body                  = "Self-Healing backend remains unhealthy; remediation Function will revalidate before action."
  freeform_tags         = var.freeform_tags
  depends_on            = [oci_ons_subscription.function]
}

resource "oci_logging_log_group" "this" {
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-logs"
  description    = "Self-Healing remediation Function logs"
  freeform_tags  = var.freeform_tags
}

resource "oci_logging_log" "function" {
  count              = var.enable_function ? 1 : 0
  display_name       = "${var.name_prefix}-function-invocations"
  log_group_id       = oci_logging_log_group.this.id
  log_type           = "SERVICE"
  is_enabled         = true
  retention_duration = 30
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
