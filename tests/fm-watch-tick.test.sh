#!/usr/bin/env bash
# tests/fm-watch-tick.test.sh - the per-poll cost economies in bin/fm-watch.sh's
# supervision tick, each pinned together with the correctness it must keep:
# the unchanged-file skip in the signal scan never hides a status change, the
# minute cadence for the liveness reconciles runs on the first poll and only
# then waits, and the idle secondmate poll backoff grows to its cap only while a
# secondmate home has no recorded windows and away mode is off.
#
# The inactive-outcome scan's status-change trigger is pinned against the real
# watcher in fm-inactive-reconcile.test.sh, next to the ledger delivery it keeps
# prompt.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-tick)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

make_home() {  # <name> [mate] -> prints the home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  [ "${2:-}" != mate ] || printf 'mate\n' > "$home/.fm-secondmate-home"
  printf '%s\n' "$home"
}

# Run <command...> in a subshell that sourced the watcher for <home>; the
# watcher's source guard returns before the lock and the loop.
in_watcher() {  # <home> <command...>
  local home=$1
  shift
  (
    # shellcheck disable=SC2030 # the sourced watcher reads them in this subshell only
    export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-watch.sh"
    "$@"
  )
}

# Counts every full seen check the scan makes, through the real check.
count_seen_checks() {
  eval "real_$(declare -f fm_wake_signal_seen_current)"
  SEEN_CHECKS=0
  # shellcheck disable=SC2329 # called by the sourced watcher's scan
  fm_wake_signal_seen_current() {
    SEEN_CHECKS=$((SEEN_CHECKS + 1))
    real_fm_wake_signal_seen_current "$@"
  }
}

scan_names() {  # prints the changed status file names of one in-process scan
  scan_signals_into
  printf '%s' "$SCAN_SIGNALS_OUT" | cut -f3 | sed 's|.*/||'
}

skip_scenario() {
  # shellcheck disable=SC2153 # STATE is the sourced watcher's state directory
  local st=$STATE out checks
  count_seen_checks
  fm_wake_status_mark_current "$st" "$st/a.status"
  fm_wake_status_mark_current "$st" "$st/b.status"

  out=$(scan_names); scan_signals_into
  [ -z "$out" ] || fail "a seen status file woke the scan: $out"
  checks=$SEEN_CHECKS
  [ "$checks" -eq 2 ] || fail "the first poll must fully check each seen file once (checks=$checks)"
  scan_signals_into
  [ -z "$SCAN_SIGNALS_OUT" ] || fail "an unchanged poll woke: $SCAN_SIGNALS_OUT"
  [ "$SEEN_CHECKS" -eq "$checks" ] || fail "an unchanged poll recomputed a seen answer ($SEEN_CHECKS > $checks)"

  printf 'done: finished\n' >> "$st/a.status"
  out=$(scan_names); scan_signals_into
  [ "$out" = a.status ] || fail "an appended status line was hidden by the skip: '$out'"

  # A same-size replacement keeps size and mtime but not the identity.
  printf 'working: two\n' > "$st/b.next"
  touch -r "$st/b.status" "$st/b.next"
  mv "$st/b.next" "$st/b.status"
  scan_signals_into
  case "$SCAN_SIGNALS_OUT" in *'/b.status'*) ;; *) fail "a same-size replaced status file was hidden: $SCAN_SIGNALS_OUT" ;; esac

  fm_wake_status_mark_current "$st" "$st/a.status"
  fm_wake_status_mark_current "$st" "$st/b.status"
  scan_signals_into
  [ -z "$SCAN_SIGNALS_OUT" ] || fail "re-marked files still woke: $SCAN_SIGNALS_OUT"
  rm -f "$st/.seen-a_status"
  out=$(scan_names); scan_signals_into
  [ "$out" = a.status ] || fail "a removed seen marker was hidden by the skip: '$out'"
}

test_unchanged_skip_never_hides_a_status_change() {
  local home
  home=$(make_home skip)
  printf 'working: one\n' > "$home/state/a.status"
  printf 'working: one\n' > "$home/state/b.status"
  in_watcher "$home" skip_scenario || exit 1
  pass "the signal scan skips unchanged seen files and still reports every status change"
}

