#!/usr/bin/env bash
# Behavior tests for bin/fm-board-refresh.sh and its triggers: an open bearings
# board is rebuilt when fleet state changes, and only then; a burst of changes
# coalesces into one rebuild; a rebuild never reopens an ended session; and every
# open captain hold shows on the board exactly once.
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
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    jq -n --arg file "$real" \
      '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
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

test_a_rebuild_never_reopens_an_ended_session() {
  local home
  home=$(make_home ended)
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  : > "$home/lavish-open"
  : > "$home/lavish-ended"
  : > "$home/lavish-calls"
  add_task "$home" t1
  in_home "$home" "$REFRESH" && fail "a refresh of an ended session reported a rebuild"
  assert_no_grep '--reopen' "$home/lavish-calls" "a refresh reopened an ended board session"
  grep -q 't1' "$home/.lavish/bearings-board.data.js" || fail "the board data was not rewritten for the next open"
  grep -q 'not live' "$home/state/.board-refresh.log" || fail "the ended session was not logged"
  pass "a rebuild rewrites the board but never reopens an ended session"
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
    --reason "Ship the board option?" --repo sample >/dev/null || fail "hold failed"
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
    captain "$home" hold "call-$i" --title "Question $i" --reason "Pick option $i?" --repo sample \
      >/dev/null || fail "hold $i failed"
  done
  captain "$home" hold dated-call --title "A dated call" --reason "Decide the dated call?" \
    --repo sample --until 2099-01-01 >/dev/null || fail "dated hold failed"
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
    --reason "Ship the board option?" --repo sample --origin t1 >/dev/null || fail "hold failed"
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
    --reason "Ship the board option?" --repo sample >/dev/null || fail "hold failed"
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
    --reason "Ship the board option?" --repo sample >/dev/null || fail "hold failed"
  captain "$home" hold other-call --title "Choose the name" \
    --reason "Pick the public name?" --repo sample >/dev/null || fail "second hold failed"
  captain "$home" answer board-call --decision-file "$decision" >/dev/null || fail "answer failed"
  in_home "$home" "$PRIO" set board-call other-call >/dev/null || fail "set failed"
  payload "$home" "$home/after.json"
  assert_equals "" "$(card_keys "$home/after.json" captains_call board-call)" "an answered hold ranked first came back as a card"
  assert_equals "" "$(card_keys "$home/after.json" waiting board-call)" "an answered hold ranked first came back as a waiting row"
  assert_equals "other-call" "$(card_keys "$home/after.json" captains_call call)" "the open hold is not the only card"
  pass "an answered hold stays off the board even when the stored priority ranks it first"
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
  test_a_rebuild_never_reopens_an_ended_session \
  test_a_captain_hold_and_its_answer_rebuild_the_board \
  test_every_open_captain_hold_has_exactly_one_board_row \
  test_a_steer_that_hands_a_decision_to_its_worker_moves_the_card_to_waiting \
  test_a_board_reconcile_request_moves_the_card_to_waiting_at_once \
  test_an_answered_hold_ranked_first_never_returns_as_a_card \
  test_a_secondmate_change_refreshes_the_parent_board
