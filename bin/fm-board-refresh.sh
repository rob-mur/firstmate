#!/usr/bin/env bash
# fm-board-refresh.sh - keep an open bearings board in step with fleet state.
#
# Usage:
#   fm-board-refresh.sh [--force]
#   fm-board-refresh.sh --kick
#
# Regenerates the board payload (bin/fm-bearings-board-payload.sh, which applies
# the captain's stored priority) and, only when it differs from the last one
# built, rebuilds the existing board through `bin/fm-bearings-board.sh build
# --no-reopen`, so the open Lavish session shows the new fleet state at the same
# URL and a refresh never opens a browser tab or revives a session the captain
# ended. A rebuild rewrites only the board's data file, and the open page patches
# just the cards that changed, so a refresh never reloads the page or touches
# what the captain is typing (bin/fm-bearings-board.sh owns how).
#
# --kick records a refresh request and starts this script detached, returning at
# once; it is a no-op for a home that has not built a board. It is the hook for
# every fleet state change: each wake appended to the queue
# (bin/fm-wake-lib.sh: worker status, PR and MR state, checks, heartbeats), each
# captain hold placed, answered, or reconciled (bin/fm-captain-hold.sh), each
# task cleanup (bin/fm-teardown.sh), and each main wake drain
# (bin/fm-wake-drain.sh).
#
# Requests are never dropped, only coalesced:
#   - each request marks state/.board-refresh.pending; a mkdir lock under state/
#     lets one refresher run at a time, and it keeps rebuilding until no request
#     is left, so a request that lands while a rebuild runs gets its own pass.
#   - a pass starts FM_BOARD_REFRESH_DEBOUNCE seconds (default 3) after the
#     request it serves and at least FM_BOARD_REFRESH_MIN_INTERVAL seconds
#     (default 15) after the previous pass, so a burst of events causes one
#     rebuild. --force skips both waits and the fingerprint comparison.
#   - a stale lock older than FM_BOARD_REFRESH_LOCK_TTL seconds (default 300) is
#     reclaimed; a running refresher refreshes the lock while it waits.
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
PENDING="$STATE/.board-refresh.pending"
STAMP="$STATE/.board-refresh.last"
SUM="$STATE/.board-refresh.sum"
LOG="$STATE/.board-refresh.log"
DEBOUNCE="${FM_BOARD_REFRESH_DEBOUNCE:-3}"
MIN_INTERVAL="${FM_BOARD_REFRESH_MIN_INTERVAL:-15}"
LOCK_TTL="${FM_BOARD_REFRESH_LOCK_TTL:-300}"

FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  --kick)
    [ -f "$BOARD" ] || exit 0
    mkdir -p "$STATE" 2>/dev/null && : >"$PENDING" 2>/dev/null || exit 0
    ( nohup "$0" >/dev/null 2>&1 </dev/null & ) 2>/dev/null || true
    exit 0
    ;;
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  '') ;;
  *) echo "fm-board-refresh: unknown argument: $1" >&2; exit 2 ;;
esac

[ -f "$BOARD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
mkdir -p "$STATE" || exit 0
: >"$PENDING" || exit 0

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

take_lock() {
  mkdir "$LOCK" 2>/dev/null && return 0
  [ $(($(date +%s) - $(mtime "$LOCK"))) -gt "$LOCK_TTL" ] || return 1
  rmdir "$LOCK" 2>/dev/null || return 1
  mkdir "$LOCK" 2>/dev/null
}

log() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"
  tail -n 20 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
}

# Sleep until <epoch>, keeping the lock fresh so a long wait is never reclaimed.
wait_until() {  # <epoch>
  while [ "$(date +%s)" -lt "$1" ]; do
    touch "$LOCK" 2>/dev/null || true
    sleep 1
  done
}

# One pass: consume the pending request, then rebuild if the payload moved.
refresh_once() {
  local tmp sum out
  if [ "$FORCE" != 1 ]; then
    wait_until $(($(mtime "$PENDING") + DEBOUNCE))
    [ ! -f "$STAMP" ] || wait_until $(($(mtime "$STAMP") + MIN_INTERVAL))
  fi
  rm -f "$PENDING"
  : >"$STAMP"
  tmp=$(mktemp "$STATE/.board-refresh.payload.XXXXXX") || return 1
  if ! "$SCRIPT_DIR/fm-bearings-board-payload.sh" >"$tmp" 2>>"$LOG"; then
    rm -f "$tmp"
    log "payload generation failed"
    return 1
  fi
  sum=$(jq -S -c 'del(.generated)' "$tmp" | cksum | awk '{print $1 "-" $2}')
  if [ "$FORCE" != 1 ] && [ -f "$SUM" ] && [ "$(cat "$SUM")" = "$sum" ]; then
    rm -f "$tmp"
    return 0
  fi
  printf '%s\n' "$sum" >"$SUM"
  if out=$("$SCRIPT_DIR/fm-bearings-board.sh" build --no-reopen "$tmp" 2>&1); then
    rm -f "$tmp"
    log "rebuilt board"
    return 0
  fi
  rm -f "$tmp"
  log "board build refused: $(printf '%s' "$out" | tail -n 1)"
  return 1
}

rc=0
# Re-check after releasing the lock: a request that arrived just as the last
# pass finished found the lock held and left its mark for this loop to serve.
while [ -f "$PENDING" ] && take_lock; do
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
  while [ -f "$PENDING" ]; do
    refresh_once || rc=1
    FORCE=0
  done
  rmdir "$LOCK" 2>/dev/null
  trap - EXIT
done
exit "$rc"
