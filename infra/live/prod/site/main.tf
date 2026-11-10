# Static site on AWS Amplify Hosting (manual deployments, no Git connection).
#
#   CI build --> s3://<bucket>/releases/site.zip (versioned, last 5 kept) --> Amplify deployment
#   Visitor --> Route 53 --> Amplify (AWS-managed CloudFront, our ACM cert, security headers)
#                              '-- /live/* reverse-proxied to s3://<bucket>/live/ (monitoring JSON)
#
# Amplify replaced a self-managed CloudFront distribution: this account is not
# allowed to create CloudFront resources (see docs/adr/0007).

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
    key          = "prod/site/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  domain      = "kovalov.in"
  repo        = "Jesferred@44315534/DevOps_AWS@1433110978"
  bucket_name = "kovalov-in-site-prod-${data.aws_caller_identity.current.account_id}"
  release_key = "releases/site.zip"

  custom_headers_file = "${path.module}/custom-headers.yml"

  # Hosted zone ID of every CloudFront distribution, used for alias records.
  cloudfront_zone_id = "Z2FDTNDATAQYW2"

  default_tags = {
    Project     = "kovalov-in"
    Stack       = "prod/site"
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

# Certificates for CloudFront-backed endpoints, Amplify included, must live in us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.default_tags
  }
}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "this" {
  name = local.domain
}

# --- TLS certificate ---

