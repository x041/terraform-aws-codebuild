data "aws_caller_identity" "default" {}

data "aws_region" "default" {}

resource "aws_s3_bucket" "cache_bucket" {
  #bridgecrew:skip=BC_AWS_S3_13:Skipping `Enable S3 Bucket Logging` check until bridgecrew will support dynamic blocks (https://github.com/bridgecrewio/checkov/issues/776).
  #bridgecrew:skip=BC_AWS_S3_14:Skipping `Ensure all data stored in the S3 bucket is securely encrypted at rest` check until bridgecrew will support dynamic blocks (https://github.com/bridgecrewio/checkov/issues/776).
  #bridgecrew:skip=CKV_AWS_52:Skipping `Ensure S3 bucket has MFA delete enabled` due to issue in terraform (https://github.com/hashicorp/terraform-provider-aws/issues/629).
  count         = module.this.enabled && local.create_s3_cache_bucket ? 1 : 0
  bucket        = local.cache_bucket_name_normalised
  force_destroy = true
  tags          = module.this.tags

  versioning {
    enabled = var.versioning_enabled
  }

  dynamic "logging" {
    for_each = var.access_log_bucket_name != "" ? [1] : []
    content {
      target_bucket = var.access_log_bucket_name
      target_prefix = "logs/${module.this.id}/"
    }
  }

  lifecycle_rule {
    id      = "codebuildcache"
    enabled = true

    prefix = "/"
    tags   = module.this.tags

    expiration {
      days = var.cache_expiration_days
    }
  }

  dynamic "server_side_encryption_configuration" {
    for_each = var.encryption_enabled ? ["true"] : []

    content {
      rule {
        apply_server_side_encryption_by_default {
          sse_algorithm = "AES256"
        }
      }
    }
  }
}

resource "random_string" "bucket_prefix" {
  count   = module.this.enabled ? 1 : 0
  length  = 12
  numeric = false
  upper   = false
  special = false
  lower   = true
}

locals {
  cache_bucket_name = "${module.this.id}${var.cache_bucket_suffix_enabled ? "-${join("", random_string.bucket_prefix.*.result)}" : ""}"

  ## Clean up the bucket name to use only hyphens, and trim its length to 63 characters.
  ## As per https://docs.aws.amazon.com/AmazonS3/latest/dev/BucketRestrictions.html
  cache_bucket_name_normalised = substr(
    join("-", split("_", lower(local.cache_bucket_name))),
    0,
    min(length(local.cache_bucket_name), 63),
  )

  s3_cache_enabled       = var.cache_type == "S3"
  create_s3_cache_bucket = local.s3_cache_enabled && var.s3_cache_bucket_name == null
  s3_bucket_name         = local.create_s3_cache_bucket ? join("", aws_s3_bucket.cache_bucket.*.bucket) : var.s3_cache_bucket_name

  ## This is the magic where a map of a list of maps is generated
  ## and used to conditionally add the cache bucket option to the
  ## aws_codebuild_project
  cache_options = {
    "S3" = {
      type     = "S3"
      location = module.this.enabled && local.s3_cache_enabled ? local.s3_bucket_name : "none"
    },
    "LOCAL" = {
      type  = "LOCAL"
      modes = var.local_cache_modes
    },
    "NO_CACHE" = {
      type = "NO_CACHE"
    }
  }

  # Final Map Selected from above
  cache = local.cache_options[var.cache_type]
}

# Main IAM Role
resource "aws_iam_role" "default" {
  count                 = module.this.enabled ? 1 : 0
  name                  = module.this.id
  assume_role_policy    = data.aws_iam_policy_document.role.json
  force_detach_policies = true
  path                  = var.iam_role_path
  permissions_boundary  = var.iam_permissions_boundary
  tags                  = module.this.tags
}

data "aws_iam_policy_document" "role" {
  statement {
    sid = ""

    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    effect = "Allow"
  }
}

resource "aws_iam_policy" "default" {
  count  = module.this.enabled ? 1 : 0
  name   = module.this.id
  path   = var.iam_policy_path
  policy = data.aws_iam_policy_document.combined_permissions.json
  tags   = module.this.tags
}

resource "aws_iam_policy" "default_cache_bucket" {
  count = module.this.enabled && local.s3_cache_enabled ? 1 : 0

  name   = "${module.this.id}-cache-bucket"
  path   = var.iam_policy_path
  policy = join("", data.aws_iam_policy_document.permissions_cache_bucket.*.json)
  tags   = module.this.tags
}

data "aws_s3_bucket" "secondary_artifact" {
  for_each = module.this.enabled ? var.secondary_artifacts : {}
  bucket   = each.value.bucket_location
}

data "aws_iam_policy_document" "permissions" {
  count = module.this.enabled ? 1 : 0

  statement {
    sid = ""

    actions = compact(concat([
      "codecommit:GitPull",
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:GetAuthorizationToken",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecs:RunTask",
      "iam:PassRole",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "ssm:GetParameters",
      "secretsmanager:GetSecretValue",
    ], var.extra_permissions))

    effect = "Allow"

    resources = [
      "*",
    ]
  }

  dynamic "statement" {
    for_each = data.aws_s3_bucket.secondary_artifact
    content {
      sid = ""

      actions = [
        "s3:PutObject",
        "s3:GetBucketAcl",
        "s3:GetBucketLocation",
        "s3:ListBucket"
      ]

      effect = "Allow"

      resources = [
        statement.value.arn,
        join("/", [statement.value.arn, "*"])
      ]
    }
  }
}

