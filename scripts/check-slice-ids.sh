#!/bin/sh
# PodWash slice ID uniqueness — one slice number per story file.
#
# Fails when:
#   - Two slice story files share the same slice-NN filename prefix
#   - **ID** metadata does not match the NN in the filename
#
# UX addenda (slice-NN-ux.md) are excluded — they inherit the parent number.
#
# Usage:
#   scripts/check-slice-ids.sh
#
# Environment:
#   PODWASH_SLICES_DIR=<dir>   alternate slices directory (tests)

set -eu

if [ -n "${PODWASH_REPO_ROOT:-}" ]; then
    REPO_ROOT=$PODWASH_REPO_ROOT
else
    REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fi
cd "$REPO_ROOT"

SLICES_DIR=${PODWASH_SLICES_DIR:-docs/slices}
FAIL=0

report_fail() {
    echo "check-slice-ids: FAIL — $1" >&2
    FAIL=1
}

if [ ! -d "$SLICES_DIR" ]; then
    report_fail "slices dir not found: $SLICES_DIR"
    exit 1
fi

TMP=$(mktemp "${TMPDIR:-/tmp}/check-slice-ids.XXXXXX")
trap 'rm -f "$TMP"' EXIT INT TERM

for f in "$SLICES_DIR"/slice-[0-9][0-9]-*.md; do
    [ -e "$f" ] || continue
    case "$f" in
        *-ux.md) continue ;;
    esac
    base=$(basename "$f")
    num=$(echo "$base" | sed -n 's/^slice-\([0-9][0-9]\)-.*/\1/p')
    if [ -z "$num" ]; then
        report_fail "cannot parse slice number from $base"
        continue
    fi
    meta_id=$(awk -F'|' '
        /^\| \*\*ID\*\* \|/ {
            v = $3
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            print v
            exit
        }
    ' "$f")
    if [ -z "$meta_id" ]; then
        report_fail "$base missing | **ID** | metadata row"
        continue
    fi
    file_id=$((10#$num))
    table_id=$((10#$meta_id))
    if [ "$file_id" -ne "$table_id" ]; then
        report_fail "$base filename is slice-$num but **ID** is $meta_id"
    fi
    printf '%d\t%s\n' "$file_id" "$f" >> "$TMP"
done

if [ ! -s "$TMP" ]; then
    report_fail "no slice story files found in $SLICES_DIR"
    exit 1
fi

dupes=$(awk -F'\t' '
{
    id = $1 + 0
    file = $2
    if (seen[id] != "") {
        print id "\t" seen[id] "\t" file
    } else {
        seen[id] = file
    }
}
' "$TMP")

if [ -n "$dupes" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        id=$(printf '%s' "$line" | cut -f1)
        a=$(printf '%s' "$line" | cut -f2)
        b=$(printf '%s' "$line" | cut -f3)
        report_fail "duplicate slice ID $id: $a and $b"
    done <<EOF
$dupes
EOF
fi

if [ "$FAIL" -ne 0 ]; then
    echo "check-slice-ids: assign the next free number in docs/slices/README.md (one slice-NN-*.md per ID)." >&2
    exit 1
fi

count=$(wc -l < "$TMP" | tr -d ' ')
echo "check-slice-ids: OK — $count slice story file(s), all IDs unique and filename-aligned"
exit 0
