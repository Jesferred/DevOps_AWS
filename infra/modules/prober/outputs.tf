output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "region" {
  value = data.aws_region.current.region
}
