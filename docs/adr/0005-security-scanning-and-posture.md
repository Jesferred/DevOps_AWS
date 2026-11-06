# 5. Security scanning in CI and a public security posture

Date: 2026-11-06
Status: Accepted

## Context

Security should be enforced before merge and verifiable by anyone after deploy.

## Decision

- **Before merge** (`security` workflow, every PR, push and weekly):
  - Trivy scans Terraform for misconfigurations, lockfiles for vulnerable
    dependencies and the whole tree for committed secrets. HIGH/CRITICAL fail
    the check. Trivy is installed from its release with checksum verification
    rather than through a third-party action.
  - CodeQL (`security-extended`) analyzes Python, TypeScript and the GitHub
    Actions workflows themselves.
  - Results are uploaded as SARIF to GitHub code scanning.
  - Accepted risks live in `.trivyignore.yaml`, each with a written reason
    (mostly CMK and WAF costs that exceed the project's whole budget).
- **Branch protection** (`.github/rulesets/main.json`): changes reach `main`
  only through PRs with all required checks green; no force pushes or deletion.
  Required workflows run on every PR so a check is never left pending.
- **After deploy**: a weekly job records the SSL Labs grade, Mozilla HTTP
  Observatory grade, HSTS preload status, CAA, DMARC and DNSSEC. The site
  shows them with links to the public reports.

## Consequences

- Fixed from the first scan: DynamoDB point-in-time recovery, X-Ray tracing on
  the aggregator.
- DNSSEC and an enforcing DMARC policy are shown as missing until they are set
  up; the posture block reports reality rather than a curated list.
