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
    key          = "global/dns/terraform.tfstate"
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
      Stack     = "global/dns"
      ManagedBy = "terraform"
    }
  }
}

# The hosted zone was created manually in the console before IaC existed.
import {
  to = module.dns.aws_route53_zone.this
  id = "Z03638582K21WB9HPWKZJ"
}

module "dns" {
  source = "../../../modules/dns"

  domain_name = "kovalov.in"

  # Mail is hosted at hostsila; records copied from the previous zone.
  mx_records = ["10 skm222.hostsila.org"]

  # `+a` from the old record is dropped on purpose: once the apex points to
  # CloudFront it would authorize CloudFront IPs to send mail for the domain.
  spf_record = "v=spf1 mx ip4:185.67.3.64 ~all"

  dkim_records = {
    default = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAulcMPNCpLQ6CkNiGTukiUx2FS3paEHG7Fgkc2oUNnpIzpg8dY46+p9/0LIfUNZT2eV3rt46OVGhItHBBQUgVqQAXC1Clh/GVW225oEXhVSxNDRbLo05+rnkSd6GfOI6KUGkqd6y9NPBmgVAfxtd7V3Qacb3j2JREnKzlHsrGqHU7kcB9FyOp3JRBycXu7DupB/cSGh/5TcRCgdd7T2IUgWqjQrvuRHT8BRZ4Igw0EpYS1FUqvqDQQvVzxK+K2vtlhfwnFsQ+NTN8HTQtRFqXiZZ235KtVvukAJMe1ZcS6q3ZpWDkP8Jpj8f5o1ku483bilKH5yjt5J1WP4mKn0m6+QIDAQAB;"
  }

  # Monitoring mode first; tighten to quarantine/reject once reports confirm
  # all legitimate mail passes SPF/DKIM alignment.
  dmarc_record = "v=DMARC1; p=none; adkim=r; aspf=r"

  # Only Amazon (ACM) may issue certificates; no wildcard certificates at all.
  caa_records = [
    "0 issue \"amazon.com\"",
    "0 issuewild \";\"",
  ]
}

output "name_servers" {
  description = "Set these at the domain registrar."
  value       = module.dns.name_servers
}