hooked_scenario() {
  local st=$STATE
  count_seen_checks
  fm_wake_status_mark_current "$st" "$st/a.status"
  scan_signals_into; scan_signals_into
  [ -z "$SCAN_SIGNALS_OUT" ] || fail "a seen file woke under an injected reader: $SCAN_SIGNALS_OUT"
  [ "$SEEN_CHECKS" -eq 2 ] || fail "an injected status reader must disable the skip (checks=$SEEN_CHECKS)"
}

test_injected_status_reader_disables_the_skip() {
  local home
  home=$(make_home hooked)
  printf 'working: one\n' > "$home/state/a.status"
  # shellcheck disable=SC2016 # the reader script expands its own argument
  printf '#!/bin/sh\nwc -c < "$1" | tr -d " "\n' > "$TMP_ROOT/size-reader"
  chmod +x "$TMP_ROOT/size-reader"
  FM_STATUS_SIZE_READER="$TMP_ROOT/size-reader" in_watcher "$home" hooked_scenario || exit 1
  pass "an injected status reader makes every poll run the full seen check"
}

cadence_scenario() {
  # shellcheck disable=SC2034 # read by the sourced watch_reconcile_due
  WATCH_RECONCILE_SECS=60
  watch_reconcile_due "" || fail "a reconcile that never ran must be due"
  watch_reconcile_due "$SECONDS" && fail "a reconcile started this poll must wait out the cadence"
  watch_reconcile_due $((SECONDS - 61)) || fail "a reconcile older than the cadence must be due"
  # shellcheck disable=SC2034
  WATCH_RECONCILE_SECS=0
  watch_reconcile_due "$SECONDS" || fail "a zero cadence must run the reconcile every poll"
  return 0
}

test_reconcile_cadence_runs_first_then_waits() {
  local home
  home=$(make_home cadence)
  in_watcher "$home" cadence_scenario || exit 1
  pass "the liveness reconciles run on the first poll, then once per cadence, or every poll at zero"
}

backoff_sequence() {  # <windows 0|1> <cycles> -> space-separated sleeps
  local i seq=""
  for ((i = 0; i < $2; i++)); do
    idle_poll_advance "$1"
    seq="$seq$IDLE_POLL_NOW "
  done
  printf '%s\n' "${seq% }"
}

backoff_scenario() {
  local got
  got=$(backoff_sequence 0 6)
  [ "$got" = "1 2 4 8 8 8" ] || fail "an idle secondmate must back off to its cap: '$got'"
  idle_poll_advance 0; idle_poll_advance 0
  idle_poll_advance 1
  [ "$IDLE_POLL_NOW" -eq 1 ] || fail "a recorded window must reset the poll ($IDLE_POLL_NOW)"
  got=$(backoff_sequence 0 3)
  [ "$got" = "1 2 4" ] || fail "the backoff must restart from the poll after a reset: '$got'"
  : > "$STATE/.afk"
  got=$(backoff_sequence 0 3)
  [ "$got" = "1 1 1" ] || fail "away mode must keep the plain poll: '$got'"
}

test_idle_secondmate_backoff_grows_to_cap_and_resets() {
  local home got
  home=$(make_home idle-mate mate)
  FM_POLL=1 FM_IDLE_POLL_MAX=8 in_watcher "$home" backoff_scenario || exit 1

  home=$(make_home idle-main)
  got=$(FM_POLL=1 FM_IDLE_POLL_MAX=8 in_watcher "$home" backoff_sequence 0 4)
  [ "$got" = "1 1 1 1" ] || fail "a main home must keep the plain poll: '$got'"

  home=$(make_home idle-mate-capped mate)
  got=$(FM_POLL=1 FM_IDLE_POLL_MAX=100000 in_watcher "$home" backoff_sequence 0 12)
  [ "${got##* }" = 150 ] || fail "the backoff must stay under half the beacon grace (300s): '$got'"

  home=$(make_home idle-mate-off mate)
  got=$(FM_POLL=5 FM_IDLE_POLL_MAX=0 in_watcher "$home" backoff_sequence 0 3)
  [ "$got" = "5 5 5" ] || fail "a zero maximum must disable the backoff: '$got'"
  pass "an idle secondmate backs off to its cap under half the beacon grace, and nothing else does"
}

fm_test_run test_unchanged_skip_never_hides_a_status_change \
  test_injected_status_reader_disables_the_skip \
  test_reconcile_cadence_runs_first_then_waits \
  test_idle_secondmate_backoff_grows_to_cap_and_resets
