# Synthetic monitoring and SLOs for kovalov.in.
#
#   probers (3 regions, every minute) --> DynamoDB --> aggregator (every 5 min)
#                                                        |--> s3://<site>/live/status.json (site "Live infra")
#                                                        '--> CloudWatch burn-rate metrics --> alarms --> SNS
#   aggregator (weekly) --> Cost Explorer, SSL Labs, Mozilla Observatory --> DynamoDB
#   CI deploy/apply jobs --> deployment events --> DynamoDB (DORA metrics)

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  backend "s3" {
    bucket       = "kovalov-in-tfstate-524941137773"
    key          = "prod/monitoring/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  name       = "kovalov-in-prod"
  target_url = "https://kovalov.in/"
  slo_target = 0.999

  default_tags = {
    Project     = "kovalov-in"
    Stack       = "prod/monitoring"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "ap_southeast_1"
  region = "ap-southeast-1"

  default_tags {
    tags = local.default_tags
  }
}

variable "probes_enabled" {
  description = "Run the probes. Keep false until the site serves traffic, or the outage before launch burns the error budget."
  type        = bool
  default     = false
}

data "aws_caller_identity" "current" {}

data "aws_s3_bucket" "site" {
  bucket = "kovalov-in-site-prod-${data.aws_caller_identity.current.account_id}"
}

# Built from the name rather than looked up, so this stack can be planned before
# global/alerting has created the topic.
locals {
  alerts_topic_arn = "arn:aws:sns:eu-central-1:${data.aws_caller_identity.current.account_id}:kovalov-in-alerts"
}

# --- storage ---

resource "aws_dynamodb_table" "monitoring" {
  name                        = "${local.name}-monitoring"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = true

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  # Restore to any second in the last 35 days; ~$0.02/month at this table size.
  point_in_time_recovery {
    enabled = true
  }

  # Raw probes expire after 35 days; rollups and incidents have no TTL attribute.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

# --- Lambda packages ---

data "archive_file" "prober" {
  type        = "zip"
  source_dir  = "${path.module}/../../../../services/prober"
  output_path = "${path.module}/.build/prober.zip"
  # Fixed mode: identical zips (and hashes) on WSL, macOS and CI runners.
  output_file_mode = "0644"
  excludes         = ["__pycache__"]
}

data "archive_file" "aggregator" {
  type        = "zip"
  source_dir  = "${path.module}/../../../../services/aggregator"
  output_path = "${path.module}/.build/aggregator.zip"
  # Fixed mode: identical zips (and hashes) on WSL, macOS and CI runners.
  output_file_mode = "0644"
  excludes         = ["__pycache__", "tests", "tests/test_slo.py"]
}

# --- IAM ---

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "prober" {
  name               = "${local.name}-prober"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "prober_logs" {
  role       = aws_iam_role.prober.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "prober" {
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.monitoring.arn]
  }
}

resource "aws_iam_role_policy" "prober" {
  name   = "write-probes"
  role   = aws_iam_role.prober.id
  policy = data.aws_iam_policy_document.prober.json
}

resource "aws_iam_role" "aggregator" {
  name               = "${local.name}-aggregator"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "aggregator_logs" {
  role       = aws_iam_role.aggregator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "aggregator_xray" {
  role       = aws_iam_role.aggregator.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "aggregator" {
  statement {
    sid       = "MonitoringTable"
    actions   = ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.monitoring.arn]
  }

  statement {
    sid       = "PublishStatus"
    actions   = ["s3:PutObject"]
    resources = ["${data.aws_s3_bucket.site.arn}/live/status.json"]
  }

  statement {
    sid       = "BurnRateMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["KovalovIn/SLO"]
    }
  }

  statement {
    sid       = "CostExplorer"
    actions   = ["ce:GetCostAndUsage", "ce:GetCostForecast"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "aggregator" {
  name   = "aggregate-slo"
  role   = aws_iam_role.aggregator.id
  policy = data.aws_iam_policy_document.aggregator.json
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name}-monitoring-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions = ["lambda:InvokeFunction"]
    resources = [
      module.prober_eu.function_arn,
      module.prober_us.function_arn,
      module.prober_ap.function_arn,
      aws_lambda_function.aggregator.arn,
    ]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "invoke-monitoring"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

# --- probers: Europe, North America, Asia ---

module "prober_eu" {
  source = "../../../modules/prober"

  name               = "${local.name}-prober"
  target_url         = local.target_url
  enabled            = var.probes_enabled
  package_path       = data.archive_file.prober.output_path
  package_hash       = data.archive_file.prober.output_base64sha256
  lambda_role_arn    = aws_iam_role.prober.arn
  scheduler_role_arn = aws_iam_role.scheduler.arn
  table_name         = aws_dynamodb_table.monitoring.name
  table_region       = "eu-central-1"
}

module "prober_us" {
  source    = "../../../modules/prober"
  providers = { aws = aws.us_east_1 }

  name               = "${local.name}-prober"
  target_url         = local.target_url
  enabled            = var.probes_enabled
  package_path       = data.archive_file.prober.output_path
  package_hash       = data.archive_file.prober.output_base64sha256
  lambda_role_arn    = aws_iam_role.prober.arn
  scheduler_role_arn = aws_iam_role.scheduler.arn
  table_name         = aws_dynamodb_table.monitoring.name
  table_region       = "eu-central-1"
}

module "prober_ap" {
  source    = "../../../modules/prober"
  providers = { aws = aws.ap_southeast_1 }

  name               = "${local.name}-prober"
  target_url         = local.target_url
  enabled            = var.probes_enabled
  package_path       = data.archive_file.prober.output_path
  package_hash       = data.archive_file.prober.output_base64sha256
  lambda_role_arn    = aws_iam_role.prober.arn
  scheduler_role_arn = aws_iam_role.scheduler.arn
  table_name         = aws_dynamodb_table.monitoring.name
  table_region       = "eu-central-1"
}

# --- aggregator ---

resource "aws_cloudwatch_log_group" "aggregator" {
  name              = "/aws/lambda/${local.name}-aggregator"
  retention_in_days = 30
}

resource "aws_lambda_function" "aggregator" {
  function_name    = "${local.name}-aggregator"
  description      = "Computes SLOs and cost for the Live infra block"
  role             = aws_iam_role.aggregator.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.aggregator.output_path
  source_code_hash = data.archive_file.aggregator.output_base64sha256
  memory_size      = 256
  # The weekly security run waits for an SSL Labs assessment (several minutes);
  # status runs finish in seconds.
  timeout = 900

  # ~8.6k invocations/month: within the X-Ray free tier (100k traces).
  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      TABLE_NAME  = aws_dynamodb_table.monitoring.name
      SITE_BUCKET = data.aws_s3_bucket.site.id
      SLO_TARGET  = tostring(local.slo_target)
      SITE_HOST   = "kovalov.in"
    }
  }

  logging_config {
    log_format            = "JSON"
    log_group             = aws_cloudwatch_log_group.aggregator.name
    application_log_level = "INFO"
    system_log_level      = "WARN"
  }
}

resource "aws_scheduler_schedule" "aggregator_status" {
  name                = "${local.name}-aggregator-status"
  schedule_expression = "rate(5 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.aggregator.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ mode = "status" })
  }
}

# Weekly is enough for a portfolio cost card: 2 calls x $0.01 x ~4.3 weeks = ~$0.09/month
# instead of ~$0.60 for a daily refresh. Mondays 06:00 UTC.
resource "aws_scheduler_schedule" "aggregator_cost" {
  name                = "${local.name}-aggregator-cost"
  schedule_expression = "cron(0 6 ? * MON *)"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 30
  }

  target {
    arn      = aws_lambda_function.aggregator.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ mode = "cost" })
  }
}

