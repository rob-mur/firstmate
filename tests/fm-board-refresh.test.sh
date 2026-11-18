#!/usr/bin/env bash
# Behavior tests for bin/fm-board-refresh.sh and its triggers: an open bearings
# board is rebuilt when fleet state changes, and only then; a burst of changes
# coalesces into one rebuild; no pass runs while the session is ended or no input
# moved, and a reopened board catches up; and every open captain hold shows on
# the board exactly once.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REFRESH="$ROOT/bin/fm-board-refresh.sh"
BOARD="$ROOT/bin/fm-bearings-board.sh"
PRIO="$ROOT/bin/fm-board-priority.sh"
TMP_ROOT=$(fm_test_tmproot fm-board-refresh)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A home with a fake lavish-axi that reports the board's session as open and
# records every session open, so a rebuild is observable.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/lavish-calls"
case "${1-}" in
  --version) printf '0.1.80\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    # A captain-ended session stays ended until something reopens it.
    if [ -e "$FM_HOME/lavish-ended" ] && [ "${2-}" != --reopen ]; then
      printf 'session:\n  status: ended\n'
      exit 0
    fi
    [ "${2-}" != --reopen ] || rm -f "$FM_HOME/lavish-ended"
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    jq -n --arg file "$real" \
      '{sessions:{"0123456789abcdef":{file:$file,status:"open",url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
      > "$LAVISH_AXI_STATE_DIR/state.json"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

in_home() {  # <home> <command...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    FM_BOARD_REFRESH_MIN_INTERVAL=0 FM_BOARD_REFRESH_DEBOUNCE=0 \
    "$@"
}

build_initial_board() {  # <home>
  local home=$1
  in_home "$home" "$ROOT/bin/fm-bearings-board-payload.sh" > "$home/payload.json" || fail "payload failed"
  in_home "$home" "$BOARD" build "$home/payload.json" >/dev/null || fail "the board did not build"
}

rebuilt_count() {  # <home>
  grep -c 'rebuilt board' "$1/state/.board-refresh.log" 2>/dev/null || true
}

