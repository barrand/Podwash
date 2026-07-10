#!/usr/bin/env python3
"""LLM fix referee — strict JSON verdict; Python enforces budgets / ledger / scope.

Replaces classify_failure + fix_playbooks as the *router*. FailurePacket and stuck
cards remain evidence formats the referee consumes.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any

from failure_packet import FailurePacket
from hypothesis_ledger import LedgerEntry, format_ledger_for_prompt

VALID_ROLES = frozenset({"Engineer", "QA"})
VALID_SCOPES = frozenset({"app", "tests"})
VALID_CONFIDENCE = frozenset({"high", "med", "low"})


class RefereeError(Exception):
    """Parse failure or low-confidence verdict — caller must halt (never guess)."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


@dataclass
class RefereeVerdict:
    primary_failure: str
    failure_groups: list[list[str]] = field(default_factory=list)
    role: str = "Engineer"
    fix_scope: str = "app"
    files: list[str] = field(default_factory=list)
    instruction: str = ""
    hypothesis: str = ""
    confidence: str = "low"
    narration: str = ""

    @property
    def is_actionable(self) -> bool:
        return self.confidence in ("high", "med") and bool(self.hypothesis.strip())


REFEREE_PROMPT_SKELETON = """You are the fix referee. Evidence: stuck card + FailurePacket JSON + ledger entries.
Slice: {slice_file}
Return ONLY JSON: {{primary_failure, failure_groups, role: Engineer|QA,
fix_scope: app|tests, files[], instruction (<=2 sentences), hypothesis, confidence: high|med|low,
narration (<=25 words, shift-supervisor voice)}}.
Rules: prefer unit assertion/crash over UITest waits as primary; never propose
weakening tests; if evidence is insufficient say confidence: low.
"""


def build_referee_prompt(
    packet: FailurePacket,
    *,
    slice_file: str,
    stuck_card: str,
    ledger_entries: list[LedgerEntry] | None = None,
    slice_deliverables: str = "",
) -> str:
    """Plan-mode prompt: evidence in, strict JSON out."""
    packet_json = {
        "test_ids": packet.test_ids,
        "assertions": packet.assertions,
        "failed_queries": packet.failed_queries,
        "crashes": packet.crashes,
        "signature": packet.signature,
        "raw_failures": packet.raw_failures[:8],
        "bundle": packet.bundle,
        "exit_code": packet.exit_code,
        "hierarchy_excerpt": (packet.hierarchy_excerpt or "")[:2500],
        "suggested_files": packet.suggested_files,
        "failure_class_hint": packet.failure_class,
    }
    ledger_block = format_ledger_for_prompt(ledger_entries or [])
    deliverables = slice_deliverables.strip() or "(see slice file)"
    return f"""You are the PodWash fix referee (SDK plan mode — readonly).
Do NOT edit files. Do NOT run verify.sh or xcodebuild.

{REFEREE_PROMPT_SKELETON.format(slice_file=slice_file)}

Slice deliverables / Role artifacts (hint):
{deliverables}

Stuck card:
{stuck_card.strip() or "(none)"}

FailurePacket JSON:
{json.dumps(packet_json, ensure_ascii=False, indent=2)}

Hypothesis ledger (prior attempts — do NOT repeat a hypothesis on the same signature):
{ledger_block}

Return ONLY a single JSON object. No markdown fences unless required; no prose outside JSON.
"""


def _extract_json_object(text: str) -> dict[str, Any]:
    if not text or not text.strip():
        raise RefereeError("referee returned empty reply")
    raw = text.strip()
    # Prefer fenced ```json ... ```
    fence = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", raw, re.DOTALL | re.IGNORECASE)
    if fence:
        raw = fence.group(1)
    else:
        start = raw.find("{")
        end = raw.rfind("}")
        if start == -1 or end == -1 or end <= start:
            raise RefereeError("referee reply has no JSON object")
        raw = raw[start : end + 1]
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RefereeError(f"referee JSON parse failed: {exc}") from exc
    if not isinstance(data, dict):
        raise RefereeError("referee JSON root must be an object")
    return data


