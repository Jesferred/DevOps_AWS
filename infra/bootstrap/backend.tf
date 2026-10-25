# After the first apply, copy this file to backend.tf and run
# `terraform init -migrate-state` to move bootstrap state into the bucket.
terraform {
  backend "s3" {
    bucket       = "kovalov-in-tfstate-524941137773"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
