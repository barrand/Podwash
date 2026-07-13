"""Parse and mutate Forge task tickets under docs/tasks/."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field


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


def task_id_from_path(path: str) -> int | None:
    base = os.path.basename(path)
    m = re.match(r"task-(\d{3})-", base)
    return int(m.group(1)) if m else None


def parse_task_ticket(path: str) -> TaskTicket:
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
    tid = task_id_from_path(path) or 0
    meta: dict[str, str] = {}
    for m in _META_RE.finditer(raw):
        meta[m.group("key").strip()] = m.group("val").strip()

    surgical: list[str] = []
    # Prefer Surgical test scope section table cells / backticks
    sec = _section(raw, "Surgical test scope")
    for m in _TEST_ID_RE.finditer(sec or raw):
        tid_s = m.group(1)
        if tid_s not in surgical:
            surgical.append(tid_s)

    auth: list[str] = []
    asec = _section(raw, "Authorized test changes")
    if asec:
        for line in asec.splitlines():
            line = line.strip()
            if line.startswith("-") and "none" not in line.lower():
                for m in _TEST_ID_RE.finditer(line):
                    if m.group(1) not in auth:
                        auth.append(m.group(1))
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


def set_task_status(path: str, status: str) -> None:
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    out: list[str] = []
    for line in lines:
        if "| **Status** |" in line or "| **Status**|" in line:
            parts = [p.strip() for p in line.strip().strip("|").split("|")]
            if len(parts) >= 2:
                parts[1] = status
                line = "| " + " | ".join(parts) + " |\n"
        out.append(line)
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(out)


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
