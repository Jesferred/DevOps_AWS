# Account-wide alerting and cost guardrails: one SNS topic for every alert,
# a monthly budget, and cost allocation tags for per-stack cost reports.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "kovalov-in-tfstate-524941137773"
    key          = "global/alerting/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      Project   = "kovalov-in"
      Stack     = "global/alerting"
      ManagedBy = "terraform"
    }
  }
}

variable "alert_email" {
  description = "Email subscribed to alerts. Passed from the ALERT_EMAIL GitHub variable, never committed."
  type        = string
  default     = null
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget in USD."
  type        = number
  default     = 5
}

data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "alerts" {
  name = "kovalov-in-alerts"
}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid       = "AllowAccountPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "AllowServicePublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com", "cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

# Email subscriptions must be confirmed from the inbox before they deliver.
resource "aws_sns_topic_subscription" "email" {
  # An unset GitHub variable arrives as "", not null.
  count = var.alert_email != null && var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_budgets_budget" "monthly" {
  name         = "kovalov-in-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  depends_on = [aws_sns_topic_policy.alerts]
}

# Makes these tag keys available as dimensions in Cost Explorer and billing reports.
resource "aws_ce_cost_allocation_tag" "this" {
  for_each = toset(["Project", "Stack"])

  tag_key = each.key
  status  = "Active"
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