data "aws_iam_policy_document" "vpc_permissions" {
  count = module.this.enabled && var.vpc_config != {} ? 1 : 0

  statement {
    sid = ""

    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs"
    ]

    resources = [
      "*",
    ]
  }

  statement {
    sid = ""

    actions = [
      "ec2:CreateNetworkInterfacePermission"
    ]

    resources = [
      "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:network-interface/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:Subnet"
      values = formatlist(
        "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:subnet/%s",
        var.vpc_config.subnets
      )
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:AuthorizedService"
      values = [
        "codebuild.amazonaws.com"
      ]
    }

  }
}

data "aws_iam_policy_document" "combined_permissions" {
  override_policy_documents = compact([
    join("", data.aws_iam_policy_document.permissions.*.json),
    var.vpc_config != {} ? join("", data.aws_iam_policy_document.vpc_permissions.*.json) : null
  ])
}

data "aws_iam_policy_document" "permissions_cache_bucket" {
  count = module.this.enabled && local.s3_cache_enabled ? 1 : 0
  statement {
    sid = ""

    actions = [
      "s3:*",
    ]

    effect = "Allow"

    resources = [
      join("", aws_s3_bucket.cache_bucket.*.arn),
      "${join("", aws_s3_bucket.cache_bucket.*.arn)}/*",
    ]
  }
}

resource "aws_iam_role_policy_attachment" "default" {
  count      = module.this.enabled ? 1 : 0
  policy_arn = join("", aws_iam_policy.default.*.arn)
  role       = join("", aws_iam_role.default.*.id)
}

resource "aws_iam_role_policy_attachment" "default_cache_bucket" {
  count      = module.this.enabled && local.s3_cache_enabled ? 1 : 0
  policy_arn = join("", aws_iam_policy.default_cache_bucket.*.arn)
  role       = join("", aws_iam_role.default.*.id)
}

# Build Batch IAM Role
resource "aws_iam_role" "build_batch" {
  count = module.this.enabled && var.build_batch_config.enabled ? 1 : 0

  name                  = "${module.this.id}-batch"
  assume_role_policy    = data.aws_iam_policy_document.role.json
  force_detach_policies = true
  path                  = var.iam_role_path

  tags = module.this.tags
}

data "aws_iam_policy_document" "build_batch" {
  count = module.this.enabled && var.build_batch_config.enabled ? 1 : 0

  statement {
    sid = ""

    actions = [
      "codebuild:StartBuild",
      "codebuild:StopBuild",
      "codebuild:RetryBuild"
    ]

    effect = "Allow"

    resources = [
      join("", aws_codebuild_project.default.*.arn)
    ]
  }
}

resource "aws_iam_role_policy" "build_batch" {
  count = module.this.enabled && var.build_batch_config.enabled ? 1 : 0

  name_prefix = "${module.this.id}-build-batch"
  role        = join("", aws_iam_role.build_batch.*.id)
  policy      = join("", data.aws_iam_policy_document.build_batch.*.json)
}

# CodeBuild Config
resource "aws_codebuild_source_credential" "authorization" {
  count       = module.this.enabled && var.private_repository ? 1 : 0
  auth_type   = var.source_credential_auth_type
  server_type = var.source_credential_server_type
  token       = var.source_credential_token
  user_name   = var.source_credential_user_name
}

