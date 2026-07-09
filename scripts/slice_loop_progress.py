"""Terminal progress formatting for scripts/slice_loop.py (unit-testable)."""

from __future__ import annotations

import json
import os
import re
from typing import Any

VERIFY_RESULT_RE = re.compile(
    r"VERIFY RESULT:\s*exit=(\d+)\s+total=([^\s]+)\s+passed=([^\s]+)\s+"
    r"failed=([^\s]+)\s+skipped=([^\s]+)",
    re.IGNORECASE,
)

SLICE_HEADING_RE = re.compile(
    r"^#\s*Slice\s+(\d+)\s*[—–-]\s*(.+?)\s*$",
    re.MULTILINE,
)


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
    return {
        "exit": m.group(1),
        "total": m.group(2),
        "passed": m.group(3),
        "failed": m.group(4),
        "skipped": m.group(5),
    }


def verify_is_green(v: dict[str, str] | None) -> bool:
    if not v:
        return False
    return v.get("exit") == "0" and v.get("failed") == "0" and v.get("skipped") == "0"


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

    blob = ""
    if isinstance(result, str):
        blob = result
    elif isinstance(result, dict):
        blob = json.dumps(result)
    else:
        blob = str(result or "")

    v = parse_verify_result(blob)
    if not v:
        return ""
    if verify_is_green(v):
        return f"GREEN — {v['passed']}/{v['total']} passed, 0 failed, 0 skipped"
    return f"RED — failed={v['failed']} skipped={v['skipped']}"


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


def format_elapsed(seconds: int) -> str:
    if seconds < 60:
        return f"{seconds}s"
    mins, secs = divmod(seconds, 60)
    if mins < 60:
        return f"{mins}m {secs}s"
    hours, mins = divmod(mins, 60)
    return f"{hours}h {mins}m {secs}s"


def slice_start_banner(slice_id: int, title: str, slice_file: str) -> str:
    line = f"  SLICE {slice_id:02d} — {title}"
    border = "═" * max(54, len(line) + 2)
    return (
        f"\n{border}\n"
        f"{line}\n"
        f"  {slice_file}\n"
        f"{border}"
    )


def _banner_line(text: str, width: int = 56) -> str:
    return f"║  {text:<{width}}║"


def slice_done_ascii_art() -> str:
    """Epic summit scene for a green slice — rider, mountain lion, eagle."""
    return (
        "                          __/\\__\n"
        "                         / >  < \\\n"
        "                        |  \\__/  |\n"
        "                         \\  ||  /\n"
        "              ,~~~.       _\\||/_\n"
        "             /     \\_____/ @ @ \\_____\n"
        "            |   |\\       /  \\|/  \\       /|\n"
        "            |   | \\_____/  o o  \\_____/ |\n"
        "             \\  |  `~ ~`  \\  ^  /  `~ ~`  |\n"
        "              \\/    ,------+------.    \\/\n"
        "               \\___/  |\\________/|  \\___/\n"
        "                    \\ |  |    |  | /\n"
        "                     \\|_/      \\_|/\n"
        "                      / `~ ~ ~ ~ ~` \\\n"
        "                     /  /\\    /\\  \\\n"
        "                    /__/  \\__/  \\__\\\n"
        "                   /____/ MOUNTAIN \\____\\\n"
        "                  /_____  SUMMIT   ______\\\n"
        "                 /_______ CONQUERED ______\\"
    )


def slice_done_banner(
    slice_id: int,
    title: str,
    verify: dict[str, str] | None,
    elapsed_secs: int,
    session: tuple[int, int] | None = None,
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
        lines.append(_banner_line(f"{emoji}  Dark factory gate cleared — safe to advance queue."))
    lines.append("╚" + "═" * 58 + "╝")
    if green:
        lines.append(slice_done_ascii_art())
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
    ):
        self.slice_id = slice_id
        self.slice_title = slice_title
        self.slice_file = slice_file
        self.log = log_fn
        self.verbose = verbose
        self.heartbeat_secs = heartbeat_secs
        self.last_activity = 0.0
        self.last_label = "coordinator starting"
        self._seen_starts: set[str] = set()
        self._active_tasks: dict[str, dict[str, str]] = {}
        self.role_stack: list[str] = ["Coordinator"]
        self._stop = None
        self._thread = None
        self._last_verify: dict[str, str] | None = None

    def slice_tag(self) -> str:
        return f"slice {self.slice_id:02d}"

    def active_role(self) -> str:
        return self.role_stack[-1] if self.role_stack else "Coordinator"

    def prefix(self) -> str:
        return f"[{self.slice_tag()}][{self.active_role()}]"

    def start(self):
        import threading
        import time

        self.last_activity = time.time()
        if self.heartbeat_secs > 0:
            self._stop = threading.Event()
            self._thread = threading.Thread(target=self._heartbeat, daemon=True)
            self._thread.start()

    def stop(self):
        if self._stop:
            self._stop.set()

    def _heartbeat(self):
        import time

        while not self._stop.wait(self.heartbeat_secs):
            idle = int(time.time() - self.last_activity)
            self.log(
                f"still running ({idle}s idle) — {self.prefix()} last: {self.last_label}"
            )

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
            elif mtype == "assistant" and self.verbose:
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
        elif mtype == "assistant" and self.verbose:
            self._assistant_typed(message)

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
            self.log(f"→ {self.prefix()} {label}")
            self.note(label)
        elif status in ("completed", "error"):
            mark = "✓" if status == "completed" else "✗"
            self.log(f"{mark} {self.prefix()} {label}")
            self.note(f"{mark} {label}")
            if norm == "shell" and "verify.sh" in arg_shell_command(args if isinstance(args, dict) else {}):
                v = parse_verify_result(str(result or ""))
                if v and verify_is_green(v):
                    self._last_verify = v

    def _handle_task_tool(self, call_id, status, args):
        if status == "running" and call_id not in self._seen_starts:
            self._seen_starts.add(call_id)
            role = infer_role(args)
            desc = task_description(args)
            self._active_tasks[call_id] = {"role": role, "desc": desc}
            self.log(f"→ [{self.slice_tag()}][Coordinator] spawn {role}: {desc}")
            self.role_stack.append(role)
            self.note(f"spawn {role}")
        elif status in ("completed", "error"):
            info = self._active_tasks.pop(call_id, None)
            if self.role_stack and self.role_stack[-1] != "Coordinator":
                self.role_stack.pop()
            mark = "✓" if status == "completed" else "✗"
            role = info["role"] if info else self.active_role()
            desc = info["desc"] if info else "subagent"
            self.log(f"{mark} [{self.slice_tag()}][{role}] finished — {desc}")
            self.note(f"{mark} {role} done")

    def _task(self, status, text):
        text = (text or "").strip()
        if not text:
            return
        line = text.split("\n", 1)[0][:72]
        self.log(f"… {self.prefix()} {line}")
        self.note(line)

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
