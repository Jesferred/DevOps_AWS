"""Turns raw probes into SLO data for the site and alerting.

Two modes, each on its own schedule:
- "status" (every 5 min): availability, error budget, burn rates, latency,
  incidents -> live/status.json in the site bucket + CloudWatch alert metrics.
- "cost" (weekly): month-to-date cost and forecast from Cost Explorer.
  Cost Explorer API calls cost $0.01 each, so they never run per request.

DynamoDB layout (single table):
  pk=probe#YYYY-MM-DD  sk=<iso>#<region>  raw probes, TTL 35 days
  pk=daily             sk=YYYY-MM-DD      finalized per-day rollup
  pk=incident          sk=<iso start>     incident start/end
  pk=cost              sk=latest          last Cost Explorer snapshot
"""

from __future__ import annotations

import json
import os
import time
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

import slo

SLO_TARGET = float(os.environ.get("SLO_TARGET", "0.999"))
WINDOW_DAYS = 30
SITE_BUCKET = os.environ["SITE_BUCKET"]
STATUS_KEY = "live/status.json"
METRIC_NAMESPACE = "KovalovIn/SLO"

# Multi-window, multi-burn-rate alerting (Google SRE Workbook, ch. 5).
FAST_BURN = {"long": 3600, "short": 300, "threshold": 14.4}  # 2% of budget in 1h
SLOW_BURN = {"long": 6 * 3600, "short": 1800, "threshold": 6.0}  # 5% of budget in 6h

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
s3 = boto3.client("s3")
cloudwatch = boto3.client("cloudwatch")
ce = boto3.client("ce", region_name="us-east-1")


# --- helpers ---------------------------------------------------------------

def _iso(ts: int | None) -> str | None:
    return None if ts is None else datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _round(v: float | None, digits: int = 2) -> float | None:
    return None if v is None else round(v, digits)


def _plain(v):
    """DynamoDB Decimals -> int/float, recursively."""
    if isinstance(v, Decimal):
        return int(v) if v == v.to_integral_value() else float(v)
    if isinstance(v, list):
        return [_plain(x) for x in v]
    if isinstance(v, dict):
        return {k: _plain(x) for k, x in v.items()}
    return v


def _query(pk: str, sk_from: str | None = None, sk_to: str | None = None) -> list[dict]:
    cond = Key("pk").eq(pk)
    if sk_from and sk_to:
        cond &= Key("sk").between(sk_from, sk_to)
    elif sk_from:
        cond &= Key("sk").gte(sk_from)
    items, kwargs = [], {"KeyConditionExpression": cond}
    while True:
        page = table.query(**kwargs)
        items.extend(_plain(i) for i in page["Items"])
        if "LastEvaluatedKey" not in page:
            return items
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def _load_probes(day: date) -> list[dict]:
    return _query(f"probe#{day.isoformat()}")


def _to_probes(items: list[dict]) -> list[slo.Probe]:
    return [slo.Probe(i["ts"], i["region"], bool(i["ok"]), i.get("total_ms")) for i in items]


def _ok_latencies(items: list[dict]) -> list[float]:
    return [i["total_ms"] for i in items if i["ok"] and i.get("total_ms") is not None]


# --- daily rollups ---------------------------------------------------------

def _rollup(day: date, items: list[dict]) -> dict:
    evaluated, bad = slo.count_minutes(slo.minute_status(_to_probes(items)), 0, 2**62)
    return {"date": day.isoformat(), "evaluated": evaluated, "bad": bad, "hist": slo.histogram(_ok_latencies(items))}


def _finalize_rollups(today: date, cached: dict[date, list[dict]]) -> None:
    """Store rollups for the last 3 complete days if missing (self-heals after downtime)."""
    for back in range(1, 4):
        day = today - timedelta(days=back)
        if table.get_item(Key={"pk": "daily", "sk": day.isoformat()}).get("Item"):
            continue
        items = cached.get(day) or _load_probes(day)
        if items:
            table.put_item(Item={"pk": "daily", "sk": day.isoformat(), **_rollup(day, items)})


# --- incidents -------------------------------------------------------------

def _sync_incidents(status: dict[int, bool]) -> None:
    if not status:
        return
    first_minute = min(status)
    for inc in slo.find_incidents(status):
        if inc.start == first_minute:
            continue  # may have started before the loaded data; recorded by an earlier run
        item = {"pk": "incident", "sk": _iso(inc.start), "start": inc.start}
        if inc.end is not None:
            item["end"] = inc.end
        table.put_item(Item=item)


