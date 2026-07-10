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

VERDICT_BEGIN = "VERDICT_JSON_BEGIN"
VERDICT_END = "VERDICT_JSON_END"

# Compact one-line example for the prompt (models copy this shape).
VERDICT_EXAMPLE = (
    f'{VERDICT_BEGIN} '
    '{"primary_failure":"PodWashTests/Foo/testA() — XCTAssertEqual failed",'
    '"failure_groups":[["assertion"]],"role":"QA","fix_scope":"tests",'
    '"files":["PodWash/PodWashTests/FooTests.swift"],'
    '"instruction":"Snapshot spy count before the event; assert one new call.",'
    '"hypothesis":"Test double-counts setup play plus the event under test.",'
    '"confidence":"high","narration":"Assertion is test-side counting."}'
    f' {VERDICT_END}'
)


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
    retry_hint: str = "",
) -> str:
    """Plan-mode prompt: evidence in, sentinel-wrapped compact JSON out."""
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
    retry_block = ""
    if retry_hint.strip():
        retry_block = f"\nRETRY: {retry_hint.strip()}\n"
    return f"""You are the PodWash fix referee (SDK plan mode — readonly).
Do NOT edit files. Do NOT run verify.sh or xcodebuild.

{REFEREE_PROMPT_SKELETON.format(slice_file=slice_file)}
{retry_block}
Slice deliverables / Role artifacts (hint):
{deliverables}

Stuck card:
{stuck_card.strip() or "(none)"}

FailurePacket JSON:
{json.dumps(packet_json, ensure_ascii=False, indent=2)}

Hypothesis ledger (prior attempts — do NOT repeat a hypothesis on the same signature):
{ledger_block}

Reply with EXACTLY one line in this form (no markdown fences, no prose outside the markers):
{VERDICT_BEGIN} {{compact single-line JSON}} {VERDICT_END}

Required JSON keys: primary_failure, failure_groups, role (Engineer|QA),
fix_scope (app|tests), files (array), instruction (<=2 sentences), hypothesis,
confidence (high|med|low), narration (<=25 words, shift-supervisor voice).
Escape any newlines inside string values as \\n. Do not pretty-print.

Example:
{VERDICT_EXAMPLE}
"""


def build_referee_retry_prompt(previous_text: str) -> str:
    """Short re-prompt after a parse failure (does not burn fix budget)."""
    excerpt = (previous_text or "")[:800]
    return (
        "Your previous reply was not parseable as a referee verdict. "
        f"Reply with ONLY one line: {VERDICT_BEGIN} {{compact JSON}} {VERDICT_END}. "
        "No markdown fences, no prose. Escape newlines in strings as \\n.\n\n"
        f"Previous reply (truncated):\n{excerpt}"
    )


def _escape_raw_newlines_in_strings(text: str) -> str:
    """Replace raw newlines/CRs that appear inside JSON string literals with \\n.

    Models often copy multi-line assertion text into primary_failure without
    escaping; json.loads then fails with 'Invalid control character'.
    """
    out: list[str] = []
    in_string = False
    escape = False
    for ch in text:
        if escape:
            out.append(ch)
            escape = False
            continue
        if ch == "\\" and in_string:
            out.append(ch)
            escape = True
            continue
        if ch == '"':
            in_string = not in_string
            out.append(ch)
            continue
        if in_string and ch in "\n\r":
            out.append("\\n")
            continue
        out.append(ch)
    return "".join(out)


def _try_load_json(cand: str) -> dict[str, Any] | None:
    cleaned = "".join(
        ch if (ord(ch) >= 32 or ch in "\n\r\t") else " " for ch in cand
    )
    cleaned = _escape_raw_newlines_in_strings(cleaned)
    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError:
        try:
            data, _ = json.JSONDecoder().raw_decode(cleaned.lstrip())
        except json.JSONDecodeError:
            return None
    return data if isinstance(data, dict) else None


