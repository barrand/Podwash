#!/usr/bin/env python3
"""Factory v2 P1 — shift-floor narrator (names + templates + Murphy).

Narration is a *rendering* of structured events. Murphy never appears in
JSONL / ledger / stuck cards — only in narrated lines.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Callable

if TYPE_CHECKING:
    from failure_packet import FailurePacket

LogFn = Callable[[str], None]

FACTORY_NAME = "Forge"

# Session taglines — one picked when the Forge ASCII banner prints (verbose).
SESSION_TAGLINES: tuple[str, ...] = (
    "Green or halt.",
    "Named crew on shift.",
    "Green sheet or halt card — pick one.",
    "The line runs.",
)

VERIFY_RED_TAILS: tuple[str, ...] = (
    "Murphy's been at the station again.",
    "Murphy got into the wrench drawer.",
    "Someone left the cage open — Murphy was helping.",
    "Murphy denies everything. The tests disagree.",
    "Fresh paw prints on the console.",
    "The floor was clean a minute ago.",
)

VERIFY_GREEN_LINES: tuple[str, ...] = (
    "{name} signs the sheet: {passed}/{total}. All clear.",
    "Green from {name} — {passed}/{total}.",
    "{passed}/{total} on {name}'s tally. Floor's quiet.",
    "All {total} accounted for. {name} closed the book.",
)

GATE_CLEARED_LINES: tuple[str, ...] = (
    "✓ {name} cleared {gate}{time}{next}",
    "✓ {gate} lands for {name}{time}{next}",
    "✓ {name} punched out on {gate}{time}{next}",
    "✓ {gate} — {name} signs off{time}{next}",
)

CHAPTER_OPEN_LINES: tuple[str, ...] = (
    "\n── Slice {slice_id} · {mid} · {who} ──",
    "\n── Act {mid} · slice {slice_id} · {who} on deck ──",
    "\n── Slice {slice_id} · {mid} · {who} takes the shift ──",
)

WORKER_DONE_LINES: tuple[str, ...] = (
    "{name} wrapped: {note}",
    "{name} clocks out — {note}",
    "{name} hands off: {note}",
)

EXONERATION_LINES: tuple[str, ...] = (
    "Turns out it wasn't Murphy — {cause}. {owner} owns it.",
    "Murphy's off the hook: {cause}. {owner} takes it.",
    "Not the monkey this time — {cause}. {owner}'s turn.",
)

FLAKE_LINES: tuple[str, ...] = (
    "Flake on rerun — green untouched. Logged.",
    "Green on cold retry without a code change. Logged.",
    "Second pass green with no edits. Logged as flake.",
)

THRASH_HALT_LINES: tuple[str, ...] = (
    "🐒 Murphy wins this round. Halting — logbook and stuck card on the desk. (exit=5)",
    "🐒 Murphy takes the shift. Halting — stuck card's on the desk. (exit=5)",
    "🐒 That's the budget. Murphy's grinning. Stuck card filed. (exit=5)",
)

INFRA_HALT_LINES: tuple[str, ...] = (
    "Something knocked the line over (infra). Halting for retry. (exit=6)",
    "Infra wobble — not code. Halting for retry. (exit=6)",
    "The line tripped on tooling. Halting for retry. (exit=6)",
)

CRASH_LINES: tuple[str, ...] = (
    "🐒 Something knocked the simulator over. Murphy denies everything. Rhea pulls the crash log.",
    "🐒 Simulator ate pavement. Murphy swears he wasn't on the keyboard. Rhea's on the log.",
    "🐒 Crash on the floor. Murphy points at a loose cable. Rhea investigates.",
)

LEDGER_BLOCK_LINES: tuple[str, ...] = (
    "{referee} checked the logbook — same theory as last time. Flipping the wrench.",
    "{referee} found a repeat in the logbook. Fresh eyes on the other role.",
    "{referee} won't sign the same ticket twice. Rerouting to the opposite role.",
)

REFEREE_NARRATION_LINES: tuple[str, ...] = (
    "⚖️ {referee} rules: {color}. {next} ({role}) gets the ticket.",
    "⚖️ {referee} calls it: {color}. {next} ({role}) takes the shift.",
    "⚖️ {referee} weighs in — {color}. Handing off to {next} ({role}).",
)

REFEREE_PRIMARY_LINES: tuple[str, ...] = (
    "⚖️ {referee} rules: primary is {short} — {next} ({role}) gets the ticket, fresh eyes.",
    "⚖️ {referee} pins it on {short}. {next} ({role}) clocks in with clean goggles.",
    "⚖️ {referee} reads the failure: {short}. {next} ({role}) owns the next pass.",
)

MURPHY_BLAME_LINES: tuple[str, ...] = (
    "I bet it was Murphy. He is always monkeying around.",
    "Murphy denies everything. The tests disagree.",
    "Could've been Murphy — he's always in the wrench drawer.",
    "Murphy swears he wasn't on the keyboard. I don't buy it.",
)

FAILURE_DETAIL_LINES: tuple[str, ...] = (
    "from {name}: {murphy_tail} I was on {test} — tried {intent}. Got {got} instead. {blame}",
    "from {name}: {murphy_tail} Working {test}: wanted {intent}, but got {got}. {blame}",
    "from {name}: {murphy_tail} {test} — expected {intent}; saw {got}. {blame}",
)

ROLE_REPORT_LINES: tuple[str, ...] = (
    "from {name}: {detail}",
    "{name} back to the coordinator: {detail}",
    "from {name} on the floor: {detail}",
)

COORDINATOR_SHIFT_OPEN_LINES: tuple[str, ...] = (
    "Coordinator {name} on shift — I'll keep the gates moving.",
    "{name} here — running the floor today.",
    "Floor lead {name} — shift is open.",
)

GATE_STUCK_LINES: tuple[str, ...] = (
    "✗ {gate} stuck — {body}",
    "✗ {gate} won't budge — {body}",
    "✗ Held up at {gate} — {body}",
    "✗ {gate} hit a wall — {body}",
)

COORDINATOR_REPORT_OPENERS: tuple[str, ...] = (
    "Signing off — slice {slice_id} cleared the floor green.",
    "Shift report: slice {slice_id} is green and ready to queue forward.",
    "Handing you the logbook — slice {slice_id} finished clean.",
    "Closing this chapter: slice {slice_id} made it through verify.",
)

COORDINATOR_REPORT_CLOSERS: tuple[str, ...] = (
    "Forge gate cleared — safe to advance the queue when you're ready.",
    "That's a green sheet from this shift. Re-run the loop for the next slice.",
    "Floor's clean. Safe to advance the queue.",
    "All accounted for — queue can move on.",
)

COORDINATOR_REPORT_HALT_CLOSERS: tuple[str, ...] = (
    "We didn't get green — check the stuck card and story recap before retrying.",
    "Shift ends on a halt. Unblock the gate, then spin the loop again.",
    "Not a green close. Logs and stuck card are on the desk.",
)


@dataclass
class StoryVoice:
    """Rotate narration templates without back-to-back repeats."""

    _last: dict[str, int] = field(default_factory=dict)
    _counts: dict[str, int] = field(default_factory=dict)

    def pick(self, category: str, templates: tuple[str, ...]) -> str:
        if not templates:
            return ""
        if len(templates) == 1:
            return templates[0]
        idx = self._counts.get(category, 0) % len(templates)
        last = self._last.get(category, -1)
        if idx == last:
            idx = (idx + 1) % len(templates)
        self._last[category] = idx
        self._counts[category] = self._counts.get(category, 0) + 1
        return templates[idx]

    def format(self, category: str, templates: tuple[str, ...], **kwargs: str) -> str:
        tpl = self.pick(category, templates)
        try:
            return tpl.format(**kwargs)
        except KeyError:
            return tpl


_default_voice = StoryVoice()

NAME_POOLS: dict[str, tuple[str, ...]] = {
    "Engineer": ("Edison", "Elena", "Ezra", "Esme", "Elliott"),
    "QA": ("Quinn", "Quincy", "Queenie", "Quill"),
    "Architect": ("Ada", "Atlas", "Aurora"),
    "PM": ("Priya", "Parker", "Penny"),
    "UX": ("Uma", "Ulysses", "Unity"),
    "Referee": ("Rhea",),
    "Coordinator": ("Kai", "Kira", "Kellen", "Kit"),
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
    "Coordinator": "C",
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


def factory_session_banner(*, voice: StoryVoice | None = None) -> str:
    """Compact ASCII title printed once per slice-loop session."""
    name = FACTORY_NAME
    v = voice or _default_voice
    tag = v.pick("session_tag", SESSION_TAGLINES)
    # Keep ≤12 lines; no competition with the coordinator shift report.
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
    voice: StoryVoice | None = None,
) -> str:
    v = voice or _default_voice
    note = summary.strip() or "wrapped the turn"
    line = v.format("worker_done", WORKER_DONE_LINES, name=name, note=note)
    _emit(line, log)
    return line


def narrate_verify_red(
    name: str,
    *,
    passed: str | int,
    total: str | int,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    v = voice or _default_voice
    tail = v.pick("verify_red", VERIFY_RED_TAILS)
    opener = v.pick(
        "verify_red_open",
        (
            "🐒 {name}'s report: {passed}/{total} — {tail}",
            "🐒 {passed}/{total} from {name}. {tail}",
            "🐒 {name} counted {passed}/{total}. {tail}",
        ),
    )
    line = opener.format(name=name, passed=passed, total=total, tail=tail)
    _emit(line, log)
    return line


def narrate_verify_green(
    name: str,
    *,
    passed: str | int,
    total: str | int,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    """Legacy entry — prefer factory_floor_llm.narrate_verify_green_dynamic."""
    del voice  # floor green voice is LLM-authored or minimal fallback
    from factory_floor_llm import narrate_verify_green_minimal

    return narrate_verify_green_minimal(
        name, passed=passed, total=total, log=log
    )


def narrate_referee(
    referee_name: str,
    *,
    primary: str,
    next_name: str,
    next_role: str,
    narration: str = "",
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    v = voice or _default_voice
    if narration.strip():
        color = narration.strip().rstrip(".")
        line = v.format(
            "referee_narration",
            REFEREE_NARRATION_LINES,
            referee=referee_name,
            color=color,
            next=next_name,
            role=next_role,
        )
    else:
        short = (primary or "primary failure")[:80]
        line = v.format(
            "referee_primary",
            REFEREE_PRIMARY_LINES,
            referee=referee_name,
            short=short,
            next=next_name,
            role=next_role,
        )
    _emit(line, log)
    return line


def narrate_exoneration(
    *,
    cause: str,
    owner: str,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    """Mandatory when referee attributes a real cause (not flake)."""
    v = voice or _default_voice
    line = v.format(
        "exoneration",
        EXONERATION_LINES,
        cause=cause.rstrip("."),
        owner=owner,
    )
    _emit(line, log)
    return line


def narrate_flake_confirmed(
    *,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    v = voice or _default_voice
    line = v.pick("flake", FLAKE_LINES)
    _emit(line, log)
    return line


def narrate_ledger_block(
    referee_name: str,
    *,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    v = voice or _default_voice
    line = v.format(
        "ledger_block",
        LEDGER_BLOCK_LINES,
        referee=referee_name,
    )
    _emit(line, log)
    return line


def narrate_thrash_halt(
    *,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    v = voice or _default_voice
    line = v.pick("thrash_halt", THRASH_HALT_LINES)
    _emit(line, log)
    return line


def narrate_infra_halt(
    *,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    v = voice or _default_voice
    line = v.pick("infra_halt", INFRA_HALT_LINES)
    _emit(line, log)
    return line


def narrate_crash(
    *,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    v = voice or _default_voice
    line = v.pick("crash", CRASH_LINES)
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
    voice: StoryVoice = field(default_factory=StoryVoice)

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
    voice: StoryVoice | None = None,
) -> str:
    """Chapter break before a gate or fix worker (replaces bare gates + clock-in)."""
    v = voice or _default_voice
    who = format_agent_label(role, name)
    if fix_attempt is not None and fix_max is not None:
        mid = f"fix {fix_attempt}/{fix_max}"
    elif act is not None and total is not None:
        mid = f"{act}/{total} {gate_label}"
    else:
        mid = gate_label
    line = v.format(
        "chapter_open",
        CHAPTER_OPEN_LINES,
        slice_id=str(slice_id),
        mid=mid,
        who=who,
    )
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
    voice: StoryVoice | None = None,
) -> str:
    v = voice or _default_voice
    time_bit = f" ({_fmt_elapsed(elapsed_secs)})" if elapsed_secs is not None else ""
    next_bit = ""
    if next_label:
        who = f" · {next_name}" if next_name else ""
        next_bit = f" — next: {next_label}{who}"
    line = v.format(
        "gate_cleared",
        GATE_CLEARED_LINES,
        name=name,
        gate=gate_label,
        time=time_bit,
        next=next_bit,
    )
    _emit(line, log)
    return line


def extract_gate_stuck_body(explain_msg: str) -> str:
    """Pull the actionable body from explain_gate_pending output."""
    body = (explain_msg or "").strip()
    marker = " — stopping."
    if marker in body:
        body = body.split(marker, 1)[1].strip()
    body = body.lstrip(". ").strip()
    if body.startswith("(") and body.endswith(")"):
        body = body[1:-1].strip()
    for prefix in ("gate ",):
        if body.lower().startswith(prefix):
            rest = body.split(" still pending after worker", 1)
            if len(rest) > 1:
                body = rest[1].strip().lstrip(". ").strip()
            break
    unblock = " unblock:"
    if unblock in body.lower():
        idx = body.lower().index(unblock)
        body = body[:idx].strip().rstrip(";") + ". " + body[idx + len(unblock) :].strip()
    return body


def narrate_failure_detail(
    name: str,
    packet: FailurePacket | None,
    *,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    """Character-voiced test failure report with test / intent / got."""
    from failure_packet import FailurePacket as _FailurePacket, failure_story_parts

    v = voice or _default_voice
    if not isinstance(packet, _FailurePacket):
        return ""
    parts = failure_story_parts(packet)
    murphy_tail = v.pick("verify_red", VERIFY_RED_TAILS)
    blame = v.pick("murphy_blame", MURPHY_BLAME_LINES)
    line = v.format(
        "failure_detail",
        FAILURE_DETAIL_LINES,
        name=name,
        murphy_tail=murphy_tail,
        test=parts["test"],
        intent=parts["intent"],
        got=parts["got"],
        blame=blame,
    )
    _emit(line, log)
    return line


def narrate_role_report(
    name: str,
    detail: str,
    *,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    """Generic in-character report (gate stuck, worker status, etc.)."""
    v = voice or _default_voice
    body = re.sub(r"\s+", " ", (detail or "").strip())
    if not body:
        return ""
    line = v.format(
        "role_report",
        ROLE_REPORT_LINES,
        name=name,
        detail=body,
    )
    _emit(line, log)
    return line


def narrate_gate_stuck(
    gate_label: str,
    explain_msg: str,
    *,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    """Story-shaped stuck line; ``explain_msg`` from explain_gate_pending."""
    v = voice or _default_voice
    body = (explain_msg or "").strip()
    marker = " — stopping."
    if marker in body:
        body = body.split(marker, 1)[1].strip()
    body = body.lstrip(". ").strip()
    if not body:
        line = f"✗ {gate_label} stuck"
    else:
        line = v.format(
            "gate_stuck",
            GATE_STUCK_LINES,
            gate=gate_label,
            body=body,
        )
    _emit(line, log)
    return line


def print_coordinator_shift_banner(
    *,
    slice_id: int,
    title: str,
    slice_file: str,
    mission: str,
) -> str:
    """Scannable ═══ banner printed once at slice kickoff (stdout, no log prefix)."""
    from slice_loop_progress import slice_start_banner

    banner = slice_start_banner(slice_id, title, slice_file, mission=mission)
    print(banner, flush=True)
    return banner


def narrate_coordinator_shift_prose(
    *,
    coordinator_name: str,
    slice_id: int,
    title: str,
    mission: str,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    """One-line coordinator check-in below the banner (banner owns slice + mission)."""
    del slice_id, title, mission  # banner already printed; prose must not repeat.
    v = voice or _default_voice
    name = (coordinator_name or "Coordinator").strip() or "Coordinator"
    line = v.format(
        "coord_shift_open",
        COORDINATOR_SHIFT_OPEN_LINES,
        name=name,
    )
    _emit(line, log)
    return line


def narrate_coordinator_shift_open(
    *,
    coordinator_name: str,
    slice_id: int,
    title: str,
    slice_file: str,
    mission: str,
    log: LogFn | None = None,
    voice: StoryVoice | None = None,
) -> str:
    """Banner + template coordinator check-in."""
    print_coordinator_shift_banner(
        slice_id=slice_id,
        title=title,
        slice_file=slice_file,
        mission=mission,
    )
    return narrate_coordinator_shift_prose(
        coordinator_name=coordinator_name,
        slice_id=slice_id,
        title=title,
        mission=mission,
        log=log,
        voice=voice,
    )


def normalize_floor_speech(text: str) -> str:
    """Collapse streaming whitespace/newlines into readable prose."""
    return re.sub(r"\s+", " ", (text or "").strip())


def parse_shift_narration_lines(text: str, *, max_lines: int = 3) -> list[str]:
    """Split LLM shift copy into console lines."""
    raw = normalize_floor_speech(text)
    if not raw:
        return []
    chunks = re.split(r"(?<=[.!?])\s+", raw)
    lines = [c.strip() for c in chunks if c.strip()]
    return lines[:max_lines]


def narrate_coordinator_shift_llm(
    lines: list[str],
    *,
    log: LogFn | None = None,
) -> str:
    # Guard: accidental per-token fragments (streaming chunks treated as lines).
    if len(lines) > 3 and sum(1 for ln in lines if len(ln.split()) <= 1) >= len(lines) - 1:
        lines = parse_shift_narration_lines("".join(lines), max_lines=3)
    out: list[str] = []
    for line in lines:
        clean = normalize_floor_speech(line)
        if clean:
            out.append(clean)
            _emit(clean, log)
    return "\n".join(out)


def narrate_slice_mission(
    *,
    slice_id: int,
    mission: str,
    log: LogFn | None = None,
) -> str:
    """Opening beat: what this slice is trying to accomplish."""
    body = (mission or "").strip() or "advance the product"
    line = f"📋 Slice {slice_id} — {body}"
    _emit(line, log)
    return line


def format_coordinator_report(
    *,
    coordinator_name: str,
    slice_id: int,
    title: str,
    elapsed_secs: int,
    green: bool,
    mission: str | None = None,
    accomplishment: str | None = None,
    cast_names: list[str] | None = None,
    murphy_visits: int = 0,
    verify: dict[str, str] | None = None,
    session: tuple[int, int] | None = None,
    voice: StoryVoice | None = None,
) -> str:
    """End-of-slice shift report from the named Forge coordinator."""
    v = voice or _default_voice
    who = (coordinator_name or "Coordinator").strip() or "Coordinator"
    opener_tpl = (
        COORDINATOR_REPORT_OPENERS
        if green
        else (
            "Slice {slice_id} did not finish green this run.",
            "Shift report: slice {slice_id} halted before verify went green.",
            "Handing off mid-shift — slice {slice_id} needs another pass.",
        )
    )
    opener = v.format(
        "coord_report_open",
        opener_tpl,
        name=who,
        slice_id=str(slice_id),
    )
    lines = [
        "",
        f"── Coordinator {who} · shift report ──",
        opener,
        f"Slice {slice_id:02d} · {title} · {_fmt_elapsed(elapsed_secs)} on the clock.",
    ]
    if mission:
        lines.append(f"We set out to {_sentence_lower(mission)}")
    if accomplishment:
        body = accomplishment.strip()
        if green:
            lines.append(body if body.lower().startswith("shipped") else f"Delivered: {body}")
        else:
            lines.append(f"Target: {body}")
    if cast_names:
        crew = ", ".join(cast_names)
        murphy_bit = f" · Murphy ×{murphy_visits}" if murphy_visits else ""
        lines.append(f"Crew on the floor: {crew}{murphy_bit}")
    elif murphy_visits:
        lines.append(f"Murphy visits this slice: ×{murphy_visits}")
    if verify:
        lines.append(
            f"Verify: exit={verify.get('exit', '?')} · "
            f"passed={verify.get('passed', '?')}/{verify.get('total', '?')} · "
            f"skipped={verify.get('skipped', '?')}"
        )
    if session:
        lines.append(f"Session: {session[0]}/{session[1]} slices completed this run.")
    closer_pool = COORDINATOR_REPORT_CLOSERS if green else COORDINATOR_REPORT_HALT_CLOSERS
    lines.append(v.pick("coord_report_close", closer_pool))
    return "\n".join(lines)


def narrate_coordinator_report(
    *,
    coordinator_name: str,
    slice_id: int,
    title: str,
    elapsed_secs: int,
    green: bool,
    mission: str | None = None,
    accomplishment: str | None = None,
    cast_names: list[str] | None = None,
    murphy_visits: int = 0,
    verify: dict[str, str] | None = None,
    session: tuple[int, int] | None = None,
    voice: StoryVoice | None = None,
    log: LogFn | None = None,
) -> str:
    report = format_coordinator_report(
        coordinator_name=coordinator_name,
        slice_id=slice_id,
        title=title,
        elapsed_secs=elapsed_secs,
        green=green,
        mission=mission,
        accomplishment=accomplishment,
        cast_names=cast_names,
        murphy_visits=murphy_visits,
        verify=verify,
        session=session,
        voice=voice,
    )
    for line in report.split("\n"):
        if line.strip():
            _emit(line, log)
    return report


def _sentence_lower(text: str) -> str:
    s = (text or "").strip()
    if not s:
        return s
    return s[0].lower() + s[1:] if len(s) > 1 else s.lower()


def format_slice_recap(
    *,
    slice_id: int,
    elapsed_secs: int,
    cast: CastLog,
    outcome: str,
    accomplishment: str | None = None,
) -> str:
    names = ", ".join(cast.cast_names()) or "—"
    base = (
        f"{FACTORY_NAME} recap · slice {slice_id} · {_fmt_elapsed(elapsed_secs)} · "
        f"{names} · Murphy ×{cast.murphy_visits} · {outcome}"
    )
    if accomplishment and outcome == "green":
        return f"{base}\n→ {accomplishment.strip()}"
    return base


def narrate_slice_recap(
    *,
    slice_id: int,
    elapsed_secs: int,
    cast: CastLog,
    outcome: str,
    accomplishment: str | None = None,
    log: LogFn | None = None,
) -> str:
    line = format_slice_recap(
        slice_id=slice_id,
        elapsed_secs=elapsed_secs,
        cast=cast,
        outcome=outcome,
        accomplishment=accomplishment,
    )
    for part in line.split("\n"):
        _emit(part, log)
    return line


def _emit(line: str, log: LogFn | None) -> None:
    if log:
        log(line)
    else:
        print(line, flush=True)
