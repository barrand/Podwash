"""Terminal progress formatting for scripts/slice_loop.py (unit-testable)."""

from __future__ import annotations

import json
import os
import re
from typing import Any

VERIFY_RESULT_RE = re.compile(
    r"VERIFY RESULT:\s*exit=(\d+)\s+total=([^\s]+)\s+passed=([^\s]+)\s+"
    r"failed=([^\s]+)\s+skipped=([^\s]+)"
    r"(?:\s+filtered=([^\s]+))?"
    r"(?:\s+bundle=([^\s]+))?"
    r"(?:\s+tier=([^\s]+))?"
    r"(?:\s+class=([^\s]+))?",
    re.IGNORECASE,
)

# Compile/build failure hints (aligned with failure_packet._BUILD_HINT_RE).
_BUILD_HINT_RE = re.compile(
    r"(error:|fatal error|compile|linker|undefined symbol|no such module|"
    r"verify\.sh.*lock|another verify|xcodebuild.*failed|"
    r"BUILD FAILED|Could not resolve|SwiftCompile|"
    r"missing its bundle executable|unable to install|"
    r"failed to install or launch|podwash encountered an error|"
    r"Testing cancelled because the build failed|cannot find)",
    re.IGNORECASE,
)
_COMPILE_ERROR_RE = re.compile(
    r"(?:^|\n)(?:[^\n]*?:\d+:\d+:\s*)?error:\s*(.+)",
    re.IGNORECASE,
)
_XCODEBUILD_ERROR_RE = re.compile(
    r"xcodebuild:\s*error:\s*(.+)",
    re.IGNORECASE,
)

# Pre-implement pipeline gates — TDD compile-red is expected.
AUTHORING_GATE_IDS = frozenset(
    {
        "story",
        "architect",
        "ux",
        "adr_review_qa",
        "adr_review_pm",
        "test_spec",
        "test_review",
    }
)

SLICE_HEADING_RE = re.compile(
    r"^#\s*Slice\s+(\d+)\s*[—–-]\s*(.+?)\s*$",
    re.MULTILINE,
)

# XCTest / xcodebuild crash lines, e.g.:
#   Crash: PodWash at AnalysisUIStateTests.testStateMachineTransitions()
#   PodWash crashed in testTogglePersistence
CRASH_LINE_RE = re.compile(
    r"(?:Crash:\s*(?:PodWash\s+)?at\s+([^\n]+))"
    r"|(?:PodWash\s+crashed[^\n]*)"
    r"|(?:Test Case\s+'.+?'\s+crashed[^\n]*)",
    re.IGNORECASE,
)

# XCTest / xcodebuild failure lines for slice-loop logging.
TEST_CASE_FAILED_RE = re.compile(
    r"Test Case '-\[(?P<cls>\S+)\s+(?P<method>\w+)\]' failed",
    re.IGNORECASE,
)
XCTASSERT_FAILED_RE = re.compile(
    r"(?P<detail>XCTAssert\w+ failed(?:\s*-\s*.+)?)",
    re.IGNORECASE,
)
TEST_EXEC_SUMMARY_RE = re.compile(
    r"Executed\s+(?P<total>\d+)\s+tests?,\s+with\s+(?P<failed>\d+)\s+failures?",
    re.IGNORECASE,
)

DIAGNOSTIC_REPORTS_DIR = os.path.expanduser("~/Library/Logs/DiagnosticReports")
PODWASH_IPS_GLOB = "PodWash-*.ips"

# After this many red verify/xcodebuild outcomes in one coordinator run, halt.
DEFAULT_MAX_RED_VERIFIES = 2

# Roles that must never be spawned to fix app/test failures.
_FIX_FORBIDDEN_ROLES = frozenset(
    {
        "UX",
        "PM",
        "PM review",
        "Architect",
        "Architect review",
    }
)
_FIX_INTENT_RE = re.compile(
    r"\b("
    r"fix|repair|debug|investigate|crash|failing|failure|red\s+test|"
    r"test\s+fail|ui\s+test|xctest|verify|implement|progress\s+ui|"
    r"accessibility\s+fix|make\s+green"
    r")\b",
    re.IGNORECASE,
)

ROLE_EDIT_PATHS: dict[str, str] = {
    "Engineer": "PodWash/PodWash/** only (no tests)",
    "QA": "PodWash/{PodWashTests,PodWashUITests,PodWashSlowTests}/** + slice docs",
    "QA review": "readonly — no edits",
    "UX": "docs/slices/** (+ UITest scenarios); MUST NOT edit app Swift",
    "Architect": "docs/adr/** (+ design notes)",
    "Architect review": "readonly — no edits",
    "PM": "docs/slices/** story/AC only",
    "PM review": "readonly — no edits",
    "Coordinator": "docs/slices status/VERIFY/plan-review lines only",
    "Subagent": "(unknown role — prefer named podwash-* subagents)",
}


class ThrashHalt(Exception):
    """Raised when the loop should stop grinding the same red verify."""

    def __init__(self, reason: str):
        self.reason = reason
        super().__init__(reason)


def normalize_tool_name(name: str) -> str:
    return (name or "").strip().lower()


def arg_path(args: dict[str, Any]) -> str:
    for key in ("path", "file", "file_path", "target_file"):
        val = args.get(key)
        if val:
            return short_path(str(val))
    return ""


def arg_shell_command(args: dict[str, Any]) -> str:
    for key in ("command", "description"):
        val = args.get(key)
        if val:
            return str(val).strip()
    return ""


def short_path(path: str, max_len: int = 52) -> str:
    if not path:
        return ""
    path = str(path)
    if len(path) <= max_len:
        return path
    return "…" + path[-(max_len - 1) :]


def raw_path(args: Any) -> str:
    if not isinstance(args, dict):
        return ""
    for key in ("path", "file", "file_path", "target_file"):
        val = args.get(key)
        if val:
            return str(val)
    return ""


def delegate_violation(path: str) -> tuple[str, str] | None:
    """If the coordinator must not edit path, return (role, subagent_id)."""
    if not path:
        return None
    p = path.replace("\\", "/")
    rules = (
        ("/PodWash/PodWash/", "Engineer", "podwash-engineer"),
        ("/PodWash/PodWashTests/", "QA", "podwash-qa"),
        ("/PodWash/PodWashUITests/", "QA", "podwash-qa"),
        ("/docs/adr/", "Architect", "podwash-architect"),
    )
    for marker, role, subagent in rules:
        if marker in p:
            return role, subagent
    return None


def is_verify_run(cmd: str) -> bool:
    """True only for real test runners — not xcresulttool / grep inspection."""
    if not cmd:
        return False
    c = cmd.strip()
    # Never treat result inspection as a verify attempt.
    if "xcresulttool" in c:
        return False
    if "verify.sh" in c:
        return True
    # xcodebuild … test (action), not merely a path containing "test".
    if "xcodebuild" in c and re.search(r"(?:^|[\s;|&])test(?:\s|$)", c):
        return True
    return False


def role_edit_paths(role: str) -> str:
    """Human-readable paths this role is allowed to edit."""
    return ROLE_EDIT_PATHS.get(role, ROLE_EDIT_PATHS["Subagent"])


def detect_wrong_role_spawn(role: str, description: str) -> str | None:
    """If a spawn asks a non-implementer to fix tests/app, return a warning.

    UX/PM/Architect must not be used for 'fix UI test' / crash / verify work —
    that is Engineer (app) or QA (tests).
    """
    role = (role or "").strip()
    desc = (description or "").strip()
    if not role or not desc:
        return None
    if role not in _FIX_FORBIDDEN_ROLES:
        return None
    if not _FIX_INTENT_RE.search(desc):
        return None
    return (
        f"{role} cannot fix app/tests — spawn podwash-engineer (app Swift) "
        f"or podwash-qa (test/fixture edits). Desc was: {desc[:80]}"
    )


def failure_signature(failures: list[str]) -> str:
    """Stable key for 'same failure ×N' tracking (prefer Class/method)."""
    if not failures:
        return ""
    first = re.sub(r"\s+", " ", failures[0].strip())
    # AnalysisProgressUITests/testProgressIndicatorLifecycle — …
    m = re.search(
        r"((?:PodWash\w*Tests|\w+Tests)/\w+|test\w+)",
        first,
        re.IGNORECASE,
    )
    if m:
        return m.group(1)
    # XCTAssertTrue failed → keep short
    if first.upper().startswith("CRASH"):
        return first[:80]
    if "XCTAssert" in first:
        return first[:80]
    return first[:80]


