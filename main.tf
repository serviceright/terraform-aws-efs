locals {
  enabled                = module.this.enabled
  security_group_enabled = local.enabled && var.create_security_group

  dns_name = format("%s.efs.%s.amazonaws.com", join("", aws_efs_file_system.default.*.id), var.region)
  # Returning null in the lookup function gives type errors and is not omitting the parameter.
  # This work around ensures null is returned.
  posix_users = {
    for k, v in var.access_points :
    k => lookup(var.access_points[k], "posix_user", {})
  }
  secondary_gids = {
    for k, v in var.access_points :
    k => lookup(local.posix_users, "secondary_gids", null)
  }
}

resource "aws_efs_file_system" "default" {
  #bridgecrew:skip=BC_AWS_GENERAL_48: BC complains about not having an AWS Backup plan. We ignore this because this can be done outside of this module.
  count                           = local.enabled ? 1 : 0
  tags                            = module.this.tags
  availability_zone_name          = var.availability_zone_name
  encrypted                       = var.encrypted
  kms_key_id                      = var.kms_key_id
  performance_mode                = var.performance_mode
  provisioned_throughput_in_mibps = var.provisioned_throughput_in_mibps
  throughput_mode                 = var.throughput_mode

  dynamic "lifecycle_policy" {
    for_each = length(var.transition_to_ia) > 0 || length(var.transition_to_primary_storage_class) > 0 ? [1] : []
    content {
      transition_to_ia                    = try(var.transition_to_ia[0], null)
      transition_to_primary_storage_class = try(var.transition_to_primary_storage_class[0], null)
    }
  }
}

resource "aws_efs_file_system_policy" "default" {
  count = local.enabled ? 1 : 0
  file_system_id = aws_efs_file_system.default[0].id

  bypass_policy_lockout_safety_check = true

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "*"
            },
            "Action": [
                "elasticfilesystem:ClientRootAccess",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:ClientMount"
            ],
            "Resource": "${aws_efs_file_system.default[0].arn}",
            "Condition": {
                "Bool": {
                    "elasticfilesystem:AccessedViaMountTarget": "true"
                }
            }
        },
        {
            "Effect": "Deny",
            "Principal": {
                "AWS": "*"
            },
            "Action": "*",
            "Resource": "${aws_efs_file_system.default[0].arn}",
            "Condition": {
                "Bool": {
                    "aws:SecureTransport": "false"
                }
            }
        }
    ]
}
POLICY
}

resource "aws_efs_mount_target" "default" {
  count          = local.enabled && length(var.subnets) > 0 ? length(var.subnets) : 0
  file_system_id = join("", aws_efs_file_system.default.*.id)
  ip_address     = var.mount_target_ip_address
  subnet_id      = var.subnets[count.index]
  security_groups = var.security_groups
}

resource "aws_efs_access_point" "default" {
  for_each = var.access_points

  file_system_id = join("", aws_efs_file_system.default.*.id)

  dynamic "posix_user" {
    for_each = local.posix_users[each.key] != null ? ["true"] : []

    content {
      gid            = local.posix_users[each.key]["gid"]
      uid            = local.posix_users[each.key]["uid"]
      secondary_gids = local.secondary_gids[each.key] != null ? split(",", local.secondary_gids[each.key]) : null
    }
  }

  root_directory {
    path = "/${each.key}"

    dynamic "creation_info" {
      for_each = try(var.access_points[each.key]["creation_info"]["gid"], "") != "" ? ["true"] : []

      content {
        owner_gid   = var.access_points[each.key]["creation_info"]["gid"]
        owner_uid   = var.access_points[each.key]["creation_info"]["uid"]
        permissions = var.access_points[each.key]["creation_info"]["permissions"]
      }
    }
  }

  tags = module.this.tags
}

module "dns" {
  source  = "cloudposse/route53-cluster-hostname/aws"
  version = "0.12.2"

  enabled  = local.enabled && length(var.zone_id) > 0
  dns_name = var.dns_name == "" ? module.this.id : var.dns_name
  ttl      = 60
  zone_id  = try(var.zone_id[0], null)
  records  = [local.dns_name]

  context = module.this.context
}

resource "aws_efs_backup_policy" "policy" {
  count = module.this.enabled ? 1 : 0

  file_system_id = join("", aws_efs_file_system.default.*.id)

  backup_policy {
    status = var.efs_backup_policy_enabled ? "ENABLED" : "DISABLED"
  }
}