def _as_str_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        parts = [p.strip() for p in re.split(r"[,;\n]", value) if p.strip()]
        return parts
    if isinstance(value, list):
        out: list[str] = []
        for item in value:
            if isinstance(item, list):
                # nested group — flatten one level for files
                out.extend(str(x).strip() for x in item if str(x).strip())
            elif str(item).strip():
                out.append(str(item).strip())
        return out
    return [str(value).strip()] if str(value).strip() else []


def _as_groups(value: Any) -> list[list[str]]:
    if value is None:
        return []
    if isinstance(value, list):
        groups: list[list[str]] = []
        for item in value:
            if isinstance(item, list):
                groups.append([str(x).strip() for x in item if str(x).strip()])
            elif isinstance(item, str) and item.strip():
                groups.append([item.strip()])
        return groups
    if isinstance(value, str) and value.strip():
        return [[value.strip()]]
    return []


def parse_referee_reply(text: str, *, require_actionable: bool = True) -> RefereeVerdict:
    """Parse strict JSON verdict. Raises RefereeError on parse/low-confidence."""
    data = _extract_json_object(text)
    role = str(data.get("role") or "").strip()
    if role not in VALID_ROLES:
        # tolerate lowercase
        role_norm = role[:1].upper() + role[1:].lower() if role else ""
        if role_norm == "Engineer" or role.lower() == "engineer":
            role = "Engineer"
        elif role_norm == "Qa" or role.lower() == "qa":
            role = "QA"
        else:
            raise RefereeError(f"referee role invalid: {data.get('role')!r}")
    fix_scope = str(data.get("fix_scope") or "").strip().lower()
    if fix_scope not in VALID_SCOPES:
        raise RefereeError(f"referee fix_scope invalid: {data.get('fix_scope')!r}")
    confidence = str(data.get("confidence") or "").strip().lower()
    if confidence == "medium":
        confidence = "med"
    if confidence not in VALID_CONFIDENCE:
        raise RefereeError(f"referee confidence invalid: {data.get('confidence')!r}")

    files = _as_str_list(data.get("files"))
    primary = str(data.get("primary_failure") or "").strip()
    instruction = str(data.get("instruction") or "").strip()
    hypothesis = str(data.get("hypothesis") or "").strip()
    narration = str(data.get("narration") or "").strip()
    groups = _as_groups(data.get("failure_groups"))

    verdict = RefereeVerdict(
        primary_failure=primary,
        failure_groups=groups,
        role=role,
        fix_scope=fix_scope,
        files=files,
        instruction=instruction,
        hypothesis=hypothesis,
        confidence=confidence,
        narration=narration,
    )
    if require_actionable and confidence == "low":
        raise RefereeError(
            "referee confidence=low — insufficient evidence; halt (never guess)"
        )
    if require_actionable and not hypothesis:
        raise RefereeError("referee omitted hypothesis — halt")
    if require_actionable and not instruction:
        raise RefereeError("referee omitted instruction — halt")
    return verdict


def apply_verdict_to_packet(
    packet: FailurePacket, verdict: RefereeVerdict
) -> FailurePacket:
    """Copy referee routing fields onto the FailurePacket for stuck cards / prompts."""
    files = list(dict.fromkeys(list(verdict.files) + list(packet.suggested_files)))
    return packet.with_updates(
        hypothesis=verdict.hypothesis,
        fix_scope=verdict.fix_scope,
        suggested_files=files,
    )


def verdict_to_dict(verdict: RefereeVerdict) -> dict[str, Any]:
    return {
        "primary_failure": verdict.primary_failure,
        "failure_groups": verdict.failure_groups,
        "role": verdict.role,
        "fix_scope": verdict.fix_scope,
        "files": verdict.files,
        "instruction": verdict.instruction,
        "hypothesis": verdict.hypothesis,
        "confidence": verdict.confidence,
        "narration": verdict.narration,
    }
