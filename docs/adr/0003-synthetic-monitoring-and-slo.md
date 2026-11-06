# 3. Synthetic monitoring and SLOs on serverless primitives

Date: 2026-11-06
Status: Accepted

## Context

The site needs a public, verifiable availability SLO with error budget, burn-rate
alerts, latency percentiles and incident stats (MTTR, MTBF), at near-zero cost.
A static site has no server logs to derive an SLI from.

Options considered:

| Option | Monthly cost | Notes |
|---|---|---|
| CloudWatch Synthetics canaries, 3 regions x 1/min | ~$47 | $0.0012 per run |
| Prometheus + blackbox_exporter on EC2 | ~$7-8 | t4g.nano + EBS + public IPv4; single probe location |
| Route 53 health checks | ~$1.50 | no latency phases, no custom SLO math |
| **Lambda probes + DynamoDB + aggregator** | **< $1** | full control of SLI definition |

## Decision

- Probe Lambdas in eu-central-1, us-east-1 and ap-southeast-1, triggered every
  minute by EventBridge Scheduler, measure DNS, TCP, TLS, TTFB and total time
  and store one item per probe in DynamoDB (TTL 35 days).
- A minute is evaluated with >= 2 reporting regions and is bad when a strict
  majority of them failed.
- SLO: 99.9% of evaluated minutes over a rolling 30 days (43.2 min budget).
- An aggregator Lambda (every 5 min) finalizes per-day rollups (minute counts and
  latency histograms), computes availability, budget, burn rates, percentiles and
  incidents, and publishes `live/status.json` to the site bucket.
- Alerting follows the multi-window, multi-burn-rate pattern (SRE Workbook):
  fast burn 14.4x over 1h and 5m, slow burn 6x over 6h and 30m. The aggregator
  publishes 0/1 flags to CloudWatch, and alarms notify the shared SNS topic.
  A watchdog alarm fires when probe results stop arriving.
- Probes stay disabled (`probes_enabled = false`) until the site serves traffic,
  so pre-launch downtime does not consume the budget.

## Consequences

- SLO math is plain Python with unit tests, independent of AWS.
- 30-day percentiles are approximations from histograms; 24-hour ones are exact.
- The SLI measures availability as seen from 3 cloud regions, not real users.
  Real-user metrics (Core Web Vitals) are a possible later addition.
