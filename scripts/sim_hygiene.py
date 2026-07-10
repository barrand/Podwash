#!/usr/bin/env python3
"""Factory v2 P1 — simulator hygiene helpers (pre-boot, crash watch, stress-run)."""

from __future__ import annotations

import os
import subprocess
import time
from dataclasses import dataclass, field
from typing import Callable

LogFn = Callable[[str], None]

DEFAULT_STRESS_RUNS = 5


@dataclass
class CrashWatchdog:
    """Track new .ips files under a directory (or list of dirs)."""

    roots: list[str] = field(default_factory=list)
    _seen: set[str] = field(default_factory=set)

    def snapshot(self) -> set[str]:
        found: set[str] = set()
        for root in self.roots:
            if not root or not os.path.isdir(root):
                continue
            for dirpath, _dirs, files in os.walk(root):
                for name in files:
                    if name.endswith(".ips"):
                        found.add(os.path.join(dirpath, name))
        return found

    def arm(self) -> None:
        self._seen = self.snapshot()

    def new_crashes(self) -> list[str]:
        now = self.snapshot()
        fresh = sorted(now - self._seen)
        self._seen = now
        return fresh


def default_ips_roots() -> list[str]:
    """Common places sim/app crash reports land during local verify."""
    home = os.path.expanduser("~")
    return [
        os.path.join("build", "test-results"),
        os.path.join(
            home,
            "Library",
            "Logs",
            "DiagnosticReports",
        ),
        os.path.join(
            home,
            "Library",
            "Developer",
            "CoreSimulator",
            "Devices",
        ),
    ]


def resolve_sim_udid(
    *,
    env: dict[str, str] | None = None,
    log: LogFn | None = None,
) -> str | None:
    """Return PODWASH_SIM_UDID if set, else first available iPhone UDID."""
    _log = log or (lambda m: None)
    e = env if env is not None else os.environ
    pinned = (e.get("PODWASH_SIM_UDID") or "").strip()
    if pinned:
        return pinned
    try:
        proc = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "-j"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        _log(f"simctl list failed: {exc}")
        return None
    if proc.returncode != 0:
        return None
    try:
        import json

        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        return None
    devices = data.get("devices") or {}
    for _runtime, rows in devices.items():
        for row in rows or []:
            name = str(row.get("name") or "")
            if not name.startswith("iPhone"):
                continue
            if row.get("isAvailable") is False:
                continue
            udid = str(row.get("udid") or "").strip()
            if udid:
                return udid
    return None


def ensure_sim_booted(
    udid: str,
    *,
    log: LogFn | None = None,
    timeout_secs: float = 120.0,
) -> bool:
    """Boot simulator if needed; wait via bootstatus. Returns True on ready."""
    _log = log or (lambda m: None)
    if not udid:
        return False
    try:
        subprocess.run(
            ["xcrun", "simctl", "boot", udid],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired):
        pass  # already booted → non-zero; fine
    try:
        proc = subprocess.run(
            ["xcrun", "simctl", "bootstatus", udid, "-b"],
            capture_output=True,
            text=True,
            timeout=timeout_secs,
        )
        ok = proc.returncode == 0
        if ok:
            _log(f"simulator ready: {udid}")
        else:
            _log(f"simulator bootstatus failed: {udid} rc={proc.returncode}")
        return ok
    except (OSError, subprocess.TimeoutExpired) as exc:
        _log(f"simulator boot wait failed: {exc}")
        return False


def is_uitest_id(test_id: str) -> bool:
    return "uitest" in (test_id or "").lower()


def should_stress_run(
    test_ids: list[str],
    *,
    just_fixed: bool,
) -> bool:
    """UITest that just flipped green gets consecutive stress runs."""
    if not just_fixed:
        return False
    return any(is_uitest_id(t) for t in test_ids)


def stress_run_count(
    test_ids: list[str],
    *,
    just_fixed: bool,
    default: int = DEFAULT_STRESS_RUNS,
) -> int:
    return default if should_stress_run(test_ids, just_fixed=just_fixed) else 1


def classify_infra_failure(
    *,
    output: str = "",
    exit_code: str | int | None = None,
    files_changed: bool = False,
) -> bool:
    """True when red looks like infra (bridge/DNS/sim) and no code changed.

    Attempt should not be burned when this returns True (exit 6 path).
    """
    if files_changed:
        return False
    blob = (output or "").lower()
    markers = (
        "failed to launch bridge",
        "connection reset",
        "could not connect",
        "dns",
        "timed out waiting for lock",
        "simulator was lost",
        "coresimulator",
        "unable to boot",
        "xcodebuild: error: unable to find a destination",
        "the device is not configured",
    )
    if any(m in blob for m in markers):
        return True
    # Soft signal: no test ids in output and non-zero exit with empty failures
    if exit_code not in (None, "0", 0) and "test case" not in blob and "xctassert" not in blob:
        if "verify.sh: another verify" in blob or "lock" in blob:
            return True
    return False


def wait_brief(secs: float = 0.0) -> None:
    if secs > 0:
        time.sleep(secs)
