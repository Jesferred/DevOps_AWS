"""Synthetic HTTPS probe, deployed to several regions and run every minute.

Measures each phase of a request separately (DNS, TCP connect, TLS handshake,
time to first byte, total) using raw sockets, verifies the certificate chain,
and stores one item per probe in DynamoDB.
"""

from __future__ import annotations

import os
import socket
import ssl
import time
from datetime import datetime, timezone
from decimal import Decimal
from urllib.parse import urlsplit

import boto3

TARGET_URL = os.environ["TARGET_URL"]
TIMEOUT_S = float(os.environ.get("TIMEOUT_S", "8"))
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "35"))
REGION = os.environ["AWS_REGION"]

table = boto3.resource("dynamodb", region_name=os.environ["TABLE_REGION"]).Table(os.environ["TABLE_NAME"])


def probe(url: str, timeout: float) -> dict:
    parts = urlsplit(url)
    host, path = parts.hostname, parts.path or "/"
    timings: dict[str, float] = {}
    t0 = time.perf_counter()

    def mark(name: str) -> None:
        timings[name] = round((time.perf_counter() - t0) * 1000, 1)

    # IPv4 only: Lambda outside a VPC has no IPv6 egress.
    family, socktype, proto, _, addr = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)[0]
    mark("dns_ms")

    with socket.socket(family, socktype, proto) as raw:
        raw.settimeout(timeout)
        raw.connect(addr)
        mark("connect_ms")

        with ssl.create_default_context().wrap_socket(raw, server_hostname=host) as tls:
            mark("tls_ms")
            cert_expires = ssl.cert_time_to_seconds(tls.getpeercert()["notAfter"])

            request = (
                f"GET {path} HTTP/1.1\r\nHost: {host}\r\n"
                f"User-Agent: kovalov-in-prober/1 ({REGION})\r\n"
                "Accept-Encoding: identity\r\nConnection: close\r\n\r\n"
            )
            tls.sendall(request.encode())
            chunks = [tls.recv(1)]
            mark("ttfb_ms")
            while chunk := tls.recv(65536):
                chunks.append(chunk)
            mark("total_ms")

    status_line = b"".join(chunks).split(b"\r\n", 1)[0]
    status = int(status_line.split(b" ", 2)[1])
    return {
        "status": status,
        "ok": status == 200,
        "cert_days_left": int((cert_expires - time.time()) // 86400),
        **timings,
    }


def handler(event, context):
    now = int(time.time())
    started = datetime.fromtimestamp(now, timezone.utc)

    try:
        result = probe(TARGET_URL, TIMEOUT_S)
    except Exception as exc:  # any failure (DNS, TCP, TLS, timeout) is a failed probe
        result = {"ok": False, "error": f"{type(exc).__name__}: {exc}"[:300]}

    item = {
        "pk": f"probe#{started:%Y-%m-%d}",
        "sk": f"{started:%Y-%m-%dT%H:%M:%SZ}#{REGION}",
        "ts": now,
        "region": REGION,
        "expires_at": now + RETENTION_DAYS * 86400,
        **{k: Decimal(str(v)) if isinstance(v, float) else v for k, v in result.items()},
    }
    table.put_item(Item=item)

    if not result["ok"]:
        print({"level": "WARN", "message": "probe failed", **result})
    return result
