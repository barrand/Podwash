#!/usr/bin/env python3
"""Factory v2 — session bundle on halt (no log archaeology).

Writes ``build/test-results/session-slice-NN/`` with stuck card, ledger,
events, VERIFY RESULT lines, xcresult paths, and a README index.
"""

from __future__ import annotations

import json
import os
import shutil
from datetime import datetime, timezone
from typing import Any


def session_bundle_dir(repo_root: str, slice_id: int | None) -> str:
    name = (
        f"session-slice-{slice_id:02d}"
        if slice_id is not None
        else "session-slice"
    )
    return os.path.join(repo_root, "build", "test-results", name)


def write_session_bundle(
    *,
    repo_root: str,
    slice_id: int | None,
    reason: str,
    stuck_card: str = "",
    verify_result: dict[str, Any] | None = None,
    failures: list[str] | None = None,
    crashes: list[str] | None = None,
    phase: str = "HALT",
    extra: dict[str, Any] | None = None,
    bundle_name: str | None = None,
) -> str:
    """Materialize a halt session bundle; returns the directory path.

    ``bundle_name`` (e.g. ``session-task-batch``) overrides the default
    ``session-slice-NN`` path so task-loop batch thrash has a dedicated bundle
    for Medic without colliding with slice sessions.
    """
    if bundle_name:
        dest = os.path.join(repo_root, "build", "test-results", bundle_name)
    else:
        dest = session_bundle_dir(repo_root, slice_id)
    os.makedirs(dest, exist_ok=True)
    tr = os.path.join(repo_root, "build", "test-results")

    meta = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "slice": slice_id,
        "phase": phase,
        "reason": reason,
        "verify_result": verify_result or {},
        "failures": (failures or [])[:20],
        "crashes": (crashes or [])[:10],
        "extra": extra or {},
    }
    with open(os.path.join(dest, "halt.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    if stuck_card.strip():
        with open(os.path.join(dest, "stuck-card.txt"), "w", encoding="utf-8") as fh:
            fh.write(stuck_card.rstrip() + "\n")
    else:
        # Prefer persisted stuck card if present
        for name in (
            f"stuck-slice-{slice_id:02d}.txt" if slice_id is not None else None,
            "stuck-slice.txt",
        ):
            if not name:
                continue
            src = os.path.join(tr, name)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(dest, "stuck-card.txt"))
                break

    # Copy durable factory artifacts when present
    copies: list[tuple[str, str]] = []
    if slice_id is not None:
        copies.extend(
            [
                (f"ledger-slice-{slice_id:02d}.jsonl", "ledger.jsonl"),
                (f"events-slice-{slice_id:02d}.jsonl", "events.jsonl"),
                (f"stuck-slice-{slice_id:02d}.txt", "stuck-card-source.txt"),
                (f"referee-slice-{slice_id:02d}-last.txt", "referee-last.txt"),
            ]
        )
    else:
        copies.extend(
            [
                ("ledger-slice.jsonl", "ledger.jsonl"),
                ("events-slice.jsonl", "events.jsonl"),
                ("referee-last.txt", "referee-last.txt"),
            ]
        )
    for src_name, dest_name in copies:
        src = os.path.join(tr, src_name)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(dest, dest_name))

    # Pointer to latest xcresult (do not copy the whole bundle — just path)
    bundle = (verify_result or {}).get("bundle") or ""
    if not bundle:
        # newest verify-*.xcresult under test-results
        try:
            cands = [
                os.path.join(tr, n)
                for n in os.listdir(tr)
                if n.startswith("verify-") and n.endswith(".xcresult")
            ]
            cands.sort(key=lambda p: os.path.getmtime(p), reverse=True)
            if cands:
                bundle = os.path.relpath(cands[0], repo_root)
        except OSError:
            pass
    with open(os.path.join(dest, "xcresult-path.txt"), "w", encoding="utf-8") as fh:
        fh.write((bundle or "(none)") + "\n")

    # Persist latest verify stdout for post-mortems / classifier replay.
    latest_out = os.path.join(tr, "verify-output-latest.txt")
    if os.path.isfile(latest_out):
        shutil.copy2(latest_out, os.path.join(dest, "verify-output.txt"))
    json_contract = os.path.join(tr, "verify-result.json")
    if os.path.isfile(json_contract):
        shutil.copy2(json_contract, os.path.join(dest, "verify-result.json"))

    lines = [
        f"# Session bundle — slice {slice_id if slice_id is not None else '?'}",
        "",
        f"- phase: `{phase}`",
        f"- reason: {reason}",
        f"- written: {meta['ts']}",
        "",
        "## Contents",
        "",
        "- `halt.json` — structured halt metadata",
        "- `stuck-card.txt` — human stuck card (if available)",
        "- `ledger.jsonl` — hypothesis ledger copy (if available)",
        "- `events.jsonl` — factory event log copy (if available)",
        "- `xcresult-path.txt` — path to latest/relevant `.xcresult`",
        "- `verify-result.json` — machine-readable VERIFY RESULT (if available)",
        "- `verify-output.txt` — raw verify stdout/stderr (if available)",
        "",
    ]
    with open(os.path.join(dest, "README.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    return dest
