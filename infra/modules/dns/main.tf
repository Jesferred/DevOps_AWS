terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

resource "aws_route53_zone" "this" {
  name    = var.domain_name
  comment = "Managed by Terraform"

  lifecycle {
    prevent_destroy = true
  }
}

# --- Mail (hosted outside AWS) ---

resource "aws_route53_record" "mx" {
  zone_id = aws_route53_zone.this.zone_id
  name    = var.domain_name
  type    = "MX"
  ttl     = var.ttl
  records = var.mx_records
}

resource "aws_route53_record" "spf" {
  zone_id = aws_route53_zone.this.zone_id
  name    = var.domain_name
  type    = "TXT"
  ttl     = var.ttl
  records = [var.spf_record]
}

resource "aws_route53_record" "dkim" {
  for_each = var.dkim_records

  zone_id = aws_route53_zone.this.zone_id
  name    = "${each.key}._domainkey.${var.domain_name}"
  type    = "TXT"
  ttl     = var.ttl
  # Route 53 limits a single TXT string to 255 chars; long DKIM keys are split into chunks.
  records = [join("\"\"", [for i in range(0, length(each.value), 255) : substr(each.value, i, 255)])]
}

resource "aws_route53_record" "dmarc" {
  zone_id = aws_route53_zone.this.zone_id
  name    = "_dmarc.${var.domain_name}"
  type    = "TXT"
  ttl     = var.ttl
  records = [var.dmarc_record]
}

# --- Certificate issuance policy ---

resource "aws_route53_record" "caa" {
  zone_id = aws_route53_zone.this.zone_id
  name    = var.domain_name
  type    = "CAA"
  ttl     = var.ttl
  records = var.caa_records
}