def _scan_verdict_objects(raw: str) -> dict[str, Any] | None:
    """Scan for brace-started objects that look like a referee verdict."""
    for m in re.finditer(r"\{", raw):
        chunk = raw[m.start() :]
        head = chunk[:800]
        if '"primary_failure"' not in head and "'primary_failure'" not in head:
            if '"hypothesis"' not in head:
                continue
        data = _try_load_json(chunk)
        if data is not None and (
            "primary_failure" in data or "hypothesis" in data or "confidence" in data
        ):
            return data
    return None


def _extract_json_object(text: str) -> dict[str, Any]:
    if not text or not text.strip():
        raise RefereeError("referee returned empty reply")
    raw = text.strip()
    last_err: Exception | None = None

    # 1) Sentinel-wrapped verdict (preferred)
    begin = raw.find(VERDICT_BEGIN)
    end = raw.find(VERDICT_END)
    if begin != -1 and end != -1 and end > begin:
        inner = raw[begin + len(VERDICT_BEGIN) : end].strip()
        data = _try_load_json(inner)
        if data is not None:
            return data
        # Fall through — maybe valid JSON exists elsewhere

    # 2) Fenced ```json ... ``` — try, but fall through on failure
    for fence in re.finditer(
        r"```(?:json)?\s*(\{.*?\})\s*```", raw, re.DOTALL | re.IGNORECASE
    ):
        data = _try_load_json(fence.group(1))
        if data is not None:
            return data

    # 3) Multi-{ scanner for verdict-shaped objects
    scanned = _scan_verdict_objects(raw)
    if scanned is not None:
        return scanned

    # 4) Fallback: first { to last }
    start = raw.find("{")
    end_brace = raw.rfind("}")
    if start == -1 or end_brace == -1 or end_brace <= start:
        raise RefereeError("referee reply has no JSON object")
    cand = raw[start : end_brace + 1]
    data = _try_load_json(cand)
    if data is not None:
        return data
    try:
        json.loads(_escape_raw_newlines_in_strings(cand))
    except json.JSONDecodeError as exc:
        last_err = exc
    if last_err is not None:
        raise RefereeError(f"referee JSON parse failed: {last_err}") from last_err
    raise RefereeError("referee JSON root must be an object")


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


def is_test_path(path: str) -> bool:
    p = (path or "").replace("\\", "/")
    return any(
        tok in p
        for tok in (
            "/PodWashTests/",
            "/PodWashUITests/",
            "/PodWashSlowTests/",
            "PodWashTests/",
            "PodWashUITests/",
            "PodWashSlowTests/",
        )
    )


def is_app_path(path: str) -> bool:
    p = (path or "").replace("\\", "/")
    if is_test_path(p):
        return False
    return "/PodWash/PodWash/" in f"/{p}" or p.startswith("PodWash/PodWash/")


def is_docs_path(path: str) -> bool:
    p = (path or "").replace("\\", "/")
    return p.startswith("docs/adr/") or "/docs/adr/" in f"/{p}"


def resolve_role_scope_contradiction(
    role: str,
    files: list[str],
) -> tuple[str, str]:
    """Flip role when every suggested file contradicts the worker's edit scope.

    Returns (role, fix_scope). No-op when files are mixed/empty/ambiguous.
    """
    paths = [f for f in files if f and f.strip()]
    if not paths:
        if role == "Architect":
            return role, "docs"
        return role, ("app" if role == "Engineer" else "tests")
    docsish = all(is_docs_path(p) for p in paths)
    testish = all(is_test_path(p) for p in paths)
    appish = all(is_app_path(p) for p in paths)
    if role == "Architect" or docsish:
        return "Architect", "docs"
    if role == "Engineer" and testish and not appish:
        return "QA", "tests"
    if role == "QA" and appish and not testish:
        return "Engineer", "app"
    if role == "Engineer" and docsish:
        return "Architect", "docs"
    if role == "Architect":
        return role, "docs"
    if role == "QA":
        return role, "tests"
    return role, "app"
