#!/usr/bin/env bash
# fm-task-inbox-take.sh - a worker's one-call read and acknowledgement of its
# steering inbox.
#
# Prints every pending NNN.msg record in numeric sequence order, each body
# framed by a header and footer that name the record file, and moves each record
# into handled/ only after its body has been written to stdout. That move is the
# whole acknowledgement the watcher's re-ring ladder and stale escalation look
# for (bin/fm-task-inbox-lib.sh owns the record format and the ladder); nothing
# else is written. Bodies come from the format-aware fm_task_inbox_body reader,
# so a writer's synthetic final newline is already removed. A record without a
# body separator is printed raw, never dropped.
#
# The scan repeats until a pass finds no pending record, so a message that
# arrives mid-run is printed in the same call. Writers publish records by atomic
# rename, so a visible NNN.msg is always complete; a record that lands after the
# final pass stays pending and rings again. A missing handled/ is created. An
# absent or empty inbox prints one line and exits 0.
#
# Usage:
#   fm-task-inbox-take.sh [<inbox-dir>]
# <inbox-dir> defaults to $FM_TASK_INBOX, which bin/fm-spawn.sh exports.
#
# Exit status: 0 when every printed record was acknowledged, 1 when a record
# could not be printed or moved (that record and any later ones stay pending),
# 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

usage() {
  sed -n '20,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }
INBOX=${1:-${FM_TASK_INBOX:-}}
[ -n "$INBOX" ] || { echo "fm-task-inbox-take: no inbox path given and FM_TASK_INBOX is unset" >&2; exit 2; }
INBOX=${INBOX%/}

# Pending record basenames, numerically ordered by sequence.
pending() {
  local f n
  for f in "$INBOX"/*.msg; do
    [ -f "$f" ] || continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    printf '%s\t%s\n' "$n" "${f##*/}"
  done | sort -n | cut -f2
}

taken=0
while :; do
  batch=$(pending)
  [ -n "$batch" ] || break
  while IFS= read -r name; do
    rec="$INBOX/$name"
    [ -f "$rec" ] || continue
    mkdir -p "$INBOX/handled" || { echo "fm-task-inbox-take: cannot create $INBOX/handled" >&2; exit 1; }
    # The trailing x keeps command substitution from stripping body newlines.
    if ! body=$(fm_task_inbox_body "$rec" && printf x) && ! body=$(cat -- "$rec" && printf x); then
      echo "fm-task-inbox-take: cannot read $rec; left pending" >&2
      exit 1
    fi
    body=${body%x}
    case "$body" in
      ''|*$'\n') : ;;
      *) body+=$'\n' ;;
    esac
    printf '=== %s ===\n%s=== end %s ===\n' "$name" "$body" "$name" || {
      echo "fm-task-inbox-take: could not print $name; left pending" >&2
      exit 1
    }
    if ! mv -- "$rec" "$INBOX/handled/" || [ -e "$rec" ]; then
      echo "fm-task-inbox-take: printed $name but could not move it into handled/; it stays pending" >&2
      exit 1
    fi
    taken=$((taken + 1))
  done <<EOF
$batch
EOF
done

[ "$taken" -gt 0 ] || echo "No pending steering messages."
exit 0
