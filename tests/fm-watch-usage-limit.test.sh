#!/usr/bin/env bash
# Behavior tests for the watcher's usage-limit stale deferral and its one reset
# steer (bin/fm-watch.sh usage_limit_stale_gate, bin/fm-usage-limit-lib.sh).
# Shared fixtures live in tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"
# shellcheck source=bin/fm-usage-limit-lib.sh
. "$ROOT/bin/fm-usage-limit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-usage-limit-tests)
WINDOW="test:fm-wedge"
VERDICT='state: working · source: pane · idle'

# A wall-clock time <secs> from now as the harness renders it, in UTC.
clock_at() {  # <offset-secs>
  local e=$(( $(date +%s) + $1 ))
  { date -u -d "@$e" '+%-I:%M%P' 2>/dev/null || date -u -r "$e" '+%-I:%M%p' | tr 'APM' 'apm'; } \
    | sed 's/^0//'
}

# A worker lane stuck on <pane>. <surfaced> 1 pre-arms the stale suppressor as
# if a supervision turn already handled this exact pane; 0 leaves it unsurfaced.
# A fake fm-send records every call it receives in <case>/sends.
limit_fixture() {  # <name> <pane-text> <surfaced>
  local dir state key
  dir=$(wedge_threshold_fixture "$1" 'working: implementing the parser' 0)
  state="$dir/state"; key=$(watch_window_key "$WINDOW")
  printf '%s' "$2" > "$dir/pane.txt"
  printf '%s' "$(hash_text "$2")" > "$state/.hash-$key"
  if [ "$3" = 1 ]; then
    printf '%s' "$(hash_text "$2")" > "$state/.stale-$key"
  else
    rm -f "$state/.stale-$key"
  fi
  cat > "$dir/fake-send.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/sends"
SH
  chmod +x "$dir/fake-send.sh"
  : > "$dir/sends"
  printf '%s\n' "$dir"
}

limit_round() {  # <dir> <exit|absorb>
  local dir=$1
  FM_USAGE_LIMIT_SEND_BIN="$dir/fake-send.sh" wedge_threshold_round "$dir/state" "$dir/fakebin" \
    "$dir/watch.out" "$dir/pane.txt" "$WINDOW" "$VERDICT" "$2"
}

limit_pane() {  # <limit-line>
  printf '%s\n' '● Running the parser tests' "  ⎿  $1" '' '>' '  ? for shortcuts'
}

