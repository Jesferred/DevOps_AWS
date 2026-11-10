"""Weekly external security posture checks for the site's public endpoint.

Each check is independent and returns None on failure, so one unavailable
third-party service never hides the others.
"""

from __future__ import annotations

import json
import time
import urllib.parse
import urllib.request

USER_AGENT = "kovalov-in-security-check/1 (+https://kovalov.in/status/)"
GRADE_ORDER = ["A+", "A", "A-", "B", "C", "D", "E", "F", "T", "M"]


def _get(url: str, method: str = "GET", timeout: float = 30, accept: str = "application/json") -> dict:
    req = urllib.request.Request(url, method=method, headers={"User-Agent": USER_AGENT, "Accept": accept})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def ssl_labs(host: str, deadline: float) -> dict | None:
    """Qualys SSL Labs grade. A fresh assessment takes a few minutes per endpoint."""
    base = "https://api.ssllabs.com/api/v3/analyze?" + urllib.parse.urlencode({"host": host, "publish": "off", "all": "done"})
    try:
        data = _get(base + "&startNew=on")
        while data.get("status") not in ("READY", "ERROR") and time.time() < deadline:
            time.sleep(20)
            data = _get(base)
    except Exception as exc:
        print({"level": "WARN", "message": "ssl labs failed", "error": str(exc)})
        return None
    if data.get("status") != "READY":
        return None

    endpoints = [e for e in data.get("endpoints", []) if e.get("grade")]
    if not endpoints:
        return None
    worst = max(endpoints, key=lambda e: GRADE_ORDER.index(e["grade"]) if e["grade"] in GRADE_ORDER else len(GRADE_ORDER))
    protocols = sorted({f'{p["name"]} {p["version"]}' for e in endpoints for p in e.get("details", {}).get("protocols", [])})
    return {
        "grade": worst["grade"],
        "endpoints": len(endpoints),
        "protocols": protocols,
        "report_url": f"https://www.ssllabs.com/ssltest/analyze.html?d={host}&hideResults=on",
    }


def observatory(host: str) -> dict | None:
    """Mozilla HTTP Observatory: HTTP security headers grade."""
    try:
        data = _get("https://observatory-api.mdn.mozilla.net/api/v2/scan?" + urllib.parse.urlencode({"host": host}), method="POST")
    except Exception as exc:
        print({"level": "WARN", "message": "observatory failed", "error": str(exc)})
        return None
    if data.get("error"):
        return None
    return {
        "grade": data.get("grade"),
        "score": data.get("score"),
        "tests_passed": data.get("tests_passed"),
        "tests_total": data.get("tests_quantity"),
        "report_url": data.get("details_url"),
    }


def hsts_preload(host: str) -> str | None:
    try:
        return _get("https://hstspreload.org/api/v2/status?" + urllib.parse.urlencode({"domain": host})).get("status")
    except Exception:
        return None


def _doh(name: str, rtype: str) -> dict | None:
    """DNS over HTTPS (Cloudflare JSON API), validating resolver."""
    try:
        return _get(
            "https://cloudflare-dns.com/dns-query?" + urllib.parse.urlencode({"name": name, "type": rtype, "do": "1"}),
            accept="application/dns-json",
        )
    except Exception:
        return None


def dns_checks(host: str) -> dict:
    a = _doh(host, "A")
    caa = _doh(host, "CAA")
    dmarc = _doh(f"_dmarc.{host}", "TXT")

    dmarc_policy = None
    for answer in (dmarc or {}).get("Answer", []):
        record = answer.get("data", "").strip('"').replace('" "', "")
        if record.startswith("v=DMARC1"):
            tags = dict(t.strip().split("=", 1) for t in record.split(";") if "=" in t)
            dmarc_policy = tags.get("p")

    return {
        "dnssec": None if a is None else bool(a.get("AD")),
        "caa": None if caa is None else bool(caa.get("Answer")),
        "dmarc_policy": dmarc_policy,
    }


def run(host: str, deadline: float) -> dict:
    return {
        "ssl_labs": ssl_labs(host, deadline),
        "observatory": observatory(host),
        "hsts_preload": hsts_preload(host),
        **dns_checks(host),
    }