def _load_incidents(since: int) -> list[slo.Incident]:
    return [slo.Incident(i["start"], i.get("end")) for i in _query("incident", _iso(since))]


# --- status ----------------------------------------------------------------

def build_status(now: int) -> tuple[dict, dict]:
    today = datetime.fromtimestamp(now, timezone.utc).date()
    yesterday = today - timedelta(days=1)
    raw = {yesterday: _load_probes(yesterday), today: _load_probes(today)}
    _finalize_rollups(today, raw)

    items = raw[yesterday] + raw[today]
    status = slo.minute_status(_to_probes(items))
    _sync_incidents(status)

    # 30d/7d = stored daily rollups + today's live data
    rollups = _query("daily", (today - timedelta(days=WINDOW_DAYS - 1)).isoformat(), yesterday.isoformat())
    today_rollup = _rollup(today, raw[today])
    days = rollups + [today_rollup]

    def window(n_days: int) -> tuple[int, int]:
        cutoff = (today - timedelta(days=n_days - 1)).isoformat()
        sel = [d for d in days if d["date"] >= cutoff]
        return sum(d["evaluated"] for d in sel), sum(d["bad"] for d in sel)

    ev30, bad30 = window(30)
    ev7, bad7 = window(7)
    ev24, bad24 = slo.count_minutes(status, now - 86400, now)

    budget_total = (1 - SLO_TARGET) * WINDOW_DAYS * 1440
    burn = {
        label: _round(slo.burn_rate(*slo.count_minutes(status, now - secs, now), SLO_TARGET))
        for label, secs in {"5m": 300, "30m": 1800, "1h": 3600, "6h": 6 * 3600}.items()
    }

    def burning(rule: dict) -> bool:
        rates = [slo.burn_rate(*slo.count_minutes(status, now - rule[w], now), SLO_TARGET) for w in ("long", "short")]
        return all(r is not None and r > rule["threshold"] for r in rates)

    alerts = {"fast_burn": burning(FAST_BURN), "slow_burn": burning(SLOW_BURN)}

    last_24h = [i for i in items if i["ts"] >= now - 86400]
    lat_24h = _ok_latencies(last_24h)
    hist_30d = slo.merge_histograms(d["hist"] for d in days)

    regions = []
    for region in sorted({i["region"] for i in last_24h}):
        mine = sorted((i for i in last_24h if i["region"] == region), key=lambda i: i["ts"])
        last = mine[-1]
        regions.append({
            "region": region,
            "last_ok": bool(last["ok"]),
            "last_ms": _round(last.get("total_ms"), 0),
            "last_at": _iso(last["ts"]),
            "p95_24h_ms": _round(slo.percentile(_ok_latencies(mine), 0.95), 0),
            "availability_24h": _round(sum(1 for i in mine if i["ok"]) / len(mine), 5),
        })

    phases = {
        p: _round(slo.percentile([i[f"{p}_ms"] for i in last_24h if i["ok"] and f"{p}_ms" in i], 0.5), 1)
        for p in ("dns", "connect", "tls", "ttfb")
    }
    cert_days = [i["cert_days_left"] for i in last_24h if "cert_days_left" in i]

    incidents_90d = _load_incidents(now - 90 * 86400)
    incidents_30d = [i for i in incidents_90d if i.start >= now - WINDOW_DAYS * 86400]
    recent = sorted(incidents_90d, key=lambda i: i.start, reverse=True)[:5]

    cost = table.get_item(Key={"pk": "cost", "sk": "latest"}).get("Item")

    doc = {
        "schema": 1,
        "generated_at": _iso(now),
        "slo": {"target": SLO_TARGET, "window_days": WINDOW_DAYS},
        "availability": {
            "30d": _round(slo.availability(ev30, bad30), 6),
            "7d": _round(slo.availability(ev7, bad7), 6),
            "24h": _round(slo.availability(ev24, bad24), 6),
        },
        "coverage_30d": _round(ev30 / (WINDOW_DAYS * 1440), 4),
        "error_budget": {
            "total_min": _round(budget_total, 1),
            "consumed_min": bad30,
            "remaining_min": _round(budget_total - bad30, 1),
            "remaining_ratio": _round(1 - bad30 / budget_total, 4),
        },
        "burn_rate": burn,
        "alerts": alerts,
        "latency_ms": {
            "24h": {f"p{int(q * 100)}": _round(slo.percentile(lat_24h, q), 0) for q in (0.5, 0.95, 0.99)},
            "30d": {f"p{int(q * 100)}": _round(slo.percentile_from_histogram(hist_30d, q), 0) for q in (0.5, 0.95, 0.99)},
        },
        "phases_ms_24h": phases,
        "tls_cert_days_left": min(cert_days) if cert_days else None,
        "regions": regions,
        "incidents": {
            "count_30d": len(incidents_30d),
            "mttr_min": _round(slo.mttr_minutes(incidents_90d), 1),
            "mtbf_h": _round(slo.mtbf_hours(incidents_30d, WINDOW_DAYS * 86400, now), 1),
            "recent": [
                {"start": _iso(i.start), "end": _iso(i.end), "duration_min": _round(i.duration_s(now) / 60, 1)}
                for i in recent
            ],
        },
        "daily": [
            {
                "date": d["date"],
                "availability": _round(slo.availability(d["evaluated"], d["bad"]), 6),
                "bad_min": d["bad"],
                "p95_ms": _round(slo.percentile_from_histogram(d["hist"], 0.95), 0),
            }
            for d in days
        ],
        "cost": _plain({k: v for k, v in cost.items() if k not in ("pk", "sk")}) if cost else None,
        "probes_5m": sum(1 for i in items if i["ts"] >= now - 300),
    }
    return doc, alerts