def infer_role(args: Any) -> str:
    if not isinstance(args, dict):
        return "Subagent"

    sub = str(args.get("subagent_type") or "").lower()
    if "podwash-pm" in sub:
        return "PM"
    if "podwash-qa" in sub:
        return "QA"
    if "podwash-ux" in sub:
        return "UX"
    if "podwash-architect" in sub:
        return "Architect"
    if "podwash-engineer" in sub or sub == "podwash-engineer":
        return "Engineer"

    desc = str(args.get("description") or "")
    prompt = str(args.get("prompt") or "")[:800]
    blob = f"{desc}\n{prompt}".lower()
    readonly = bool(args.get("readonly")) or "readonly" in blob

    if "architect agent" in blob or "adr-" in desc.lower() and "author" in blob:
        if readonly or "review" in blob:
            return "Architect review"
        return "Architect"
    if "engineer agent" in blob or "implement" in desc.lower():
        return "Engineer"
    if "qa agent" in blob:
        return "QA review" if readonly else "QA"
    if "pm agent" in blob:
        return "PM review" if readonly else "PM"
    if "ux agent" in blob:
        return "UX"

    desc_l = desc.lower()
    if desc_l.startswith("pm ") or " pm " in f" {desc_l} ":
        return "PM review" if readonly else "PM"
    if desc_l.startswith("qa ") or "test spec" in desc_l:
        return "QA review" if readonly else "QA"
    if "architect" in desc_l:
        return "Architect review" if readonly else "Architect"
    if "engineer" in desc_l or "implement" in desc_l:
        return "Engineer"
    if "ux " in desc_l or "ui test" in desc_l:
        return "UX"
    if "accessibility" in desc_l or "a11y" in desc_l:
        return "UX"

    return "Subagent"


def task_description(args: Any, max_len: int = 64) -> str:
    if not isinstance(args, dict):
        return "subagent work"
    desc = str(args.get("description") or "").strip()
    if desc:
        return desc[:max_len]
    prompt = str(args.get("prompt") or "").strip().split("\n", 1)[0]
    return (prompt[:max_len] if prompt else "subagent work")


def parse_verify_result(text: str) -> dict[str, str] | None:
    if not text:
        return None
    m = VERIFY_RESULT_RE.search(text)
    if not m:
        return None
    out = {
        "exit": m.group(1),
        "total": m.group(2),
        "passed": m.group(3),
        "failed": m.group(4),
        "skipped": m.group(5),
    }
    if m.group(6) is not None:
        out["filtered"] = m.group(6)
    if m.group(7) is not None:
        out["bundle"] = m.group(7)
    if m.lastindex and m.lastindex >= 8 and m.group(8) is not None:
        out["tier"] = m.group(8)
    if m.lastindex and m.lastindex >= 9 and m.group(9) is not None:
        out["class"] = m.group(9)
    return out


def _truncate_build_detail(detail: str, *, limit: int = 100) -> str:
    detail = re.sub(r"\s+", " ", (detail or "").strip())
    if len(detail) > limit:
        return detail[: limit - 1].rstrip() + "…"
    return detail


def extract_build_error(text: str) -> str | None:
    """Return ``build_error: <detail>`` when output looks like a compile/build fail."""
    if not text:
        return None
    for m in _COMPILE_ERROR_RE.finditer(text):
        detail = (m.group(1) or "").strip()
        # Skip XCTest assertion noise that also uses "error:"
        if not detail or detail.lower().startswith("xctassert"):
            continue
        return f"build_error: {_truncate_build_detail(detail)}"
    for m in _XCODEBUILD_ERROR_RE.finditer(text):
        detail = (m.group(1) or "").strip()
        if detail:
            return f"build_error: {_truncate_build_detail(detail)}"
    if (
        "** BUILD FAILED **" in text
        or "Testing cancelled because the build failed" in text
        or _BUILD_HINT_RE.search(text)
    ):
        # Only claim build when there is a strong build signal (not mere "error:")
        if (
            "** BUILD FAILED **" in text
            or "Testing cancelled because the build failed" in text
            or "SwiftCompile" in text
            or "cannot find" in text.lower()
        ):
            return "build_error: BUILD FAILED"
    return None


def looks_like_build_failure(
    text: str, verify: dict[str, str] | None = None
) -> bool:
    """True when verify/xcodebuild failed with no tests executed (compile-red)."""
    from failure_packet import is_artifact_fixture_failure, is_test_decode_assertion_blob

    blob = text or ""
    if is_artifact_fixture_failure(blob) or is_test_decode_assertion_blob(blob):
        return False
    if verify and verify.get("class") == "build":
        return True
    if verify:
        try:
            exit_code = int(verify.get("exit") or "0")
            total = verify.get("total") or "?"
            failed = verify.get("failed") or "?"
            total_n = int(total) if str(total).isdigit() else -1
            failed_n = int(failed) if str(failed).isdigit() else -1
            if exit_code != 0 and total_n == 0 and failed_n == 0:
                return True
            # Tests ran and failed — generic ``error:`` in decode assertions is not build.
            if exit_code != 0 and total_n > 0 and failed_n > 0:
                if is_artifact_fixture_failure(blob) or is_test_decode_assertion_blob(
                    blob
                ):
                    return False
        except ValueError:
            pass
    return extract_build_error(text) is not None


def enrich_build_failures(
    failures: list[str],
    output: str,
    verify: dict[str, str] | None = None,
) -> list[str]:
    """Ensure compile/scheme-red verify runs surface a ``build_error:`` line."""
    if any((f or "").startswith("build_error:") for f in failures):
        return list(failures)
    if not looks_like_build_failure(output, verify):
        return list(failures)
    detail = extract_build_error(output)
    if not detail:
        exit_code = (verify or {}).get("exit") or "?"
        detail = f"build_error: exit={exit_code} (0 tests executed)"
    return [detail, *failures]


def verify_is_green(v: dict[str, str] | None) -> bool:
    if not v:
        return False
    return v.get("exit") == "0" and v.get("failed") == "0" and v.get("skipped") == "0"


def _result_blob(result: Any) -> str:
    if isinstance(result, str):
        return result
    if isinstance(result, dict):
        return json.dumps(result)
    return str(result or "")


def detect_simulator_crashes(text: str, *, limit: int = 5) -> list[str]:
    """Extract distinct crash descriptors from verify/xcodebuild output."""
    if not text:
        return []
    found: list[str] = []
    seen: set[str] = set()
    for m in CRASH_LINE_RE.finditer(text):
        detail = (m.group(1) or m.group(0) or "").strip()
        detail = re.sub(r"\s+", " ", detail)
        if len(detail) > 96:
            detail = detail[:93] + "…"
        key = detail.lower()
        if not detail or key in seen:
            continue
        seen.add(key)
        found.append(detail)
        if len(found) >= limit:
            break
    return found


def detect_test_failures(text: str, *, limit: int = 8) -> list[str]:
    """Extract human-readable test failure lines from verify/xcodebuild output."""
    if not text:
        return []
    found: list[str] = []
    seen: set[str] = set()

    def add(item: str) -> None:
        item = re.sub(r"\s+", " ", item.strip())
        if len(item) > 140:
            item = item[:137] + "…"
        key = item.lower()
        if not item or key in seen:
            return
        seen.add(key)
        found.append(item)

    for m in CRASH_LINE_RE.finditer(text):
        target = (m.group(1) or m.group(0) or "").strip()
        if target:
            add(f"CRASH — {target}")

    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = TEST_CASE_FAILED_RE.search(line)
        if m:
            test_id = f"{m.group('cls')}/{m.group('method')}"
            detail = ""
            for follow in lines[i + 1 : i + 6]:
                xm = XCTASSERT_FAILED_RE.search(follow)
                if xm:
                    detail = xm.group("detail").strip()
                    break
                if follow.strip().startswith("error:"):
                    detail = follow.strip()[:100]
                    break
            add(f"{test_id} — {detail}" if detail else test_id)
            if len(found) >= limit:
                return found

        xm = XCTASSERT_FAILED_RE.search(line)
        if xm and "Test Case" not in line:
            add(xm.group("detail").strip())

    for m in TEST_EXEC_SUMMARY_RE.finditer(text):
        failed = int(m.group("failed"))
        if failed > 0:
            add(f"summary — {failed} failure(s) in run")

    if len(found) < limit:
        build = extract_build_error(text)
        if build:
            add(build)
            return found[:limit]

    if len(found) < limit and (
        "** TEST FAILED **" in text or ("TEST FAILED" in text and "TEST SUCCEEDED" not in text)
    ):
        # Opaque TEST FAILED with 0 executed tests → prefer build classification
        if "Executed 0 tests" in text or "Testing cancelled because the build failed" in text:
            add("build_error: BUILD FAILED")
        else:
            add("xcodebuild — TEST FAILED")

    return found[:limit]


def latest_xcresult_path(repo_root: str) -> str | None:
    """Newest verify-*.xcresult under build/test-results/."""
    import glob

    pattern = os.path.join(repo_root, "build", "test-results", "verify-*.xcresult")
    paths = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    return paths[0] if paths else None


def read_failures_from_xcresult(xcresult_path: str, *, limit: int = 8) -> list[str]:
    """Parse testFailures from an .xcresult summary (when shell output is sparse)."""
    import subprocess

    if not xcresult_path or not os.path.isdir(xcresult_path):
        return []
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
            timeout=15,
            check=False,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            return []
        data = json.loads(proc.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError, ValueError):
        return []

    out: list[str] = []
    for item in data.get("testFailures") or []:
        if not isinstance(item, dict):
            continue
        target = str(item.get("targetName") or "")
        name = str(item.get("testName") or item.get("testIdentifierString") or "")
        detail = str(item.get("failureText") or "").strip()
        detail = re.sub(r"\s+", " ", detail)
        if len(detail) > 100:
            detail = detail[:97] + "…"
        test_id = f"{target}/{name}" if target and name else (name or target or "unknown")
        line = f"{test_id} — {detail}" if detail else test_id
        out.append(line)
        if len(out) >= limit:
            break
    return out


