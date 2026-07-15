#!/bin/sh
# PodWash next-work — unified "what's next?" brain for tasks + slices.
#
# Usage:
#   scripts/next-work.sh            # human-readable
#   scripts/next-work.sh --json     # machine JSON (forge_loop)
#   scripts/next-work.sh --help
#
# Priority: reclaim In Progress (task or slice), then highest Priority among
# Queued tasks (P0>P1>P2>P3), then eligible slices (default P3). Tasks win ties
# at the same priority rank when both are startable.
#
# Implemented (tier-2 green) counts as complete for deps / queue advancement —
# same as Done for "is this work finished?" purposes. Ship-gate Done is separate.
#
# Environment: PODWASH_TASKS_DIR, PODWASH_SLICES_DIR

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

MODE=human
case "${1:-}" in
    --json)   MODE=json ;;
    -h|--help) usage; exit 0 ;;
    "")       MODE=human ;;
    *) echo "next-work.sh: unknown option: $1 (try --help)" >&2; exit 1 ;;
esac

TASK_JSON=$(PODWASH_TASKS_DIR="${PODWASH_TASKS_DIR:-}" "$REPO_ROOT/scripts/next-task.sh" --json 2>/dev/null || printf '{"action":"done"}')
SLICE_JSON=$(PODWASH_SLICES_DIR="${PODWASH_SLICES_DIR:-}" "$REPO_ROOT/scripts/next-slice.sh" --json 2>/dev/null || printf '{"action":"done"}')

RESULT=$(/usr/bin/python3 - "$TASK_JSON" "$SLICE_JSON" <<'PY'
import json, sys

task = json.loads(sys.argv[1] or "{}")
slc = json.loads(sys.argv[2] or "{}")

def prio_rank(p: str) -> int:
    return {"P0": 0, "P1": 1, "P2": 2, "P3": 3}.get((p or "P2").strip(), 2)

# Prefer reclaiming In Progress via each brain's start (next-task reclaims first).
ta = task.get("action")
sa = slc.get("action")

def emit(kind: str, d: dict) -> None:
    out = dict(d)
    out["kind"] = kind
    print(json.dumps(out, separators=(",", ":")))

# Halt-and-ask on slices blocks the unified queue when it is the next slice.
if sa == "halt" and ta != "start":
    emit("slice", slc)
    sys.exit(0)

if ta == "start" and sa == "start":
    tp = prio_rank(task.get("priority") or "P1")
    # Slices default P3 unless a Priority field is later added to slice JSON.
    sp = prio_rank(slc.get("priority") or "P3")
    if tp <= sp:
        emit("task", task)
    else:
        emit("slice", slc)
    sys.exit(0)

if ta == "start":
    emit("task", task)
    sys.exit(0)

if sa == "start":
    emit("slice", slc)
    sys.exit(0)

if sa == "halt":
    emit("slice", slc)
    sys.exit(0)

if ta == "wait":
    emit("task", task)
    sys.exit(0)

if sa == "wait":
    emit("slice", slc)
    sys.exit(0)

emit("none", {"action": "done", "message": "No eligible work remaining"})
PY
)

ACTION=$(printf '%s' "$RESULT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("action",""))')

if [ "$MODE" = json ]; then
    printf '%s\n' "$RESULT"
    exit 0
fi

KIND=$(printf '%s' "$RESULT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("kind",""))')
case "$ACTION" in
    start)
        printf 'Next work: %s — %s\n' "$KIND" "$RESULT"
        printf 'Run: scripts/forge.sh  (or Forge Floor → Start Forge)\n'
        ;;
    halt)
        printf 'HALT — %s needs a decision: %s\n' "$KIND" "$RESULT"
        ;;
    wait)
        printf 'WAIT — %s\n' "$RESULT"
        ;;
    done)
        printf 'DONE — no eligible work remaining.\n'
        ;;
    *)
        printf '%s\n' "$RESULT"
        ;;
esac
exit 0
