#!/bin/sh
# PodWash next-slice runner — the dependency-aware "what do I run next?" brain.
#
# Reads the slice stories under docs/slices/ and decides the single next slice
# to run, respecting `## Depends on` dependencies and halt-and-ask gates. It
# never modifies any file; it only reports.
#
# Usage:
#   scripts/next-slice.sh            # human-readable summary + copy-paste coordinator prompt
#   scripts/next-slice.sh --json     # one machine-readable JSON object (for future automation)
#   scripts/next-slice.sh --status   # table of every slice: ID, status, deps-met, blocked-by
#   scripts/next-slice.sh --help     # this help
#
# A slice counts as DONE only when BOTH are true (conservative finish signal, so
# a half-finished slice never advances the queue):
#   - its file has `| **Status** | Done |`
#   - its verification record has a `VERIFY RESULT: exit=0 ... failed=0 ... skipped=0` line
#
# Actions:
#   start  lowest eligible (deps all Done, not halt-gated) slice — run it now
#   halt   lowest eligible slice needs a user decision first (halt-and-ask gate)
#   wait   every remaining slice is blocked on an unfinished dependency
#   done   no slices remain — the queue is complete
#
# Environment overrides:
#   PODWASH_SLICES_DIR=<dir>   scan a different slices directory (used by tests)
#
# Sequential policy: among eligible slices, the LOWEST slice number is chosen.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

SLICES_DIR=${PODWASH_SLICES_DIR:-docs/slices}

# Slices that require a product decision (halt-and-ask) before an agent starts.
# Hardcoded from docs/slices/README.md to avoid false positives on slices that
# only mention halt-and-ask for a narrow sub-case (e.g. slice 05's iOS floor).
HALT_SLICES="11 13 15 17"

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

MODE=human
case "${1:-}" in
    --json)   MODE=json ;;
    --status) MODE=status ;;
    -h|--help) usage; exit 0 ;;
    "")       MODE=human ;;
    *) echo "next-slice.sh: unknown option: $1 (try --help)" >&2; exit 1 ;;
esac

if [ ! -d "$SLICES_DIR" ]; then
    echo "next-slice.sh: slices dir not found: $SLICES_DIR" >&2
    exit 1
fi

# ---------------------------------------------------------------- parse pass --
# Emit one TAB-separated record per slice file:
#   id \t status \t verify_green \t deps(space-sep) \t title \t file
TMP=$(mktemp "${TMPDIR:-/tmp}/next-slice.XXXXXX")
trap 'rm -f "$TMP"' EXIT INT TERM

PARSE_AWK='
BEGIN { status=""; title=""; vg=0; indeps=0; deps="" }
/^\| \*\*Status\*\* \|/ {
    split($0, a, "|"); v=a[3]; gsub(/^[ \t]+|[ \t]+$/, "", v); status=v; next
}
/^\| \*\*Title\*\* \|/ {
    split($0, a, "|"); v=a[3]; gsub(/^[ \t]+|[ \t]+$/, "", v); title=v; next
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
        # Only bullet lines. Strip everything but digits, then collect numbers.
        # (The "**Parallelizable:**" note is not a bullet, so its slice numbers
        # are correctly ignored.)
        tmp=$0
        gsub(/[^0-9]/, " ", tmp)
        m=split(tmp, b, " ")
        for (i=1; i<=m; i++) if (b[i]+0 > 0) deps = deps " " (b[i]+0)
    }
}
END {
    gsub(/^ +/, "", deps)
    printf "%s\t%d\t%s\t%s", status, vg, deps, title
}
'

