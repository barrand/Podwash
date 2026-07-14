#!/bin/sh
# PodWash next-task — dependency-aware "what's next?" brain for docs/tasks/.
#
# Usage:
#   scripts/next-task.sh            # human-readable
#   scripts/next-task.sh --json     # machine JSON (task-loop)
#   scripts/next-task.sh --status   # kanban table
#   scripts/next-task.sh --help
#
# Done when Status=Done AND VERIFY RESULT is green (tier-2 filtered=1 accepted).
# Needs-human tickets are never started by the automatable queue (action skips them).
# Among Queued (or equivalent) automatable tasks with deps met, pick highest
# Priority (P0>P1>P2>P3), then lowest id.
#
# Environment: PODWASH_TASKS_DIR=<dir>

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

TASKS_DIR=${PODWASH_TASKS_DIR:-docs/tasks}

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

MODE=human
case "${1:-}" in
    --json)   MODE=json ;;
    --status) MODE=status ;;
    -h|--help) usage; exit 0 ;;
    "")       MODE=human ;;
    *) echo "next-task.sh: unknown option: $1 (try --help)" >&2; exit 1 ;;
esac

if [ ! -d "$TASKS_DIR" ]; then
    echo "next-task.sh: tasks dir not found: $TASKS_DIR" >&2
    exit 1
fi

TMP=$(mktemp "${TMPDIR:-/tmp}/next-task.XXXXXX")
trap 'rm -f "$TMP"' EXIT INT TERM