# Wait up to ~10s for the detached refresher to log <n> rebuilds and finish.
await_rebuilds() {  # <home> <n>
  local i=0
  while [ "$i" -lt 100 ]; do
    if [ "$(rebuilt_count "$1")" -ge "$2" ] && [ ! -e "$1/state/.board-refresh.lock" ] \
      && [ ! -e "$1/state/.board-refresh.pending" ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

add_task() {  # <home> <id>
  printf 'task=%s\nrepo=alpha\nkind=ship\nwindow=x\n' "$2" > "$1/state/$2.meta"
}

# The captain closes the board: Lavish records the session as ended and a plain
# open no longer revives it.
end_session() {  # <home>
  : > "$1/lavish-open"
  : > "$1/lavish-ended"
  jq '.sessions[].status = "ended"' "$1/lavish-state/state.json" > "$1/lavish-state/state.tmp" \
    && mv "$1/lavish-state/state.tmp" "$1/lavish-state/state.json"
}

# Run the refresher with a payload command that counts each fleet snapshot.
counted_refresh() {  # <home> <refresh args...>
  local home=$1
  shift
  if [ ! -x "$home/counted-payload" ]; then
    printf '#!/usr/bin/env bash\necho run >> "%s/payload-runs"\nexec "%s" "$@"\n' \
      "$home" "$ROOT/bin/fm-bearings-board-payload.sh" > "$home/counted-payload"
    chmod +x "$home/counted-payload"
  fi
  FM_BOARD_REFRESH_PAYLOAD="$home/counted-payload" in_home "$home" "$REFRESH" "$@"
}

payload_runs() {  # <home>
  if [ -f "$1/payload-runs" ]; then wc -l < "$1/payload-runs" | tr -d ' '; else echo 0; fi
}

# The current PATH less every directory holding a lavish-axi, so neither the
# fake nor a real one can be reached through it.
path_without_lavish() {
  local dir out=
  local IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] && [ ! -e "$dir/lavish-axi" ] && out="$out${out:+:}$dir"
  done
  printf '%s\n' "$out"
}

test_a_home_without_a_board_is_left_alone() {
  local home
  home=$(make_home no-board)
  in_home "$home" "$REFRESH" || fail "refresh failed with no board"
  [ ! -e "$home/.lavish/bearings-board.html" ] || fail "refresh created a board"
  [ ! -e "$home/state/.board-refresh.log" ] || fail "refresh did work with no board"
  pass "a home without a board is left alone"
}

test_the_board_is_rebuilt_only_when_fleet_state_changes() {
  local home
  home=$(make_home changes)
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "first refresh failed"
  [ "$(rebuilt_count "$home")" = 1 ] || fail "the first refresh did not record a baseline build"
  in_home "$home" "$REFRESH" || fail "second refresh failed"
  [ "$(rebuilt_count "$home")" = 1 ] || fail "an unchanged fleet rebuilt the board"
  add_task "$home" t1
  in_home "$home" "$REFRESH" || fail "third refresh failed"
  [ "$(rebuilt_count "$home")" = 2 ] || fail "a new task did not rebuild the board"
  grep -q 't1' "$home/.lavish/bearings-board.data.js" || fail "the rebuilt board does not show the new task"
  pass "the board is rebuilt only when fleet state changes"
}

test_a_priority_change_rebuilds_the_board() {
  local home
  home=$(make_home priority)
  add_task "$home" t1
  add_task "$home" t2
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  in_home "$home" "$PRIO" set t2 t1 || fail "set failed"
  in_home "$home" "$REFRESH" || fail "refresh after a priority change failed"
  [ "$(rebuilt_count "$home")" = 2 ] || fail "a new priority did not rebuild the board"
  pass "a stored priority change rebuilds the board"
}

test_the_throttle_defers_a_refresh_and_the_lock_hands_it_on() {
  local home start
  home=$(make_home guards)
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  add_task "$home" t1
  start=$(date +%s)
  in_home "$home" env FM_BOARD_REFRESH_MIN_INTERVAL=2 "$REFRESH" || fail "throttled refresh failed"
  [ "$(rebuilt_count "$home")" = 2 ] || fail "a throttled request was dropped instead of deferred"
  [ $(($(date +%s) - start)) -ge 1 ] || fail "a throttled request did not wait out the interval"
  add_task "$home" t2
  mkdir "$home/state/.board-refresh.lock"
  in_home "$home" "$REFRESH" || fail "locked refresh failed"
  [ "$(rebuilt_count "$home")" = 2 ] || fail "a refresh ran while another held the lock"
  [ -e "$home/state/.board-refresh.pending" ] || fail "a locked-out request was not left for the lock holder"
  rmdir "$home/state/.board-refresh.lock"
  in_home "$home" "$REFRESH" || fail "unlocked refresh failed"
  [ "$(rebuilt_count "$home")" = 3 ] || fail "the refresh did not run once the lock cleared"
  pass "the throttle defers a refresh and the lock hands a request on"
}

test_a_kick_without_a_board_does_nothing() {
  local home
  home=$(make_home kick-no-board)
  in_home "$home" "$REFRESH" --kick || fail "a kick with no board failed"
  sleep 0.5
  [ ! -e "$home/state/.board-refresh.pending" ] || fail "a kick with no board recorded a request"
  [ ! -e "$home/state/.board-refresh.log" ] || fail "a kick with no board did work"
  pass "a kick without a board does nothing"
}

test_a_burst_of_kicks_coalesces_into_one_rebuild() {
  local home i
  home=$(make_home burst)
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  for i in 1 2 3 4 5; do
    add_task "$home" "t$i"
    in_home "$home" env FM_BOARD_REFRESH_DEBOUNCE=1 "$REFRESH" --kick || fail "kick $i failed"
  done
  await_rebuilds "$home" 2 || fail "the kicked refresh did not rebuild the board"
  sleep 1.5
  [ "$(rebuilt_count "$home")" = 2 ] || fail "a burst of kicks rebuilt more than once: $(rebuilt_count "$home")"
  grep -q 't5' "$home/.lavish/bearings-board.data.js" || fail "the coalesced rebuild missed the last change"
  pass "a burst of kicks coalesces into one rebuild with the latest state"
}

test_a_wake_append_rebuilds_the_board() {
  local home
  home=$(make_home wake-append)
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  add_task "$home" t1
  # shellcheck disable=SC2016
  in_home "$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal "signal: t1" "t1"' _ "$ROOT" \
    >/dev/null 2>&1 || fail "the wake append failed"
  await_rebuilds "$home" 2 || fail "a queued wake did not refresh the open board"
  pass "a queued wake refreshes the open board"
}

test_an_ended_session_takes_no_pass_and_a_reopen_brings_it_current() {
  local home
  home=$(make_home ended)
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  end_session "$home"
  : > "$home/lavish-calls"
  add_task "$home" t1
  counted_refresh "$home" || fail "a refresh of an ended session failed"
  counted_refresh "$home" || fail "a second refresh of an ended session failed"
  counted_refresh "$home" --force || fail "a forced refresh of an ended session failed"
  assert_equals "0" "$(payload_runs "$home")" "a fleet snapshot was taken while nobody can see the board"
  [ ! -s "$home/lavish-calls" ] || fail "a refresh called Lavish for an ended session: $(cat "$home/lavish-calls")"
  ! grep -q 't1' "$home/.lavish/bearings-board.data.js" || fail "an ended board was rebuilt"
  assert_equals "1" "$(grep -c 'session is ended' "$home/state/.board-refresh.log")" \
    "the skip was not logged exactly once"
  # The captain asks for the board again: the reopened board catches up on its
  # own, from the refresh the reopen starts.
  in_home "$home" "$BOARD" url >/dev/null 2>"$home/url.err" || fail "url failed: $(cat "$home/url.err")"
  grep -q 'reopened: yes' "$home/url.err" || fail "url did not reopen the board: $(cat "$home/url.err")"
  await_rebuilds "$home" 2 || fail "the reopened board was not brought current"
  grep -q 't1' "$home/.lavish/bearings-board.data.js" || fail "the reopened board misses the change made while it was ended"
  pass "an ended session takes no fleet snapshot, and reopening it brings the board current"
}

test_an_unchanged_fleet_takes_no_snapshot_until_its_live_inputs_age() {
  local home
  home=$(make_home unchanged)
  add_task "$home" t1
  build_initial_board "$home"
  counted_refresh "$home" || fail "baseline refresh failed"
  assert_equals "1" "$(payload_runs "$home")" "the first refresh took no fleet snapshot"
  counted_refresh "$home" || fail "repeat refresh failed"
  counted_refresh "$home" || fail "third refresh failed"
  assert_equals "1" "$(payload_runs "$home")" "an unchanged fleet was snapshotted again"
  counted_refresh "$home" --force || fail "forced refresh failed"
  assert_equals "2" "$(payload_runs "$home")" "a forced refresh skipped the snapshot"
  # Worker liveness, forge state, and the date move with no file write.
  FM_BOARD_REFRESH_MAX_AGE=0 counted_refresh "$home" || fail "aged refresh failed"
  assert_equals "3" "$(payload_runs "$home")" "an aged-out signature did not take a fresh snapshot"
  pass "an unchanged fleet takes no snapshot until its live inputs age out"
}

test_every_kind_of_input_change_refreshes_the_board() {
  local home mate runs=1
  home=$(make_home on-change)
  mate="$TMP_ROOT/on-change-mate"
  mkdir -p "$mate/state"
  printf -- '- mate - A test mate. (home: %s; scope: tests; projects: none; added 2026-11-13)\n' "$mate" \
    > "$home/data/secondmates.md"
  add_task "$home" t1
  build_initial_board "$home"
  counted_refresh "$home" || fail "baseline refresh failed"
  assert_equals "1" "$(payload_runs "$home")" "the baseline refresh took no snapshot"
  after() {  # <what changed>
    counted_refresh "$home" || fail "refresh after $1 failed"
    runs=$((runs + 1))
    assert_equals "$runs" "$(payload_runs "$home")" "$1 did not take a fresh snapshot"
  }
  add_task "$home" t2
  after "a new task"
  printf 'working [at=%s]: started\n' "$(date +%s)" >> "$home/state/t2.status"
  after "a status line"
  rm -f "$home/state/t2.status"
  after "a removed status"
  rm -f "$home/state/t1.meta"
  after "a finished task"
  printf 'needs-decision [at=%s]: pick a name\n' "$(date +%s)" >> "$mate/state/m1.status"
  after "a secondmate status line"
  printf '{"generated":"2026-11-13T00:00:00Z","generated_epoch":1,"endpoints":[{"id":"m1","endpoint":{"observed_at":"2026-11-13T00:00:00Z"}}],"contributions":{"known":1,"valid_until":600}}\n' \
    > "$mate/state/home-summary.json"
  after "a new secondmate summary"
  printf '{"generated_epoch":301,"contributions":{"valid_until":905,"known":1},"endpoints":[{"endpoint":{"observed_at":"2026-11-13T00:05:00Z"},"id":"m1"}],"generated":"2026-11-13T00:05:00Z"}\n' \
    > "$mate/state/home-summary.json"
  counted_refresh "$home" || fail "refresh after a restamped summary failed"
  assert_equals "$runs" "$(payload_runs "$home")" "a secondmate summary that only changed its stamp took a snapshot"
  pass "a task, status, removal, or secondmate change each refresh the board, and a restamped summary does not"
}

test_lavish_axi_is_found_without_it_on_path_or_retried_later() {
  local home bare
  home=$(make_home lavish-path)
  build_initial_board "$home"
  mkdir -p "$home/lavishbin"
  mv "$home/fakebin/lavish-axi" "$home/lavishbin/lavish-axi"
  bare=$(path_without_lavish)
  [ -n "$bare" ] || fail "could not build a PATH without lavish-axi"
  PATH="$home/lavishbin:$bare" counted_refresh "$home" || fail "refresh with lavish-axi on PATH failed"
  assert_equals "1" "$(rebuilt_count "$home")" "the baseline refresh did not rebuild"
  add_task "$home" t1
  PATH="$bare" counted_refresh "$home" || fail "a refresh started without lavish-axi on PATH failed"
  assert_equals "2" "$(rebuilt_count "$home")" "a refresh without lavish-axi on PATH did not find it where it was before"
  rm -f "$home/state/.board-refresh.lavish-dir"
  add_task "$home" t2
  PATH="$bare" counted_refresh "$home" && fail "a refresh with no lavish-axi reported success"
  assert_equals "2" "$(payload_runs "$home")" "a fleet snapshot was taken with no way to show it"
  grep -q 'lavish-axi is not on PATH' "$home/state/.board-refresh.log" || fail "the missing lavish-axi was not logged"
  PATH="$home/lavishbin:$bare" counted_refresh "$home" || fail "the retry failed"
  assert_equals "3" "$(rebuilt_count "$home")" "the missed refresh was not retried once lavish-axi was back"
  grep -q 't2' "$home/.lavish/bearings-board.data.js" || fail "the retried board misses the change"
  pass "lavish-axi is found where an earlier refresh saw it, and a refresh without it is retried later"
}

# A home on the tasks-axi backend, so captain holds go through the real owner.
make_hold_home() {  # <name>
  local home
  home=$(make_home "$1")
  mkdir -p "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fm_fake_exit0 "$home/fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

captain() {  # <home> <fm-captain-hold args...>
  local home=$1
  shift
  in_home "$home" env REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

test_a_captain_hold_and_its_answer_rebuild_the_board() {
  local home decision
  [ -n "$TASKS_AXI_BIN" ] || { pass "skip: tasks-axi not found"; return; }
  home=$(make_hold_home hold-kick)
  decision="$home/decision.txt"
  printf 'go\n' > "$decision"
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  captain "$home" hold board-call --title "Choose the board option" \
    --reason "Ship the board option?" --repo sample --option yes=Yes --option no=No --no-link >/dev/null || fail "hold failed"
  await_rebuilds "$home" 2 || fail "a captain hold did not refresh the open board"
  grep -q 'board-call' "$home/.lavish/bearings-board.data.js" || fail "the new hold has no card"
  captain "$home" answer board-call --decision-file "$decision" >/dev/null || fail "answer failed"
  await_rebuilds "$home" 3 || fail "an answer did not refresh the open board"
  in_home "$home" "$ROOT/bin/fm-bearings-board-payload.sh" > "$home/after.json" || fail "payload failed"
  assert_equals "0" "$(jq '[(.captains_call[]?, .waiting[]?) | select(.key | test("board-call"))] | length' "$home/after.json")" \
    "an answered hold stayed on the board"
  pass "a captain hold and its answer each rebuild the board, and the answered card drops off"
}

test_every_open_captain_hold_has_exactly_one_board_row() {
  local home i keys
  [ -n "$TASKS_AXI_BIN" ] || { pass "skip: tasks-axi not found"; return; }
  home=$(make_hold_home completeness)
  for i in 1 2 3; do
    captain "$home" hold "call-$i" --title "Question $i" --reason "Pick option $i?" --repo sample --option yes=Yes --option no=No --no-link \
      >/dev/null || fail "hold $i failed"
  done
  captain "$home" hold dated-call --title "A dated call" --reason "Decide the dated call?" \
    --repo sample --option yes=Yes --option no=No --no-link --until 2099-01-01 >/dev/null || fail "dated hold failed"
  in_home "$home" env FM_BEARINGS_DECISIONS=2 "$ROOT/bin/fm-bearings-board-payload.sh" \
    > "$home/payload.json" || fail "payload failed"
  keys=$(jq -r '[(.captains_call[]?, .waiting[]?) | .key | select(test("call"))] | sort | join(",")' "$home/payload.json")
  assert_equals "call-1,call-2,call-3" "$keys" "every open undated captain hold must show exactly once as a call"
  # A call the captain deferred to a date sits in Charted Next with that date,
  # never as a call card and never twice (docs/captain-hold-lifecycle.md).
  assert_equals "1" "$(jq '[.charted[]? | select(.id == "dated-call")] | length' "$home/payload.json")" \
    "a dated captain hold must be charted exactly once"
  jq -e '.charted[] | select(.id == "dated-call") | .reason | test("until 2099-01-01")' "$home/payload.json" >/dev/null \
    || fail "the charted dated hold does not show its date"
  assert_equals "0" "$(jq '[.charted[]? | select(.id | test("^call-"))] | length' "$home/payload.json")" \
    "an undated captain hold was charted as a gate instead of shown"
  pass "every open captain hold has exactly one board row past the decision cap, a dated one charted with its date"
}

test_a_failed_build_is_logged_and_not_retried_until_state_changes() {
  local home
  home=$(make_home failing)
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  add_task "$home" t1
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/lavish-axi"
  in_home "$home" "$REFRESH" && fail "a refused build reported success"
  grep -q 'board build refused' "$home/state/.board-refresh.log" || fail "the refusal was not logged"
  local before
  before=$(wc -l < "$home/state/.board-refresh.log")
  in_home "$home" "$REFRESH" || fail "retry of an unchanged fleet failed"
  [ "$(wc -l < "$home/state/.board-refresh.log")" = "$before" ] || fail "a failed build was retried with no state change"
  pass "a failed build is logged and not retried until state changes"
}

test_the_wake_drain_starts_a_refresh_in_the_background() {
  local home i=0
  home=$(make_home drain)
  build_initial_board "$home"
  add_task "$home" t1
  in_home "$home" env FM_BOARD_REFRESH_MIN_INTERVAL=0 bash "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
  while [ "$i" -lt 100 ] && [ "$(rebuilt_count "$home")" = 0 ]; do i=$((i + 1)); sleep 0.1; done
  [ "$(rebuilt_count "$home")" -ge 1 ] || fail "a main wake drain did not refresh the open board"
  pass "a main wake drain refreshes the open board in the background"
}

card_keys() {  # <payload> <group> <pattern>
  jq -r --arg g "$2" --arg re "$3" '[.[$g][]? | (.key // .id) | select(test($re))] | join(",")' "$1"
}

payload() {  # <home> <out>
  in_home "$1" "$ROOT/bin/fm-bearings-board-payload.sh" > "$2" || fail "payload failed"
}

# A task whose terminal is a stubbed tmux pane, so fm-send can steer it.
add_steerable_task() {  # <home> <id>
  fm_write_meta "$1/state/$2.meta" "task=$2" "repo=alpha" "kind=ship" "window=sess:fm-$2" "harness=claude"
}

steer() {  # <home> <task> <text>
  in_home "$1" env FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$2" "$3" >/dev/null 2>&1
}

test_a_steer_that_hands_a_decision_to_its_worker_moves_the_card_to_waiting() {
  local home later
  [ -n "$TASKS_AXI_BIN" ] || { pass "skip: tasks-axi not found"; return; }
  home=$(make_hold_home handed-steer)
  add_steerable_task "$home" t1
  captain "$home" hold board-call --title "Choose the board option" \
    --reason "Ship the board option?" --repo sample --option yes=Yes --option no=No --no-link --origin t1 >/dev/null || fail "hold failed"
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  sleep 1.1
  steer "$home" t1 "Keep board-call held: the captain decides." || fail "the wait steer failed"
  payload "$home" "$home/wait.json"
  assert_equals "board-call" "$(card_keys "$home/wait.json" captains_call board-call)" \
    "a steer telling the worker to wait for the captain took the card away"
  steer "$home" t1 "Relaying a page note on another thread; carry on." || fail "the unrelated steer failed"
  payload "$home" "$home/other.json"
  assert_equals "board-call" "$(card_keys "$home/other.json" captains_call board-call)" \
    "a steer that does not name the decision took the card away"
  steer "$home" t1 "The captain chose option two for board-call; go ahead and ship it." || fail "the answering steer failed"
  await_rebuilds "$home" 2 || fail "a steer did not refresh the open board"
  grep -q 'With t1 since' "$home/.lavish/bearings-board.data.js" || fail "the open board does not show the handed decision as waiting on t1"
  payload "$home" "$home/handed.json"
  assert_equals "" "$(card_keys "$home/handed.json" captains_call board-call)" "a decision handed to its worker stayed a Captain's Call card"
  assert_equals "board-call" "$(card_keys "$home/handed.json" waiting board-call)" "a decision handed to its worker is not shown waiting"
  later=$(( $(date +%s) + 5 ))
  printf 'needs-decision [at=%s]: board-call needs a fresh pick between the two layouts\n' "$later" >> "$home/state/t1.status"
  payload "$home" "$home/again.json"
  assert_equals "board-call" "$(card_keys "$home/again.json" captains_call '^board-call$')" \
    "a fresh question from the worker did not bring the decision back as a card"
  pass "a steer that hands a decision to its worker moves the card to waiting until the worker asks again"
}

test_a_board_reconcile_request_moves_the_card_to_waiting_at_once() {
  local home
  [ -n "$TASKS_AXI_BIN" ] || { pass "skip: tasks-axi not found"; return; }
  home=$(make_hold_home reconcile)
  captain "$home" hold board-call --title "Choose the board option" \
    --reason "Ship the board option?" --repo sample --option yes=Yes --option no=No --no-link >/dev/null || fail "hold failed"
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  sleep 1.1
  captain "$home" bind board-src >/dev/null || fail "bind failed"
  printf 'board-call\n' | captain "$home" reconcile-requests --source-id board-src \
    --source "captured board result" >/dev/null || fail "the reconcile request failed"
  await_rebuilds "$home" 2 || fail "a reconcile request did not refresh the open board"
  grep -q 'Marked out of date on the board' "$home/.lavish/bearings-board.data.js" \
    || fail "the open board does not show the out-of-date decision as waiting"
  payload "$home" "$home/after.json"
  assert_equals "" "$(card_keys "$home/after.json" captains_call board-call)" "a card marked out of date stayed a Captain's Call card"
  pass "a reconcile request from the board moves the card to waiting and refreshes the open board"
}

test_an_answered_hold_ranked_first_never_returns_as_a_card() {
  local home decision
  [ -n "$TASKS_AXI_BIN" ] || { pass "skip: tasks-axi not found"; return; }
  home=$(make_hold_home answered-ranked)
  decision="$home/decision.txt"
  printf 'go\n' > "$decision"
  captain "$home" hold board-call --title "Choose the board option" \
    --reason "Ship the board option?" --repo sample --option yes=Yes --option no=No --no-link >/dev/null || fail "hold failed"
  captain "$home" hold other-call --title "Choose the name" \
    --reason "Pick the public name?" --repo sample --option yes=Yes --option no=No --no-link >/dev/null || fail "second hold failed"
  captain "$home" answer board-call --decision-file "$decision" >/dev/null || fail "answer failed"
  in_home "$home" "$PRIO" set board-call other-call >/dev/null || fail "set failed"
  payload "$home" "$home/after.json"
  assert_equals "" "$(card_keys "$home/after.json" captains_call board-call)" "an answered hold ranked first came back as a card"
  assert_equals "" "$(card_keys "$home/after.json" waiting board-call)" "an answered hold ranked first came back as a waiting row"
  assert_equals "other-call" "$(card_keys "$home/after.json" captains_call call)" "the open hold is not the only card"
  pass "an answered hold stays off the board even when the stored priority ranks it first"
}

# A held task closed straight to done (a reconcile close, not an answer) keeps
# its hold marker on the done line; the stored priority still naming it first
# must not bring it back as a card, on the payload or on the open board.
test_a_done_task_ranked_first_never_renders_as_a_card() {
  local home
  [ -n "$TASKS_AXI_BIN" ] || { pass "skip: tasks-axi not found"; return; }
  home=$(make_hold_home done-ranked)
  captain "$home" hold done-call --title "Post the held comments" \
    --reason "Post the held set?" --repo sample --option yes=Yes --option no=No --no-link >/dev/null || fail "hold failed"
  captain "$home" hold other-call --title "Choose the name" \
    --reason "Pick the public name?" --repo sample --option yes=Yes --option no=No --no-link >/dev/null || fail "second hold failed"
  build_initial_board "$home"
  in_home "$home" env REAL_TASKS_AXI="$TASKS_AXI_BIN" "$ROOT/bin/fm-tasks-axi.sh" 'done' done-call >/dev/null \
    || fail "the held task could not be closed as done"
  grep -q '^- \[x\] done-call .*(hold: ' "$home/data/backlog.md" \
    || fail "the done task did not keep its hold marker, so this test no longer covers that case"
  in_home "$home" "$PRIO" set done-call other-call >/dev/null || fail "set failed"
  in_home "$home" "$REFRESH" || fail "the refresh failed"
  payload "$home" "$home/after.json"
  assert_equals "" "$(card_keys "$home/after.json" captains_call done-call)" "a done task ranked first came back as a card"
  assert_equals "" "$(card_keys "$home/after.json" waiting done-call)" "a done task ranked first came back as a waiting row"
  assert_equals "other-call" "$(card_keys "$home/after.json" captains_call call)" "the open hold is not the only card"
  grep -q 'other-call' "$home/.lavish/bearings-board.data.js" || fail "the open board lost the open hold"
  ! grep -q 'done-call' "$home/.lavish/bearings-board.data.js" || fail "the open board still carries the done task"
  pass "a done task stays off the board even when the stored priority ranks it first"
}

# A secondmate home has no board; its decisions show on the parent's board, so
# its record changes must refresh that board.
make_mate_home() {  # <name> <parent> [route]
  local mate
  mate=$(make_home "$1")
  if [ "${3:-local}" = local ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$2" > "$mate/.fm-secondmate-parent"
  else
    printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=box\n' > "$mate/.fm-secondmate-parent"
  fi
  printf '%s\n' "$mate"
}

test_a_secondmate_change_refreshes_the_parent_board() {
  local parent mate remote
  parent=$(make_home parent)
  build_initial_board "$parent"
  in_home "$parent" "$REFRESH" || fail "baseline refresh failed"
  mate=$(make_mate_home mate "$parent")
  remote=$(make_mate_home remote-mate "$parent" remote)
  add_task "$parent" t1
  in_home "$remote" "$REFRESH" --kick || fail "a remote-route kick failed"
  sleep 0.5
  [ "$(rebuilt_count "$parent")" = 1 ] || fail "a remote-route secondmate kick refreshed a local board"
  [ ! -e "$remote/state/.board-refresh.pending" ] || fail "a kick without a board recorded a request in the secondmate home"
  in_home "$mate" "$REFRESH" --kick || fail "the secondmate kick failed"
  await_rebuilds "$parent" 2 || fail "a secondmate kick did not refresh the parent board"
  grep -q 't1' "$parent/.lavish/bearings-board.data.js" || fail "the forwarded refresh did not read the parent home"
  [ ! -e "$mate/.lavish/bearings-board.html" ] || fail "the forwarded refresh built a board in the secondmate home"
  add_task "$parent" t2
  # shellcheck disable=SC2016
  in_home "$mate" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal "signal: m1" "m1"' _ "$ROOT" \
    >/dev/null 2>&1 || fail "the secondmate wake append failed"
  await_rebuilds "$parent" 3 || fail "a secondmate wake did not refresh the parent board"
  pass "a secondmate kick or wake refreshes the parent board once, and a remote route does not"
}

test_new_board_code_is_installed_with_an_unchanged_fleet() {
  local home tmpl
  home=$(make_home new-code)
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  cp "$home/.lavish/bearings-board.app.js" "$home/old-app.js"
  tmpl="$home/template.html"
  awk '{ print } $0 == "<script>" { print "/* a newer board code */" }' \
    "$ROOT/.agents/skills/bearings/assets/board-template.html" > "$tmpl"
  FM_BEARINGS_BOARD_TEMPLATE="$tmpl" in_home "$home" "$REFRESH" || fail "refresh with new board code failed"
  [ "$(rebuilt_count "$home")" = 2 ] || fail "new board code did not rebuild an unchanged fleet's board"
  cmp -s "$home/old-app.js" "$home/.lavish/bearings-board.app.js" \
    && fail "the rebuild did not install the new board code"
  FM_BEARINGS_BOARD_TEMPLATE="$tmpl" in_home "$home" "$REFRESH" || fail "repeat refresh failed"
  [ "$(rebuilt_count "$home")" = 2 ] || fail "unchanged code and fleet rebuilt the board again"
  pass "new board code is installed on the next refresh even when the fleet has not moved"
}

# A home that carries its own Firstmate code, as the main home does, has its
# board built by that code alone. Another code root that asks for a refresh,
# such as a secondmate on an older or newer release forwarding its kick, must
# not rewrite the board page with its own template: Lavish reloads the whole
# board, and every page frame in it, whenever that file changes.
make_code_home() {  # <name>
  local home
  home=$(make_home "$1")
  cp -R "$ROOT/bin" "$home/bin"
  mkdir -p "$home/.agents/skills"
  cp -R "$ROOT/.agents/skills/bearings" "$home/.agents/skills/bearings"
  awk '{ print } $0 == "<body>" { print "<!-- this home'"'"'s own board code -->" }' \
    "$ROOT/.agents/skills/bearings/assets/board-template.html" > "$home/template.tmp"
  mv "$home/template.tmp" "$home/.agents/skills/bearings/assets/board-template.html"
  printf '%s\n' "$home"
}

test_a_home_board_is_built_by_its_own_code_whoever_asks() {
  local parent mate
  parent=$(make_code_home code-parent)
  in_home "$parent" "$parent/bin/fm-bearings-board-payload.sh" > "$parent/payload.json" || fail "payload failed"
  in_home "$parent" "$parent/bin/fm-bearings-board.sh" build "$parent/payload.json" >/dev/null \
    || fail "the board did not build"
  grep -q "this home's own board code" "$parent/.lavish/bearings-board.html" \
    || fail "the fixture board does not carry its home's own markup"
  in_home "$parent" "$parent/bin/fm-board-refresh.sh" || fail "baseline refresh failed"
  cp "$parent/.lavish/bearings-board.html" "$parent/page-before.html"
  cp "$parent/.lavish/bearings-board.app.js" "$parent/app-before.js"
  mate=$(make_mate_home code-mate "$parent")
  add_task "$parent" t1
  in_home "$mate" "$REFRESH" --kick || fail "the secondmate kick failed"
  await_rebuilds "$parent" 2 || fail "a secondmate kick did not refresh the parent board"
  grep -q 't1' "$parent/.lavish/bearings-board.data.js" || fail "the forwarded refresh did not read the fleet"
  cmp -s "$parent/page-before.html" "$parent/.lavish/bearings-board.html" \
    || fail "a kick from another code root rewrote the board page, which reloads every page in it"
  cmp -s "$parent/app-before.js" "$parent/.lavish/bearings-board.app.js" \
    || fail "a kick from another code root replaced the board code"
  add_task "$parent" t2
  in_home "$parent" "$REFRESH" --force || fail "a direct refresh from another code root failed"
  await_rebuilds "$parent" 3 || fail "a direct refresh from another code root did not refresh the board"
  grep -q 't2' "$parent/.lavish/bearings-board.data.js" || fail "the direct refresh did not read the fleet"
  cmp -s "$parent/page-before.html" "$parent/.lavish/bearings-board.html" \
    || fail "a refresh run from another code root rewrote the board page"
  pass "a home's board is built by its own code, whichever code root asks for the refresh"
}

# An older code root's refresher, as a secondmate on an older release starts by
# forwarding a kick, holds the home's lock and serves every later request with
# its own code. Stands in for that loop: it holds the lock between passes until
# it is stopped.
start_old_refresher() {  # <old-root> <home> -> pid
  local pidfile="$2/old-refresher.pid" i=0
  mkdir -p "$1/bin"
  cat > "$1/bin/fm-board-refresh.sh" <<'SH'
#!/usr/bin/env bash
lock="${FM_STATE_OVERRIDE:-$FM_HOME/state}/.board-refresh.lock"
mkdir "$lock" || exit 1
trap 'rmdir "$lock"' EXIT
printf '%s\n' "$$" > "$OLD_REFRESHER_PIDFILE"
while :; do touch "$lock"; sleep 1; done
SH
  chmod +x "$1/bin/fm-board-refresh.sh"
  rm -f "$pidfile"
  ( OLD_REFRESHER_PIDFILE=$pidfile in_home "$2" nohup bash "$1/bin/fm-board-refresh.sh" \
      >/dev/null 2>&1 </dev/null & )
  while [ ! -s "$pidfile" ]; do
    i=$((i + 1)); [ "$i" -lt 50 ] || fail "the old refresher did not start"; sleep 0.1
  done
  cat "$pidfile"
}

test_a_home_replaces_a_refresher_another_code_root_left_running() {
  local home other old_pid other_pid
  [ -r "/proc/$$/environ" ] || { echo "skip: no /proc process environments"; return 0; }
  home=$(make_code_home code-replace)
  in_home "$home" "$home/bin/fm-bearings-board-payload.sh" > "$home/payload.json" || fail "payload failed"
  in_home "$home" "$home/bin/fm-bearings-board.sh" build "$home/payload.json" >/dev/null || fail "the board did not build"
  in_home "$home" "$home/bin/fm-board-refresh.sh" || fail "baseline refresh failed"
  other=$(make_home code-replace-other)
  old_pid=$(start_old_refresher "$TMP_ROOT/old-root" "$home")
  other_pid=$(start_old_refresher "$TMP_ROOT/old-root" "$other")
  add_task "$home" t1
  in_home "$home" "$home/bin/fm-board-refresh.sh" --kick || fail "the home kick failed"
  await_rebuilds "$home" 2 || fail "the home's own code did not take over from the old refresher"
  grep -q 't1' "$home/.lavish/bearings-board.data.js" || fail "the new refresher did not read the fleet"
  kill -0 "$old_pid" 2>/dev/null && fail "the old code root's refresher for this home is still running"
  kill -0 "$other_pid" 2>/dev/null || fail "a refresher for another home was stopped"
  [ -d "$other/state/.board-refresh.lock" ] || fail "another home's refresher lost its lock"
  kill "$other_pid" 2>/dev/null
  pass "a home's own code replaces a refresher another code root left running for it, and no other"
}

# The captain reads the board while away instead of chat, so an active away
# window must not freeze it. A chat bearings read still asks for the return first.
test_the_board_rebuilds_during_an_active_away_window() {
  local home rc=0
  home=$(make_home away)
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  printf 'mode=away\n' > "$home/state/.afk"
  printf 'entered_epoch=1\n' > "$home/state/.afk-contract"
  add_task "$home" t1
  in_home "$home" "$REFRESH" || fail "the refresh failed during an active away window: $(tail -3 "$home/state/.board-refresh.log")"
  [ "$(rebuilt_count "$home")" = 2 ] || fail "the board was not rebuilt during an active away window"
  grep -q 't1' "$home/.lavish/bearings-board.data.js" || fail "the board built during the away window misses the new task"
  in_home "$home" "$ROOT/bin/fm-bearings-snapshot.sh" --json >/dev/null 2>&1 || rc=$?
  assert_equals "3" "$rc" "a chat bearings read did not still ask for the return first"
  pass "the board rebuilds during an active away window while a chat bearings read still refuses"
}

# A home whose payload fails while $home/payload-fail exists, and whose fm-send
# is a stub that records each message and exits with $home/send-status (0 if absent).
make_notify_home() {  # <name> <with-board-keeper: 0|1>
  local home
  home=$(make_home "$1")
  build_initial_board "$home"
  printf '#!/usr/bin/env bash\n[ ! -e "%s/payload-fail" ] || exit 1\nexec "%s" "$@"\n' \
    "$home" "$ROOT/bin/fm-bearings-board-payload.sh" > "$home/flaky-payload"
  cat > "$home/send-stub" <<SH
#!/usr/bin/env bash
{ printf 'FM_HOME=%s\\n' "\$FM_HOME"; printf '%s\\n' "\$@"; printf -- '--\\n'; } >> "$home/sends"
exit "\$(cat "$home/send-status" 2>/dev/null || echo 0)"
SH
  chmod +x "$home/flaky-payload" "$home/send-stub"
  if [ "$2" = 1 ]; then
    printf -- '- board-keeper - Keeps the bearings board healthy. (home: %s/keeper; scope: the board; projects: firstmate; added 2026-11-18)\n' \
      "$TMP_ROOT" > "$home/data/secondmates.md"
  fi
  printf '%s\n' "$home"
}

notify_refresh() {  # <home> -> the refresh exit status
  local home=$1
  FM_BOARD_REFRESH_PAYLOAD="$home/flaky-payload" FM_BOARD_REFRESH_SEND="$home/send-stub" \
    in_home "$home" "$REFRESH" --force
}

sends() {  # <home>
  if [ -f "$1/sends" ]; then grep -c '^--$' "$1/sends"; else echo 0; fi
}

test_a_failure_episode_tells_board_keeper_once() {
  local home
  home=$(make_notify_home notify-once 1)
  : > "$home/payload-fail"
  notify_refresh "$home" && fail "a failed payload reported success"
  notify_refresh "$home" && fail "a second failed payload reported success"
  assert_equals "1" "$(sends "$home")" "two failures in one episode did not send exactly one notice"
  grep -qx 'board-keeper' "$home/sends" || fail "the notice did not go to board-keeper: $(cat "$home/sends")"
  grep -qx "FM_HOME=$home" "$home/sends" || fail "the notice was not sent from this home"
  grep -q '^[0-9TZ:-]* payload generation failed$' "$home/sends" || fail "the notice lacks the failure line: $(cat "$home/sends")"
  grep -qx 'The bearings board build is failing.' "$home/sends" || fail "the notice lacks its sentence"
  rm -f "$home/payload-fail"
  notify_refresh "$home" || fail "the recovering build failed: $(tail -3 "$home/state/.board-refresh.log")"
  : > "$home/payload-fail"
  notify_refresh "$home" && fail "a failed payload after recovery reported success"
  assert_equals "2" "$(sends "$home")" "a failure after a successful build did not send a new notice"
  pass "a failure episode tells board-keeper once, and a failure after a success is news again"
}

test_no_notice_without_a_board_keeper_route() {
  local home
  home=$(make_notify_home notify-none 0)
  : > "$home/payload-fail"
  notify_refresh "$home" && fail "a failed payload reported success"
  printf -- '- other-mate - Does other work. (home: %s/other; scope: other; projects: firstmate; added 2026-11-18)\n' \
    "$TMP_ROOT" > "$home/data/secondmates.md"
  notify_refresh "$home" && fail "a failed payload reported success"
  assert_equals "0" "$(sends "$home")" "a notice was sent with no board-keeper route"
  grep -q 'payload generation failed' "$home/state/.board-refresh.log" || fail "the failure was not logged"
  pass "no notice is sent without a board-keeper route"
}

test_a_failing_send_never_changes_the_build_result() {
  local home rc
  home=$(make_notify_home notify-send-fails 1)
  printf '7\n' > "$home/send-status"
  : > "$home/payload-fail"
  rc=0; notify_refresh "$home" || rc=$?
  assert_equals "1" "$rc" "a failing send changed the failed build's result"
  assert_equals "1" "$(sends "$home")" "the failing send was not attempted"
  rm -f "$home/payload-fail"
  rc=0; notify_refresh "$home" || rc=$?
  assert_equals "0" "$rc" "the build after a failing send did not succeed"
  pass "a failing send never changes the build result"
}

fm_test_run \
  test_a_home_without_a_board_is_left_alone \
  test_the_board_is_rebuilt_only_when_fleet_state_changes \
  test_a_priority_change_rebuilds_the_board \
  test_the_throttle_defers_a_refresh_and_the_lock_hands_it_on \
  test_a_failed_build_is_logged_and_not_retried_until_state_changes \
  test_the_wake_drain_starts_a_refresh_in_the_background \
  test_a_kick_without_a_board_does_nothing \
  test_a_burst_of_kicks_coalesces_into_one_rebuild \
  test_a_wake_append_rebuilds_the_board \
  test_an_ended_session_takes_no_pass_and_a_reopen_brings_it_current \
  test_an_unchanged_fleet_takes_no_snapshot_until_its_live_inputs_age \
  test_every_kind_of_input_change_refreshes_the_board \
  test_lavish_axi_is_found_without_it_on_path_or_retried_later \
  test_a_captain_hold_and_its_answer_rebuild_the_board \
  test_every_open_captain_hold_has_exactly_one_board_row \
  test_a_steer_that_hands_a_decision_to_its_worker_moves_the_card_to_waiting \
  test_a_board_reconcile_request_moves_the_card_to_waiting_at_once \
  test_an_answered_hold_ranked_first_never_returns_as_a_card \
  test_a_done_task_ranked_first_never_renders_as_a_card \
  test_a_secondmate_change_refreshes_the_parent_board \
  test_new_board_code_is_installed_with_an_unchanged_fleet \
  test_a_home_board_is_built_by_its_own_code_whoever_asks \
  test_a_home_replaces_a_refresher_another_code_root_left_running \
  test_the_board_rebuilds_during_an_active_away_window \
  test_a_failure_episode_tells_board_keeper_once \
  test_no_notice_without_a_board_keeper_route \
  test_a_failing_send_never_changes_the_build_result
