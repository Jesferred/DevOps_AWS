# kovalov.in

Personal site of a DevOps engineer, built and operated as a production system on AWS.

## Layout

```
infra/
  bootstrap/          S3 bucket for Terraform remote state (native S3 locking)
  modules/dns/        Route 53 public zone: mail records, DMARC, CAA
  live/global/dns/    The kovalov.in zone
```

## Requirements

- Terraform >= 1.11 (S3 backend `use_lockfile`)
- AWS CLI profile for the target account

Static keys exported in the shell (`AWS_ACCESS_KEY_ID`) take precedence over
`AWS_PROFILE`. Unset them before running Terraform:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_PROFILE=new2026
aws sts get-caller-identity   # must print 524941137773
```

## Bootstrap (one-time)

```bash
cd infra/bootstrap
terraform init && terraform apply
cp backend.tf.example backend.tf   # fill in account ID
terraform init -migrate-state
```

## DNS migration runbook

The domain is registered at an external registrar (Endurance / NIXI `.in`).
DNS moves from the old AWS account's zone to the zone managed here.

1. `terraform apply` in `infra/live/global/dns`.
2. Verify records against the new name servers before delegating:
   `dig @ns-1059.awsdns-04.org kovalov.in MX`
3. At the registrar, replace name servers with the `name_servers` output.
4. Wait at least 48 h (parent NS TTL) with both zones unchanged; send a test email.
5. Delete the old zone (`Z0624273Z3CGB3AQ36CV`, account 654654144212).