# Record: id \t status \t verify_green \t deps \t title \t priority \t kind \t area \t file
PARSE_AWK='
BEGIN { status=""; title=""; kind=""; prio="P2"; area=""; vg=0; indeps=0; deps="" }
/^\| \*\*Status\*\* \|/ {
    split($0, a, "|"); v=a[3]; gsub(/^[ \t]+|[ \t]+$/, "", v); status=v; next
}
/^\| \*\*Title\*\* \|/ {
    split($0, a, "|"); v=a[3]; gsub(/^[ \t]+|[ \t]+$/, "", v); title=v; next
}
/^\| \*\*Kind\*\* \|/ {
    split($0, a, "|"); v=a[3]; gsub(/^[ \t]+|[ \t]+$/, "", v); kind=v; next
}
/^\| \*\*Priority\*\* \|/ {
    split($0, a, "|"); v=a[3]; gsub(/^[ \t]+|[ \t]+$/, "", v)
    if (v ~ /P0/) prio="P0"
    else if (v ~ /P1/) prio="P1"
    else if (v ~ /P2/) prio="P2"
    else if (v ~ /P3/) prio="P3"
    else prio="P2"
    next
}
/^\| \*\*Area\*\* \|/ {
    split($0, a, "|"); v=a[3]; gsub(/^[ \t]+|[ \t]+$/, "", v); area=v; next
}
/VERIFY RESULT:/ {
    if ($0 ~ /exit=0/ && $0 ~ /failed=0/ && $0 ~ /skipped=0/) vg=1
    next
}
/^## / {
    indeps = ($0 ~ /^## Depends on/) ? 1 : 0
    next
}
{
    if (indeps == 1 && $0 ~ /^[ \t]*[-*] /) {
        line=$0
        # "None" / "None (…)" is not a dependency — do not scrape numbers from prose.
        if (line ~ /^[ \t]*[-*][ \t]+[Nn]one([ \t]|[(]|$)/) next
        sub(/^[ \t]*[-*][ \t]+/, "", line)
        # Only explicit task refs at the start of the bullet:
        #   Task 007 … / task-007 … / 007 …
        dep=""
        if (match(line, /^[Tt]ask[ \t-]+[0-9]+/)) {
            dep = substr(line, RSTART, RLENGTH)
            gsub(/[^0-9]/, "", dep)
        } else if (match(line, /^[0-9]+/)) {
            dep = substr(line, RSTART, RLENGTH)
        }
        if (dep+0 > 0) deps = deps " " (dep+0)
    }
}
END {
    gsub(/^ +/, "", deps)
    gsub(/"/, "", area)
    gsub(/"/, "", title)
    printf "%s\t%d\t%s\t%s\t%s\t%s\t%s", status, vg, deps, title, prio, kind, area
}
'

shopt_null=0
for f in "$TASKS_DIR"/task-[0-9][0-9][0-9]-*.md; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    num=$(echo "$base" | sed -n 's/^task-\([0-9][0-9][0-9]\)-.*/\1/p')
    [ -n "$num" ] || continue
    id=$((10#$num))
    rest=$(awk "$PARSE_AWK" "$f")
    printf '%d\t%s\t%s\n' "$id" "$rest" "$f" >> "$TMP"
    shopt_null=1
done

if [ ! -s "$TMP" ]; then
    if [ "$MODE" = json ]; then
        printf '{"action":"done","message":"No task files found"}\n'
        exit 0
    fi
    echo "next-task.sh: no task files found in $TASKS_DIR" >&2
    exit 1
fi

# Fields after id: status vg deps title prio kind area file
# $1=id $2=status $3=vg $4=deps $5=title $6=prio $7=kind $8=area $9=file
DECIDE_AWK='
function prio_rank(p) {
    if (p == "P0") return 0
    if (p == "P1") return 1
    if (p == "P2") return 2
    if (p == "P3") return 3
    return 2
}
function open_node(x) {
    return (x in ids) && !done_[x] && !needs_human[x]
}
# Walk incomplete deps from `from`; true if we hit `target` (cycle / reachability).
function can_reach(from, target,   q, h, t, seen, cur, m, d, dd, i) {
    if (from+0 == target+0) return 1
    if (!open_node(from)) return 0
    delete seen
    h=1; t=0
    q[++t] = from+0
    seen[from+0] = 1
    while (h <= t) {
        cur = q[h++]
        m = split(deps[cur], d, " ")
        for (i=1; i<=m; i++) {
            dd = d[i]+0
            if (dd <= 0) continue
            if (dd == target+0) return 1
            if (!open_node(dd)) continue
            if (seen[dd]) continue
            seen[dd] = 1
            q[++t] = dd
        }
    }
    return 0
}
# Real blocker? Ignore missing/self/Done and edges that close a cycle (unblocks deadlocks).
function dep_blocks(id, dd) {
    if (dd <= 0) return 0
    if (dd == id) return 0
    if (done_[dd]) return 0
    if (!(dd in ids)) return 1
    if (can_reach(dd, id)) {
        printf "next-task.sh: ignoring cyclic dep task-%03d → task-%03d\n", id, dd > "/dev/stderr"
        return 0
    }
    return 1
}
{
    id=$1+0
    ids[id]=1
    status[id]=$2
    vg[id]=$3
    deps[id]=$4
    title[id]=$5
    prio[id]=$6
    kind[id]=$7
    area[id]=$8
    file[id]=$9
    done_[id] = ($2 == "Done" && $3+0 == 1) ? 1 : 0
    needs_human[id] = ($2 ~ /[Nn]eeds-[Hh]uman/ || $7 ~ /needs-human/) ? 1 : 0
    queued[id] = ($2 ~ /^Queued/ || $2 == "Ready") ? 1 : 0
}
END {
    n=0
    for (k in ids) arr[++n]=k+0
    for (i=1; i<=n; i++) for (j=i+1; j<=n; j++) if (arr[i] > arr[j]) { t=arr[i]; arr[i]=arr[j]; arr[j]=t }

    # Pass A: reclaim In Progress before offering Queued (never idle-drain past stuck work)
    candidate=-1
    for (pass = 0; pass <= 3; pass++) {
        for (i=1; i<=n; i++) {
            id=arr[i]
            if (needs_human[id]) continue
            if (status[id] !~ /^In Progress/) continue
            if (prio_rank(prio[id]) != pass) continue
            candidate=id
            break
        }
        if (candidate >= 0) break
    }
    if (candidate >= 0) {
        id=candidate
        printf "start\t%d\t%s\t%s\t\t%s\t%s\t%s\n", id, file[id], title[id], prio[id], kind[id], area[id]
        exit
    }

    candidate=-1
    lowest_blocked=-1
    blocked_miss=""
    for (pass = 0; pass <= 3; pass++) {
        for (i=1; i<=n; i++) {
            id=arr[i]
            if (done_[id]) continue
            if (needs_human[id]) continue
            if (!(status[id] ~ /^Queued/ || status[id] == "Ready")) continue
            if (prio_rank(prio[id]) != pass) continue
            ok=1
            miss=""
            m=split(deps[id], d, " ")
            for (k=1; k<=m; k++) {
                dd=d[k]+0
                if (dep_blocks(id, dd)) { ok=0; miss = miss " " dd }
            }
            if (ok) { candidate=id; break }
            if (lowest_blocked < 0) { lowest_blocked=id; gsub(/^ +/, "", miss); blocked_miss=miss }
        }
        if (candidate >= 0) break
    }

    if (candidate < 0) {
        # Halted open work — park for Requeue; do not report done (idle-drain FULL-VERIFY)
        halted_first=-1
        halted_ids=""
        for (i=1; i<=n; i++) {
            id=arr[i]
            if (status[id] ~ /^Halted/) {
                if (halted_first < 0) halted_first=id
                halted_ids = halted_ids " " id
            }
        }
        if (halted_first >= 0) {
            gsub(/^ +/, "", halted_ids)
            printf "park\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", halted_first, file[halted_first], title[halted_first], halted_ids, prio[halted_first], kind[halted_first], area[halted_first]
            exit
        }
        any_open=0
        for (i=1; i<=n; i++) {
            id=arr[i]
            if (!done_[id] && !needs_human[id] && status[id] !~ /^Done/) any_open=1
        }
        if (!any_open || lowest_blocked < 0) { printf "done\t\t\t\t\t\t\t\n"; exit }
        printf "wait\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", lowest_blocked, file[lowest_blocked], title[lowest_blocked], blocked_miss, prio[lowest_blocked], kind[lowest_blocked], area[lowest_blocked]
        exit
    }

    id=candidate
    printf "start\t%d\t%s\t%s\t\t%s\t%s\t%s\n", id, file[id], title[id], prio[id], kind[id], area[id]
}
'

RESULT=$(awk -F'\t' "$DECIDE_AWK" "$TMP")

ACTION=$(printf '%s' "$RESULT" | cut -f1)
RID=$(printf '%s' "$RESULT" | cut -f2)
RFILE=$(printf '%s' "$RESULT" | cut -f3)
RTITLE=$(printf '%s' "$RESULT" | cut -f4)
REXTRA=$(printf '%s' "$RESULT" | cut -f5)
RPRIO=$(printf '%s' "$RESULT" | cut -f6)
RKIND=$(printf '%s' "$RESULT" | cut -f7)
RAREA=$(printf '%s' "$RESULT" | cut -f8)

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if [ "$MODE" = status ]; then
    awk -F'\t' '
    {
        id=$1+0; ids[id]=1; status[id]=$2; vg[id]=$3; deps[id]=$4
        prio[id]=$6; kind[id]=$7
        done_[id] = ($2 == "Done" && $3+0 == 1) ? 1 : 0
    }
    END {
        n=0; for (k in ids) arr[++n]=k+0
        for (i=1; i<=n; i++) for (j=i+1; j<=n; j++) if (arr[i] > arr[j]) { t=arr[i]; arr[i]=arr[j]; arr[j]=t }
        printf "%-5s  %-8s  %-12s  %-11s  %s\n", "ID", "Prio", "Kind", "Status", "DepsMet"
        for (i=1; i<=n; i++) {
            id=arr[i]; blocked=""
            m=split(deps[id], d, " ")
            for (k=1; k<=m; k++) { dd=d[k]+0; if (dd>0 && !done_[dd]) blocked = blocked (blocked=="" ? "" : " ") dd }
            depsmet = done_[id] ? "done" : (blocked=="" ? "yes" : "no")
            printf "%-5s  %-8s  %-12s  %-11s  %s\n", sprintf("%03d", id), prio[id], kind[id], status[id], depsmet
        }
    }
    ' "$TMP"
    exit 0
fi

if [ "$MODE" = json ]; then
    case "$ACTION" in
        start)
            printf '{"action":"start","id":%d,"file":"%s","title":"%s","priority":"%s","kind":"%s","area":"%s","prompt":"Run task-%03d per %s via rapid_task_pipeline (QA tests then Engineer; tier-2 verify)."}\n' \
                "$RID" "$(json_escape "$RFILE")" "$(json_escape "$RTITLE")" "$(json_escape "$RPRIO")" "$(json_escape "$RKIND")" "$(json_escape "$RAREA")" "$RID" "$(json_escape "$RFILE")"
            ;;
        wait)
            arr=""
            for d in $REXTRA; do arr="${arr:+$arr,}$d"; done
            printf '{"action":"wait","id":%d,"blocked_by":[%s],"message":"Task %03d waiting on task(s) %s"}\n' "$RID" "$arr" "$RID" "$REXTRA"
            ;;
        park)
            printf '{"action":"wait","id":%d,"blocked_by":[],"message":"Halted task(s) %s need Requeue — not idle-draining to full verify"}\n' \
                "$RID" "$(json_escape "$REXTRA")"
            ;;
        done)
            printf '{"action":"done","message":"No eligible automatable tasks remaining"}\n'
            ;;
    esac
    exit 0
fi

case "$ACTION" in
    start)
        printf 'Next task: %03d — %s (%s %s)\n' "$RID" "$RTITLE" "$RPRIO" "$RKIND"
        printf 'File: %s\n' "$RFILE"
        printf 'Area: %s\n' "$RAREA"
        printf 'Run: scripts/task-loop.sh  (or Forge Floor → Start)\n'
        ;;
    wait)
        printf 'WAIT — Task %03d blocked by: %s\n' "$RID" "$REXTRA"
        ;;
    park)
        printf 'WAIT — Halted task(s) %s need Requeue before idle drain / full verify\n' "$REXTRA"
        ;;
    done)
        printf 'DONE — no eligible automatable tasks remaining.\n'
        ;;
esac
exit 0
