#!/usr/bin/env bash
# tests/fm-spawn-local-bin-path.test.sh - a worker must keep the launcher's
# ~/.local/bin PATH entry even when its pane shell starts without it.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane received under a synthetic pane PATH that lacks the entry,
# with the harness binary replaced by a probe that prints the PATH it started
# with. What the probe prints is the PATH a real agent would have received.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-local-bin-path)
BASE_PATH=$PATH

# make_case <name> <id>
# Sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG LOCAL_BIN.
make_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$1"
  fm_test_spawn_brief "$HOME_DIR" "$2"
  # fm_test_run_spawn launches with HOME=<home>/user-home.
  LOCAL_BIN="$HOME_DIR/user-home/.local/bin"
}

# spawn_with_launcher_path <launcher-path> <id>
# The fixture prepends the fake bin directory, so the launcher's PATH is
# <fakebin>:<launcher-path>.
spawn_with_launcher_path() {
  local launcher_path=$1 id=$2 out status
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  out=$(PATH="$launcher_path" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "spawn $id should succeed: $out"
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/bin/sh
printf '%s\n' "$PATH"
SH
  chmod +x "$FAKEBIN_DIR/codex"
}

# agent_path <pane-path>: the PATH the agent starts with when the pane shell
# holds <pane-path> and replays its pre-launch exports before the launch.
agent_path() {
  local preamble
  preamble=$(grep '^export ' "$PANE_LOG")
  env -i HOME="$HOME_DIR/user-home" PATH="$1" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$preamble
$(cat "$LAUNCH_LOG")"
}

test_restores_entry_in_launcher_order() {
  local setting seen
  for setting in absent enabled; do
    make_case "restore-$setting" "restore-$setting-a1"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    spawn_with_launcher_path "$LOCAL_BIN:$BASE_PATH" "restore-$setting-a1"
    seen=$(agent_path "$FAKEBIN_DIR:$BASE_PATH") \
      || fail "allowlist=$setting: the emitted launch failed to run"
    # Launcher order is fakebin, local bin, BASE_PATH: the entry returns just
    # before the first pane entry that follows it on the launcher's PATH.
    assert_equals "$FAKEBIN_DIR:$LOCAL_BIN:$BASE_PATH" "$seen" \
      "allowlist=$setting: the agent PATH must regain ~/.local/bin in the launcher's order"
  done
  pass "a worker regains the launcher's ~/.local/bin entry in launcher order, with or without an allowlist"
}

test_appends_when_no_later_launcher_entry_is_present() {
  local seen
  make_case append append-a1
  # ~/.local/bin is last on the launcher's PATH, so no pane entry follows it.
  spawn_with_launcher_path "$BASE_PATH:$LOCAL_BIN" append-a1
  seen=$(agent_path "$FAKEBIN_DIR:$BASE_PATH") \
    || fail "append: the emitted launch failed to run"
  assert_equals "$FAKEBIN_DIR:$BASE_PATH:$LOCAL_BIN" "$seen" \
    "with no later launcher entry in the pane, ~/.local/bin should be appended"
  pass "a pane without any later launcher entry gains ~/.local/bin at the end"
}

test_no_duplicate_when_pane_already_has_it() {
  local seen
  make_case present present-a1
  spawn_with_launcher_path "$LOCAL_BIN:$BASE_PATH" present-a1
  seen=$(agent_path "$LOCAL_BIN:$FAKEBIN_DIR:$BASE_PATH") \
    || fail "present: the emitted launch failed to run"
  assert_equals "$LOCAL_BIN:$FAKEBIN_DIR:$BASE_PATH" "$seen" \
    "a pane PATH that already holds ~/.local/bin must be left exactly as it is"
  pass "a pane that already has ~/.local/bin keeps its PATH unchanged"
}

test_never_added_when_launcher_lacks_it() {
  local seen
  make_case absent absent-a1
  spawn_with_launcher_path "$BASE_PATH" absent-a1
  seen=$(agent_path "$FAKEBIN_DIR:$BASE_PATH") \
    || fail "absent: the emitted launch failed to run"
  assert_equals "$FAKEBIN_DIR:$BASE_PATH" "$seen" \
    "a launcher without ~/.local/bin on PATH must not add it to the worker"
  pass "a launcher without ~/.local/bin leaves the worker PATH unchanged"
}

test_restores_entry_in_launcher_order
test_appends_when_no_later_launcher_entry_is_present
test_no_duplicate_when_pane_already_has_it
test_never_added_when_launcher_lacks_it
