# One synthetic probe location: Lambda + EventBridge Scheduler in the region of
# the `aws` provider passed in. IAM roles are global and created by the caller.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_region" "current" {}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "this" {
  function_name    = var.name
  description      = "Synthetic HTTPS probe for ${var.target_url}"
  role             = var.lambda_role_arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = var.package_path
  source_code_hash = var.package_hash
  memory_size      = 128
  timeout          = 15

  environment {
    variables = {
      TARGET_URL   = var.target_url
      TABLE_NAME   = var.table_name
      TABLE_REGION = var.table_region
    }
  }

  # WARN level drops START/END/REPORT lines: ~130k invocations a month would
  # otherwise be the largest CloudWatch Logs cost of the whole project.
  logging_config {
    log_format            = "JSON"
    log_group             = aws_cloudwatch_log_group.this.name
    application_log_level = "WARN"
    system_log_level      = "WARN"
  }
}

resource "aws_scheduler_schedule" "this" {
  name                = var.name
  description         = "Run ${var.name} every minute"
  schedule_expression = "rate(1 minutes)"
  state               = var.enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.this.arn
    role_arn = var.scheduler_role_arn

    retry_policy {
      maximum_retry_attempts = 0 # a late probe is worse than a missing one
    }
  }
}
