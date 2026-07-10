#!/usr/bin/env python3
"""Hypothesis ledger — reject repeat hypotheses on the same failure signature.

Durable JSONL under ``build/test-results/ledger-slice-NN.jsonl``. Survives
bridge death so a resumed session never re-explores from zero.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_hypothesis(text: str) -> str:
    """Collapse whitespace / case for ledger equality checks."""
    return re.sub(r"\s+", " ", (text or "").strip().lower())


def normalize_signature(text: str) -> str:
    return re.sub(r"\s+", " ", (text or "").strip().lower())


@dataclass
class LedgerEntry:
    ts: str
    slice: int | None
    attempt: int
    role: str
    hypothesis: str
    files_touched: list[str] = field(default_factory=list)
    result_signature: str = ""
    verify_tier: int = 1
    outcome: str = "red"  # red | green | halt
    agent_name: str = ""
    primary_failure: str = ""
    instruction: str = ""

    def matches(self, hypothesis: str, signature: str) -> bool:
        return (
            normalize_hypothesis(self.hypothesis) == normalize_hypothesis(hypothesis)
            and normalize_signature(self.result_signature)
            == normalize_signature(signature)
            and bool(normalize_hypothesis(hypothesis))
            and bool(normalize_signature(signature))
        )


def ledger_path(repo_root: str, slice_id: int | None) -> str:
    name = (
        f"ledger-slice-{slice_id:02d}.jsonl"
        if slice_id is not None
        else "ledger-slice.jsonl"
    )
    return os.path.join(repo_root, "build", "test-results", name)


def load_ledger(repo_root: str, slice_id: int | None) -> list[LedgerEntry]:
    path = ledger_path(repo_root, slice_id)
    if not os.path.isfile(path):
        return []
    entries: list[LedgerEntry] = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(data, dict):
                    continue
                entries.append(_entry_from_dict(data))
    except OSError:
        return []
    return entries


def _entry_from_dict(data: dict[str, Any]) -> LedgerEntry:
    files = data.get("files_touched") or []
    if isinstance(files, str):
        files = [f.strip() for f in files.split(",") if f.strip()]
    return LedgerEntry(
        ts=str(data.get("ts") or ""),
        slice=data.get("slice"),
        attempt=int(data.get("attempt") or 0),
        role=str(data.get("role") or ""),
        hypothesis=str(data.get("hypothesis") or ""),
        files_touched=[str(f) for f in files],
        result_signature=str(data.get("result_signature") or ""),
        verify_tier=int(data.get("verify_tier") or 1),
        outcome=str(data.get("outcome") or "red"),
        agent_name=str(data.get("agent_name") or ""),
        primary_failure=str(data.get("primary_failure") or ""),
        instruction=str(data.get("instruction") or ""),
    )


def append_ledger(
    entry: LedgerEntry,
    *,
    repo_root: str,
    slice_id: int | None = None,
) -> str:
    """Append one JSONL line. Returns path written."""
    sid = entry.slice if entry.slice is not None else slice_id
    path = ledger_path(repo_root, sid)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    payload = asdict(entry)
    if not entry.ts:
        payload["ts"] = _utc_now()
        entry.ts = payload["ts"]
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, ensure_ascii=False) + "\n")
    return path


def hypothesis_seen(
    entries: list[LedgerEntry],
    hypothesis: str,
    signature: str,
) -> bool:
    """True when the same hypothesis was already tried on this signature."""
    for e in entries:
        if e.matches(hypothesis, signature):
            return True
    return False


def format_ledger_for_prompt(entries: list[LedgerEntry], *, limit: int = 12) -> str:
    """Human-readable ledger block for fix / referee prompts."""
    if not entries:
        return "(empty — no prior fix hypotheses)"
    lines: list[str] = []
    for e in entries[-limit:]:
        hyp = (e.hypothesis or "(none)")[:120]
        lines.append(
            f"- attempt={e.attempt} role={e.role} outcome={e.outcome} "
            f"tier={e.verify_tier} hyp={hyp}"
        )
    return "\n".join(lines)


def make_entry(
    *,
    slice_id: int | None,
    attempt: int,
    role: str,
    hypothesis: str,
    signature: str,
    files_touched: list[str] | None = None,
    verify_tier: int = 1,
    outcome: str = "red",
    agent_name: str = "",
    primary_failure: str = "",
    instruction: str = "",
) -> LedgerEntry:
    return LedgerEntry(
        ts=_utc_now(),
        slice=slice_id,
        attempt=attempt,
        role=role,
        hypothesis=hypothesis,
        files_touched=list(files_touched or []),
        result_signature=signature,
        verify_tier=verify_tier,
        outcome=outcome,
        agent_name=agent_name,
        primary_failure=primary_failure,
        instruction=instruction,
    )