def update_status() -> dict:
    now = int(time.time())
    doc, alerts = build_status(now)

    s3.put_object(
        Bucket=SITE_BUCKET,
        Key=STATUS_KEY,
        Body=json.dumps(doc, separators=(",", ":")).encode(),
        ContentType="application/json",
        CacheControl="public, max-age=60",
    )
    cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {"MetricName": "FastBurn", "Value": float(alerts["fast_burn"]), "Unit": "Count"},
            {"MetricName": "SlowBurn", "Value": float(alerts["slow_burn"]), "Unit": "Count"},
            {"MetricName": "ProbeCount5m", "Value": float(doc["probes_5m"]), "Unit": "Count"},
        ],
    )
    return {"availability_30d": doc["availability"]["30d"], **alerts}


# --- cost ------------------------------------------------------------------

def update_cost() -> dict:
    today = datetime.now(timezone.utc).date()
    month_start = today.replace(day=1)
    next_month = (month_start + timedelta(days=32)).replace(day=1)
    usage_only = {"Dimensions": {"Key": "RECORD_TYPE", "Values": ["Usage"]}}  # before credits

    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": month_start.isoformat(), "End": (today + timedelta(days=1)).isoformat()},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        Filter=usage_only,
    )
    groups = [g for r in resp["ResultsByTime"] for g in r["Groups"]]
    by_service = sorted(
        ({"service": g["Keys"][0], "amount": round(float(g["Metrics"]["UnblendedCost"]["Amount"]), 4)} for g in groups),
        key=lambda s: s["amount"],
        reverse=True,
    )
    mtd = round(sum(s["amount"] for s in by_service), 4)

    forecast = None
    if today + timedelta(days=1) < next_month:
        try:
            f = ce.get_cost_forecast(
                TimePeriod={"Start": (today + timedelta(days=1)).isoformat(), "End": next_month.isoformat()},
                Metric="UNBLENDED_COST",
                Granularity="MONTHLY",
                Filter=usage_only,
            )
            forecast = round(mtd + float(f["Total"]["Amount"]), 2)
        except ce.exceptions.DataUnavailableException:
            pass  # new accounts lack enough history for a forecast

    item = {
        "pk": "cost",
        "sk": "latest",
        "currency": "USD",
        "month": month_start.strftime("%Y-%m"),
        "month_to_date": Decimal(str(mtd)),
        "forecast_month": None if forecast is None else Decimal(str(forecast)),
        "by_service": [{"service": s["service"], "amount": Decimal(str(s["amount"]))} for s in by_service[:8]],
        "updated_at": _iso(int(time.time())),
    }
    table.put_item(Item=item)
    return {"month_to_date": mtd, "forecast": forecast}


def handler(event, context):
    return update_cost() if (event or {}).get("mode") == "cost" else update_status()