def summarize_ips_crash(path: str) -> str:
    """Best-effort one-line summary from a PodWash .ips crash report."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            raw = fh.read(120_000)
    except OSError:
        return os.path.basename(path)

    # IPS format: optional first-line metadata JSON, then the crash JSON body.
    # Prefer the object that carries threads/exception (usually line 2+).
    data = _parse_ips_payload(raw)
    if not data:
        return os.path.basename(path)

    exc = data.get("exception") or {}
    exc_type = exc.get("type") or "CRASH"
    signal = exc.get("signal") or ""
    images = data.get("usedImages") or []
    triggered = data.get("faultingThread", 0)
    threads = data.get("threads") or []
    frames: list[Any] = []
    if isinstance(triggered, int) and 0 <= triggered < len(threads):
        frames = threads[triggered].get("frames") or []

    podwash_syms: list[str] = []
    for fr in frames[:24]:
        if not isinstance(fr, dict):
            continue
        idx = fr.get("imageIndex", -1)
        img = images[idx] if isinstance(idx, int) and 0 <= idx < len(images) else {}
        name = str(img.get("name") or img.get("path") or "")
        if "PodWash" not in name:
            continue
        sym = str(fr.get("symbol") or "").strip()
        if sym:
            podwash_syms.append(sym.split("(")[0].strip())
        if len(podwash_syms) >= 2:
            break

    where = " → ".join(podwash_syms) if podwash_syms else os.path.basename(path)
    sig = f"{exc_type}/{signal}" if signal else str(exc_type)
    return f"{sig} in {where}"


def _parse_ips_payload(raw: str) -> dict[str, Any] | None:
    """Parse IPS text into the crash JSON object (skip metadata preamble)."""
    decoder = json.JSONDecoder()
    candidates: list[dict[str, Any]] = []

    # Try whole-file and each newline-delimited JSON object.
    chunks = [raw]
    lines = raw.splitlines()
    if len(lines) > 1:
        chunks.append("\n".join(lines[1:]))
    for line in lines[:4]:
        if line.strip().startswith("{"):
            chunks.append(line)

    for chunk in chunks:
        text = chunk.lstrip()
        if not text.startswith("{"):
            continue
        try:
            obj, _ = decoder.raw_decode(text)
        except (json.JSONDecodeError, ValueError):
            continue
        if isinstance(obj, dict):
            candidates.append(obj)

    if not candidates:
        return None
    for obj in candidates:
        if obj.get("threads") or obj.get("exception"):
            return obj
    return candidates[-1]


def list_new_podwash_ips(since_mtime: float, *, reports_dir: str | None = None) -> list[str]:
    """Return PodWash .ips paths modified after ``since_mtime``, oldest first."""
    import glob

    root = reports_dir or DIAGNOSTIC_REPORTS_DIR
    paths = sorted(
        glob.glob(os.path.join(root, PODWASH_IPS_GLOB)),
        key=lambda p: os.path.getmtime(p),
    )
    out: list[str] = []
    for path in paths:
        try:
            if os.path.getmtime(path) > since_mtime:
                out.append(path)
        except OSError:
            continue
    return out


def shell_result_note(args: Any, result: Any) -> str:
    if not isinstance(args, dict):
        return ""
    cmd = arg_shell_command(args)
    if "verify.sh" not in cmd:
        if cmd.startswith("git commit"):
            return "committed"
        if cmd.startswith("git push"):
            return "pushed"
        return ""

    blob = _result_blob(result)
    crashes = detect_simulator_crashes(blob)
    failures = detect_test_failures(blob)
    crash_failures = [f for f in failures if f.upper().startswith("CRASH")]
    test_failures = [f for f in failures if not f.upper().startswith("CRASH")]
    v = parse_verify_result(blob)
    if v:
        if verify_is_green(v):
            return f"GREEN — {v['passed']}/{v['total']} passed, 0 failed, 0 skipped"
        note = f"RED — failed={v['failed']} skipped={v['skipped']}"
        if test_failures:
            note += f" · FAIL ×{len(test_failures)}"
        if crashes or crash_failures:
            note += f" · CRASH ×{max(len(crashes), len(crash_failures))}"
        return note
    if test_failures:
        return f"FAIL ×{len(test_failures)} — {test_failures[0]}"
    if crashes or crash_failures:
        n = max(len(crashes), len(crash_failures))
        sample = crashes[0] if crashes else crash_failures[0]
        return f"CRASH ×{n} — {sample}"
    if "** TEST FAILED **" in blob or "TEST FAILED" in blob:
        return "RED — TEST FAILED"
    return ""


def summarize_tool(name: str, args: Any, result: Any = None) -> str:
    if args is None:
        args = {}
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except json.JSONDecodeError:
            args = {}
    if not isinstance(args, dict):
        args = {}

    norm = normalize_tool_name(name)

    if norm in ("task", "agent"):
        role = infer_role(args)
        return f"spawn {role}: {task_description(args)}"

    if norm in ("edit", "strreplace", "write"):
        path = arg_path(args)
        verb = "write" if norm == "write" else "edit"
        return f"{verb} {path}" if path else f"{verb} file"

    if norm == "read":
        path = arg_path(args)
        return f"read {path}" if path else "read file"

    if norm == "delete":
        path = arg_path(args)
        return f"delete {path}" if path else "delete file"

    if norm == "shell":
        cmd = arg_shell_command(args)
        if not cmd:
            return "shell"
        line = cmd.split("\n", 1)[0].strip()
        if "verify.sh" in line:
            filtered = "filtered" if "-only-testing:" in cmd else "full suite"
            note = shell_result_note(args, result)
            base = f"verify.sh ({filtered})"
            return f"{base} — {note}" if note else base
        if "xcodebuild" in line and "test" in line:
            note = shell_result_note(args, result) if "verify.sh" in cmd else ""
            failures = detect_test_failures(_result_blob(result))
            if failures:
                return f"xcodebuild test — FAIL ×{len(failures)}: {failures[0][:60]}"
            if "** TEST SUCCEEDED **" in _result_blob(result):
                return "xcodebuild test — GREEN"
            if "** TEST FAILED **" in _result_blob(result):
                return "xcodebuild test — RED"
            return "xcodebuild test"
        if line.startswith("git commit"):
            return "git commit (slice)"
        if line.startswith("git push"):
            return "git push"
        if line.startswith("scripts/"):
            return line[:72]
        return f"shell: {line[:68]}"

    if norm == "grep":
        pat = str(args.get("pattern") or "")[:36]
        return f"grep '{pat}'" if pat else "grep"

    if norm == "glob":
        pat = str(args.get("glob_pattern") or args.get("pattern") or "")[:40]
        return f"glob {pat}" if pat else "glob"

    if norm in ("updatetodos", "todowrite", "todo_write"):
        todos = args.get("todos") or []
        if isinstance(todos, list) and todos:
            first = todos[0]
            if isinstance(first, dict):
                content = str(first.get("content") or first.get("id") or "")[:48]
                if content:
                    return f"gate checklist — {content}"
        return "update gate checklist"

    if norm:
        return norm
    return name or "tool"


def read_slice_meta(slice_file: str, repo_root: str) -> tuple[str, str]:
    """Return (title, relative path) from a slice markdown file."""
    rel = slice_file
    path = slice_file if os.path.isabs(slice_file) else os.path.join(repo_root, slice_file)
    title = os.path.splitext(os.path.basename(slice_file))[0].replace("-", " ")
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read(4096)
        m = SLICE_HEADING_RE.search(text)
        if m:
            title = m.group(2).strip()
    except OSError:
        pass
    return title, rel


def read_verify_from_slice(slice_file: str, repo_root: str) -> dict[str, str] | None:
    path = slice_file if os.path.isabs(slice_file) else os.path.join(repo_root, slice_file)
    try:
        with open(path, encoding="utf-8") as fh:
            return parse_verify_result(fh.read())
    except OSError:
        return None


def _read_slice_text(slice_file: str, repo_root: str) -> str:
    path = slice_file if os.path.isabs(slice_file) else os.path.join(repo_root, slice_file)
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def _status_from_text(text: str) -> str:
    for line in text.splitlines():
        if "| **Status** |" in line or "| **Status**|" in line:
            parts = [p.strip() for p in line.strip().strip("|").split("|")]
            if len(parts) >= 2:
                return parts[1]
    return ""


def _section_body(text: str, heading: str) -> str:
    """Return markdown body under ``## heading`` until the next ``## ``."""
    pat = re.compile(
        rf"^##\s+{re.escape(heading)}\s*$",
        re.MULTILINE | re.IGNORECASE,
    )
    m = pat.search(text)
    if not m:
        return ""
    rest = text[m.end() :]
    nxt = re.search(r"^##\s+", rest, re.MULTILINE)
    return rest[: nxt.start()] if nxt else rest


def _crux_from_table(text: str) -> str:
    for line in text.splitlines():
        if "| **Crux** |" in line or "| **Crux**|" in line:
            parts = [p.strip() for p in line.strip().strip("|").split("|")]
            if len(parts) >= 2:
                return parts[1]
    return ""


def _first_paragraph(body: str) -> str:
    """First non-empty prose line (skip tables, headings, bullets)."""
    for line in body.splitlines():
        s = line.strip()
        if not s or s.startswith("|") or s.startswith("#"):
            continue
        if s.startswith("- "):
            continue
        return s
    return ""


def _bullet_items(body: str) -> list[str]:
    items: list[str] = []
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("- "):
            items.append(s[2:].strip())
    return items


