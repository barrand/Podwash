#!/usr/bin/env python3
"""Factory v2 P1 — JSONL event log + phase timeline + SUMMARY contract."""

from __future__ import annotations

import json
import os
import re
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable

from factory_narrator import format_agent_label

LogFn = Callable[[str], None]

SUMMARY_RE = re.compile(r"(?im)^\s*SUMMARY:\s*(.+)$")

PHASE_BANNERS = (
    "IMPLEMENT",
    "TIER2-GATE",
    "FULL-VERIFY",
    "REFEREE",
    "FIX",
    "RECORD",
    "COMMIT",
    "HALT",
)


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class FactoryEvent:
    ts: str
    slice: int | None
    phase: str
    role: str
    event: str
    detail: dict[str, Any] = field(default_factory=dict)
    agent_name: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def event_log_path(
    repo_root: str,
    slice_id: int | None,
    *,
    kind: str = "slice",
) -> str:
    if kind == "task":
        name = (
            f"events-task-{slice_id:03d}.jsonl"
            if slice_id is not None
            else "events-task.jsonl"
        )
    else:
        name = (
            f"events-slice-{slice_id:02d}.jsonl"
            if slice_id is not None
            else "events-slice.jsonl"
        )
    return os.path.join(repo_root, "build", "test-results", name)


def append_event(
    event: FactoryEvent,
    *,
    repo_root: str,
    slice_id: int | None = None,
    kind: str = "slice",
) -> str:
    sid = event.slice if event.slice is not None else slice_id
    path = event_log_path(repo_root, sid, kind=kind)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not event.ts:
        event.ts = _utc_now()
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(event.to_dict(), ensure_ascii=False) + "\n")
    return path


def make_event(
    *,
    slice_id: int | None,
    phase: str,
    role: str,
    event: str,
    detail: dict[str, Any] | None = None,
    agent_name: str = "",
) -> FactoryEvent:
    return FactoryEvent(
        ts=_utc_now(),
        slice=slice_id,
        phase=phase,
        role=role,
        event=event,
        detail=dict(detail or {}),
        agent_name=agent_name,
    )


def parse_summary_line(text: str) -> str | None:
    """Extract the machine-parseable SUMMARY: line from worker output."""
    if not text:
        return None
    m = SUMMARY_RE.search(text)
    if not m:
        return None
    return m.group(1).strip()


def format_phase_banner(
    phase: str,
    *,
    role: str = "",
    agent_name: str = "",
    mission: str = "",
    elapsed_secs: float | None = None,
) -> str:
    """One-line Cursor-like phase banner for the terminal timeline."""
    label = phase.upper().replace("_", "-")
    who = format_agent_label(role, agent_name) if (role or agent_name) else "loop"
    bits = [f"══ {label} ══", who]
    if mission:
        bits.append(mission[:100])
    if elapsed_secs is not None:
        bits.append(f"{elapsed_secs:.0f}s")
    return " · ".join(bits)


def emit_timeline(
    phase: str,
    *,
    role: str = "",
    agent_name: str = "",
    mission: str = "",
    elapsed_secs: float | None = None,
    log: LogFn | None = None,
) -> str:
    line = format_phase_banner(
        phase,
        role=role,
        agent_name=agent_name,
        mission=mission,
        elapsed_secs=elapsed_secs,
    )
    if log:
        log(line)
    else:
        print(line, flush=True)
    return line


class EventLog:
    """Thin helper bound to one slice run."""

    def __init__(
        self,
        repo_root: str,
        slice_id: int | None,
        *,
        log: LogFn | None = None,
        kind: str = "slice",
    ):
        self.repo_root = repo_root
        self.slice_id = slice_id
        self.kind = kind
        self.log = log or (lambda m: None)
        self.path = event_log_path(repo_root, slice_id, kind=kind)

    def record(
        self,
        phase: str,
        role: str,
        event: str,
        *,
        detail: dict[str, Any] | None = None,
        agent_name: str = "",
        timeline: bool = False,
        mission: str = "",
    ) -> FactoryEvent:
        ev = make_event(
            slice_id=self.slice_id,
            phase=phase,
            role=role,
            event=event,
            detail=detail,
            agent_name=agent_name,
        )
        append_event(
            ev,
            repo_root=self.repo_root,
            slice_id=self.slice_id,
            kind=self.kind,
        )
        if timeline:
            emit_timeline(
                phase,
                role=role,
                agent_name=agent_name,
                mission=mission or event,
                log=self.log,
            )
        return ev
