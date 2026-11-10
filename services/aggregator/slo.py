"""SLO math: pure functions, no AWS calls, covered by tests/test_slo.py.

Definitions used across the project:
- A *minute* is evaluated when at least 2 regions reported a probe in it.
- An evaluated minute is *bad* when a strict majority of reporting regions failed,
  so one flaky probe location cannot burn the error budget on its own.
- Availability = 1 - bad / evaluated minutes.
- Burn rate = observed error ratio / allowed error ratio (1 - SLO).
  A burn rate of 1 spends exactly the whole budget over the SLO window.
"""

from __future__ import annotations

import math
from bisect import bisect_left
from dataclasses import dataclass
from typing import Iterable, Sequence

# Upper bounds (inclusive) of latency histogram buckets, ms. A final overflow
# bucket catches everything above the last bound.
BUCKETS_MS: tuple[int, ...] = (
    25, 50, 75, 100, 125, 150, 200, 250, 300, 400, 500, 750, 1000, 1500, 2000, 3000, 5000, 10000,
)


@dataclass(frozen=True)
class Probe:
    ts: int  # unix seconds
    region: str
    ok: bool
    total_ms: float | None = None


@dataclass(frozen=True)
class Incident:
    start: int  # first bad minute, unix seconds
    end: int | None  # first minute of sustained recovery; None while ongoing

    def duration_s(self, now: int) -> int:
        return (self.end if self.end is not None else now) - self.start


def minute_of(ts: int) -> int:
    return ts - ts % 60


def minute_status(probes: Iterable[Probe]) -> dict[int, bool]:
    """Map evaluated minute -> True if the minute is bad."""
    by_minute: dict[int, dict[str, bool]] = {}
    for p in probes:
        by_minute.setdefault(minute_of(p.ts), {})[p.region] = p.ok

    status: dict[int, bool] = {}
    for minute, regions in by_minute.items():
        if len(regions) < 2:
            continue
        failures = sum(1 for ok in regions.values() if not ok)
        status[minute] = failures * 2 > len(regions)
    return status


def count_minutes(status: dict[int, bool], start: int, end: int) -> tuple[int, int]:
    """(evaluated, bad) minutes in [start, end)."""
    evaluated = bad = 0
    for minute, is_bad in status.items():
        if start <= minute < end:
            evaluated += 1
            bad += is_bad
    return evaluated, bad


def availability(evaluated: int, bad: int) -> float | None:
    return None if evaluated == 0 else 1 - bad / evaluated


def burn_rate(evaluated: int, bad: int, slo: float) -> float | None:
    if evaluated == 0:
        return None
    return (bad / evaluated) / (1 - slo)


def histogram(values: Iterable[float]) -> list[int]:
    counts = [0] * (len(BUCKETS_MS) + 1)
    for v in values:
        counts[bisect_left(BUCKETS_MS, v)] += 1
    return counts


def merge_histograms(hists: Iterable[Sequence[int]]) -> list[int]:
    merged = [0] * (len(BUCKETS_MS) + 1)
    for h in hists:
        for i, c in enumerate(h):
            merged[i] += int(c)
    return merged


def percentile_from_histogram(counts: Sequence[int], q: float) -> float | None:
    """Estimate a quantile with linear interpolation inside the bucket, like
    Prometheus histogram_quantile. The overflow bucket returns its lower bound."""
    total = sum(counts)
    if total == 0:
        return None
    rank = q * total
    cumulative = 0
    for i, c in enumerate(counts):
        if c and cumulative + c >= rank:
            lower = BUCKETS_MS[i - 1] if i > 0 else 0
            if i >= len(BUCKETS_MS):
                return float(lower)
            upper = BUCKETS_MS[i]
            return lower + (upper - lower) * (rank - cumulative) / c
        cumulative += c
    return float(BUCKETS_MS[-1])


def percentile(values: Sequence[float], q: float) -> float | None:
    """Exact nearest-rank quantile."""
    if not values:
        return None
    ordered = sorted(values)
    idx = max(0, math.ceil(q * len(ordered)) - 1)
    return float(ordered[idx])


def find_incidents(status: dict[int, bool], recovery_minutes: int = 2) -> list[Incident]:
    """Group bad minutes into incidents. An incident ends at the first of
    `recovery_minutes` consecutive good minutes; unevaluated minutes neither
    extend nor end it."""
    incidents: list[Incident] = []
    start: int | None = None
    good_run_start: int | None = None
    good_run = 0

    for minute in sorted(status):
        if status[minute]:
            if start is None:
                start = minute
            good_run, good_run_start = 0, None
        elif start is not None:
            if good_run == 0:
                good_run_start = minute
            good_run += 1
            if good_run >= recovery_minutes:
                incidents.append(Incident(start, good_run_start))
                start, good_run, good_run_start = None, 0, None

    if start is not None:
        incidents.append(Incident(start, None))
    return incidents


def mtbf_hours(incidents: Sequence[Incident], window_s: int, now: int) -> float | None:
    """Mean time between failures: uptime in the window divided by incident count."""
    if not incidents:
        return None
    downtime = sum(i.duration_s(now) for i in incidents)
    return (window_s - downtime) / len(incidents) / 3600


def mttr_minutes(incidents: Sequence[Incident]) -> float | None:
    """Mean time to recovery over resolved incidents."""
    resolved = [i for i in incidents if i.end is not None]
    if not resolved:
        return None
    return sum(i.end - i.start for i in resolved) / len(resolved) / 60


def hourly(probes: Sequence[Probe], now: int, hours: int = 24) -> list[dict]:
    """Per-hour series for the last `hours` whole hours plus the current one.

    Each bucket: start (unix s), p50/p95 of successful probe latency, and
    availability over the evaluated minutes in that hour (None without data),
    so short-window charts work from the first hour instead of the first day.
    """
    current = now - now % 3600
    starts = [current - (hours - 1 - i) * 3600 for i in range(hours)]
    status = minute_status(probes)
    out = []
    for start in starts:
        end = start + 3600
        lat = [p.total_ms for p in probes if start <= p.ts < end and p.ok and p.total_ms is not None]
        evaluated, bad = count_minutes(status, start, end)
        out.append({
            "start": start,
            "p50_ms": percentile(lat, 0.5),
            "p95_ms": percentile(lat, 0.95),
            "availability": availability(evaluated, bad),
        })
    return out
