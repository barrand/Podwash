"""Parse and mutate Forge task tickets under docs/tasks/."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone


@dataclass
class TaskTicket:
    path: str
    id: int
    title: str = ""
    status: str = ""
    kind: str = ""
    priority: str = "P2"
    area: str = ""
    surgical_tests: list[str] = field(default_factory=list)
    authorized_test_changes: list[str] = field(default_factory=list)
    raw: str = ""


_META_RE = re.compile(
    r"^\|\s*\*\*(?P<key>[^*]+)\*\*\s*\|\s*(?P<val>[^|]*)\|",
    re.MULTILINE,
)
_TEST_ID_RE = re.compile(
    r"`?(PodWash(?:Tests|UITests|SlowTests)/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)?(?:\(\))?)`?"
)
# scripts.test_module.Class.method  or  scripts.test_module.Class/method
_SCRIPTS_TEST_ID_RE = re.compile(
    r"`?(scripts\.test_[A-Za-z0-9_]+(?:\.[A-Za-z_][A-Za-z0-9_]*)+(?:/[A-Za-z_][A-Za-z0-9_]*)?)`?"
)


def task_id_from_path(path: str) -> int | None:
    base = os.path.basename(path)
    m = re.match(r"task-(\d{3})-", base)
    return int(m.group(1)) if m else None


def normalize_scripts_test_id(tid: str) -> str:
    """Normalize Class/method slash form to dotted unittest id."""
    return (tid or "").strip().replace("/", ".")


def is_scripts_test_id(tid: str) -> bool:
    return normalize_scripts_test_id(tid).startswith("scripts.test_")


def is_xcode_test_id(tid: str) -> bool:
    t = (tid or "").strip()
    return t.startswith(("PodWashTests/", "PodWashUITests/", "PodWashSlowTests/"))


def surgical_backend(tests: list[str]) -> str:
    """Return ``xcode``, ``scripts``, ``mixed``, or ``empty`` for surgical scope."""
    if not tests:
        return "empty"
    scripts = sum(1 for t in tests if is_scripts_test_id(t))
    xcode = sum(1 for t in tests if is_xcode_test_id(t))
    if scripts and xcode:
        return "mixed"
    if scripts == len(tests):
        return "scripts"
    if xcode == len(tests):
        return "xcode"
    # Unknown tokens — treat as mixed so the pipeline halts loudly
    return "mixed"


def xcode_class_id(tid: str) -> str | None:
    """Return ``Target/Class`` for a method- or class-scoped Xcode test id."""
    t = (tid or "").strip().rstrip("()")
    if not is_xcode_test_id(t) and not is_xcode_test_id(t + "()"):
        # Accept already-stripped Target/Class/method
        if not t.startswith(("PodWashTests/", "PodWashUITests/", "PodWashSlowTests/")):
            return None
    parts = t.split("/")
    if len(parts) >= 2:
        return f"{parts[0]}/{parts[1]}"
    return None


def expand_surgical_to_class(
    tests: list[str],
) -> tuple[list[str], list[tuple[str, str]]]:
    """Expand method-scoped Xcode ids to ``Target/Class`` for sibling coverage.

    Returns ``(expanded_ids, expansions)`` where each expansion is
    ``(original_method_id, class_id)`` for logging. Scripts ids and already
    class-scoped Xcode ids pass through unchanged.
    """
    expanded: list[str] = []
    expansions: list[tuple[str, str]] = []
    seen: set[str] = set()
    for tid in tests or []:
        raw = (tid or "").strip()
        if not raw:
            continue
        if is_scripts_test_id(raw):
            norm = normalize_scripts_test_id(raw)
            if norm not in seen:
                seen.add(norm)
                expanded.append(norm)
            continue
        class_id = xcode_class_id(raw)
        parts = raw.rstrip("()").split("/")
        # Method-scoped: Target/Class/method → expand to Target/Class
        if class_id and len(parts) >= 3:
            if class_id not in seen:
                seen.add(class_id)
                expanded.append(class_id)
            expansions.append((raw, class_id))
            continue
        # Class-scoped or unknown — keep as-is
        keep = class_id or raw
        if keep not in seen:
            seen.add(keep)
            expanded.append(keep)
    return expanded, expansions


def test_id_in_surgical_scope(failure_id: str, surgical: list[str]) -> bool:
    """True when ``failure_id`` was listed in surgical scope (exact or class filter).

    Method-scoped surgical entries only cover that method. Class-scoped entries
    (``Target/Class`` with no method) cover every method in the class. Sibling
    methods in the same class as a listed method are **not** considered in-scope
    — that is intentional so batch can detect Done filters that never ran them.
    """
    fid = (failure_id or "").strip()
    if not fid:
        return False
    fid_norm = (
        normalize_scripts_test_id(fid) if is_scripts_test_id(fid) else fid.rstrip("()")
    )
    fid_class = xcode_class_id(fid)
    for s in surgical or []:
        sid = (s or "").strip()
        if not sid:
            continue
        if is_scripts_test_id(sid):
            if normalize_scripts_test_id(sid) == fid_norm:
                return True
            continue
        s_norm = sid.rstrip("()")
        if fid_norm == s_norm or fid == sid:
            return True
        s_parts = s_norm.split("/")
        # Explicit class-scoped surgical (Target/Class) covers methods in that class
        if len(s_parts) == 2 and fid_class and f"{s_parts[0]}/{s_parts[1]}" == fid_class:
            return True
    return False


def collect_done_surgical_tests(tasks_dir: str) -> list[str]:
    """Union of Surgical test scope ids from Status=Done tickets under tasks_dir."""
    if not os.path.isdir(tasks_dir):
        return []
    found: list[str] = []
    seen: set[str] = set()
    for name in sorted(os.listdir(tasks_dir)):
        if not re.match(r"task-\d{3}-.+\.md$", name):
            continue
        path = os.path.join(tasks_dir, name)
        try:
            ticket = parse_task_ticket(path)
        except OSError:
            continue
        if (ticket.status or "").strip().lower() != "done":
            continue
        for tid in ticket.surgical_tests:
            if tid not in seen:
                seen.add(tid)
                found.append(tid)
    return found


def failures_outside_surgical_scope(
    failure_ids: list[str],
    surgical: list[str],
) -> list[str]:
    """Return failure ids that do not match any surgical method/class."""
    return [
        fid
        for fid in failure_ids
        if (fid or "").strip() and not test_id_in_surgical_scope(fid, surgical)
    ]


def batch_failures_are_scope_miss(
    failure_ids: list[str],
    surgical: list[str],
) -> bool:
    """True when every failure is outside Done-task surgical scopes (contract drift)."""
    cleaned = [(f or "").strip() for f in failure_ids if (f or "").strip()]
    if not cleaned:
        return False
    return all(not test_id_in_surgical_scope(fid, surgical) for fid in cleaned)


def _extract_test_ids(text: str) -> list[str]:
    found: list[str] = []
    for m in _TEST_ID_RE.finditer(text):
        tid_s = m.group(1)
        if tid_s not in found:
            found.append(tid_s)
    for m in _SCRIPTS_TEST_ID_RE.finditer(text):
        tid_s = normalize_scripts_test_id(m.group(1))
        if tid_s not in found:
            found.append(tid_s)
    return found


def parse_task_ticket(path: str) -> TaskTicket:
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
    tid = task_id_from_path(path) or 0
    meta: dict[str, str] = {}
    for m in _META_RE.finditer(raw):
        meta[m.group("key").strip()] = m.group("val").strip()

    # Prefer Surgical test scope section table cells / backticks
    sec = _section(raw, "Surgical test scope")
    surgical = _extract_test_ids(sec or raw)

    auth: list[str] = []
    asec = _section(raw, "Authorized test changes")
    if asec:
        for line in asec.splitlines():
            line = line.strip()
            if line.startswith("-") and "none" not in line.lower():
                for tid_s in _extract_test_ids(line):
                    if tid_s not in auth:
                        auth.append(tid_s)
                rest = line.lstrip("- ").strip()
                if rest and rest not in auth and "(" in rest:
                    auth.append(rest)

    return TaskTicket(
        path=path,
        id=tid,
        title=meta.get("Title", ""),
        status=meta.get("Status", ""),
        kind=meta.get("Kind", ""),
        priority=meta.get("Priority", "P2").split()[0] if meta.get("Priority") else "P2",
        area=meta.get("Area", ""),
        surgical_tests=surgical,
        authorized_test_changes=auth,
        raw=raw,
    )


def _section(text: str, heading: str) -> str | None:
    m = re.search(
        rf"^##\s+{re.escape(heading)}\s*$",
        text,
        re.MULTILINE | re.IGNORECASE,
    )
    if not m:
        return None
    start = m.end()
    n = re.search(r"^##\s+", text[start:], re.MULTILINE)
    end = start + n.start() if n else len(text)
    return text[start:end]


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _rewrite_status_lines(lines: list[str], status: str) -> list[str]:
    out: list[str] = []
    done_at_updated = False
    status_out_idx: int | None = None
    for line in lines:
        if "| **Done at** |" in line or "| **Done at**|" in line:
            if status == "Done":
                line = f"| **Done at** | {_utc_now_iso()} |\n"
                done_at_updated = True
        if "| **Status** |" in line or "| **Status**|" in line:
            parts = [p.strip() for p in line.strip().strip("|").split("|")]
            if len(parts) >= 2:
                parts[1] = status
                line = "| " + " | ".join(parts) + " |\n"
            status_out_idx = len(out)
        out.append(line)
    if status == "Done" and not done_at_updated:
        row = f"| **Done at** | {_utc_now_iso()} |\n"
        if status_out_idx is not None:
            out.insert(status_out_idx + 1, row)
        else:
            out.append(row)
    return out


def set_task_status(path: str, status: str) -> None:
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(_rewrite_status_lines(lines, status))


def set_task_priority(path: str, priority: str) -> None:
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    out: list[str] = []
    for line in lines:
        if "| **Priority** |" in line or "| **Priority**|" in line:
            parts = [p.strip() for p in line.strip().strip("|").split("|")]
            if len(parts) >= 2:
                parts[1] = priority
                line = "| " + " | ".join(parts) + " |\n"
        out.append(line)
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(out)


def write_task_verify_result(path: str, result: dict[str, str]) -> None:
    from slice_pipeline import format_verify_result_line

    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    line = format_verify_result_line(result)
    if re.search(r"^VERIFY RESULT:", text, re.MULTILINE | re.IGNORECASE):
        text = re.sub(
            r"^VERIFY RESULT:.*$",
            line,
            text,
            count=1,
            flags=re.MULTILINE | re.IGNORECASE,
        )
    else:
        m = re.search(r"(##\s+Verification record[^\n]*\n)", text, re.IGNORECASE)
        if m:
            insert_at = m.end()
            text = text[:insert_at] + "\n```\n" + line + "\n```\n" + text[insert_at:]
        else:
            text = text.rstrip() + "\n\n## Verification record\n\n```\n" + line + "\n```\n"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def areas_overlap(a: str, b: str) -> bool:
    """True if Area tag strings share a path token (comma/space separated)."""
    def toks(s: str) -> set[str]:
        parts = re.split(r"[,;\s]+", (s or "").strip())
        return {p.strip().rstrip("/") for p in parts if p.strip()}

    ta, tb = toks(a), toks(b)
    if not ta or not tb:
        return False
    for x in ta:
        for y in tb:
            if x == y or x in y or y in x:
                return True
    return False
