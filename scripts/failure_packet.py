#!/usr/bin/env python3
"""FailurePacket + stuck card for loop-owned verify / fix workers.

Built from xcresult summary + exported UITest attachments so fix prompts are
never blind ``xcodebuild — TEST FAILED`` when the bundle has names.

Spike (Xcode 26 / xcresulttool 24408):
  xcrun xcresulttool get test-results summary --path <bundle>
  xcrun xcresulttool export attachments --path <bundle> --output-path <dir> \\
      --test-id '<Class/testName()>'
Hierarchy / query-chain live in exported ``*.txt``; prefer suggested names
containing ``hierarchy`` or ``Debug description``. Truncate hierarchy to
HIERARCHY_MAX chars; keep lines mentioning failing identifiers / query chains.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field, replace
from typing import Any

HIERARCHY_MAX = 4000
ATTACHMENT_TEXT_MAX = 8000

_QUERY_ID_RE = re.compile(
    r"""['"]([A-Za-z_][A-Za-z0-9_]*)['"]\s+IN\s+identifiers""",
    re.IGNORECASE,
)
_IDENTIFIER_RE = re.compile(r"identifier:\s*'([^']+)'")
_BUILD_HINT_RE = re.compile(
    r"(error:|fatal error|compile|linker|undefined symbol|no such module|"
    r"verify\.sh.*lock|another verify|xcodebuild.*failed|"
    r"BUILD FAILED|Could not resolve|SwiftCompile|"
    r"missing its bundle executable|unable to install|"
    r"failed to install or launch|podwash encountered an error)",
    re.IGNORECASE,
)
_UI_RACE_RE = re.compile(
    r"(appear|disappear|timeout|progress|wait|exist|hittable|transient|"
    r"asynchronous wait|unfulfilled expectation)",
    re.IGNORECASE,
)
_POST_SUCCESS_IDS = ("cleaningBadge", "episodeOn", "ready", "complete", "done")
_IDLE_FLAKE_RE = re.compile(r"failed to become idle", re.IGNORECASE)
_WAIT_FAILURE_RE = re.compile(
    r"(asynchronous wait failed|unfulfilled expectation|exceeded timeout)",
    re.IGNORECASE,
)
# XCTestExpectation double-fulfill / API violation — almost always a test harness bug.
_EXPECTATION_API_VIOLATION_RE = re.compile(
    r"(api violation.*fulfill|multiple calls made to.*(?:xctestexpectation|fulfill)|"
    r"nsinternalinconsistencyexception.*fulfill)",
    re.IGNORECASE,
)
# Sim launch/bootstrap — infra, not missing @main packaging (see sim_hygiene).
_SIM_LAUNCH_INFRA_RE = re.compile(
    r"(failed to install or launch|sbmainworkspace|launchd job spawn failed|"
    r"early unexpected exit|never finished bootstrapping|"
    r"simulator device failed to launch|the process failed to launch)",
    re.IGNORECASE,
)
# When NSPredicate waits attach only "Target Application" query chains, infer
# the identifier the UITest is waiting for from the test id / assertion text.
_INFER_QUERY_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"progress|analyz", re.IGNORECASE), "analysisProgress"),
    (re.compile(r"cleaningBadge|badge", re.IGNORECASE), "cleaningBadge_episodeOn"),
)


@dataclass
class FailurePacket:
    test_ids: list[str] = field(default_factory=list)
    assertions: list[str] = field(default_factory=list)
    hierarchy_excerpt: str = ""
    failed_queries: list[str] = field(default_factory=list)
    bundle: str | None = None
    crashes: list[str] = field(default_factory=list)
    signature: str = ""
    raw_failures: list[str] = field(default_factory=list)
    exit_code: str | None = None
    failure_class: str = "unknown"
    hypothesis: str = ""
    fix_scope: str = "app"  # app | tests
    suggested_files: list[str] = field(default_factory=list)
    actionable: bool = True
    halt_reason: str = ""

    def with_updates(self, **kwargs: Any) -> FailurePacket:
        return replace(self, **kwargs)