resource "aws_scheduler_schedule" "aggregator_security" {
  name                = "${local.name}-aggregator-security"
  description         = "Weekly SSL Labs, Mozilla Observatory, HSTS preload and DNS checks"
  schedule_expression = "cron(30 6 ? * MON *)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.aggregator.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ mode = "security" })

    retry_policy {
      maximum_retry_attempts = 0 # SSL Labs rate-limits new assessments
    }
  }
}

# --- DORA: CI records deployment events ---

# The deploy role lives in prod/site; this stack grants it write access to its
# own table so the dependency points one way (monitoring -> site).
data "aws_iam_policy_document" "record_deployments" {
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.monitoring.arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "dynamodb:LeadingKeys"
      values   = ["deploy"]
    }
  }
}

resource "aws_iam_role_policy" "site_deploy_records" {
  name   = "record-deployments"
  role   = "gha-deploy-site-prod"
  policy = data.aws_iam_policy_document.record_deployments.json
}

# --- alerts ---

# Fast burn: 2% of the 30-day budget gone in 1 hour (confirmed over 5 min). Page.
resource "aws_cloudwatch_metric_alarm" "fast_burn" {
  alarm_name          = "${local.name}-slo-fast-burn"
  alarm_description   = "Availability SLO ${local.slo_target}: burn rate > 14.4 over 1h and 5m."
  namespace           = "KovalovIn/SLO"
  metric_name         = "FastBurn"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.alerts_topic_arn]
  ok_actions          = [local.alerts_topic_arn]
}

# Slow burn: 5% of the budget gone in 6 hours (confirmed over 30 min). Ticket.
resource "aws_cloudwatch_metric_alarm" "slow_burn" {
  alarm_name          = "${local.name}-slo-slow-burn"
  alarm_description   = "Availability SLO ${local.slo_target}: burn rate > 6 over 6h and 30m."
  namespace           = "KovalovIn/SLO"
  metric_name         = "SlowBurn"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.alerts_topic_arn]
  ok_actions          = [local.alerts_topic_arn]
}

# Watchdog: monitoring that silently stops is worse than no monitoring.
resource "aws_cloudwatch_metric_alarm" "probes_missing" {
  count = var.probes_enabled ? 1 : 0

  alarm_name          = "${local.name}-probes-missing"
  alarm_description   = "No probe results in the last 10 minutes: the SLO is blind."
  namespace           = "KovalovIn/SLO"
  metric_name         = "ProbeCount5m"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [local.alerts_topic_arn]
  ok_actions          = [local.alerts_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "aggregator_errors" {
  alarm_name          = "${local.name}-aggregator-errors"
  alarm_description   = "SLO aggregator Lambda is failing."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.aggregator.function_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.alerts_topic_arn]
}

output "table_name" {
  value = aws_dynamodb_table.monitoring.name
}

output "aggregator_function" {
  value = aws_lambda_function.aggregator.function_name
}
