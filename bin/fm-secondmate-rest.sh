#!/usr/bin/env bash
# fm-secondmate-rest.sh - declare a dated rest from a standing-work secondmate.
#
# A `drive` mate may end a turn with nothing under way only by doing real work,
# holding a captain question, or declaring a dated rest. This script is the
# rest: it records the rest in this home's state/.mandate-rest
# (bin/fm-standing-mandate-lib.sh owns the record) and publishes the matching
# `paused: ... until <time>` line on the parent channel
# (bin/fm-parent-channel-lib.sh), so the parent sees the wait and rechecks it
# at that time. Every stopped-mate check and the mate's own watcher skip the
# mate while the rest is active, and the rest ends by itself at its date.
#
# Usage:
#   fm-secondmate-rest.sh --until <YYYY-MM-DDTHH:MM[:SS]Z> --reason <text>
#
# Run it from the secondmate home with FM_HOME set to that home. --until must be
# a UTC time in the future and at most 24 hours away; a longer pause is a
# posture change, not a rest. --reason is one line saying why nothing in the
# charter can move until then.
#
# Exit codes: 0 rest recorded and published; 1 refused (bad arguments, not a
# secondmate home, or the record could not be written); 4 the rest is recorded
# but the parent line could not be appended, so the parent learns of it only
# from the home's published summary.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-standing-mandate-lib.sh
. "$SCRIPT_DIR/fm-standing-mandate-lib.sh"

usage() {
  printf '%s\n' "Usage: fm-secondmate-rest.sh --until <YYYY-MM-DDTHH:MM[:SS]Z> --reason <text>" >&2
  exit 1
}

UNTIL=
REASON=
while [ $# -gt 0 ]; do
  case "$1" in
    --until) [ $# -ge 2 ] || usage; UNTIL=$2; shift 2 ;;
    --until=*) UNTIL=${1#--until=}; shift ;;
    --reason) [ $# -ge 2 ] || usage; REASON=$2; shift 2 ;;
    --reason=*) REASON=${1#--reason=}; shift ;;
    -h|--help)
      printf '%s\n' "Usage: fm-secondmate-rest.sh --until <YYYY-MM-DDTHH:MM[:SS]Z> --reason <text>"
      exit 0
      ;;
    *) usage ;;
  esac
done
[ -n "$UNTIL" ] || { echo "error: --until is required" >&2; usage; }

REASON=$(fm_parent_channel_clean_note "$REASON")
REASON=$(printf '%s' "$REASON" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
[ -n "$REASON" ] || { echo "error: --reason is required" >&2; usage; }

HOME_DIR=${FM_HOME:-}
[ -n "$HOME_DIR" ] || { echo "error: FM_HOME is required so the rest lands in this mate's home" >&2; exit 1; }
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"
if ! fm_parent_channel_home_id "$HOME_DIR" >/dev/null 2>&1; then
  echo "error: $HOME_DIR is not a secondmate home; only a secondmate declares a rest" >&2
  exit 1
fi

if ! UNTIL_EPOCH=$(fm_utc_iso_to_epoch "$UNTIL"); then
  echo "error: --until must be a UTC time like 2026-11-25T18:00Z (got '$UNTIL')" >&2
  exit 1
fi
NOW=$(date +%s)
if [ "$UNTIL_EPOCH" -le "$NOW" ]; then
  echo "error: --until $UNTIL is not in the future" >&2
  exit 1
fi
if [ "$UNTIL_EPOCH" -gt $(( NOW + FM_MANDATE_REST_MAX_SECONDS )) ]; then
  echo "error: --until $UNTIL is more than 24 hours away; a longer pause is a posture change for main to make" >&2
  exit 1
fi

if ! fm_mandate_rest_write "$STATE_DIR" "$UNTIL_EPOCH" "$UNTIL" "$REASON" "$NOW"; then
  echo "error: could not write the rest record in $STATE_DIR" >&2
  exit 1
fi

rc=0
fm_parent_channel_report "$HOME_DIR" "$STATE_DIR" "paused: standing mandate rest until $UNTIL: $REASON" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "error: the rest is recorded, but the parent line could not be appended (code $rc)" >&2
  exit 4
fi
printf 'rest recorded until %s\n' "$UNTIL"