resource "aws_codebuild_project" "default" {
  count                  = module.this.enabled ? 1 : 0
  name                   = module.this.id
  description            = var.description
  concurrent_build_limit = var.concurrent_build_limit
  service_role           = join("", aws_iam_role.default.*.arn)
  badge_enabled          = var.badge_enabled
  build_timeout          = var.build_timeout
  source_version         = var.source_version != "" ? var.source_version : null
  encryption_key         = var.encryption_key

  tags = {
    for name, value in module.this.tags :
    name => value
    if length(value) > 0
  }

  dynamic "build_batch_config" {
    for_each = var.build_batch_config.enabled ? [1] : []
    content {
      service_role      = join("", aws_iam_role.build_batch.*.arn)
      combine_artifacts = var.build_batch_config.combine_artifacts
      timeout_in_mins   = var.build_batch_config.timeout_in_mins

      restrictions {
        maximum_builds_allowed = var.build_batch_config.restrictions.maximum_builds_allowed
        compute_types_allowed  = var.build_batch_config.restrictions.compute_types_allowed
      }
    }
  }

  artifacts {
    type     = var.artifact_type
    location = var.artifact_location
  }

  dynamic "secondary_artifacts" {
    for_each = var.secondary_artifacts
    content {
      type                = "S3"
      artifact_identifier = secondary_artifacts.key

      location            = secondary_artifacts.value.bucket_location
      encryption_disabled = !secondary_artifacts.value.encryption_enabled
      path                = secondary_artifacts.value.path
      name                = secondary_artifacts.value.name
    }
  }

  cache {
    type     = lookup(local.cache, "type", null)
    location = lookup(local.cache, "location", null)
    modes    = lookup(local.cache, "modes", null)
  }

  environment {
    compute_type                = var.build_compute_type
    image                       = var.build_image
    image_pull_credentials_type = var.build_image_pull_credentials_type
    type                        = var.build_type
    privileged_mode             = var.privileged_mode

    environment_variable {
      name  = "AWS_REGION"
      value = signum(length(var.aws_region)) == 1 ? var.aws_region : data.aws_region.default.name
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = signum(length(var.aws_account_id)) == 1 ? var.aws_account_id : data.aws_caller_identity.default.account_id
    }

    dynamic "environment_variable" {
      for_each = signum(length(var.image_repo_name)) == 1 ? [""] : []
      content {
        name  = "IMAGE_REPO_NAME"
        value = var.image_repo_name
      }
    }

    dynamic "environment_variable" {
      for_each = signum(length(var.image_tag)) == 1 ? [""] : []
      content {
        name  = "IMAGE_TAG"
        value = var.image_tag
      }
    }

    dynamic "environment_variable" {
      for_each = signum(length(module.this.stage)) == 1 ? [""] : []
      content {
        name  = "STAGE"
        value = module.this.stage
      }
    }

    dynamic "environment_variable" {
      for_each = signum(length(var.github_token)) == 1 ? [""] : []
      content {
        name  = "GITHUB_TOKEN"
        value = var.github_token
        type  = var.github_token_type
      }
    }

    dynamic "environment_variable" {
      for_each = var.environment_variables
      content {
        name  = environment_variable.value.name
        value = environment_variable.value.value
        type  = environment_variable.value.type
      }
    }

  }

  source {
    buildspec           = var.buildspec
    type                = var.source_type
    location            = var.source_location
    report_build_status = var.report_build_status
    git_clone_depth     = var.git_clone_depth != null ? var.git_clone_depth : null

    dynamic "git_submodules_config" {
      for_each = var.fetch_git_submodules ? [""] : []
      content {
        fetch_submodules = true
      }
    }
  }

  dynamic "secondary_sources" {
    for_each = var.secondary_sources
    content {
      git_clone_depth     = secondary_source.value.git_clone_depth
      location            = secondary_source.value.location
      source_identifier   = secondary_source.value.source_identifier
      type                = secondary_source.value.type
      insecure_ssl        = secondary_source.value.insecure_ssl
      report_build_status = secondary_source.value.report_build_status

      git_submodules_config {
        fetch_submodules = secondary_source.value.fetch_submodules
      }
    }
  }

  dynamic "vpc_config" {
    for_each = length(var.vpc_config) > 0 ? [""] : []
    content {
      vpc_id             = lookup(var.vpc_config, "vpc_id", null)
      subnets            = lookup(var.vpc_config, "subnets", null)
      security_group_ids = lookup(var.vpc_config, "security_group_ids", null)
    }
  }

  dynamic "logs_config" {
    for_each = length(var.logs_config) > 0 ? [""] : []
    content {
      dynamic "cloudwatch_logs" {
        for_each = contains(keys(var.logs_config), "cloudwatch_logs") ? { key = var.logs_config["cloudwatch_logs"] } : {}
        content {
          status      = lookup(cloudwatch_logs.value, "status", null)
          group_name  = lookup(cloudwatch_logs.value, "group_name", null)
          stream_name = lookup(cloudwatch_logs.value, "stream_name", null)
        }
      }

      dynamic "s3_logs" {
        for_each = contains(keys(var.logs_config), "s3_logs") ? { key = var.logs_config["s3_logs"] } : {}
        content {
          status              = lookup(s3_logs.value, "status", null)
          location            = lookup(s3_logs.value, "location", null)
          encryption_disabled = lookup(s3_logs.value, "encryption_disabled", null)
        }
      }
    }
  }

  dynamic "file_system_locations" {
    for_each = length(var.file_system_locations) > 0 ? [""] : []
    content {
      identifier    = lookup(file_system_locations.value, "identifier", null)
      location      = lookup(file_system_locations.value, "location", null)
      mount_options = lookup(file_system_locations.value, "mount_options", null)
      mount_point   = lookup(file_system_locations.value, "mount_point", null)
      type          = lookup(file_system_locations.value, "type", null)
    }
  }
}

# Webhook (GitHub)
resource "aws_codebuild_webhook" "default" {
  count = module.this.enabled && var.webhook.enabled ? 1 : 0

  project_name = join("", aws_codebuild_project.default.*.name)

  build_type = module.this.enabled && var.build_batch_config.enabled ? "BUILD_BATCH" : "BUILD"

  dynamic "filter_group" {
    for_each = var.webhook.filter_groups
    content {
      dynamic "filter" {
        for_each = filter_group.value.filters
        content {
          type                    = filter.value.type
          pattern                 = filter.value.pattern
          exclude_matched_pattern = filter.value.exclude
        }
      }
    }
  }
}