test_usage_limit_read_parses_the_recorded_forms() {
  local now got
  now=$(TZ=UTC date -d '2026-11-27 13:00' +%s 2>/dev/null) || now=1795784400
  got=$(fm_usage_limit_read "$(limit_pane "You've hit your 5-hour limit · resets 3:40pm (UTC)")" "$now")
  [ "$got" = "limited $(( now + 9600 ))" ] || fail "a 5-hour limit read as '$got'"
  got=$(fm_usage_limit_read "$(limit_pane "You've hit your 5-hour limit · resets 2pm (Europe/Paris)")" "$now")
  [ "$got" = "limited $now" ] || [ "$got" = "reset $now" ] || fail "a zoned limit read as '$got'"
  got=$(fm_usage_limit_read "$(limit_pane "You've hit your weekly limit · resets Nov 28, 3pm (UTC)")" "$now")
  [ "$got" = "limited $(( now + 86400 + 7200 ))" ] || fail "a dated weekly limit read as '$got'"
  # Past midnight the nearest occurrence of the time is tomorrow, not today.
  got=$(fm_usage_limit_read "$(limit_pane "You've hit your 5-hour limit · resets 1am (UTC)")" "$(( now + 36000 ))")
  [ "$got" = "limited $(( now + 43200 ))" ] || fail "a reset after midnight read as '$got'"
  got=$(fm_usage_limit_read "$(limit_pane 'Usage limit reached · continuing automatically at 2:30pm (UTC) · esc to cancel')" "$now")
  [ "$got" = "limited $(( now + 5400 ))" ] || fail "an auto-continue wait read as '$got'"
  got=$(fm_usage_limit_read "$(limit_pane "You've hit your 5-hour limit · resets 12:30pm (UTC)")" "$now")
  [ "$got" = "reset $(( now - 1800 ))" ] || fail "a passed reset read as '$got'"
  got=$(fm_usage_limit_read "$(limit_pane 'Usage limit has reset · Press enter to continue')" "$now")
  [ "$got" = "reset 0" ] || fail "a reset banner read as '$got'"
  fm_usage_limit_read "$(limit_pane "You've hit your 5-hour limit · resets soon")" "$now" >/dev/null \
    && fail "an unparseable reset was read as a limit"
  fm_usage_limit_read "$(printf "You've hit your 5-hour limit · resets 3pm (UTC)\n%s" "$(seq 1 30)")" "$now" >/dev/null \
    && fail "limit wording far above the pane bottom was read as a live limit"
  fm_usage_limit_read "$(limit_pane 'all tests green')" "$now" >/dev/null \
    && fail "an ordinary pane was read as a limit"
  pass "the limit reader parses zoned, dated, rollover, auto-continue and reset forms and ignores the rest"
}

test_first_sight_wakes_once_then_defers_to_the_reset() {
  local dir state out key pane n
  pane=$(limit_pane "You've hit your 5-hour limit · resets $(clock_at 7200) (UTC)")
  dir=$(limit_fixture first-sight "$pane" 0)
  state="$dir/state"; out="$dir/watch.out"; key=$(watch_window_key "$WINDOW")
  limit_round "$dir" exit || fail "the first sight of a usage-limit wait did not wake: $(cat "$out")"
  grep -F 'usage-limit wait until' "$out" >/dev/null || fail "the first wake did not name the limit: $(cat "$out")"
  grep -F 'demand-deep-inspection' "$out" >/dev/null || fail "the first wake lost its deep-inspection clause: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first sight"
  n=1
  while [ "$n" -le 3 ]; do
    limit_round "$dir" absorb || fail "a deferred usage-limit round $n failed: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$WINDOW")" -eq 0 ] \
    || fail "a usage-limit wait was re-woken before its reset: $(cat "$state/.wake-queue")"
  grep -F 'possible wedge' "$out" >/dev/null && fail "a usage-limit wait escalated as a wedge"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a usage-limit wait counted wedge escalations"
  [ ! -s "$dir/sends" ] || fail "a steer was sent before the reset: $(cat "$dir/sends")"
  pass "a usage-limit wait wakes once with deep inspection, then stays silent until its reset"
}

test_reset_sends_exactly_one_continue_steer() {
  local dir state out
  dir=$(limit_fixture reset-banner "$(limit_pane 'Usage limit has reset · Press enter to continue')" 1)
  state="$dir/state"; out="$dir/watch.out"
  # The steer goes out on the first stale poll; a pane that has not moved by the
  # next poll is back on the ordinary ladder, which wakes at its threshold.
  limit_round "$dir" exit || fail "a pane still stuck after the reset steer never woke: $(cat "$out")"
  [ "$(wc -l < "$dir/sends" | tr -d ' ')" -eq 1 ] || fail "the reset sent $(wc -l < "$dir/sends") steers"
  grep -F 'wedge The usage limit has reset. Continue where you stopped' "$dir/sends" >/dev/null \
    || fail "the steer did not go to the task through fm-send: $(cat "$dir/sends")"
  grep -F 'possible wedge' "$out" >/dev/null \
    || fail "a worker still stuck after the steer did not reach the ordinary ladder: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the post-steer escalation"
  limit_round "$dir" exit || fail "the ordinary ladder stopped after the steer: $(cat "$out")"
  [ "$(wc -l < "$dir/sends" | tr -d ' ')" -eq 1 ] || fail "the reset steer repeated: $(cat "$dir/sends")"

  dir=$(limit_fixture reset-passed \
    "$(limit_pane "You've hit your 5-hour limit · resets $(clock_at -600) (UTC)")" 1)
  limit_round "$dir" exit || fail "a passed reset never reached the ordinary ladder: $(cat "$dir/watch.out")"
  [ "$(wc -l < "$dir/sends" | tr -d ' ')" -eq 1 ] \
    || fail "a reset time that has passed sent $(wc -l < "$dir/sends") steers"
  pass "at the reset one continue steer goes through fm-send, then the ordinary ladder owns the pane"
}

test_reset_with_the_limit_menu_open_sends_nothing() {
  local dir pane
  pane=$(printf '%s\n' "You've hit your 5-hour limit · resets $(clock_at -600) (UTC)" \
    'What do you want to do?' '❯ 1. Stop and wait for limit to reset' \
    "  2. Wait here, then continue automatically at $(clock_at -600) (UTC)")
  dir=$(limit_fixture menu-open "$pane" 1)
  limit_round "$dir" exit || fail "a reset with the limit menu open left the ordinary ladder: $(cat "$dir/watch.out")"
  [ ! -s "$dir/sends" ] || fail "typed text was sent into the open limit menu: $(cat "$dir/sends")"
  pass "a reset with the limit menu open sends no steer"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

fm_test_run \
  test_usage_limit_read_parses_the_recorded_forms \
  test_first_sight_wakes_once_then_defers_to_the_reset \
  test_reset_sends_exactly_one_continue_steer \
  test_reset_with_the_limit_menu_open_sends_nothing
