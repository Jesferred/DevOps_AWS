# 4. Cost visibility for every change

Date: 2026-11-06
Status: Accepted

## Context

The project must stay cheap. Cost should be visible before a resource is created,
and the actual spend should be visible after it exists.

## Decision

- **Before:** Infracost runs on every PR that touches `infra/` and comments the
  monthly cost per stack and the difference introduced by the PR. Usage-based
  resources get explicit traffic assumptions in `infracost-usage.yml` files next
  to their stacks.
- **After:** `Project` and `Stack` are activated as cost allocation tags, so Cost
  Explorer can break real spend down per Terraform stack. The site shows
  month-to-date cost and forecast, refreshed weekly via the Cost Explorer API.
- **Guardrail:** a $5 monthly AWS Budget alerts at 80% actual and 100% forecasted
  spend through the shared SNS topic.

## Consequences

- Infracost uses list prices; it does not apply the free tier or credits.
- Cost Explorer API calls cost $0.01 each: two per week, about $0.09 a month.
  The cost card can be up to 7 days behind; the site shows when it was updated.