# Our own certificate instead of an Amplify-managed one: Amplify's managed
# certificate includes a wildcard, which the zone's CAA record (`issuewild ";"`)
# forbids on purpose.
resource "aws_acm_certificate" "site" {
  provider = aws.us_east_1

  domain_name               = local.domain
  subject_alternative_names = ["www.${local.domain}"]
  validation_method         = "DNS"
  key_algorithm             = "EC_prime256v1"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.site.domain_validation_options : o.domain_name => o
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  ttl             = 300
  records         = [each.value.resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# --- Release and live-data bucket ---
#   releases/  private, versioned: one object version per deploy, read by Amplify
#   live/      public-read JSON written by the monitoring aggregator

resource "aws_s3_bucket" "site" {
  bucket = local.bucket_name
}

# Public access is allowed by policy only (for live/*); ACLs stay disabled.
resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Every deploy is a new version of releases/site.zip, so rolling back means
# restoring an older version (see .github/workflows/rollback.yml).
resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  # Releases: expire only when older than 90 days AND beyond the 5 most recent,
  # so a site untouched for a year still has 5 releases to roll back to.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 5
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  # status.json is rewritten every 5 minutes; its history has no value.
  rule {
    id     = "expire-live-data-history"
    status = "Enabled"

    filter {
      prefix = "live/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

data "aws_iam_policy_document" "site_bucket" {
  # Amplify's pre-flight check rejects aws:SourceArn conditions, so access is
  # scoped to this account's Amplify apps and the releases/ prefix.
  statement {
    sid       = "AmplifyReadReleases"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/releases/*"]

    principals {
      type        = "Service"
      identifiers = ["amplify.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # Monitoring data shown on the site; public by design, proxied by Amplify.
  statement {
    sid       = "PublicReadLiveData"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/live/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.site]
}

# --- Amplify Hosting ---

resource "aws_amplify_app" "site" {
  name        = "kovalov-in-prod"
  description = "kovalov.in, deployed from CI as zip releases"
  platform    = "WEB"
  # Initial value only; updates go through terraform_data.custom_headers below.
  custom_headers = file(local.custom_headers_file)

  cache_config {
    type = "AMPLIFY_MANAGED_NO_COOKIES"
  }

  lifecycle {
    ignore_changes = [custom_headers]
  }

  # Rules are evaluated top to bottom. The bare-host rule covers "/", which the
  # <*> form does not match.
  custom_rule {
    source = "https://www.${local.domain}"
    target = "https://${local.domain}"
    status = "301"
  }

  custom_rule {
    source = "https://www.${local.domain}/<*>"
    target = "https://${local.domain}/<*>"
    status = "301"
  }

  # Reverse proxy keeps the JSON same-origin, so the CSP stays `connect-src 'self'`.
  custom_rule {
    source = "/live/<*>"
    target = "https://${aws_s3_bucket.site.bucket_regional_domain_name}/live/<*>"
    status = "200"
  }

  # Applied only when no file matches the path.
  custom_rule {
    source = "/<*>"
    target = "/404.html"
    status = "404"
  }
}

# The Amplify API accepts headers only as YAML with a top-level `customHeaders`
# key but returns them as a bare JSON array, so the attribute can never match
# its own config and would show a diff on every plan. Terraform ignores it and
# pushes the file through the API whenever its content changes.
resource "terraform_data" "custom_headers" {
  triggers_replace = [aws_amplify_app.site.id, filesha256(local.custom_headers_file)]

  provisioner "local-exec" {
    command = "aws amplify update-app --region eu-central-1 --app-id ${aws_amplify_app.site.id} --custom-headers file://${local.custom_headers_file} --query app.appId --output text"
  }
}

resource "aws_amplify_branch" "main" {
  app_id            = aws_amplify_app.site.id
  branch_name       = "main"
  stage             = "PRODUCTION"
  enable_auto_build = false
}

resource "aws_amplify_domain_association" "site" {
  app_id                 = aws_amplify_app.site.id
  domain_name            = local.domain
  enable_auto_sub_domain = false
  wait_for_verification  = true

  certificate_settings {
    type                   = "CUSTOM"
    custom_certificate_arn = aws_acm_certificate_validation.site.certificate_arn
  }

  sub_domain {
    branch_name = aws_amplify_branch.main.branch_name
    prefix      = ""
  }

  sub_domain {
    branch_name = aws_amplify_branch.main.branch_name
    prefix      = "www"
  }
}

# --- DNS ---

locals {
  # dns_record looks like "www CNAME d123.cloudfront.net" (apex: " CNAME d123...").
  amplify_target = split(" ", one([
    for s in aws_amplify_domain_association.site.sub_domain : s.dns_record if s.prefix == ""
  ]))[2]
}

# Amplify writes the same records itself when the zone is in this account;
# keeping them here puts DNS in code and adds IPv6 (Amplify creates A only).
resource "aws_route53_record" "apex" {
  for_each = toset(["A", "AAAA"])

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = local.domain
  type            = each.key
  allow_overwrite = true

  alias {
    name                   = local.amplify_target
    zone_id                = local.cloudfront_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  zone_id         = data.aws_route53_zone.this.zone_id
  name            = "www.${local.domain}"
  type            = "CNAME"
  ttl             = 300
  records         = [local.amplify_target]
  allow_overwrite = true
}

# --- Deploy wiring for CI ---

resource "aws_ssm_parameter" "app_id" {
  name  = "/kovalov-in/prod/site/amplify-app-id"
  type  = "String"
  value = aws_amplify_app.site.id
}

resource "aws_ssm_parameter" "bucket" {
  name  = "/kovalov-in/prod/site/bucket"
  type  = "String"
  value = aws_s3_bucket.site.id
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:environment:production"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "gha-deploy-site-prod"
  description          = "GitHub Actions: publish a site release to Amplify, or roll back"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "PublishRelease"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.site.arn}/${local.release_key}"]
  }

  # StartDeployment checks these on the caller's behalf before Amplify reads the
  # zip (it sets an object ACL; a no-op here since ACLs are disabled).
  statement {
    sid       = "LetAmplifyReadRelease"
    actions   = ["s3:GetObjectAcl", "s3:PutObjectAcl"]
    resources = ["${aws_s3_bucket.site.arn}/${local.release_key}"]
  }

  statement {
    sid       = "ReadReleaseHistory"
    actions   = ["s3:GetObjectVersion", "s3:ListBucketVersions"]
    resources = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/${local.release_key}"]
  }

  # StartDeployment is authorized against .../branches/main/deployments/start,
  # GetJob and ListJobs against .../branches/main/jobs/<id>.
  statement {
    sid     = "DeployToAmplify"
    actions = ["amplify:StartDeployment", "amplify:GetJob", "amplify:ListJobs"]
    resources = [
      aws_amplify_branch.main.arn,
      "${aws_amplify_branch.main.arn}/deployments/*",
      "${aws_amplify_branch.main.arn}/jobs/*",
    ]
  }

  statement {
    sid       = "ReadDeployParameters"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.app_id.arn, aws_ssm_parameter.bucket.arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy-site"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "bucket" {
  value = aws_s3_bucket.site.id
}

output "amplify_app_id" {
  value = aws_amplify_app.site.id
}

output "deploy_role_arn" {
  value = aws_iam_role.deploy.arn
}
