#!/usr/bin/env bash
# Behavior tests for bin/fm-board-refresh.sh and its wake-drain trigger: an open
# bearings board is rebuilt when fleet state changes, and only then.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REFRESH="$ROOT/bin/fm-board-refresh.sh"
BOARD="$ROOT/bin/fm-bearings-board.sh"
PRIO="$ROOT/bin/fm-board-priority.sh"
TMP_ROOT=$(fm_test_tmproot fm-board-refresh)

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
    FM_BOARD_REFRESH_MIN_INTERVAL=0 \
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
  grep -q 't1' "$home/.lavish/bearings-board.html" || fail "the rebuilt board does not show the new task"
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

test_the_throttle_and_the_lock_stop_a_refresh() {
  local home
  home=$(make_home guards)
  build_initial_board "$home"
  in_home "$home" "$REFRESH" || fail "baseline refresh failed"
  add_task "$home" t1
  in_home "$home" env FM_BOARD_REFRESH_MIN_INTERVAL=3600 "$REFRESH" || fail "throttled refresh failed"
  [ "$(rebuilt_count "$home")" = 1 ] || fail "a throttled refresh rebuilt the board"
  mkdir "$home/state/.board-refresh.lock"
  in_home "$home" "$REFRESH" || fail "locked refresh failed"
  [ "$(rebuilt_count "$home")" = 1 ] || fail "a refresh ran while another held the lock"
  rmdir "$home/state/.board-refresh.lock"
  in_home "$home" "$REFRESH" || fail "unlocked refresh failed"
  [ "$(rebuilt_count "$home")" = 2 ] || fail "the refresh did not run once the lock cleared"
  pass "the throttle and the lock stop a refresh"
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

fm_test_run \
  test_a_home_without_a_board_is_left_alone \
  test_the_board_is_rebuilt_only_when_fleet_state_changes \
  test_a_priority_change_rebuilds_the_board \
  test_the_throttle_and_the_lock_stop_a_refresh \
  test_a_failed_build_is_logged_and_not_retried_until_state_changes \
  test_the_wake_drain_starts_a_refresh_in_the_background