for f in "$SLICES_DIR"/slice-[0-9][0-9]-*.md; do
    [ -e "$f" ] || continue
    case "$f" in
        *-ux.md) continue ;;
    esac
    base=$(basename "$f")
    num=$(echo "$base" | sed -n 's/^slice-\([0-9][0-9]\)-.*/\1/p')
    [ -n "$num" ] || continue
    id=$((10#$num))
    rest=$(awk "$PARSE_AWK" "$f")
    printf '%d\t%s\t%s\n' "$id" "$rest" "$f" >> "$TMP"
done

if [ ! -s "$TMP" ]; then
    echo "next-slice.sh: no slice files found in $SLICES_DIR" >&2
    exit 1
fi

# --------------------------------------------------------------- decide pass --
# Reads the records, computes the next action, prints a single result line:
#   action \t id \t file \t title \t extra
# where extra = space-separated blocked-by ids (wait) or empty otherwise.
DECIDE_AWK='
BEGIN { split(HALT, hs, " "); for (i in hs) halt[hs[i]+0]=1 }
{
    id=$1+0
    ids[id]=1
    status[id]=$2
    vg[id]=$3
    deps[id]=$4
    title[id]=$5
    file[id]=$6
    done_[id] = ($2 == "Done" && $3+0 == 1) ? 1 : 0
}
END {
    n=0
    for (k in ids) arr[++n]=k+0
    for (i=1; i<=n; i++) for (j=i+1; j<=n; j++) if (arr[i] > arr[j]) { t=arr[i]; arr[i]=arr[j]; arr[j]=t }

    candidate=-1; lowest_nondone=-1
    for (i=1; i<=n; i++) {
        id=arr[i]
        if (done_[id]) continue
        if (lowest_nondone < 0) lowest_nondone=id
        ok=1
        m=split(deps[id], d, " ")
        for (k=1; k<=m; k++) if (!done_[d[k]+0]) ok=0
        if (ok) { candidate=id; break }
    }

    if (lowest_nondone < 0) { printf "done\t\t\t\t\n"; exit }

    if (candidate < 0) {
        id=lowest_nondone; miss=""
        m=split(deps[id], d, " ")
        for (k=1; k<=m; k++) if (!done_[d[k]+0]) miss = miss " " (d[k]+0)
        gsub(/^ +/, "", miss)
        printf "wait\t%d\t%s\t%s\t%s\n", id, file[id], title[id], miss
        exit
    }

    id=candidate
    action = halt[id] ? "halt" : "start"
    printf "%s\t%d\t%s\t%s\t\n", action, id, file[id], title[id]
}
'

RESULT=$(awk -F'\t' -v HALT="$HALT_SLICES" "$DECIDE_AWK" "$TMP")

ACTION=$(printf '%s' "$RESULT" | cut -f1)
RID=$(printf '%s' "$RESULT" | cut -f2)
RFILE=$(printf '%s' "$RESULT" | cut -f3)
RTITLE=$(printf '%s' "$RESULT" | cut -f4)
REXTRA=$(printf '%s' "$RESULT" | cut -f5)

# Human-readable deps line for the chosen slice ("Slice 01 (Done), ...").
deps_desc() {
    _id=$1
    _deps=$(awk -F'\t' -v id="$_id" '($1+0==id){print $4}' "$TMP")
    [ -n "$_deps" ] || { printf 'None'; return; }
    _out=""
    for d in $_deps; do
        _st=$(awk -F'\t' -v id="$d" '($1+0==id){print $2}' "$TMP")
        _vg=$(awk -F'\t' -v id="$d" '($1+0==id){print $3}' "$TMP")
        if [ "$_st" = "Done" ] && [ "${_vg:-0}" = "1" ]; then
            _state="Done"
        elif [ -z "$_st" ]; then
            _state="missing"
        else
            _state="$_st"
        fi
        _label=$(printf 'Slice %02d (%s)' "$d" "$_state")
        _out="${_out:+$_out, }$_label"
    done
    printf '%s' "$_out"
}

coordinator_prompt_oneline() {
    printf 'Run Slice %02d per %s. Coordinator: enforce gates, spawn role subagents as needed (Architect/Engineer -> Grok 4.5 High grok-4.5[effort=high,fast=false]; PM/UX/QA -> Composer 2.5). Never grok-4.5-fast-xhigh. Done = scripts/verify.sh full suite green + verification record + auto-commit. If this slice hits a halt-and-ask item, stop and ask before implementation.' "$1" "$2"
}

coordinator_prompt_block() {
    cat <<EOF
Run Slice $(printf '%02d' "$1") per $2.
Coordinator: enforce gates, spawn role subagents as needed
(Architect/Engineer -> Grok 4.5 High; PM/UX/QA -> Composer 2.5).
Done = scripts/verify.sh full suite green + verification record + auto-commit.
If this slice hits a halt-and-ask item, stop and ask before implementation.
EOF
}

# ----------------------------------------------------------------- --status --
if [ "$MODE" = status ]; then
    awk -F'\t' '
    {
        id=$1+0; ids[id]=1; status[id]=$2; vg[id]=$3; deps[id]=$4
        done_[id] = ($2 == "Done" && $3+0 == 1) ? 1 : 0
    }
    END {
        n=0; for (k in ids) arr[++n]=k+0
        for (i=1; i<=n; i++) for (j=i+1; j<=n; j++) if (arr[i] > arr[j]) { t=arr[i]; arr[i]=arr[j]; arr[j]=t }
        printf "%-4s  %-11s  %-8s  %s\n", "ID", "Status", "DepsMet", "BlockedBy"
        printf "%-4s  %-11s  %-8s  %s\n", "--", "------", "-------", "---------"
        for (i=1; i<=n; i++) {
            id=arr[i]; blocked=""
            m=split(deps[id], d, " ")
            for (k=1; k<=m; k++) { dd=d[k]+0; if (!done_[dd]) blocked = blocked (blocked=="" ? "" : " ") dd }
            depsmet = done_[id] ? "done" : (blocked=="" ? "yes" : "no")
            st=status[id]
            if      (st ~ /^Done/)        st="Done"
            else if (st ~ /^In Progress/) st="In Progress"
            else if (st ~ /^Draft/)       st="Draft"
            else if (st ~ /^Ready/)       st="Ready"
            else if (st ~ /^Verify/)      st="Verify"
            printf "%-4s  %-11s  %-8s  %s\n", sprintf("%02d", id), st, depsmet, (blocked=="" ? "-" : blocked)
        }
    }
    ' "$TMP"
    exit 0
fi

# ------------------------------------------------------------------- --json --
if [ "$MODE" = json ]; then
    case "$ACTION" in
        start|halt)
            PROMPT=$(coordinator_prompt_oneline "$RID" "$RFILE")
            if [ "$ACTION" = start ]; then
                printf '{"action":"start","id":%d,"file":"%s","prompt":"%s"}\n' "$RID" "$RFILE" "$PROMPT"
            else
                printf '{"action":"halt","id":%d,"file":"%s","reason":"Slice %02d (%s) is a halt-and-ask gate — the user must make a product decision before this slice starts."}\n' "$RID" "$RFILE" "$RID" "$RTITLE"
            fi
            ;;
        wait)
            # blocked_by as JSON array
            arr=""
            for d in $REXTRA; do arr="${arr:+$arr,}$d"; done
            printf '{"action":"wait","id":%d,"blocked_by":[%s],"message":"Slice %02d waiting on slice(s) %s"}\n' "$RID" "$arr" "$RID" "$REXTRA"
            ;;
        done)
            printf '{"action":"done","message":"No eligible slices remaining"}\n'
            ;;
    esac
    exit 0
