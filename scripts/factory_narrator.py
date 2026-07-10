#!/usr/bin/env python3
"""Factory v2 P1 — shift-floor narrator (names + templates + Murphy).

Narration is a *rendering* of structured events. Murphy never appears in
JSONL / ledger / stuck cards — only in narrated lines.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

LogFn = Callable[[str], None]

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


def _emit(line: str, log: LogFn | None) -> None:
    if log:
        log(line)
    else:
        print(line, flush=True)
