#!/usr/bin/env bash
# fm-board-refresh.sh - keep an open bearings board in step with fleet state.
#
# Usage:
#   fm-board-refresh.sh [--force]
#
# Regenerates the board payload (bin/fm-bearings-board-payload.sh, which applies
# the captain's stored priority) and, only when it differs from the last one
# built, rebuilds the existing board through bin/fm-bearings-board.sh build, so
# the open Lavish session shows the new fleet state. The board's own order store
# and queued-answer preservation carry the captain's work across the rebuild.
# bin/fm-wake-drain.sh starts this detached on every main wake-handling turn when
# a board file exists; it never runs for a home that has not built a board.
#
# Guards, so it can never loop or pile up:
#   - no board file at the stable path: exit 0 without doing anything.
#   - a mkdir lock under state/ allows one refresh at a time; a stale lock older
#     than FM_BOARD_REFRESH_LOCK_TTL seconds (default 300) is reclaimed.
#   - at most one attempt per FM_BOARD_REFRESH_MIN_INTERVAL seconds (default 60)
#     unless --force.
#   - the payload fingerprint ignores the `generated` stamp; an attempt, even a
#     failed one, records it, so an ended session or a refused payload is not
#     retried until fleet state changes again.
# A failed build is logged to state/.board-refresh.log (last 20 lines kept) and
# never changes the caller's exit status beyond this script's own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BOARD="$FM_HOME/.lavish/bearings-board.html"
LOCK="$STATE/.board-refresh.lock"
STAMP="$STATE/.board-refresh.last"
SUM="$STATE/.board-refresh.sum"
LOG="$STATE/.board-refresh.log"
MIN_INTERVAL="${FM_BOARD_REFRESH_MIN_INTERVAL:-60}"
LOCK_TTL="${FM_BOARD_REFRESH_LOCK_TTL:-300}"

FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  '') ;;
  *) echo "fm-board-refresh: unknown argument: $1" >&2; exit 2 ;;
esac

[ -f "$BOARD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
mkdir -p "$STATE" || exit 0

now=$(date +%s)
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

if ! mkdir "$LOCK" 2>/dev/null; then
  if [ $((now - $(mtime "$LOCK"))) -gt "$LOCK_TTL" ]; then
    rmdir "$LOCK" 2>/dev/null || exit 0
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
tmp=$(mktemp "$STATE/.board-refresh.payload.XXXXXX") || { rmdir "$LOCK"; exit 0; }
trap 'rm -f "$tmp"; rmdir "$LOCK" 2>/dev/null' EXIT

log() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"
  tail -n 20 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
}

if [ "$FORCE" != 1 ] && [ -f "$STAMP" ] && [ $((now - $(mtime "$STAMP"))) -lt "$MIN_INTERVAL" ]; then
  exit 0
fi
: >"$STAMP"

if ! "$SCRIPT_DIR/fm-bearings-board-payload.sh" >"$tmp" 2>>"$LOG"; then
  log "payload generation failed"
  exit 1
fi
sum=$(jq -S -c 'del(.generated)' "$tmp" | cksum | awk '{print $1 "-" $2}')
if [ "$FORCE" != 1 ] && [ -f "$SUM" ] && [ "$(cat "$SUM")" = "$sum" ]; then
  exit 0
fi
printf '%s\n' "$sum" >"$SUM"

if out=$("$SCRIPT_DIR/fm-bearings-board.sh" build "$tmp" 2>&1); then
  log "rebuilt board"
else
  log "board build refused: $(printf '%s' "$out" | tail -n 1)"
  exit 1
fi