def _shorten_text(text: str, max_len: int) -> str:
    s = " ".join((text or "").split())
    if len(s) <= max_len:
        return s
    cut = s[: max_len - 1].rsplit(" ", 1)[0]
    return cut.rstrip(".,;:") + "…"


def _friendly_deliverable(line: str) -> str:
    s = re.sub(r"`([^`]+)`", r"\1", line.strip())
    if " — " in s:
        s = s.split(" — ", 1)[0].strip()
    return _shorten_text(s, 72)


def extract_slice_mission(slice_file: str, repo_root: str) -> str:
    """User-friendly summary of what this slice is trying to accomplish."""
    text = _read_slice_text(slice_file, repo_root)
    goal = _first_paragraph(_section_body(text, "Goal"))
    if goal:
        return _shorten_text(goal, 220)
    crux = _crux_from_table(text)
    if crux:
        return _shorten_text(crux, 220)
    title, _ = read_slice_meta(slice_file, repo_root)
    return title


def extract_slice_accomplishment(slice_file: str, repo_root: str) -> str:
    """Short description of what the slice delivers (for green wrap-up)."""
    text = _read_slice_text(slice_file, repo_root)
    bullets = _bullet_items(_section_body(text, "Deliverables"))
    if bullets:
        items = [_friendly_deliverable(b) for b in bullets[:3]]
        tail = "…" if len(bullets) > 3 else ""
        return "Shipped: " + "; ".join(items) + tail
    goal = _first_paragraph(_section_body(text, "Goal"))
    if goal:
        return "Completed: " + _shorten_text(goal, 200)
    title, _ = read_slice_meta(slice_file, repo_root)
    return f"Completed: {title}"


def _wrap_banner_text(prefix: str, text: str, *, width: int = 52) -> list[str]:
    """Wrap ``text`` for ASCII banners with a fixed prefix on the first line."""
    import textwrap

    if not text:
        return []
    body_width = max(20, width - len(prefix))
    chunks = textwrap.wrap(text, width=body_width)
    if not chunks:
        return []
    lines = [f"  {prefix}{chunks[0]}"]
    pad = " " * (2 + len(prefix))
    for chunk in chunks[1:]:
        lines.append(f"{pad}{chunk}")
    return lines


def _role_artifact_rows(text: str) -> list[dict[str, str]]:
    body = _section_body(text, "Role artifacts")
    rows: list[dict[str, str]] = []
    for line in body.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3:
            continue
        if cells[0].lower() in ("role", "----", "---") or set(cells[0]) <= {"-", " "}:
            continue
        rows.append({"role": cells[0], "gate": cells[1], "path": cells[2]})
    return rows


def _plan_review_line(text: str, prefix: str) -> str:
    for line in text.splitlines():
        if line.lower().startswith(prefix.lower()):
            return line.split(":", 1)[-1].strip() if ":" in line else line
    return ""


def _story_content_ok(text: str) -> bool:
    """True when Crux is non-empty and Acceptance criteria has checklist items.

    Does **not** require Status Ready+ — that is the harness/coordinator flip.
    """
    if not re.search(r"^\| \*\*Crux\*\* \|.+\|", text, re.MULTILINE):
        return False
    # Reject empty Crux cells like "| **Crux** | |" / "| **Crux** |  |"
    m = re.search(r"^\| \*\*Crux\*\* \|([^|]*)\|", text, re.MULTILINE)
    if not m or not m.group(1).strip():
        return False
    body = _section_body(text, "Acceptance criteria")
    return bool(re.search(r"^- \[[ xX]\]", body, re.MULTILINE))


def _story_done(text: str) -> bool:
    """Story gate satisfied: content ok and Status is Ready or later (not Draft)."""
    status = _status_from_text(text).lower()
    if status in ("", "draft"):
        return False
    return _story_content_ok(text)


def story_pending_reasons(text: str) -> list[str]:
    """Human-readable predicates that keep the story gate pending."""
    reasons: list[str] = []
    status = _status_from_text(text)
    status_l = status.lower()
    if status_l in ("", "draft"):
        reasons.append(f"Status is {status or '(empty)'} (need Ready+)")
    m = re.search(r"^\| \*\*Crux\*\* \|([^|]*)\|", text, re.MULTILINE)
    if not m or not m.group(1).strip():
        reasons.append("missing or empty Crux")
    body = _section_body(text, "Acceptance criteria")
    if not re.search(r"^- \[[ xX]\]", body, re.MULTILINE):
        reasons.append("no Acceptance criteria checkboxes")
    return reasons


def _review_cleared(value: str) -> bool:
    v = (value or "").strip().lower()
    if not v or v in ("(pending)", "pending"):
        return False
    return any(
        tok in v
        for tok in ("waived", "cleared", "no blockers", "approved", "pass", "ok —", "ok -")
    )


def _path_exists(repo_root: str, raw: str) -> bool:
    raw = (raw or "").strip().strip("`")
    if not raw or raw in ("—", "-", "n/a", "N/A"):
        return False
    # Take first path-like token (tables sometimes add notes after em-dash).
    token = re.split(r"\s+[—–-]\s+", raw, maxsplit=1)[0].strip().strip("`")
    token = token.split()[0] if token.split() else token
    if not token.endswith((".md", ".swift", ".json", ".txt", ".yml", ".yaml")):
        # ADR paths without extension notes still ok if they look like docs/
        if not token.startswith("docs/") and "/" not in token:
            return False
    path = token if os.path.isabs(token) else os.path.join(repo_root, token)
    return os.path.isfile(path)


_ARTIFACT_EXTENSIONS = (".md", ".swift", ".json", ".txt", ".yml", ".yaml", ".xcdatamodeld")


def _looks_like_artifact_path(token: str) -> bool:
    """True for file/repo paths — not inline type names like ``SettingsStore``."""
    token = (token or "").strip().strip("`")
    if not token or token in ("—", "-", "n/a", "N/A"):
        return False
    if "/" in token or token.startswith("docs/"):
        return True
    return token.endswith(_ARTIFACT_EXTENSIONS)


def _artifact_paths_from_cell(raw: str) -> list[str]:
    """Backtick tokens from a Role-artifacts cell that look like paths on disk."""
    return [p for p in _extract_backtick_paths(raw or "") if _looks_like_artifact_path(p)]


def artifact_cell_satisfied(repo_root: str, raw: str) -> bool:
    """True when every backtick path in a Role-artifacts cell exists on disk.

    Slice tables often list multiple artifacts in one cell, e.g.
    ``007.md`` (stack) + ``009.md`` (APIs). ``_path_exists`` only checks the
    first token — use this for gate FSM rows. Inline type names in backticks
    (e.g. ``SettingsStore`` API) are ignored.
    """
    paths = _artifact_paths_from_cell(raw)
    if paths:
        return all(_path_exists(repo_root, p) for p in paths)
    return _path_exists(repo_root, raw)


def missing_artifact_paths(repo_root: str, raw: str) -> list[str]:
    """Backtick paths from a cell that are not yet on disk."""
    paths = _artifact_paths_from_cell(raw)
    if not paths:
        return [] if _path_exists(repo_root, raw) else [raw.strip()]
    return [p for p in paths if not _path_exists(repo_root, p)]


def _extract_backtick_paths(text: str) -> list[str]:
    return re.findall(r"`([^`]+)`", text or "")


def _verification_mapping_filled(text: str) -> bool:
    body = _section_body(text, "Verification mapping")
    for line in body.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3:
            continue
        if cells[0].lower() in ("ac#", "ac") or set(cells[0]) <= {"-", " "}:
            continue
        method = cells[2] if len(cells) > 2 else ""
        test_file = cells[1] if len(cells) > 1 else ""
        if method and method not in ("—", "-", "(pending)", "TBD", "…", "..."):
            if "test" in method.lower() or method.endswith("()") or "`" in line:
                return True
        if test_file.endswith(".swift") and "Test" in test_file:
            return True
    return False


def _mapped_test_files_exist(text: str, repo_root: str) -> bool:
    body = _section_body(text, "Verification mapping")
    found_any = False
    for line in body.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip().strip("`") for c in line.strip().strip("|").split("|")]
        if len(cells) < 2:
            continue
        tf = cells[1]
        if not tf.endswith(".swift"):
            continue
        found_any = True
        if not _path_exists(repo_root, tf):
            return False
    return found_any


def _implement_artifacts_exist(text: str, repo_root: str) -> bool:
    """True when at least one app deliverable path is on disk."""
    deliverables = _section_body(text, "Deliverables")
    candidates = _extract_backtick_paths(deliverables)
    # Bare Foo.swift mentions in deliverables bullets.
    candidates += re.findall(
        r"\b([A-Za-z][A-Za-z0-9]+(?:View|ViewModel|Store|State|Engine|Pipeline|Analyzer|Fixture)[A-Za-z0-9]*\.swift)\b",
        deliverables,
    )
    # Type names without .swift (common in deliverables): `AnalysisUIViewModel`
    candidates += re.findall(
        r"\b([A-Za-z][A-Za-z0-9]*(?:ViewModel|View|Store|Pipeline|Analyzer|Fixture|Engine|State))\b",
        deliverables,
    )

    def looks_like_app(path: str) -> bool:
        norm = path.replace("\\", "/")
        if any(x in norm for x in ("Tests/", "UITests/", "SlowTests/", "PodWashTests")):
            return False
        return True

    for c in candidates:
        c = c.strip().strip("`")
        if not c:
            continue
        if not c.endswith(".swift"):
            c = f"{c}.swift"
        if not looks_like_app(c):
            continue
        if "/" not in c:
            c = f"PodWash/PodWash/{c}"
        if _path_exists(repo_root, c):
            return True

    for c in _extract_backtick_paths(text):
        norm = c.replace("\\", "/")
        if (
            "PodWash/PodWash/" in norm
            and norm.endswith(".swift")
            and looks_like_app(norm)
            and _path_exists(repo_root, c)
        ):
            return True
    return False


