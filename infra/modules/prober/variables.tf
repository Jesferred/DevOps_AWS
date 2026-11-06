variable "name" {
  description = "Lambda function and schedule name."
  type        = string
}

variable "target_url" {
  description = "HTTPS URL to probe."
  type        = string
}

variable "enabled" {
  description = "Whether the schedule runs."
  type        = bool
}

variable "package_path" {
  description = "Path to the Lambda zip."
  type        = string
}

variable "package_hash" {
  description = "Base64 SHA-256 of the Lambda zip."
  type        = string
}

variable "lambda_role_arn" {
  description = "Execution role for the probe Lambda."
  type        = string
}

variable "scheduler_role_arn" {
  description = "Role EventBridge Scheduler assumes to invoke the Lambda."
  type        = string
}

variable "table_name" {
  description = "DynamoDB table receiving probe results."
  type        = string
}

variable "table_region" {
  description = "Region of the DynamoDB table."
  type        = string
}