def packet_signature(
    test_ids: list[str],
    crashes: list[str] | None = None,
) -> str:
    """Stable signature: test ids + crash fingerprint (not assertion/hierarchy)."""
    ids = sorted({_norm_test_id(t) for t in test_ids if t and t.strip()})
    crash_bits: list[str] = []
    for c in crashes or []:
        c = (c or "").strip()
        if not c:
            continue
        # Prefer IPS basename / exception type tokens
        base = os.path.basename(c.split()[0]) if c else ""
        short = re.sub(r"\s+", " ", c.lower())[:60]
        crash_bits.append(base or short)
    crash_bits = sorted(set(crash_bits))[:3]
    if ids or crash_bits:
        return "|".join(ids + [f"crash:{x}" for x in crash_bits])
    return ""


def _norm_test_id(raw: str) -> str:
    s = re.sub(r"\s+", " ", (raw or "").strip())
    # Strip trailing assertion after em-dash / " — "
    s = re.split(r"\s+[—–-]\s+", s, maxsplit=1)[0].strip()
    return s


def _looks_buildish(raw_failures: list[str], exit_code: str | None, output: str) -> bool:
    blob = "\n".join(raw_failures) + "\n" + (output or "")
    if _BUILD_HINT_RE.search(blob):
        return True
    if exit_code and exit_code not in ("0", "1", "65", "?"):
        # Non-standard exits often mean tooling/lock
        return True
    if "lock" in blob.lower() and "verify" in blob.lower():
        return True
    return False


def read_xcresult_summary(xcresult_path: str) -> dict[str, Any] | None:
    if not xcresult_path or not os.path.isdir(xcresult_path):
        return None
    try:
        proc = subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                "summary",
                "--path",
                xcresult_path,
            ],
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            return None
        data = json.loads(proc.stdout)
        return data if isinstance(data, dict) else None
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError, ValueError):
        return None


def summary_test_failures(data: dict[str, Any]) -> list[tuple[str, str]]:
    """Return list of (test_id, assertion) from summary testFailures."""
    out: list[tuple[str, str]] = []
    for item in data.get("testFailures") or []:
        if not isinstance(item, dict):
            continue
        target = str(item.get("targetName") or "")
        ident = str(item.get("testIdentifierString") or "").strip()
        name = str(item.get("testName") or "").strip()
        detail = re.sub(r"\s+", " ", str(item.get("failureText") or "").strip())
        if len(detail) > 200:
            detail = detail[:197] + "…"
        # Prefer Target/Class/method when identifier is Class/method
        if ident and "/" in ident:
            test_id = f"{target}/{ident}" if target and not ident.startswith(target) else ident
        elif target and name:
            test_id = f"{target}/{name}"
        else:
            test_id = ident or name or target or "unknown"
        out.append((test_id, detail))
    return out