def assess_slice_gates(slice_file: str, repo_root: str) -> dict[str, Any]:
    """Heuristic gate checklist for progress logs (not a Done authority).

    Returns dict with keys: gates (list), done, total, next, summary.
    Waived gates count as done. Skipped (N/A) gates are omitted from total.
    """
    text = _read_slice_text(slice_file, repo_root)
    status = _status_from_text(text)
    status_l = status.lower()
    verify = parse_verify_result(text)
    green = verify_is_green(verify)

    rows = _role_artifact_rows(text)
    arch_row = next((r for r in rows if "architect" in r["role"].lower()), None)
    ux_row = next(
        (r for r in rows if r["role"].strip().lower() == "ux"),
        None,
    )

    def role_done(row: dict[str, str] | None) -> tuple[bool, bool]:
        """Return (done, applicable). Missing row ⇒ not applicable."""
        if row is None:
            return True, False
        gate = row["gate"].lower()
        if "waiv" in gate:
            return True, True
        path = row["path"]
        if artifact_cell_satisfied(repo_root, path):
            return True, True
        if "accepted" in gate or "(done)" in gate or "done)" in path.lower():
            return True, True
        return False, True

    arch_done, arch_on = role_done(arch_row)
    ux_done, ux_on = role_done(ux_row)

    adr_line = _plan_review_line(text, "ADR review")
    # Architect waived ⇒ ADR review auto-cleared / still shown as done.
    if arch_row and "waiv" in arch_row["gate"].lower():
        adr_done, adr_on = True, True
    elif not arch_on:
        adr_done, adr_on = True, False
    else:
        adr_done = _review_cleared(adr_line) or "waiv" in (adr_line or "").lower()
        adr_on = True

    test_spec_done = _verification_mapping_filled(text) or _mapped_test_files_exist(
        text, repo_root
    )
    tsr_line = _plan_review_line(text, "Test spec review")
    test_review_done = _review_cleared(tsr_line)

    # Same predicate as assess_gate_state / _story_done — never show next:ux
    # while Status is still Draft.
    story_done = _story_done(text)
    implement_done = _implement_artifacts_exist(text, repo_root) or status_l in (
        "verify",
        "done",
    )
    verify_done = green
    commit_done = status_l == "done" and green

    gates: list[dict[str, Any]] = []

    def add(gid: str, label: str, done: bool, applicable: bool = True) -> None:
        if not applicable:
            return
        gates.append({"id": gid, "label": label, "done": bool(done)})

    add("story", "story", story_done)
    add("architect", "architect", arch_done, arch_on)
    add("ux", "ux", ux_done, ux_on)
    add("adr_review", "ADR review", adr_done, adr_on)
    add("test_spec", "test spec", test_spec_done)
    add("test_review", "test-spec review", test_review_done)
    add("implement", "implement", implement_done)
    add("verify", "verify", verify_done)
    add("commit", "commit", commit_done)

    done_n = sum(1 for g in gates if g["done"])
    total = len(gates)
    nxt = next((g["label"] for g in gates if not g["done"]), "done")
    bar_done = "█" * done_n
    bar_todo = "░" * (total - done_n)
    summary = f"gates {done_n}/{total} {bar_done}{bar_todo} · next: {nxt}"
    return {
        "gates": gates,
        "done": done_n,
        "total": total,
        "next": nxt,
        "summary": summary,
        "status": status,
    }


def format_gate_detail(progress: dict[str, Any]) -> str:
    """Compact checklist: story✓ ux✓ test_spec✓ implement· verify· …"""
    parts: list[str] = []
    for g in progress.get("gates") or []:
        mark = "✓" if g.get("done") else "·"
        parts.append(f"{g['label']}{mark}")
    return " ".join(parts)


def format_elapsed(seconds: int) -> str:
    if seconds < 60:
        return f"{seconds}s"
    mins, secs = divmod(seconds, 60)
    if mins < 60:
        return f"{mins}m {secs}s"
    hours, mins = divmod(mins, 60)
    return f"{hours}h {mins}m {secs}s"


