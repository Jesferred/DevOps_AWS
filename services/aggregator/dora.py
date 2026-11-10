"""DORA metrics from deployment events recorded by CI. Pure functions, see tests/test_dora.py.

Performance levels follow the thresholds of the DORA State of DevOps report.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from slo import Incident, percentile

HOUR = 3600
DAY = 24 * HOUR
WEEK = 7 * DAY
MONTH = 30 * DAY

# A successful deploy followed by an SLO incident within this window counts as a failed change.
FAILURE_ATTRIBUTION_S = HOUR


@dataclass(frozen=True)
class Deployment:
    deployed_at: int  # unix seconds
    commit_at: int  # earliest commit in the deployed change
    ok: bool
    kind: str  # "site" | "infra"


def caused_incident(d: Deployment, incidents: Sequence[Incident]) -> bool:
    return any(d.deployed_at <= i.start <= d.deployed_at + FAILURE_ATTRIBUTION_S for i in incidents)


def frequency_level(per_day: float) -> str:
    if per_day >= 1:
        return "elite"
    if per_day >= 1 / 7:
        return "high"
    if per_day >= 1 / 30:
        return "medium"
    return "low"


def lead_time_level(seconds: float) -> str:
    if seconds < DAY:
        return "elite"
    if seconds < WEEK:
        return "high"
    if seconds < MONTH:
        return "medium"
    return "low"


def failure_rate_level(rate: float) -> str:
    if rate <= 0.05:
        return "elite"
    if rate <= 0.10:
        return "high"
    if rate <= 0.15:
        return "medium"
    return "low"


def restore_level(seconds: float) -> str:
    if seconds < HOUR:
        return "elite"
    if seconds < DAY:
        return "high"
    if seconds < WEEK:
        return "medium"
    return "low"


def dora(deployments: Sequence[Deployment], incidents: Sequence[Incident], mttr_s: float | None, window_s: int) -> dict:
    succeeded = [d for d in deployments if d.ok]
    failed = [d for d in deployments if not d.ok or caused_incident(d, incidents)]

    per_day = len(succeeded) / (window_s / DAY)
    lead = percentile([d.deployed_at - d.commit_at for d in succeeded], 0.5)
    cfr = len(failed) / len(deployments) if deployments else None

    return {
        "deployments": len(succeeded),
        "deploys_per_week": round(per_day * 7, 2),
        "deploy_frequency_level": frequency_level(per_day) if deployments else None,
        "lead_time_h": None if lead is None else round(lead / HOUR, 2),
        "lead_time_level": None if lead is None else lead_time_level(lead),
        "change_failure_rate": None if cfr is None else round(cfr, 4),
        "change_failure_rate_level": None if cfr is None else failure_rate_level(cfr),
        "time_to_restore_min": None if mttr_s is None else round(mttr_s / 60, 1),
        "time_to_restore_level": None if mttr_s is None else restore_level(mttr_s),
    }
