#!/usr/bin/env python3
"""Read-only Palette VerteX registry synchronization check."""

from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any


def clean(value: Any) -> str:
    return re.sub(r"[\x00-\x1f]+", " ", str(value or "")).strip()


def emit(level: str, message: str) -> None:
    print(f"{clean(level)}\t{clean(message)}", flush=True)


def parse_time(value: Any) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


class RegistryClient:
    def __init__(self, base_url: str, insecure: bool) -> None:
        self.base_url = base_url.rstrip("/")
        self.headers = {"Accept": "application/json"}
        api_key = os.environ.get("VERTEX_API_KEY", "")
        auth_token = os.environ.get("VERTEX_AUTH_TOKEN", "")
        if api_key:
            self.headers["apiKey"] = api_key
        elif auth_token:
            self.headers["Authorization"] = auth_token
        else:
            raise ValueError("set VERTEX_API_KEY or VERTEX_AUTH_TOKEN")
        self.context = ssl._create_unverified_context() if insecure else None

    def get_items(self, path: str, paginated: bool) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        params: dict[str, str] = {"limit": "50"} if paginated else {}
        seen_tokens: set[str] = set()

        while True:
            query = urllib.parse.urlencode(params)
            url = f"{self.base_url}{path}" + (f"?{query}" if query else "")
            request = urllib.request.Request(url, headers=self.headers, method="GET")
            with urllib.request.urlopen(
                request, timeout=30, context=self.context
            ) as response:
                payload = json.load(response)

            page = payload.get("items", []) if isinstance(payload, dict) else []
            if not isinstance(page, list):
                raise ValueError(f"{path} returned an invalid items field")
            items.extend(page)
            if not paginated:
                return items

            metadata = payload.get("listmeta") or payload.get("listMeta") or {}
            token = str(metadata.get("continue") or "")
            if not token:
                return items
            if token in seen_tokens:
                raise ValueError(f"{path} returned a repeated pagination token")
            seen_tokens.add(token)
            params = {
                "limit": "50",
                "continue": token,
                "offset": str(metadata.get("offset") or len(items)),
            }


def evaluate(
    registry_type: str,
    item: dict[str, Any],
    max_age_hours: int,
    running_warn_hours: int,
) -> tuple[dict[str, Any], str, str]:
    metadata = item.get("metadata") or {}
    spec = item.get("spec") or {}
    sync = (item.get("status") or {}).get("sync") or {}
    name = clean(metadata.get("name") or metadata.get("uid") or "unnamed")
    scope = clean(spec.get("scope") or "unknown").lower()
    status = clean(sync.get("status") or "unknown")
    status_lower = status.lower()
    last_synced = sync.get("lastSyncedTime") or "never"
    last_run = sync.get("lastRunTime") or ""
    provider = clean(spec.get("registryType") or spec.get("providerType"))
    display_type = f"OCI/{provider}" if registry_type == "OCI" and provider else registry_type
    label = f"[{scope} {display_type}] {name}"

    record = {
        "type": display_type,
        "name": name,
        "uid": metadata.get("uid", ""),
        "scope": scope,
        "endpoint": spec.get("endpoint", ""),
        "sync": sync,
    }

    if sync.get("isSyncSupported") is False:
        return record, "INFO", f"{label} — synchronization is disabled or unsupported"

    issues: list[str] = []
    failure_words = ("fail", "error", "abort", "interrupt", "cancel", "timeout", "unhealthy")
    running_words = ("progress", "running", "pending", "syncing", "queued", "started")
    is_running = any(word in status_lower for word in running_words)
    if scope not in {"system", "tenant"}:
        issues.append(f"unexpected scope '{scope}'")
    if any(word in status_lower for word in failure_words):
        issues.append(f"sync status is {status}")

    recovery = sync.get("syncRecovery") or {}
    recovery_state = clean(recovery.get("syncRecoveryState"))
    if recovery_state.lower() in {"interrupted", "recovering"}:
        issues.append(f"recovery state is {recovery_state}")

    now = datetime.now(timezone.utc)
    synced_time = parse_time(last_synced)
    run_time = parse_time(last_run)
    if is_running:
        if run_time and (now - run_time).total_seconds() > running_warn_hours * 3600:
            issues.append(f"sync has run for more than {running_warn_hours} hour(s)")
        elif not issues:
            return record, "INFO", f"{label} — sync currently {status}"
    elif not synced_time:
        issues.append("no successful synchronization time is recorded")
    elif (now - synced_time).total_seconds() > max_age_hours * 3600:
        age = int((now - synced_time).total_seconds() // 3600)
        issues.append(f"last successful sync is {age} hours old (limit: {max_age_hours})")

    messages = " ".join(
        clean(value)
        for value in (sync.get("message"), recovery.get("message"))
        if value
    )
    if messages and any(word in messages.lower() for word in failure_words):
        issues.append(f"API message: {messages}")

    if issues:
        detail = "; ".join(issues)
        return record, "WARN", f"{label} — {detail} (status: {status}; last sync: {last_synced})"
    return record, "PASS", f"{label} — sync healthy (status: {status}; last sync: {last_synced})"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--url", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--max-age-hours", type=int, default=48)
    parser.add_argument("--running-warn-hours", type=int, default=1)
    parser.add_argument("--insecure", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        client = RegistryClient(args.url, args.insecure)
        groups = (
            ("OCI", "/v1/registries/oci/summary", False),
            ("Helm", "/v1/registries/helm/summary", True),
            ("Pack", "/v1/registries/pack/summary", True),
        )
        report: dict[str, Any] = {
            "checkedAt": datetime.now(timezone.utc).isoformat(),
            "apiUrl": args.url.rstrip("/"),
            "registries": [],
        }
        total = 0
        for registry_type, path, paginated in groups:
            items = client.get_items(path, paginated)
            scopes = {"system": 0, "tenant": 0, "other": 0}
            events: list[tuple[str, str]] = []
            for item in items:
                record, level, message = evaluate(
                    registry_type,
                    item,
                    args.max_age_hours,
                    args.running_warn_hours,
                )
                report["registries"].append(record)
                events.append((level, message))
                total += 1
                scope = record["scope"]
                scopes[scope if scope in {"system", "tenant"} else "other"] += 1
            emit(
                "INFO",
                f"{registry_type} registries — system: {scopes['system']}, "
                f"tenant: {scopes['tenant']}, other: {scopes['other']}",
            )
            for level, message in events:
                emit(level, message)

        if total == 0:
            emit("WARN", "The API returned no OCI, Helm, or Pack registries")
        with open(args.report, "w", encoding="utf-8") as output:
            json.dump(report, output, indent=2, sort_keys=True)
            output.write("\n")
        return 0
    except urllib.error.HTTPError as error:
        emit("ERROR", f"HTTP {error.code} from {error.url}; check URL and permissions")
    except urllib.error.URLError as error:
        emit("ERROR", f"Could not reach the VerteX API: {error.reason}")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        emit("ERROR", str(error))
    return 1


if __name__ == "__main__":
    sys.exit(main())
