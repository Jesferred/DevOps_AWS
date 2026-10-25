# 1. Single AWS account for now

Date: 2026-10-25
Status: Accepted

## Context

Multi-account (AWS Organizations: management / staging / prod) is the standard
landing-zone pattern. The project runs on a new account on the AWS Free plan.
Creating or joining an Organization upgrades a Free plan account to paid and
expires all remaining Free Tier credits immediately.

## Decision

Run everything in one account (524941137773). Separate environments by
Terraform state key and resource name prefix, not by account.

## Consequences

- Free Tier credits are preserved.
- Weaker blast-radius isolation between environments; mitigated by separate
  state files and least-privilege CI roles.
- Stacks take no hard-coded assumptions about sharing an account, so moving
  staging/prod into separate accounts later is a backend/provider change.
