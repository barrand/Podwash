#!/usr/bin/env python3
"""Forge supervisor — optional self-heal wrapper around slice_loop.py.

Runs ``slice_loop.py`` as a subprocess so medic patches reload on resume.
Thin by design: exit dispatch, budgets, invoke ``forge_medic.run_medic_heal``.

Usage:
  scripts/slice-loop.sh --self-heal …
  python3 scripts/forge_supervisor.py --self-heal --max 1
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from typing import Sequence

# Exit codes — mirror slice_loop.py (do not import the pipeline).
EXIT_OK = 0
EXIT_STARTUP = 1
EXIT_RUN_FAILED = 2
EXIT_WAIT = 3
EXIT_HALT = 4
EXIT_THRASH = 5
EXIT_INFRA = 6

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOOP_PY = os.path.join(REPO_ROOT, "scripts", "slice_loop.py")


def log(msg: str) -> None:
    print(f"[forge-supervisor] {msg}", flush=True)


def strip_supervisor_args(argv: Sequence[str]) -> tuple[list[str], dict[str, bool]]:
    """Remove supervisor-only flags; return (loop_argv, flags)."""
    flags = {
        "self_heal": False,
        "medic_no_push": False,
        "medic_no_commit": False,
    }
    out: list[str] = []
    for arg in argv:
        if arg == "--self-heal":
            flags["self_heal"] = True
            continue
        if arg == "--medic-no-push":
            flags["medic_no_push"] = True
            continue
        if arg == "--medic-no-commit":
            flags["medic_no_commit"] = True
            continue
        out.append(arg)
    return out, flags


def run_slice_loop(loop_argv: list[str], *, python: str | None = None) -> int:
    py = python or sys.executable
    cmd = [py, LOOP_PY, *loop_argv]
    log(f"spawn slice_loop: {' '.join(cmd[1:])}")
    proc = subprocess.run(cmd, cwd=REPO_ROOT)
    return int(proc.returncode)


def _peek_slice_id() -> int | None:
    """Best-effort slice id from newest halt.json."""
    sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))
    from forge_medic import find_halt_bundle, load_halt_json

    bundle = find_halt_bundle(REPO_ROOT)
    if not bundle:
        return None
    try:
        halt = load_halt_json(bundle)
    except (OSError, ValueError):
        return None
    sid = halt.get("slice")
    if isinstance(sid, int):
        return sid
    if isinstance(sid, str) and sid.isdigit():
        return int(sid)
    return None


def run_medic(
    *,
    exit_code: int,
    do_push: bool,
    do_commit: bool,
    session_heal_count: int,
) -> tuple[bool, int]:
    """Invoke medic heal. Returns (resume_loop, new_session_heal_count)."""
    sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))
    from forge_medic import MAX_HEALS_PER_SESSION, run_medic_heal

    slice_id = _peek_slice_id()
    result = run_medic_heal(
        repo_root=REPO_ROOT,
        exit_code=exit_code,
        slice_id=slice_id,
        log=log,
        do_commit=do_commit,
        do_push=do_push,
        session_heal_count=session_heal_count,
    )
    new_count = session_heal_count + (1 if result.outcome != "signature_repeat" else 0)
    # Count only real heal attempts that burned budget
    if result.outcome in (
        "healed",
        "canary_failed",
        "suite_failed",
        "denylist",
        "path_guard",
        "implement_failed",
        "critic_blocked",
        "diagnose_failed",
        "diagnose_parse",
        "lane_test",
        "empty_delta",
    ):
        new_count = session_heal_count + 1
    else:
        new_count = session_heal_count

    if result.ok:
        log(f"medic healed sig={result.signature} — resuming slice_loop")
        return True, new_count

    log(f"medic stopped ({result.outcome}) — human needed")
    if new_count >= MAX_HEALS_PER_SESSION:
        log(f"session medic cap {MAX_HEALS_PER_SESSION} exhausted")
    return False, new_count


def supervisor_main(argv: Sequence[str] | None = None) -> int:
    argv = list(argv if argv is not None else sys.argv[1:])
    loop_argv, flags = strip_supervisor_args(argv)

    if not flags["self_heal"]:
        # Passthrough without heal (caller should normally use slice_loop)
        return run_slice_loop(loop_argv)

    # Parse known dry-run early — no medic on dry-run
    if "--dry-run" in loop_argv:
        return run_slice_loop(loop_argv)

    do_push = not flags["medic_no_push"]
    do_commit = not flags["medic_no_commit"]
    if flags["medic_no_commit"]:
        do_push = False

    session_heals = 0
    infra_retried = False

    while True:
        rc = run_slice_loop(loop_argv)

        if rc == EXIT_OK:
            return EXIT_OK
        if rc in (EXIT_WAIT, EXIT_HALT, EXIT_STARTUP, EXIT_RUN_FAILED):
            # Never medic these
            return rc

        if rc == EXIT_INFRA:
            if not infra_retried:
                infra_retried = True
                log("infra exit=6 — one free plain retry before medic")
                continue
            log("infra recurred — invoking medic")
            resume, session_heals = run_medic(
                exit_code=EXIT_INFRA,
                do_push=do_push,
                do_commit=do_commit,
                session_heal_count=session_heals,
            )
            if resume:
                infra_retried = False  # fresh process after heal
                continue
            return EXIT_INFRA

        if rc == EXIT_THRASH:
            log("thrash exit=5 — invoking medic")
            resume, session_heals = run_medic(
                exit_code=EXIT_THRASH,
                do_push=do_push,
                do_commit=do_commit,
                session_heal_count=session_heals,
            )
            if resume:
                infra_retried = False
                continue
            return EXIT_THRASH

        log(f"unexpected exit={rc} — stopping (no medic)")
        return rc if rc else EXIT_RUN_FAILED


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Forge supervisor — slice_loop with optional Medic self-heal",
    )
    p.add_argument(
        "--self-heal",
        action="store_true",
        help="on exit 5/6, run Medic heal then resume (default off when using slice_loop directly)",
    )
    p.add_argument(
        "--medic-no-push",
        action="store_true",
        help="medic commits but does not push",
    )
    p.add_argument(
        "--medic-no-commit",
        action="store_true",
        help="medic leaves a dirty tree (no commit/push)",
    )
    # Remaining args forwarded to slice_loop — documented there
    p.add_argument("loop_args", nargs=argparse.REMAINDER, help=argparse.SUPPRESS)
    return p


if __name__ == "__main__":
    # Allow `python forge_supervisor.py --help` but forward unknown to loop
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        build_arg_parser().print_help()
        print(
            "\nAll other flags are forwarded to scripts/slice_loop.py "
            "(e.g. --max, --orchestrator, --no-push)."
        )
        sys.exit(0)
    sys.exit(supervisor_main())