def sniff_background_build() -> str | None:
    """Best-effort: is xcodebuild/verify.sh running for PodWash right now?"""
    import subprocess

    try:
        proc = subprocess.run(
            ["ps", "aux"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    for line in proc.stdout.splitlines():
        if "PodWash" not in line:
            continue
        if "verify.sh" in line and "grep" not in line:
            filtered = "filtered" if "-only-testing:" in line else "full suite"
            return f"verify.sh ({filtered})"
        if "xcodebuild" in line and "test" in line:
            m = re.search(r"-only-testing:([^\s]+)", line)
            if m:
                target = m.group(1).split("/")[-1][:48]
                return f"xcodebuild ({target})"
            return "xcodebuild (tests)"
    return None


def format_active_tasks(
    tasks: list[dict[str, Any]], *, now: float | None = None
) -> str:
    """Human-readable summary of in-flight subagent Tasks."""
    import time

    now = now if now is not None else time.time()
    if not tasks:
        return ""
    parts: list[str] = []
    # Longest-running first so the heartbeat highlights the slow one.
    ordered = sorted(
        tasks,
        key=lambda t: float(t.get("started_at") or 0),
    )
    for t in ordered:
        role = str(t.get("role") or "Subagent")
        desc = str(t.get("desc") or "working")[:52]
        started = float(t.get("started_at") or now)
        elapsed = format_elapsed(max(0, int(now - started)))
        parts.append(f"{role}: {desc} ({elapsed})")
    return " · ".join(parts)


def slice_start_banner(
    slice_id: int,
    title: str,
    slice_file: str,
    *,
    mission: str | None = None,
) -> str:
    line = f"  SLICE {slice_id:02d} — {title}"
    border = "═" * max(54, len(line) + 2)
    parts = [f"\n{border}", line, f"  {slice_file}"]
    if mission:
        parts.extend(_wrap_banner_text("→ ", mission))
    parts.append(border)
    return "\n".join(parts)


def _banner_line(text: str, width: int = 56) -> str:
    return f"║  {text:<{width}}║"


def _wrap_done_accomplishment(text: str, width: int = 56) -> list[str]:
    import textwrap

    if not text:
        return []
    return textwrap.wrap(text, width=width)


def slice_done_banner(
    slice_id: int,
    title: str,
    verify: dict[str, str] | None,
    elapsed_secs: int,
    session: tuple[int, int] | None = None,
    *,
    accomplishment: str | None = None,
) -> str:
    green = verify_is_green(verify)
    if green:
        headline = f"✓  SLICE {slice_id:02d} DONE — ALL TESTS PASSED"
        emoji = "🎉"
    else:
        headline = f"!  SLICE {slice_id:02d} FINISHED — verify not confirmed green"
        emoji = ""

    lines = [
        "",
        "╔" + "═" * 58 + "╗",
        _banner_line(headline),
        _banner_line(title),
    ]
    if accomplishment and green:
        for wrapped in _wrap_done_accomplishment(accomplishment):
            lines.append(_banner_line(wrapped))
    if verify:
        detail = (
            f"VERIFY: exit={verify['exit']}  passed={verify['passed']}  "
            f"failed={verify['failed']}  skipped={verify['skipped']}"
        )
        lines.append(_banner_line(detail))
    else:
        lines.append(_banner_line("(no VERIFY RESULT in slice file yet)"))
    lines.append(_banner_line(f"elapsed: {format_elapsed(elapsed_secs)}"))
    if session:
        lines.append(_banner_line(f"session: {session[0]}/{session[1]} slices this run"))
    if green:
        lines.append(_banner_line(""))
        lines.append(_banner_line(f"{emoji}  Forge gate cleared — safe to advance queue."))
    lines.append("╚" + "═" * 58 + "╝")
    lines.append("")
    return "\n".join(lines)


class RunProgress:
    """Concise, role-aware terminal progress for one slice coordinator run."""

    def __init__(
        self,
        slice_id: int,
        slice_title: str,
        slice_file: str,
        log_fn,
        verbose: bool = False,
        heartbeat_secs: int = 90,
        repo_root: str | None = None,
        max_red_verifies: int = DEFAULT_MAX_RED_VERIFIES,
        forced_role: str | None = None,
        agent_name: str | None = None,
        fix_worker: bool = False,
        authoring_gate: bool = False,
        gate_id: str | None = None,
        event_log: Any | None = None,
    ):
        self.slice_id = slice_id
        self.slice_title = slice_title
        self.slice_file = slice_file
        self.log = log_fn
        self.verbose = verbose
        self.heartbeat_secs = heartbeat_secs
        self.repo_root = repo_root or os.getcwd()
        # Fix workers: disable nested red-verify thrash (loop owns budget).
        if fix_worker:
            self.max_red_verifies = 0
        else:
            self.max_red_verifies = max(1, int(max_red_verifies))
        self.forced_role = (forced_role or "").strip() or None
        self.agent_name = (agent_name or "").strip() or None
        self.fix_worker = bool(fix_worker)
        self.authoring_gate = bool(authoring_gate)
        self.gate_id = (gate_id or "").strip() or None
        self._event_log = event_log
        self.last_activity = 0.0
        self.last_label = "coordinator starting"
        self._seen_starts: set[str] = set()
        # call_id → {role, desc, started_at} — source of truth for active role
        # (LIFO stack breaks when Architect+Engineer run in parallel).
        self._active_tasks: dict[str, dict[str, Any]] = {}
        self._stop = None
        self._thread = None
        self._last_verify: dict[str, str] | None = None
        self._run_started_at = 0.0
        self._announced_ips: set[str] = set()
        self._announced_crash_keys: set[str] = set()
        self._announced_failure_keys: set[str] = set()
        self._crash_watch_enabled = True
        self._last_long_idle_warn = 0.0
        self._last_gate_summary: str | None = None
        self._gate_log_counter = 0
        # call_id → {label, started_at} for coordinator shell/edit tools still running
        self._active_shell: dict[str, dict[str, Any]] = {}
        # Anti-thrash: same red verify signature ×N → halt
        self._red_verify_count = 0
        self._last_failure_sig = ""
        self._same_failure_streak = 0
        self._known_failing_test = ""
        self._halt_reason: str | None = None
        self._wrong_role_warned: set[str] = set()
        self.halted = False
        # Verify-ban (fix workers + authoring gates)
        self._bound_run: Any = None
        self._verify_violations = 0
        self.verify_violation_burned = False
        self._reprompt_pending = False
        self._authoring_red_logged = False
        self.assistant_text = ""
        self._files_touched: list[str] = []

    def bind_run(self, run: Any) -> None:
        self._bound_run = run

    def set_assistant_text(self, text: str) -> None:
        self.assistant_text = text or ""

    def append_assistant_text(self, text: str) -> None:
        t = (text or "").strip()
        if not t:
            return
        if self.assistant_text:
            self.assistant_text = self.assistant_text + "\n" + t
        else:
            self.assistant_text = t

    def refresh_gates(self) -> dict[str, Any]:
        return assess_slice_gates(self.slice_file, self.repo_root)

    def log_gate_progress(self, *, force: bool = False, detail: bool = False) -> None:
        """Print ``gates N/M … · next: …`` when the checklist changes (or forced)."""
        try:
            info = self.refresh_gates()
        except OSError:
            return
        summary = str(info.get("summary") or "")
        if not force and summary == self._last_gate_summary:
            return
        self._last_gate_summary = summary
        self.log(f"📋 [{self.slice_tag()}] {summary}")
        if detail:
            self.log(f"   [{self.slice_tag()}] {format_gate_detail(info)}")

    def slice_tag(self) -> str:
        return f"slice {self.slice_id:02d}"

    def active_role(self) -> str:
        """Role shown in progress lines — prefers long-running workers when parallel."""
        if not self._active_tasks:
            return self.forced_role or "Coordinator"
        roles = [str(t.get("role") or "Subagent") for t in self._active_tasks.values()]
        # Prefer implement/verify over short readonly reviews when both are open.
        for preferred in (
            "Engineer",
            "QA",
            "QA review",
            "Architect",
            "Architect review",
            "PM",
            "PM review",
            "UX",
            "Subagent",
        ):
            if preferred in roles:
                return preferred
        # Fall back to most recently started.
        newest = max(
            self._active_tasks.values(),
            key=lambda t: float(t.get("started_at") or 0),
        )
        return str(newest.get("role") or "Subagent")

    def active_roles_label(self) -> str:
        """Heartbeat label when multiple subagents are in flight."""
        if not self._active_tasks:
            return self.forced_role or "Coordinator"
        roles = [str(t.get("role") or "Subagent") for t in self._active_tasks.values()]
        primary = self.active_role()
        others = [r for r in roles if r != primary]
        if not others:
            return primary
        return f"{primary} (+{len(others)} parallel)"

    def prefix(self) -> str:
        role = self.active_role()
        if self.agent_name:
            from factory_narrator import format_agent_label

            base = self.forced_role or role.split(" (+")[0]
            label = format_agent_label(base, self.agent_name)
        else:
            label = role
        return f"[{self.slice_tag()}][{label}]"

    def _primary_active_task(self) -> dict[str, Any] | None:
        if not self._active_tasks:
            return None
        preferred = self.active_role()
        for t in self._active_tasks.values():
            if t.get("role") == preferred:
                return t
        return max(
            self._active_tasks.values(),
            key=lambda t: float(t.get("started_at") or 0),
        )

    def format_work_status(self) -> str:
        """One-line status for heartbeats: what's running now."""
        import time

        now = time.time()
        bits: list[str] = []

        bg = sniff_background_build()
        if bg:
            bits.append(f"🧪 {bg}")

        shell_bits: list[str] = []
        for t in sorted(
            self._active_shell.values(),
            key=lambda x: float(x.get("started_at") or 0),
        ):
            label = str(t.get("label") or "shell")
            elapsed = format_elapsed(max(0, int(now - float(t.get("started_at") or now))))
            shell_bits.append(f"{label} ({elapsed})")
        if shell_bits:
            bits.append("⚙ " + " · ".join(shell_bits[:2]))

        task_line = format_active_tasks(list(self._active_tasks.values()), now=now)
        if task_line:
            bits.append(f"▶ {task_line}")

        if bits:
            status = " · ".join(bits)
            if self._known_failing_test:
                streak = (
                    f" ×{self._same_failure_streak}"
                    if self._same_failure_streak > 1
                    else ""
                )
                status += f" · ❌ {self._known_failing_test}{streak}"
            return status

        quiet = int(now - self.last_activity)
        fail_bit = ""
        if self._known_failing_test:
            streak = (
                f" ×{self._same_failure_streak}"
                if self._same_failure_streak > 1
                else ""
            )
            fail_bit = f" · ❌ {self._known_failing_test}{streak}"
        if quiet < 30:
            return f"last: {self.last_label}{fail_bit}"
        if self.agent_name and self.forced_role:
            from factory_narrator import FACTORY_NAME, format_agent_label

            who = format_agent_label(self.forced_role, self.agent_name)
            return (
                f"{FACTORY_NAME} · {self.slice_tag()} · {who} · "
                f"{format_elapsed(quiet)}{fail_bit}"
            )
        return (
            f"coordinator quiet {format_elapsed(quiet)} · "
            f"last: {self.last_label}{fail_bit}"
        )
    def start(self):
        import threading
        import time

        self.last_activity = time.time()
        self._run_started_at = self.last_activity
        # Gate bar is a story checkpoint after clear — not on every worker start.
        if self.heartbeat_secs > 0:
            self._stop = threading.Event()
            self._thread = threading.Thread(target=self._heartbeat, daemon=True)
            self._thread.start()

    def stop(self):
        if self._stop:
            self._stop.set()
        # Gate bar printed by pipeline after clear — not on every stop.

    def _heartbeat(self):
        import time

        while not self._stop.wait(self.heartbeat_secs):
            self._scan_diagnostic_reports()
            self._gate_log_counter += 1
            if self._gate_log_counter % 2 == 0:
                self.log_gate_progress()
            role_label = self.active_roles_label()
            work = self.format_work_status()
            # Don't re-print the gates bar every heartbeat — chapter/clear owns that.
            self.log(f"⏳ [{self.slice_tag()}][{role_label}] {work}")
            now = time.time()
            has_workers = bool(
                self._active_tasks or self._active_shell or sniff_background_build()
            )
            # Warn when a single subagent has been quiet a very long time.
            primary = self._primary_active_task()
            if primary:
                running_for = int(now - float(primary.get("started_at") or now))
                if running_for >= 600 and (now - self._last_long_idle_warn) >= 600:
                    self._last_long_idle_warn = now
                    role = primary.get("role", "Subagent")
                    desc = primary.get("desc", "working")
                    self.log(
                        f"⏳ [{self.slice_tag()}] long subagent run ({format_elapsed(running_for)}) — "
                        f"{role}: {desc}. Normal for verify/Engineer/UX; bridge timeout is disabled."
                    )
            elif not has_workers:
                quiet = int(now - self.last_activity)
                if quiet >= 600 and (now - self._last_long_idle_warn) >= 600:
                    self._last_long_idle_warn = now
                    self.log(
                        f"⏳ [{self.slice_tag()}] Forge quiet {format_elapsed(quiet)} — "
                        f"no subagent Task open. Last: {self.last_label}"
                    )

    def _announce_crashes(self, crashes: list[str], *, source: str) -> None:
        """Log that a simulator crash was observed and is being investigated."""
        if not crashes:
            return
        fresh = [c for c in crashes if c.lower() not in self._announced_crash_keys]
        if not fresh:
            return
        for c in fresh:
            self._announced_crash_keys.add(c.lower())
        sample = fresh[0]
        extra = f" (+{len(fresh) - 1} more)" if len(fresh) > 1 else ""
        self.log(
            f"💥 {self.prefix()} SIMULATOR CRASH detected ({source}): {sample}{extra}"
        )
        self.log(
            f"🔎 {self.prefix()} investigating crash — "
            f"spawn podwash-engineer if not already fixing "
            f"(do not ignore; parse stack / DiagnosticReports)"
        )
        self.note(f"💥 crash: {sample[:60]}")

    def _announce_test_failures(self, failures: list[str], *, source: str) -> None:
        """Log XCTest failures so red verify runs are visible in slice-loop output."""
        if not failures:
            return
        sig = failure_signature(failures)
        if sig:
            if sig == self._last_failure_sig:
                self._same_failure_streak += 1
            else:
                self._last_failure_sig = sig
                self._same_failure_streak = 1
            self._known_failing_test = sig

        fresh = [f for f in failures if f.lower() not in self._announced_failure_keys]
        if fresh:
            for f in fresh:
                self._announced_failure_keys.add(f.lower())
            self.log(
                f"❌ {self.prefix()} TEST FAIL ({source}) — {fresh[0]}"
                + (f" (+{len(fresh) - 1} more)" if len(fresh) > 1 else "")
            )
            for extra in fresh[1:3]:
                self.log(f"   {self.prefix()} ↳ {extra}")
            self.note(f"❌ fail: {fresh[0][:60]}")
        elif self._same_failure_streak > 1 and sig:
            self.log(
                f"🔁 {self.prefix()} same failure ×{self._same_failure_streak} — {sig}"
            )
            self.note(f"🔁 same fail ×{self._same_failure_streak}: {sig[:50]}")

    def _clear_failure_streak(self) -> None:
        self._red_verify_count = 0
        self._same_failure_streak = 0
        self._last_failure_sig = ""
        self._known_failing_test = ""

    def _record_red_verify(
        self, failures: list[str], *, cmd: str, blob: str, verify: dict[str, str] | None
    ) -> None:
        """Count red verify/xcodebuild outcomes; halt after max_red_verifies."""
        if not is_verify_run(cmd):
            return
        # Fix workers: loop owns thrash budget — never nest halt here.
        if self.fix_worker or self.max_red_verifies <= 0:
            return
        # Authoring gates: TDD compile-red is expected — never count or halt.
        if self.authoring_gate:
            if not self._authoring_red_logged:
                self._authoring_red_logged = True
                self.log(
                    f"ℹ {self.prefix()} authoring-phase red verify ignored "
                    "(TDD compile-red expected until Engineer implements)"
                )
            return

        if verify and verify_is_green(verify):
            self._clear_failure_streak()
            return

        red = bool(failures) or (
            verify is not None and not verify_is_green(verify)
        ) or ("** TEST FAILED **" in blob) or (
            "TEST FAILED" in blob and "TEST SUCCEEDED" not in blob
        )
        if not red:
            return

        self._red_verify_count += 1
        sig = (
            self._known_failing_test
            or failure_signature(failures)
            or "unknown failure"
        )
        if not self._known_failing_test and sig != "unknown failure":
            self._known_failing_test = sig
        self.log(
            f"📉 {self.prefix()} red verify {self._red_verify_count}/"
            f"{self.max_red_verifies} — {sig}"
        )
        if self._red_verify_count < self.max_red_verifies:
            remaining = self.max_red_verifies - self._red_verify_count
            self.log(
                f"   {self.prefix()} {remaining} retry left — spawn podwash-engineer "
                f"(app) or podwash-qa (tests); do NOT spawn UX/PM to fix"
            )
            return

        pre_implement = bool(
            self.authoring_gate
            or (self.gate_id and self.gate_id in AUTHORING_GATE_IDS)
        )
        if pre_implement:
            next_hint = (
                "Next: complete test-spec review, then Engineer implement "
                "(do not blind-reverify TDD compile-red)."
            )
        else:
            next_hint = (
                "Next: kill any leftover xcodebuild, inspect the failing test, spawn "
                "podwash-engineer (app Swift) or podwash-qa (test edits) in a fresh "
                "session, then re-run scripts/slice-loop.sh."
            )
        self._halt_for_thrash(
            "HALT: red verify limit reached "
            f"({self._red_verify_count}/{self.max_red_verifies}). "
            f"Stuck on: {sig}. "
            "What happened: the same (or successive) verify/xcodebuild runs stayed "
            "RED without reaching Done. The loop stops so agents cannot grind "
            f"filtered UI tests for hours. {next_hint}"
        )

    def _cancel_bound_run(self) -> None:
        run = self._bound_run
        if run is not None and hasattr(run, "supports") and run.supports("cancel"):
            try:
                run.cancel()
            except Exception as exc:  # noqa: BLE001 — best-effort cancel
                self.log(f"   {self.prefix()} cancel failed: {exc}")
        elif run is not None and hasattr(run, "cancel"):
            try:
                run.cancel()
            except Exception as exc:  # noqa: BLE001
                self.log(f"   {self.prefix()} cancel failed: {exc}")

    def _handle_verify_ban(self, cmd: str) -> bool:
        """Cancel verify during fix workers / authoring gates.

        Fix workers: first violation re-prompts; second burns the attempt.
        Authoring gates: cancel and continue — never burn budget (TDD red expected).

        Returns True if the shell event was handled as a violation.
        """
        if not is_verify_run(cmd):
            return False
        if not (self.fix_worker or self.authoring_gate):
            return False

        self._verify_violations += 1

        if self.authoring_gate:
            self.log(
                f"⚠ {self.prefix()} AUTHORING VERIFY BAN: TDD red is expected — "
                f"do not verify during test-spec; end your turn when tests are "
                f"written (violation {self._verify_violations})"
            )
            self._cancel_bound_run()
            # Never burn authoring budget — cancel and let the worker finish.
            return True

        self.log(
            f"⚠ {self.prefix()} WORKER VIOLATION: verify owned by loop — "
            f"do not run verify.sh / xcodebuild test (violation "
            f"{self._verify_violations})"
        )
        self._cancel_bound_run()

        if self._verify_violations == 1:
            self._reprompt_pending = True
            self.log(
                f"   {self.prefix()} re-prompt: continue the fix without verifying; "
                f"loop will verify after you end your turn"
            )
            return True

        self.verify_violation_burned = True
        self.log(
            f"   {self.prefix()} second verify violation — attempt burned"
        )
        return True

    def _halt_for_thrash(self, reason: str) -> None:
        """Log a clear halt explanation, leave artifacts, raise ThrashHalt."""
        if self.halted:
            raise ThrashHalt(self._halt_reason or reason)
        self.halted = True
        self._halt_reason = reason
        sig = self._known_failing_test or self._last_failure_sig or ""
        gate = self.gate_id or ("authoring" if self.authoring_gate else "post-implement")

        card = (
            f"THRASH HALT — Slice {self.slice_id:02d}\n"
            f"Gate: {gate}\n"
            f"Signature: {sig or '(unknown)'}\n"
            f"{reason}\n"
        )
        try:
            from failure_packet import persist_stuck_card
            from session_bundle import write_session_bundle

            persist_stuck_card(
                card, repo_root=self.repo_root, slice_file=self.slice_file
            )
            bundle_dir = write_session_bundle(
                repo_root=self.repo_root,
                slice_id=self.slice_id,
                reason=reason,
                stuck_card=card,
                verify_result=self._last_verify,
                failures=[sig] if sig else [],
                phase="HALT",
                extra={"gate": gate, "signature": sig},
            )
            self.log(f"   {self.prefix()} session bundle: {bundle_dir}")
        except Exception as exc:  # noqa: BLE001 — halt must still raise
            self.log(f"   {self.prefix()} halt artifact write failed: {exc}")

        if self._event_log is not None:
            try:
                self._event_log.record(
                    "HALT",
                    self.active_role(),
                    "thrash_halt",
                    detail={
                        "reason": reason,
                        "gate": gate,
                        "signature": sig,
                    },
                    timeline=True,
                    mission="thrash halt",
                )
            except Exception as exc:  # noqa: BLE001
                self.log(f"   {self.prefix()} HALT event log failed: {exc}")

        self.log(f"🛑 [{self.slice_tag()}] {reason}")
        self.log(
            f"🛑 [{self.slice_tag()}] loop stopping — disk work is preserved; "
            "restart after a real fix (Engineer/QA), not another blind verify."
        )
        self.note("🛑 thrash halt")
        raise ThrashHalt(reason)

    def _collect_test_failures(self, blob: str, cmd: str) -> list[str]:
        failures = detect_test_failures(blob)
        if failures:
            return failures
        redish = (
            is_verify_run(cmd)
            or "xcresulttool" in cmd
            or "** TEST FAILED **" in blob
            or "TEST FAILED" in blob
            or "** BUILD FAILED **" in blob
        )
        if not redish:
            return []
        xc = latest_xcresult_path(self.repo_root)
        if xc:
            return read_failures_from_xcresult(xc)
        return []
    def _scan_diagnostic_reports(self) -> None:
        if not self._crash_watch_enabled or not self._run_started_at:
            return
        new_paths = list_new_podwash_ips(self._run_started_at)
        for path in new_paths:
            if path in self._announced_ips:
                continue
            self._announced_ips.add(path)
            summary = summarize_ips_crash(path)
            self._announce_crashes([summary], source=os.path.basename(path))

    def note(self, label: str):
        import time

        self.last_activity = time.time()
        self.last_label = label

    def handle(self, message):
        if isinstance(message, dict):
            mtype = message.get("type")
            if mtype == "tool_call":
                self._tool(
                    message.get("callId") or message.get("call_id", ""),
                    message.get("name", "tool"),
                    message.get("status", ""),
                    message.get("args"),
                    message.get("result"),
                )
            elif mtype == "task":
                self._task(message.get("status", ""), message.get("text", ""))
            elif mtype == "status":
                self._status(message.get("message") or message.get("status", ""))
            elif mtype == "assistant":
                # Always accumulate diagnose/fix assistant text (not only verbose).
                self._capture_assistant_dict(message)
                if self.verbose:
                    self._assistant_dict(message)
            return

        mtype = getattr(message, "type", None)
        if mtype == "tool_call":
            self._tool(
                getattr(message, "call_id", ""),
                getattr(message, "name", "tool"),
                getattr(message, "status", ""),
                getattr(message, "args", None),
                getattr(message, "result", None),
            )
        elif mtype == "task":
            self._task(getattr(message, "status", ""), getattr(message, "text", ""))
        elif mtype == "status":
            self._status(getattr(message, "message", "") or getattr(message, "status", ""))
        elif mtype == "assistant":
            self._capture_assistant_typed(message)
            if self.verbose:
                self._assistant_typed(message)

    def _capture_assistant_typed(self, message) -> None:
        parts: list[str] = []
        for block in getattr(getattr(message, "message", None), "content", []) or []:
            if getattr(block, "type", None) == "text":
                text = getattr(block, "text", "") or ""
                if text:
                    parts.append(str(text))
        if parts:
            self.append_assistant_text("\n".join(parts))
            return
        direct = getattr(message, "text", None)
        if isinstance(direct, str) and direct.strip():
            self.append_assistant_text(direct)

    def _capture_assistant_dict(self, message: dict) -> None:
        parts: list[str] = []
        msg = message.get("message") or {}
        if isinstance(msg, dict):
            for block in msg.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "text":
                    text = block.get("text") or ""
                    if text:
                        parts.append(str(text))
        if parts:
            self.append_assistant_text("\n".join(parts))
            return
        direct = message.get("text")
        if isinstance(direct, str) and direct.strip():
            self.append_assistant_text(direct)

    def _warn_delegate_violation(self, norm: str, args: Any) -> None:
        if norm not in ("edit", "strreplace", "write", "delete"):
            return
        if self.active_role() != "Coordinator":
            return
        path = raw_path(args)
        hit = delegate_violation(path)
        if not hit:
            return
        role, subagent = hit
        self.log(
            f"⚠ {self.prefix()} delegate violation — spawn {subagent} ({role}), "
            f"coordinator must not edit {short_path(path)}"
        )

    def _tool(self, call_id, name, status, args, result=None):
        norm = normalize_tool_name(name)

        if norm in ("task", "agent"):
            self._handle_task_tool(call_id, status, args)
            return

        label = summarize_tool(name, args, result if status != "running" else None)

        if status == "running" and call_id not in self._seen_starts:
            self._seen_starts.add(call_id)
            self._warn_delegate_violation(norm, args)
            cmd_early = arg_shell_command(args if isinstance(args, dict) else {})
            if (
                norm == "shell"
                and (self.fix_worker or self.authoring_gate)
                and is_verify_run(cmd_early)
            ):
                self._handle_verify_ban(cmd_early)
                self.log(f"→ {self.prefix()} blocked verify: {label}")
                self.note(f"blocked verify: {label}")
                return
            self.log(f"→ {self.prefix()} {label}")
            import time

            self._active_shell[call_id] = {
                "label": label,
                "started_at": time.time(),
            }
            self.note(label)
        elif status in ("completed", "error"):
            self._active_shell.pop(call_id, None)
            mark = "✓" if status == "completed" else "✗"
            self.log(f"{mark} {self.prefix()} {label}")
            self.note(f"{mark} {label}")
            cmd = arg_shell_command(args if isinstance(args, dict) else {})
            if (
                norm == "shell"
                and (self.fix_worker or self.authoring_gate)
                and is_verify_run(cmd)
            ):
                self._handle_verify_ban(cmd)
                return
            blob = _result_blob(result)
            # Real test runs OR inspection of results (xcresulttool) / crash text.
            if norm == "shell" and (
                is_verify_run(cmd)
                or "xcresulttool" in cmd
                or "Crash:" in blob
            ):
                crashes = detect_simulator_crashes(blob)
                if crashes:
                    self._announce_crashes(crashes, source="verify/xcodebuild")
                failures = self._collect_test_failures(blob, cmd)
                v = parse_verify_result(blob) if "verify.sh" in cmd else None
                if looks_like_build_failure(blob, v):
                    if not any(f.startswith("build_error:") for f in failures):
                        be = extract_build_error(blob) or (
                            f"build_error: exit={v.get('exit') if v else '?'} "
                            "(0 tests executed)"
                        )
                        failures = [be] + list(failures)
                    self.log(
                        f"   {self.prefix()} likely compile/build failure "
                        "(0 tests executed)"
                    )
                if failures:
                    # Inspection (xcresulttool) may refine the failure name without
                    # counting as another red verify attempt.
                    source = (
                        "verify/xcodebuild"
                        if is_verify_run(cmd)
                        else "xcresulttool"
                    )
                    self._announce_test_failures(failures, source=source)
                elif is_verify_run(cmd) and v and not verify_is_green(v):
                    self.log(
                        f"❌ {self.prefix()} verify RED — "
                        f"failed={v.get('failed')} skipped={v.get('skipped')} "
                        f"(no per-test detail in output; check build/test-results/)"
                    )
                if is_verify_run(cmd):
                    if v and verify_is_green(v):
                        self._last_verify = v
                        self._clear_failure_streak()
                    elif (
                        not failures
                        and ("** TEST SUCCEEDED **" in blob or "TEST SUCCEEDED" in blob)
                        and "TEST FAILED" not in blob
                    ):
                        self._clear_failure_streak()
                    else:
                        self._record_red_verify(
                            failures, cmd=cmd, blob=blob, verify=v
                        )
            # Always peek DiagnosticReports after a shell tool finishes —
            # crashes often land as .ips slightly after verify returns.
            self._scan_diagnostic_reports()
            if norm in ("shell", "edit", "strreplace", "write"):
                self.log_gate_progress()

    def _handle_task_tool(self, call_id, status, args):
        import time

        if status == "running" and call_id not in self._seen_starts:
            self._seen_starts.add(call_id)
            role = infer_role(args)
            desc = task_description(args)
            self._active_tasks[call_id] = {
                "role": role,
                "desc": desc,
                "started_at": time.time(),
            }
            parallel = len(self._active_tasks)
            extra = f" ({parallel} in flight)" if parallel > 1 else ""
            paths = role_edit_paths(role)
            self.log(f"→ [{self.slice_tag()}][Coordinator] spawn {role}: {desc}{extra}")
            self.log(f"   [{self.slice_tag()}] allowed edits: {paths}")
            wrong = detect_wrong_role_spawn(role, desc)
            if wrong:
                key = f"{role}:{desc[:40]}".lower()
                if key not in self._wrong_role_warned:
                    self._wrong_role_warned.add(key)
                    self.log(f"⚠ [{self.slice_tag()}] WRONG ROLE — {wrong}")
                    self.log(
                        f"   [{self.slice_tag()}] abort this subagent mentally; "
                        "spawn podwash-engineer for app fixes"
                    )
            self.note(f"{role}: {desc}")
        elif status in ("completed", "error"):
            info = self._active_tasks.pop(call_id, None)
            mark = "✓" if status == "completed" else "✗"
            role = info["role"] if info else infer_role(args if isinstance(args, dict) else {})
            desc = info["desc"] if info else task_description(args if isinstance(args, dict) else {})
            remaining = len(self._active_tasks)
            still = (
                f" — still running: {self.active_roles_label()}"
                if remaining
                else ""
            )
            self.log(f"{mark} [{self.slice_tag()}][{role}] finished — {desc}{still}")
            if remaining:
                primary = self._primary_active_task()
                if primary:
                    import time

                    elapsed = format_elapsed(
                        max(0, int(time.time() - float(primary.get("started_at") or time.time())))
                    )
                    self.note(
                        f"{primary.get('role')}: {primary.get('desc', 'working')} ({elapsed})"
                    )
            else:
                self.note(f"{mark} {role} done")
            # Subagent may have left new crash reports / artifacts while we were idle.
            self._scan_diagnostic_reports()
            self.log_gate_progress()

    def _task(self, status, text):
        text = (text or "").strip()
        if not text:
            return
        line = text.split("\n", 1)[0][:72]
        self.log(f"… {self.prefix()} {line}")
        self.note(line)
        crashes = detect_simulator_crashes(text)
        if crashes:
            self._announce_crashes(crashes, source="agent note")

    def _status(self, text):
        text = (text or "").strip()
        if not text:
            return
        self.log(f"… {self.prefix()} status: {text[:80]}")
        self.note(text[:72])

    def _assistant_typed(self, message):
        import sys

        for block in getattr(getattr(message, "message", None), "content", []):
            if getattr(block, "type", None) == "text":
                text = getattr(block, "text", "")
                if text:
                    sys.stdout.write(text)
                    sys.stdout.flush()
                    self.note("assistant text")

    def _assistant_dict(self, message):
        import sys

        msg = message.get("message") or {}
        for block in msg.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text", "")
                if text:
                    sys.stdout.write(text)
                    sys.stdout.flush()
                    self.note("assistant text")

    @property
    def last_verify(self) -> dict[str, str] | None:
        return self._last_verify
