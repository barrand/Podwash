#!/usr/bin/env python3
"""LLM-authored floor narration (creative prose, no template pools).

Enabled when FORGE_LLM_NARRATION=1 (default). Set FORGE_LLM_NARRATION=0 for
minimal factual fallbacks only. FORGE_LLM_SHIFT_NARRATION is a legacy alias.
"""

from __future__ import annotations

import os
import re
from typing import Any, Callable

from factory_narrator import (
    LogFn,
    _emit,
    narrate_coordinator_shift_llm,
    parse_shift_narration_lines,
)

_FLOOR_LLM_TRUTHY = frozenset({"1", "true", "yes", "on"})


def floor_narration_llm_enabled() -> bool:
    for key in ("FORGE_LLM_NARRATION", "FORGE_LLM_SHIFT_NARRATION"):
        raw = os.environ.get(key, "").strip().lower()
        if raw:
            return raw in _FLOOR_LLM_TRUTHY
    # Default on — creative floor voice when the SDK is available.
    return True


def first_narration_line(text: str) -> str:
    """One console line from model output."""
    raw = (text or "").strip()
    if not raw:
        return ""
    raw = re.sub(r"^['\"]+|['\"]+$", "", raw)
    lines = parse_shift_narration_lines(raw, max_lines=1)
    if lines:
        return lines[0]
    return raw.splitlines()[0].strip()


def invoke_floor_narrator_llm(
    client: Any,
    *,
    role: str,
    prompt: str,
    api_key: str,
    repo_root: str,
    log: LogFn,
    run_worker: Callable[..., tuple[bool, str]],
    max_lines: int = 1,
) -> list[str]:
    assistant_bits: list[str] = []

    def _capture(text: str) -> None:
        assistant_bits.append(text)

    try:
        ok, _status = run_worker(
            client,
            role=role,
            prompt=prompt,
            api_key=api_key,
            repo_root=repo_root,
            log=log,
            on_assistant_text=_capture,
        )
    except Exception as exc:
        log(f"floor narration LLM failed: {exc}")
        return []
    text = "\n".join(assistant_bits).strip()
    lines = parse_shift_narration_lines(text, max_lines=max_lines)
    if ok and lines:
        return lines
    if text:
        log(f"floor narration LLM unusable ({text[:80]!r})")
    return []


def build_coordinator_shift_llm_prompt(
    *,
    coordinator_name: str,
    slice_id: int,
    title: str,
    mission: str,
) -> str:
    goal = (mission or "").strip() or "advance the product"
    return f"""You are {coordinator_name}, the Forge floor coordinator, speaking to the project stakeholder at slice kickoff.

Write exactly 2 short sentences in plain text:
1. Check in by name and identify slice {slice_id}: {title}.
2. State today's goal in your own words: {goal}

Rules: conversational, unique wording each time, no markdown, no emoji, no monkey jokes, no Murphy references, no bullet points, no stock factory clichés."""


def build_verify_green_llm_prompt(
    *,
    name: str,
    role: str,
    passed: str | int,
    total: str | int,
) -> str:
    who = (name or "").strip() or "the crew"
    job = (role or "QA").strip()
    return f"""You are {who}, a Forge {job} on the PodWash factory floor, speaking to the coordinator and stakeholder.

The automated test suite just finished fully green: {passed} of {total} tests passed.

Write exactly ONE sentence. Invent fresh wording every time — do not follow a formula or template. Convey relief and quiet pride that the suite is green. Work the numbers in naturally.

Hard rules: plain text only; no markdown; no emoji; no monkeys; no Murphy; no quotation marks; max 28 words."""


def narrate_verify_green_minimal(
    name: str,
    *,
    passed: str | int,
    total: str | int,
    log: LogFn | None = None,
) -> str:
    """Factual fallback when LLM narration is off or unavailable."""
    who = (name or "").strip() or "Forge"
    line = f"✓ {who} — all green ({passed}/{total})."
    _emit(line, log)
    return line


def narrate_verify_green_dynamic(
    client: Any | None,
    name: str,
    *,
    passed: str | int,
    total: str | int,
    role: str = "QA",
    api_key: str = "",
    repo_root: str = "",
    log: LogFn | None = None,
    run_worker: Callable[..., tuple[bool, str]] | None = None,
) -> str:
    """Creative LLM green-verify line, or minimal fallback."""
    if (
        client is not None
        and api_key
        and repo_root
        and run_worker is not None
        and floor_narration_llm_enabled()
    ):
        prompt = build_verify_green_llm_prompt(
            name=name,
            role=role,
            passed=passed,
            total=total,
        )
        line = invoke_floor_narrator_llm(
            client,
            role=role,
            prompt=prompt,
            api_key=api_key,
            repo_root=repo_root,
            log=log or (lambda _m: None),
            run_worker=run_worker,
            max_lines=1,
        )
        if line:
            _emit(line[0], log)
            return line[0]
    return narrate_verify_green_minimal(
        name, passed=passed, total=total, log=log
    )


def try_coordinator_shift_llm(
    client: Any,
    *,
    coordinator_name: str,
    slice_id: int,
    title: str,
    mission: str,
    api_key: str,
    repo_root: str,
    log: LogFn,
    run_worker: Callable[..., tuple[bool, str]],
) -> bool:
    if not floor_narration_llm_enabled():
        return False
    prompt = build_coordinator_shift_llm_prompt(
        coordinator_name=coordinator_name,
        slice_id=slice_id,
        title=title,
        mission=mission,
    )
    lines = invoke_floor_narrator_llm(
        client,
        role="Coordinator",
        prompt=prompt,
        api_key=api_key,
        repo_root=repo_root,
        log=log,
        run_worker=run_worker,
        max_lines=3,
    )
    if lines:
        narrate_coordinator_shift_llm(lines, log=log)
        return True
    return False
