#!/usr/bin/env python3
"""Factory v2 P1 — shift-floor narrator (names + templates + Murphy).

Narration is a *rendering* of structured events. Murphy never appears in
JSONL / ledger / stuck cards — only in narrated lines.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

LogFn = Callable[[str], None]

FACTORY_NAME = "Forge"

NAME_POOLS: dict[str, tuple[str, ...]] = {
    "Engineer": ("Edison", "Elena", "Ezra", "Esme", "Elliott"),
    "QA": ("Quinn", "Quincy", "Queenie", "Quill"),
    "Architect": ("Ada", "Atlas", "Aurora"),
    "PM": ("Priya", "Parker", "Penny"),
    "UX": ("Uma", "Ulysses", "Unity"),
    "Referee": ("Rhea",),
    "QA review": ("Quinn", "Quincy", "Queenie", "Quill"),
    "PM review": ("Priya", "Parker", "Penny"),
    "Architect review": ("Ada", "Atlas", "Aurora"),
}

ROLE_INITIAL: dict[str, str] = {
    "Engineer": "E",
    "QA": "Q",
    "Architect": "A",
    "PM": "P",
    "UX": "U",
    "Referee": "R",
    "QA review": "Q",
    "PM review": "P",
    "Architect review": "A",
}


@dataclass
class NameAssigner:
    """Cycle through role-initial name pools once per run."""

    _indexes: dict[str, int] = field(default_factory=dict)
    _assigned: dict[str, str] = field(default_factory=dict)

    def assign(self, role: str, *, slot: str | None = None) -> str:
        key = slot or role
        if key in self._assigned:
            return self._assigned[key]
        pool = NAME_POOLS.get(role) or NAME_POOLS.get(role.split()[0], ("Agent",))
        idx = self._indexes.get(role, 0)
        name = pool[idx % len(pool)]
        self._indexes[role] = idx + 1
        self._assigned[key] = name
        return name

    def initial(self, role: str) -> str:
        return ROLE_INITIAL.get(role, role[:1].upper() if role else "?")


def format_agent_label(role: str, name: str | None = None) -> str:
    """Scannable worker label: ``QA Quincy`` when both are set."""
    role = (role or "").strip()
    name = (name or "").strip()
    if role and name:
        return f"{role} {name}"
    return role or name or "loop"


def factory_session_banner() -> str:
    """Compact ASCII title printed once per slice-loop session."""
    name = FACTORY_NAME
    tag = "Murphy on the floor. Green or halt."
    # Keep ≤12 lines; no competition with the mountain summit done-art.
    inner = 42
    return (
        "\n"
        f"╔{'═' * inner}╗\n"
        f"║{name:^{inner}}║\n"
        f"║{'':^{inner}}║\n"
        f"║{'════╤════':^{inner}}║\n"
        f"║{'╱╲ │ ╱╲':^{inner}}║\n"
        f"║{'╱  ╲│╱  ╲':^{inner}}║\n"
        f"║{'───╱────┴────╲───':^{inner}}║\n"
        f"║{'':^{inner}}║\n"
        f"║{tag:^{inner}}║\n"
        f"╚{'═' * inner}╝\n"
    )


def narrate_spawn(
    name: str,
    role: str,
    mission: str,
    *,
    log: LogFn | None = None,
) -> str:
    emoji = {
        "Engineer": "🔧",
        "QA": "🧪",
        "QA review": "🧪",
        "Architect": "📐",
        "Architect review": "📐",
        "PM": "📋",
        "PM review": "📋",
        "UX": "🎨",
        "Referee": "⚖️",
    }.get(role, "•")
    line = f"{emoji} {name} ({role}) clocking in — mission: {mission.rstrip('.')}."
    _emit(line, log)
    return line


def narrate_worker_done(
    name: str,
    summary: str,
    *,
    log: LogFn | None = None,
) -> str:
    note = summary.strip() or "wrapped the turn"
    line = f"{name} wrapped: {note}"
    _emit(line, log)
    return line


def narrate_verify_red(
    name: str,
    *,
    passed: str | int,
    total: str | int,
    log: LogFn | None = None,
) -> str:
    line = (
        f"🐒 {name}'s report: {passed}/{total} — "
        f"Murphy's been at the station again."
    )
    _emit(line, log)
    return line


def narrate_verify_green(
    name: str,
    *,
    passed: str | int,
    total: str | int,
    log: LogFn | None = None,
) -> str:
    line = f"Not a monkey in sight. {passed}/{total}."
    if name:
        line = f"{name} signs the sheet: {passed}/{total}. Not a monkey in sight."
    _emit(line, log)
    return line


def narrate_referee(
    referee_name: str,
    *,
    primary: str,
    next_name: str,
    next_role: str,
    narration: str = "",
    log: LogFn | None = None,
) -> str:
    if narration.strip():
        color = narration.strip().rstrip(".")
        line = f"⚖️ {referee_name} rules: {color}. {next_name} ({next_role}) gets the ticket."
    else:
        short = (primary or "primary failure")[:80]
        line = (
            f"⚖️ {referee_name} rules: primary is {short} — "
            f"{next_name} ({next_role}) gets the ticket, fresh eyes."
        )
    _emit(line, log)
    return line


def narrate_exoneration(
    *,
    cause: str,
    owner: str,
    log: LogFn | None = None,
) -> str:
    """Mandatory when referee attributes a real cause (not flake)."""
    line = (
        f"Turns out it wasn't Murphy — {cause.rstrip('.')}. {owner} owns it."
    )
    _emit(line, log)
    return line


def narrate_flake_confirmed(*, log: LogFn | None = None) -> str:
    line = "Murphy confirmed. It ran green untouched. Logging the flake and moving on."
    _emit(line, log)
    return line


def narrate_ledger_block(
    referee_name: str,
    *,
    log: LogFn | None = None,
) -> str:
    line = (
        f"{referee_name} checked the logbook — theory matches a failed attempt. "
        f"Halting before we burn tokens on a rerun."
    )
    _emit(line, log)
    return line


def narrate_thrash_halt(*, log: LogFn | None = None) -> str:
    line = "🐒 Murphy wins this round. Halting — logbook and stuck card are on the desk. (exit=5)"
    _emit(line, log)
    return line


def narrate_infra_halt(*, log: LogFn | None = None) -> str:
    line = "🐒 Something knocked the line over (infra). Murphy denies everything. (exit=6)"
    _emit(line, log)
    return line


def narrate_crash(*, log: LogFn | None = None) -> str:
    line = (
        "🐒 Something knocked the simulator over. Murphy denies everything. "
        "Rhea is pulling the crash log."
    )
    _emit(line, log)
    return line


def _fmt_elapsed(secs: float | int | None) -> str:
    if secs is None:
        return "?"
    s = max(0, int(secs))
    if s < 60:
        return f"{s}s"
    mins, rem = divmod(s, 60)
    if mins < 60:
        return f"{mins}m {rem}s" if rem else f"{mins}m"
    hours, mins = divmod(mins, 60)
    return f"{hours}h {mins}m"


@dataclass
class CastEntry:
    role: str
    name: str
    gate: str
    secs: float = 0.0


@dataclass
class CastLog:
    """Who worked a slice — feeds the end-of-slice recap."""

    entries: list[CastEntry] = field(default_factory=list)
    murphy_visits: int = 0

    def add(
        self,
        role: str,
        name: str,
        gate: str,
        *,
        secs: float = 0.0,
    ) -> None:
        self.entries.append(
            CastEntry(role=role, name=name, gate=gate, secs=float(secs or 0))
        )

    def note_murphy(self) -> None:
        self.murphy_visits += 1

    def cast_names(self) -> list[str]:
        seen: list[str] = []
        for e in self.entries:
            n = (e.name or "").strip()
            if n and n not in seen:
                seen.append(n)
        return seen


def narrate_chapter_open(
    *,
    slice_id: int,
    gate_label: str,
    role: str,
    name: str,
    act: int | None = None,
    total: int | None = None,
    fix_attempt: int | None = None,
    fix_max: int | None = None,
    log: LogFn | None = None,
) -> str:
    """Chapter break before a gate or fix worker (replaces bare gates + clock-in)."""
    who = format_agent_label(role, name)
    if fix_attempt is not None and fix_max is not None:
        mid = f"fix {fix_attempt}/{fix_max}"
    elif act is not None and total is not None:
        mid = f"{act}/{total} {gate_label}"
    else:
        mid = gate_label
    line = f"\n── Slice {slice_id} · {mid} · {who} ──"
    _emit(line, log)
    return line


def narrate_gate_cleared(
    name: str,
    gate_label: str,
    *,
    next_label: str | None = None,
    next_name: str | None = None,
    elapsed_secs: float | None = None,
    log: LogFn | None = None,
) -> str:
    time_bit = f" ({_fmt_elapsed(elapsed_secs)})" if elapsed_secs is not None else ""
    next_bit = ""
    if next_label:
        who = f" · {next_name}" if next_name else ""
        next_bit = f" — next: {next_label}{who}"
    line = f"✓ {name} cleared {gate_label}{time_bit}{next_bit}"
    _emit(line, log)
    return line


def narrate_gate_stuck(
    gate_label: str,
    explain_msg: str,
    *,
    log: LogFn | None = None,
) -> str:
    """Story-shaped stuck line; ``explain_msg`` from explain_gate_pending."""
    body = (explain_msg or "").strip()
    marker = " — stopping."
    if marker in body:
        body = body.split(marker, 1)[1].strip()
    body = body.lstrip(". ").strip()
    if body.startswith("(") and "unblock:" in body.lower():
        # "(Status=…) unblock: …" → keep readable
        pass
    line = f"✗ {gate_label} stuck — {body}" if body else f"✗ {gate_label} stuck"
    _emit(line, log)
    return line


def format_slice_recap(
    *,
    slice_id: int,
    elapsed_secs: int,
    cast: CastLog,
    outcome: str,
) -> str:
    names = ", ".join(cast.cast_names()) or "—"
    return (
        f"{FACTORY_NAME} recap · slice {slice_id} · {_fmt_elapsed(elapsed_secs)} · "
        f"{names} · Murphy ×{cast.murphy_visits} · {outcome}"
    )


def narrate_slice_recap(
    *,
    slice_id: int,
    elapsed_secs: int,
    cast: CastLog,
    outcome: str,
    log: LogFn | None = None,
) -> str:
    line = format_slice_recap(
        slice_id=slice_id,
        elapsed_secs=elapsed_secs,
        cast=cast,
        outcome=outcome,
    )
    _emit(line, log)
    return line


def persist_story_recap(
    recap: str,
    *,
    repo_root: str,
    slice_id: int,
) -> str:
    """Write recap to build/test-results/story-slice-NN.txt. Returns path."""
    import os

    out_dir = os.path.join(repo_root, "build", "test-results")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"story-slice-{slice_id:02d}.txt")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(recap.rstrip() + "\n")
    return path


def _emit(line: str, log: LogFn | None) -> None:
    if log:
        log(line)
    else:
        print(line, flush=True)
