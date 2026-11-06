# 6. DORA metrics from CI deployment events

Date: 2026-11-06
Status: Accepted

## Decision

Production deploy jobs (`site` deploy, `terraform` apply when something
changed) write an event to the monitoring table: kind, sha, run URL, status,
deploy time and the time of the earliest commit in the push.

The aggregator computes, over 30 days:

| Metric | Definition |
|---|---|
| Deployment frequency | successful deploys per week |
| Lead time for changes | median of deploy time minus earliest commit time |
| Change failure rate | deploys that failed, or were followed by an SLO incident within 1 hour |
| Time to restore | MTTR of SLO incidents |

Each metric gets a level (elite/high/medium/low) using the DORA report thresholds.

## Consequences

- Events come from the pipeline itself, so no GitHub API rate limits or tokens.
- Recording is `continue-on-error`: metrics never block a deploy.
- Lead time starts at the earliest commit in the push to `main`, so for a
  merged PR it covers the whole branch, not just the merge.