def export_attachments_for_test(
    xcresult_path: str,
    test_id: str,
    *,
    output_dir: str | None = None,
) -> str | None:
    """Export attachments for one test. Returns output dir or None on failure.

    Uses: xcresulttool export attachments --test-id … (Xcode 16+ / 26).
    """
    if not xcresult_path or not os.path.isdir(xcresult_path) or not test_id:
        return None
    out = output_dir or tempfile.mkdtemp(prefix="xcattach-")
    os.makedirs(out, exist_ok=True)
    parts = [p for p in test_id.split("/") if p]
    candidates: list[str] = []
    # Class/method() — what xcresulttool --test-id expects for UITests
    if len(parts) >= 2:
        candidates.append("/".join(parts[-2:]))
    if len(parts) >= 3:
        candidates.append("/".join(parts[1:]))
    candidates.append(test_id)
    if parts:
        candidates.append(parts[-1])

    tried: set[str] = set()
    for tid in candidates:
        tid = tid.strip()
        if not tid or tid in tried:
            continue
        tried.add(tid)
        try:
            proc = subprocess.run(
                [
                    "xcrun",
                    "xcresulttool",
                    "export",
                    "attachments",
                    "--path",
                    xcresult_path,
                    "--output-path",
                    out,
                    "--test-id",
                    tid,
                ],
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        # Success if any .txt landed or manifest non-empty list
        txts = [
            f
            for f in os.listdir(out)
            if f.endswith(".txt") or f == "manifest.json"
        ]
        if proc.returncode == 0 and any(f.endswith(".txt") for f in txts):
            return out
        if proc.returncode == 0 and os.path.isfile(os.path.join(out, "manifest.json")):
            try:
                man = json.loads(
                    open(os.path.join(out, "manifest.json"), encoding="utf-8").read()
                )
                if man:
                    return out
            except (OSError, json.JSONDecodeError, ValueError):
                pass
    return out if any(f.endswith(".txt") for f in os.listdir(out)) else None


def _load_manifest(attach_dir: str) -> list[dict[str, Any]]:
    path = os.path.join(attach_dir, "manifest.json")
    if not os.path.isfile(path):
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.loads(fh.read())
    except (OSError, json.JSONDecodeError, ValueError):
        return []
    if isinstance(data, list):
        # list of test entries or flat attachments
        atts: list[dict[str, Any]] = []
        for item in data:
            if isinstance(item, dict) and "attachments" in item:
                atts.extend(
                    a for a in (item.get("attachments") or []) if isinstance(a, dict)
                )
            elif isinstance(item, dict) and "exportedFileName" in item:
                atts.append(item)
        return atts
    if isinstance(data, dict):
        return [a for a in (data.get("attachments") or []) if isinstance(a, dict)]
    return []


def parse_attachment_texts(attach_dir: str) -> tuple[str, list[str], str]:
    """Return (hierarchy_excerpt, failed_queries, got_clue) from exported dir."""
    if not attach_dir or not os.path.isdir(attach_dir):
        return "", [], ""

    manifest = _load_manifest(attach_dir)
    name_by_file = {
        str(a.get("exportedFileName") or ""): str(
            a.get("suggestedHumanReadableName") or ""
        )
        for a in manifest
    }

    hierarchy_parts: list[str] = []
    queries: list[str] = []
    got_bits: list[str] = []

    txt_files = sorted(
        f for f in os.listdir(attach_dir) if f.endswith(".txt")
    )
    for fn in txt_files:
        path = os.path.join(attach_dir, fn)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read(ATTACHMENT_TEXT_MAX)
        except OSError:
            continue
        suggested = name_by_file.get(fn, fn).lower()
        is_hierarchy = "hierarchy" in suggested or text.lstrip().startswith(
            "Application,"
        )
        is_query = (
            "debug description" in suggested
            or "query chain" in text.lower()
            or "IN identifiers" in text
        )
        if is_query:
            for m in _QUERY_ID_RE.finditer(text):
                qid = m.group(1)
                if qid not in queries:
                    queries.append(qid)
            # Also bare quoted ids in Find lines
            for m in re.finditer(r'"([A-Za-z_][A-Za-z0-9_]*)"', text):
                qid = m.group(1)
                if qid not in queries and "identifier" in text.lower():
                    queries.append(qid)
            # NSPredicate / Target Application-only chains still count as query
            # evidence (empty id list) so callers know attachments existed.
            if "query chain" in text.lower() and "target application" in text.lower():
                if "_nspredicate_app_query" not in queries:
                    # sentinel stripped later — marks sparse predicate wait
                    pass
        if is_hierarchy:
            hierarchy_parts.append(text)
            ids = _IDENTIFIER_RE.findall(text)
            for hint in _POST_SUCCESS_IDS:
                for i in ids:
                    if hint.lower() in i.lower() and i not in got_bits:
                        got_bits.append(i)

    hierarchy = "\n---\n".join(hierarchy_parts)
    if len(hierarchy) > HIERARCHY_MAX:
        # Prefer lines with identifiers / queries
        keep_ids = set(queries) | set(got_bits)
        lines = hierarchy.splitlines()
        scored = [
            ln
            for ln in lines
            if any(k in ln for k in keep_ids)
            or "identifier:" in ln
            or "Query chain" in ln
        ]
        if scored:
            hierarchy = "\n".join(scored)
        if len(hierarchy) > HIERARCHY_MAX:
            hierarchy = hierarchy[: HIERARCHY_MAX - 1] + "…"

    got = "; ".join(got_bits[:6])
    if queries and hierarchy:
        missing = [q for q in queries if q not in hierarchy]
        if missing and not got:
            got = f"query empty for {', '.join(missing)}; hierarchy present"
        elif missing and got:
            got = f"{got} present; {', '.join(missing)} query empty"
    return hierarchy, queries, got


def is_expectation_api_violation(text: str) -> bool:
    """True when XCTestExpectation was fulfilled more than once (test harness)."""
    return bool(_EXPECTATION_API_VIOLATION_RE.search(text or ""))


def classify_failure(packet: FailurePacket) -> str:
    """Heuristic failure class (no LLM)."""
    blob = "\n".join(
        packet.assertions
        + packet.raw_failures
        + packet.crashes
        + packet.failed_queries
        + [packet.hierarchy_excerpt[:500]]
    )
    low = blob.lower()
    # XCTestExpectation double-fulfill is an assertion/harness bug, not a crash.
    if is_expectation_api_violation(blob):
        return "assertion"
    # Real packaging defect only — SBMainWorkspace launch failures are infra/flake.
    if "missing its bundle executable" in low:
        return "build_error"
    # Sim launch/bootstrap: treat as flake even when xcresult invents a fake
    # "PodWashTests/PodWash encountered an error" test id (slice 12 run 1–2).
    if _SIM_LAUNCH_INFRA_RE.search(blob) and "xctassert" not in low:
        return "flake"
    if "unable to install" in low and "missing its bundle executable" not in low:
        if "xctassert" not in low:
            return "flake"
    if packet.crashes or "crash:" in low or ".ips" in low:
        return "crash"
    if _looks_buildish(packet.raw_failures, packet.exit_code, blob) and not packet.test_ids:
        return "build_error"
    uitest = any("uitest" in t.lower() for t in packet.test_ids) or "uitest" in low
    if uitest:
        if packet.failed_queries:
            hier = packet.hierarchy_excerpt
            missing_entirely = all(q not in hier for q in packet.failed_queries)
            post = any(h.lower() in hier.lower() for h in _POST_SUCCESS_IDS)
            if missing_entirely and post:
                return "ui_race"
            if missing_entirely and not post and hier:
                return "missing_identifier"
            if _UI_RACE_RE.search(blob) or post:
                return "ui_race"
        # XCTWaiter / NSPredicate timeout on a progress/appear test → ui_race
        # even when attachments have no hierarchy (common for BLOCKPREDICATE).
        if _WAIT_FAILURE_RE.search(blob) and (
            _UI_RACE_RE.search(blob)
            or any("progress" in t.lower() or "analyz" in t.lower() for t in packet.test_ids)
        ):
            return "ui_race"
        if _UI_RACE_RE.search(blob):
            return "ui_race"
    if "xctassert" in low and not packet.hierarchy_excerpt and not uitest:
        return "assertion"
    if packet.test_ids and "xctassert" in low and not uitest:
        return "assertion"
    if _IDLE_FLAKE_RE.search(blob):
        return "flake"
    return "unknown"


def is_flake_signal(packet: FailurePacket) -> bool:
    """True only for likely infrastructure flakes — not XCTWaiter/UI race timeouts.

    XCTWaiter "Asynchronous wait failed / Exceeded timeout" with a named test is a
    real product failure (often ui_race). Do not burn a cold re-verify on those.
    """
    blob = "\n".join(packet.assertions + packet.raw_failures)
    if _IDLE_FLAKE_RE.search(blob):
        return True
    if packet.failure_class == "flake" and not _WAIT_FAILURE_RE.search(blob):
        return True
    # Explicit wait/expectation failures are not flakes even if attachments are sparse.
    if _WAIT_FAILURE_RE.search(blob):
        return False
    if packet.failure_class in (
        "ui_race",
        "missing_identifier",
        "assertion",
        "crash",
        "build_error",
        "wrong_state",
    ):
        return False
    # Last-resort flake: timeout language, no test id, no hierarchy, no queries.
    if (
        "timeout" in blob.lower()
        and not packet.test_ids
        and not packet.hierarchy_excerpt
        and not packet.failed_queries
    ):
        return True
    return False


def infer_failed_queries(
    test_ids: list[str],
    assertions: list[str],
    existing: list[str] | None = None,
) -> list[str]:
    """Infer accessibility ids when attachments lack IN-identifiers query chains."""
    out = list(existing or [])
    blob = " ".join(test_ids + assertions)
    for cre, qid in _INFER_QUERY_PATTERNS:
        if cre.search(blob) and qid not in out:
            out.append(qid)
    return out


def build_failure_packet(
    *,
    failures: list[str],
    crashes: list[str],
    bundle: str | None,
    exit_code: str | None = None,
    output: str = "",
    repo_root: str | None = None,
    export_attachments: bool = True,
) -> FailurePacket:
    """Build a FailurePacket from verify outcome pieces."""
    from slice_loop_progress import enrich_build_failures

    raw = list(failures or [])
    verify_hint = {"exit": str(exit_code)} if exit_code else None
    raw = enrich_build_failures(raw, output, verify_hint)
    crash_list = list(crashes or [])
    test_ids: list[str] = []
    assertions: list[str] = []
    hierarchy = ""
    queries: list[str] = []
    got_clue = ""

    summary = read_xcresult_summary(bundle) if bundle else None
    if summary:
        enriched: list[str] = []
        for tid, detail in summary_test_failures(summary):
            if tid and tid not in test_ids:
                test_ids.append(tid)
            if detail and detail not in assertions:
                assertions.append(detail)
            line = f"{tid} — {detail}" if detail else tid
            if line not in enriched:
                enriched.append(line)
        if enriched:
            # Drop sparse shell-only noise when summary has real test names
            kept = [r for r in raw if not r.lower().startswith("xcodebuild")]
            for line in enriched:
                tid = line.split(" — ")[0]
                if not any(tid in r for r in kept):
                    kept.append(line)
            raw = kept or list(enriched)

    # Parse test ids from existing failure strings if summary empty
    if not test_ids:
        for f in raw:
            if f.lower().startswith("xcodebuild"):
                continue
            tid = _norm_test_id(f)
            if tid and ("/" in tid or "test" in tid.lower()):
                if tid not in test_ids:
                    test_ids.append(tid)
                rest = f[len(tid) :].lstrip(" —–-")
                if rest and rest not in assertions:
                    assertions.append(rest)

    attach_dir: str | None = None
    if export_attachments and bundle and test_ids:
        dest = None
        if repo_root:
            dest = os.path.join(
                repo_root,
                "build",
                "test-results",
                "attachments-" + re.sub(r"[^\w.-]+", "_", test_ids[0])[:80],
            )
            if os.path.isdir(dest):
                shutil.rmtree(dest, ignore_errors=True)
        try:
            attach_dir = export_attachments_for_test(
                bundle, test_ids[0], output_dir=dest
            )
            if attach_dir:
                hierarchy, queries, got_clue = parse_attachment_texts(attach_dir)
        except (OSError, subprocess.SubprocessError, ValueError):
            pass

    if got_clue and got_clue not in assertions:
        # Keep as separate clue via hierarchy; assertions stay XCTAssert text
        pass

    # NSPredicate waits often export only "Target Application" query chains with
    # no hierarchy dump — infer the id the UITest is waiting for from the name.
    if not queries:
        queries = infer_failed_queries(test_ids, assertions)
    elif not any(q for q in queries if not q.startswith("_")):
        queries = infer_failed_queries(test_ids, assertions, queries)

    if not got_clue and queries and _WAIT_FAILURE_RE.search("\n".join(assertions)):
        got_clue = (
            f"wait timed out for {', '.join(queries)}; "
            "attachments lack hierarchy (NSPredicate expectation)"
        )

    sig = packet_signature(test_ids, crash_list)
    if not sig and raw:
        # Fallback signature from non-xcodebuild raw lines (still better than empty)
        cleaned = [
            re.sub(r"\s+", " ", r.strip().lower())[:80]
            for r in raw
            if not r.lower().startswith("xcodebuild")
        ]
        sig = "|".join(sorted(set(cleaned))[:5]) or packet_signature([], crash_list)

    packet = FailurePacket(
        test_ids=test_ids,
        assertions=assertions,
        hierarchy_excerpt=hierarchy,
        failed_queries=queries,
        bundle=bundle,
        crashes=crash_list,
        signature=sig,
        raw_failures=raw,
        exit_code=exit_code,
    )
    # Soft undiagnosable
    has_evidence = bool(
        test_ids or crash_list or (raw and not all(
            r.lower().startswith("xcodebuild") for r in raw
        ))
        or _looks_buildish(raw, exit_code, output)
        or (bundle and summary)
    )
    if not has_evidence and not bundle:
        packet.actionable = False
        packet.halt_reason = (
            "DIAGNOSE FAILED: no actionable evidence "
            "(no test id, no crashes, no build signal, no xcresult bundle)"
        )
    elif not test_ids and _looks_buildish(raw, exit_code, output):
        packet.failure_class = "build_error"
        packet.fix_scope = "app"
        packet.actionable = True
    else:
        packet.failure_class = classify_failure(packet)
        raw_blob = "\n".join(raw + assertions)
        if is_expectation_api_violation(raw_blob):
            # Double-fulfill / API violation lives in the test harness, not the app.
            packet.fix_scope = "tests"
            packet.hypothesis = (
                packet.hypothesis
                or "Test harness: live KVO across setRate double-fulfills expectation"
            )
        elif packet.failure_class in ("assertion",) and "test" in " ".join(test_ids).lower():
            # default scope; diagnose may override
            packet.fix_scope = "tests" if "fixture" in raw_blob.lower() else "app"
        packet.actionable = True

    # Stash got_clue into hierarchy header for stuck card
    if got_clue:
        packet.hierarchy_excerpt = (
            f"[got] {got_clue}\n{packet.hierarchy_excerpt}"
            if packet.hierarchy_excerpt
            else f"[got] {got_clue}"
        )
    return packet


def _shorten(text: str, limit: int) -> str:
    s = re.sub(r"\s+", " ", (text or "").strip())
    if len(s) <= limit:
        return s
    return s[: limit - 1].rstrip() + "…"


def failure_story_parts(packet: FailurePacket) -> dict[str, str]:
    """Extract test / intent / got strings for floor narration."""
    if packet.test_ids:
        test = ", ".join(packet.test_ids[:2])
        if len(packet.test_ids) > 2:
            test += f" (+{len(packet.test_ids) - 2} more)"
    elif packet.crashes:
        test = "a simulator crash"
    else:
        test = "the verify run"

    if packet.assertions:
        intent = _shorten(packet.assertions[0], 120)
    elif packet.hypothesis:
        intent = _shorten(packet.hypothesis, 120)
    else:
        intent = "get green"

    got = ""
    if packet.hierarchy_excerpt.startswith("[got] "):
        got = _shorten(
            packet.hierarchy_excerpt.split("\n", 1)[0][len("[got] ") :],
            140,
        )
    elif packet.failed_queries:
        got = _shorten(
            f"queries missing: {', '.join(packet.failed_queries[:3])}",
            140,
        )
    elif packet.raw_failures:
        got = _shorten(packet.raw_failures[0], 140)
    elif packet.crashes:
        got = _shorten(packet.crashes[0], 140)
    else:
        got = "(no detail captured)"

    return {"test": test, "intent": intent, "got": got}


def slice_id_from_path(slice_file: str) -> int | None:
    m = re.search(r"slice-(\d+)", slice_file or "")
    return int(m.group(1)) if m else None


def format_stuck_card(
    packet: FailurePacket,
    *,
    slice_file: str = "",
    attempt: int = 0,
    max_attempts: int = 2,
    next_role: str = "",
    lever: str = "",
    levers_tried: list[str] | None = None,
) -> str:
    sid = slice_id_from_path(slice_file)
    title = f"Slice {sid:02d}" if sid is not None else (slice_file or "slice")
    test_line = ", ".join(packet.test_ids) if packet.test_ids else "(no test id)"
    assert_line = "; ".join(packet.assertions[:2]) if packet.assertions else "(none)"
    got = ""
    if packet.hierarchy_excerpt.startswith("[got] "):
        got = packet.hierarchy_excerpt.split("\n", 1)[0][len("[got] ") :]
    elif packet.failed_queries:
        got = f"queries: {', '.join(packet.failed_queries)}"
    elif packet.raw_failures:
        got = packet.raw_failures[0][:120]
    lines = [
        f"STUCK — {title}",
        f"Test: {test_line}",
        f"Assert: {assert_line}",
        f"Got: {got or '(no hierarchy clue)'}",
        f"Class: {packet.failure_class}",
    ]
    if lever:
        lines.append(f"Lever: {lever}")
    if packet.hypothesis:
        lines.append(f"Hypothesis: {packet.hypothesis[:160]}")
    if attempt or max_attempts:
        role_bit = f" · next role: {next_role}" if next_role else ""
        lines.append(f"Attempt: {attempt}/{max_attempts}{role_bit}")
    if levers_tried:
        lines.append("Tried: " + " | ".join(levers_tried))
    if packet.suggested_files:
        lines.append("Files: " + ", ".join(packet.suggested_files[:6]))
    if packet.bundle:
        lines.append(f"Bundle: {packet.bundle}")
    if not packet.actionable and packet.halt_reason:
        lines.append(packet.halt_reason)
    return "\n".join(lines)


def persist_stuck_card(
    card: str,
    *,
    repo_root: str,
    slice_file: str = "",
) -> str:
    """Write stuck card to build/test-results/stuck-slice-NN.txt. Returns path."""
    sid = slice_id_from_path(slice_file)
    name = f"stuck-slice-{sid:02d}.txt" if sid is not None else "stuck-slice.txt"
    out_dir = os.path.join(repo_root, "build", "test-results")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(card.rstrip() + "\n")
    return path


def parse_diagnose_reply(text: str) -> dict[str, str]:
    """Extract structured fields from a plan-mode diagnose reply."""
    out: dict[str, str] = {}
    if not text:
        return out
    patterns = {
        "class": re.compile(
            r"(?im)^\s*(?:failure[_ ]?class|class)\s*[:=]\s*([a-z_]+)"
        ),
        "hypothesis": re.compile(
            r"(?im)^\s*(?:hypothesis)\s*[:=]\s*(.+)$"
        ),
        "fix_scope": re.compile(
            r"(?im)^\s*(?:fix[_ ]?scope|scope)\s*[:=]\s*(app|tests)\b"
        ),
        "suggested_files": re.compile(
            r"(?im)^\s*(?:suggested[_ ]?files|files)\s*[:=]\s*(.+)$"
        ),
    }
    for key, cre in patterns.items():
        m = cre.search(text)
        if m:
            out[key] = m.group(1).strip().strip("`\"'")
    # JSON fence fallback
    jm = re.search(r"\{[^{}]+\}", text, re.DOTALL)
    if jm and len(out) < 2:
        try:
            data = json.loads(jm.group(0))
            if isinstance(data, dict):
                for k in ("class", "failure_class", "hypothesis", "fix_scope", "suggested_files"):
                    if k in data and k not in out and str(data[k]).strip():
                        key = "class" if k == "failure_class" else k
                        val = data[k]
                        if isinstance(val, list):
                            out[key] = ", ".join(str(x) for x in val)
                        else:
                            out[key] = str(val).strip()
        except (json.JSONDecodeError, ValueError):
            pass
    return out


def merge_diagnose_into_packet(
    packet: FailurePacket, parsed: dict[str, str]
) -> FailurePacket:
    """Merge diagnose reply. Heuristic class wins unless unknown."""
    if not parsed:
        return packet
    kwargs: dict[str, Any] = {}
    if parsed.get("hypothesis"):
        kwargs["hypothesis"] = parsed["hypothesis"]
    if parsed.get("fix_scope") in ("app", "tests"):
        kwargs["fix_scope"] = parsed["fix_scope"]
    if parsed.get("suggested_files"):
        files = [
            f.strip().strip("`")
            for f in re.split(r"[,;\n]", parsed["suggested_files"])
            if f.strip()
        ]
        if files:
            merged = list(dict.fromkeys(packet.suggested_files + files))
            kwargs["suggested_files"] = merged
    new_class = (parsed.get("class") or "").strip().lower()
    if new_class and packet.failure_class == "unknown":
        kwargs["failure_class"] = new_class
    return packet.with_updates(**kwargs) if kwargs else packet


def extract_slice_swift_paths(slice_text: str) -> list[str]:
    """Pull Swift paths mentioned in Role artifacts / Deliverables."""
    if not slice_text:
        return []
    found = re.findall(
        r"`?(PodWash/PodWash(?:Tests|UITests|SlowTests)?/[A-Za-z0-9_./]+\.swift)`?",
        slice_text,
    )
    # Dedup preserve order
    return list(dict.fromkeys(found))