fi

# -------------------------------------------------------------------- human --
case "$ACTION" in
    start)
        printf 'Next slice: %02d — %s\n' "$RID" "$RTITLE"
        printf 'File: %s\n' "$RFILE"
        printf 'Depends on: %s — all dependencies met.\n\n' "$(deps_desc "$RID")"
        printf 'Paste this into a new coordinator chat:\n'
        printf -- '------------------------------------------------------------\n'
        coordinator_prompt_block "$RID" "$RFILE"
        printf -- '------------------------------------------------------------\n'
        ;;
    halt)
        printf 'HALT — Slice %02d (%s) needs a product decision first.\n' "$RID" "$RTITLE"
        printf 'File: %s\n' "$RFILE"
        printf 'This slice is a halt-and-ask gate. Resolve the open decision with the\n'
        printf 'user (and record it in the PRD/ADR) before starting the slice.\n'
        ;;
    wait)
        printf 'WAIT — no eligible slice right now.\n'
        printf 'Lowest remaining slice: %02d — %s\n' "$RID" "$RTITLE"
        printf 'Blocked by unfinished slice(s): %s\n' "$REXTRA"
        printf 'Finish the blocking slice(s), then run this again.\n'
        ;;
    done)
        printf 'DONE — no slices remaining. The queue is complete.\n'
        ;;
esac
exit 0
