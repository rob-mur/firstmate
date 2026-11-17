#!/usr/bin/env bash
# Behavior tests for bin/fm-lavish-watchdog.sh, the opt-in Lavish board server
# memory watchdog the watcher runs each reconcile pass.
#
# Every case runs a private stand-in server: a node script installed under a
# lavish-axi path, started with `server --port <private port>` and its own
# LAVISH_AXI_STATE_DIR, so the watchdog's identity check sees the same argv
# shape as the real server. Every watchdog call goes through `wd`, which always
# sets LAVISH_AXI_PORT to that private port, so no case can reach a real board
# server on the default port. Stand-ins are stopped by exact pid.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCHDOG="$ROOT/bin/fm-lavish-watchdog.sh"
WATCH="$ROOT/bin/fm-watch.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"

[ "$(uname -s)" = Linux ] || { echo "skip: the watchdog acts only where /proc is available (Linux)"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found (needed for the stand-in server)"; exit 0; }
command -v ss >/dev/null 2>&1 || { echo "skip: ss not found (the watchdog's listener lookup)"; exit 0; }
command -v prlimit >/dev/null 2>&1 || { echo "skip: prlimit not found (the watchdog's core-limit setter)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the watchdog's state reader)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-lavish-watchdog)
STARTED_PIDS=()

stop_started() {
  local pid
  for pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
}
trap 'stop_started; fm_test_cleanup' EXIT

# A stand-in server. It answers HTTP on the port after `--port`, keeps an
# optional FAKE_PAD_MB of touched memory, and ignores SIGTERM when
# FAKE_IGNORE_TERM=1, so a case can prove the watchdog never escalates.
write_server_script() {  # <path>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'JS'
import http from 'node:http';
const i = process.argv.indexOf('--port');
const port = Number(process.argv[i + 1]);
if (process.env.FAKE_IGNORE_TERM === '1') process.on('SIGTERM', () => {});
const pad = Number(process.env.FAKE_PAD_MB || 0);
globalThis.keep = pad > 0 ? Buffer.alloc(pad * 1048576, 1) : null;
http.createServer((q, r) => r.end('ok')).listen(port, '127.0.0.1');
JS
}

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

# make_case <name>: a fixture home, a private Lavish state dir, the stand-in
# script under a lavish-axi path, a non-Lavish script, and a free port.
make_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/lavish-state"
  write_server_script "$dir/node_modules/lavish-axi/dist/server.mjs"
  write_server_script "$dir/other/server.mjs"
  printf '%s\n' '{"sessions":{}}' > "$dir/lavish-state/state.json"
  fm_touch_epoch "$(( $(date +%s) - 3600 ))" "$dir/lavish-state/state.json"
  free_port > "$dir/port"
  printf '%s\n' "$dir"
}

port_of() { cat "$1/port"; }

# start_server <dir> [lavish|other]: start a stand-in detached with a nonzero
# soft core limit, record its pid in <dir>/server.pid, and wait for its listener.
start_server() {
  local dir=$1 kind=${2:-lavish} script port pid i
  port=$(port_of "$dir")
  if [ "$kind" = lavish ]; then
    script="$dir/node_modules/lavish-axi/dist/server.mjs"
  else
    script="$dir/other/server.mjs"
  fi
  (
    ulimit -S -c 4096 2>/dev/null || true
    LAVISH_AXI_STATE_DIR="$dir/lavish-state" FAKE_MARK=kept-env \
      exec setsid node "$script" server --port "$port" \
      > "$dir/server.out" 2>&1 < /dev/null
  ) &
  pid=$!
  disown "$pid" 2>/dev/null || true
  STARTED_PIDS+=("$pid")
  printf '%s\n' "$pid" > "$dir/server.pid"
  i=0
  until listener_pid "$dir" >/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || fail "stand-in server did not listen on $port"
    sleep 0.05
  done
}

listener_pid() {  # <dir>
  local port pids
  port=$(port_of "$1")
  pids=$(ss -Hltnp "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
  [ -n "$pids" ] || return 1
  printf '%s\n' "$pids"
}

soft_core() { awk '/^Max core file size/ { print $5 }' "/proc/$1/limits"; }
hard_core() { awk '/^Max core file size/ { print $6 }' "/proc/$1/limits"; }

# wd <dir> <args>: run the watchdog against the case's home and private port.
wd() {
  local dir=$1 port
  shift
  port=$(port_of "$dir")
  [ -n "$port" ] && [ "$port" != 4387 ] || fail "refusing to run the watchdog without a private port"
  FM_HOME="$dir/home" LAVISH_AXI_PORT="$port" FM_LAVISH_WATCHDOG_STOP_WAIT=3 "$WATCHDOG" "$@"
}

enable() {  # <dir> <config-body>
  printf '%s\n' "$2" > "$1/home/config/lavish-heap-watchdog"
}

test_config_absent_is_inert() {
  local dir out pid
  dir=$(make_case absent)
  start_server "$dir"
  pid=$(cat "$dir/server.pid")
  [ "$(soft_core "$pid")" != 0 ] || fail "fixture could not give the stand-in a nonzero core limit"
  out=$(wd "$dir" check) || fail "check without config failed: $out"
  assert_equals "" "$out" "check without config printed output"
  assert_equals "$pid" "$(listener_pid "$dir")" "check without config touched the server"
  assert_not_equals 0 "$(soft_core "$pid")" "check without config changed the core limit"
  pass "without config/lavish-heap-watchdog the check does nothing"
}

test_under_threshold_only_disables_core_dumps() {
  local dir out pid
  dir=$(make_case under)
  enable "$dir" 'rss_mb=100000'
  start_server "$dir"
  pid=$(cat "$dir/server.pid")
  [ "$(soft_core "$pid")" != 0 ] || fail "fixture could not give the stand-in a nonzero core limit"
  out=$(wd "$dir" check) || fail "under-threshold check failed: $out"
  assert_contains "$out" "ok" "under-threshold check did not report ok"
  assert_equals "$pid" "$(listener_pid "$dir")" "under-threshold check restarted the server"
  assert_equals 0 "$(soft_core "$pid")" "under-threshold check left core dumps enabled (soft)"
  assert_equals 0 "$(hard_core "$pid")" "under-threshold check left core dumps enabled (hard)"
  pass "under the threshold the server keeps running with core dumps disabled"
}

test_over_threshold_idle_restarts_faithfully() {
  local dir out old new before after
  dir=$(make_case over)
  enable "$dir" 'rss_mb=1'
  start_server "$dir"
  old=$(cat "$dir/server.pid")
  before=$(tr '\0' ' ' < "/proc/$old/cmdline")
  out=$(wd "$dir" check) || fail "over-threshold check failed: $out"
  assert_contains "$out" "restarted" "over-threshold idle check did not restart"
  new=$(listener_pid "$dir") || fail "no server listens after the restart"
  STARTED_PIDS+=("$new")
  assert_not_equals "$old" "$new" "the listener pid did not change"
  ! kill -0 "$old" 2>/dev/null || fail "the old server is still running"
  after=$(tr '\0' ' ' < "/proc/$new/cmdline")
  assert_equals "$before" "$after" "the restarted server's argv differs"
  tr '\0' '\n' < "/proc/$new/environ" | grep -qxF FAKE_MARK=kept-env \
    || fail "the restarted server lost its environment"
  tr '\0' '\n' < "/proc/$new/environ" | grep -qxF "LAVISH_AXI_STATE_DIR=$dir/lavish-state" \
    || fail "the restarted server lost its state dir"
  assert_equals 0 "$(soft_core "$new")" "the restarted server can dump core (soft)"
  assert_equals 0 "$(hard_core "$new")" "the restarted server can dump core (hard)"
  assert_grep "restarted" "$dir/home/state/lavish-watchdog.log" "the restart was not logged"
  pass "over the threshold an idle server restarts with the same argv and env and no core dumps"
}

defer_case() {  # <name> <state-json> <expected-reason> [recent]
  local dir out pid
  dir=$(make_case "$1")
  enable "$dir" 'rss_mb=1'
  printf '%s\n' "$2" > "$dir/lavish-state/state.json"
  if [ "${4:-}" = recent ]; then
    touch "$dir/lavish-state/state.json"
  else
    fm_touch_epoch "$(( $(date +%s) - 3600 ))" "$dir/lavish-state/state.json"
  fi
  start_server "$dir"
  pid=$(cat "$dir/server.pid")
  out=$(wd "$dir" check) || fail "$1: deferring check failed: $out"
  assert_contains "$out" "deferred" "$1: check did not defer"
  assert_contains "$out" "$3" "$1: deferral did not name its reason"
  assert_equals "$pid" "$(listener_pid "$dir")" "$1: a deferred check restarted the server"
  assert_equals 0 "$(soft_core "$pid")" "$1: a deferred check left core dumps enabled"
  assert_grep "deferred" "$dir/home/state/lavish-watchdog.log" "$1: the deferral was not logged"
}

iso_ago() {  # <seconds> -> lavish-axi updated_at form
  date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%S.000Z
}
test_feedback_session_defers() {
  defer_case feedback "{\"sessions\":{\"k1\":{\"key\":\"k1\",\"status\":\"feedback\",\"prompts\":[{\"text\":\"x\"}],\"updated_at\":\"$(iso_ago 600)\"}}}" "k1"
  pass "a session holding unread feedback defers the restart"
}

test_pending_prompt_defers() {
  defer_case prompts '{"sessions":{"k2":{"key":"k2","status":"open","prompts":[{"text":"x"}]}}}' "k2"
  pass "a session holding an undelivered prompt defers the restart"
}
test_stale_feedback_round_does_not_block() {
  local dir out pid
  dir=$(make_case stale)
  enable "$dir" "rss_mb=1
round_secs=3600"
  printf '%s\n' "{\"sessions\":{\"old\":{\"key\":\"old\",\"status\":\"feedback\",\"prompts\":[],\"updated_at\":\"$(iso_ago 7200)\"}}}" \
    > "$dir/lavish-state/state.json"
  fm_touch_epoch "$(( $(date +%s) - 3600 ))" "$dir/lavish-state/state.json"
  start_server "$dir"
  pid=$(cat "$dir/server.pid")
  out=$(wd "$dir" check) || fail "stale round: check failed: $out"
  assert_contains "$out" "restarted" "a feedback round idle past round_secs still blocked the restart"
  STARTED_PIDS+=("$(listener_pid "$dir")")
  assert_not_equals "$pid" "$(listener_pid "$dir")" "stale round: server pid did not change"
  assert_grep "old" "$dir/home/state/lavish-watchdog.log" "stale round: the ignored session was not logged"
  pass "a feedback round idle past round_secs does not block the restart forever"
}

test_recent_activity_defers() {
  defer_case recent '{"sessions":{"k3":{"key":"k3","status":"open","prompts":[]}}}' "recent" recent
  pass "recent page activity defers the restart"
}

test_unhandled_lavish_capture_defers() {
  local dir out pid inbox
  dir=$(make_case capture)
  enable "$dir" 'rss_mb=1'
  inbox="$dir/home/state/procevent-inbox"
  mkdir -p "$inbox"
  printf 'answer\n' > "$inbox/lavish-board.7.result"
  printf 'lavish\n' > "$inbox/lavish-board.7.adapter"
  start_server "$dir"
  pid=$(cat "$dir/server.pid")
  out=$(wd "$dir" check) || fail "capture check failed: $out"
  assert_contains "$out" "deferred" "an unhandled Lavish capture did not defer"
  assert_contains "$out" "lavish-board" "the deferral did not name the capture"
  assert_equals "$pid" "$(listener_pid "$dir")" "an unhandled capture still restarted the server"

  : > "$inbox/lavish-board.7.handled"
  out=$(wd "$dir" check) || fail "handled-capture check failed: $out"
  assert_contains "$out" "restarted" "a handled capture still deferred"
  STARTED_PIDS+=("$(listener_pid "$dir")")
  pass "an unhandled Lavish capture in this home defers the restart until it is handled"
}

test_non_lavish_listener_untouched() {
  local dir out pid
  dir=$(make_case other)
  enable "$dir" 'rss_mb=1'
  start_server "$dir" other
  pid=$(cat "$dir/server.pid")
  out=$(wd "$dir" check) || fail "non-Lavish check failed: $out"
  assert_contains "$out" "not a lavish" "a non-Lavish listener was not named as such"
  assert_equals "$pid" "$(listener_pid "$dir")" "a non-Lavish listener was restarted"
  assert_not_equals 0 "$(soft_core "$pid")" "a non-Lavish listener had its core limit changed"
  pass "a listener that is not a Lavish server is left alone"
}

test_no_listener_is_quiet() {
  local dir out
  dir=$(make_case none)
  enable "$dir" 'rss_mb=1'
  out=$(wd "$dir" check) || fail "no-listener check failed: $out"
  assert_contains "$out" "no server" "no-listener check did not say so"
  pass "with no server listening the check does nothing"
}

test_term_refusing_server_is_never_killed() {
  local dir out pid rc
  dir=$(make_case stubborn)
  enable "$dir" 'rss_mb=1'
  FAKE_IGNORE_TERM=1 start_server "$dir"
  pid=$(cat "$dir/server.pid")
  set +e
  out=$(wd "$dir" check)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a server that ignored SIGTERM was reported as restarted: $out"
  assert_contains "$out" "did not exit" "the failure did not say the server stayed up"
  kill -0 "$pid" 2>/dev/null || fail "the watchdog escalated past SIGTERM"
  assert_equals "$pid" "$(listener_pid "$dir")" "the stubborn server lost its port"
  assert_grep "did not exit" "$dir/home/state/lavish-watchdog.log" "the failure was not logged"
  pass "a server that ignores SIGTERM is reported, never killed harder"
}

test_malformed_config_refuses() {
  local dir out pid rc
  dir=$(make_case malformed)
  enable "$dir" 'rss_mb=lots'
  start_server "$dir"
  pid=$(cat "$dir/server.pid")
  set +e
  out=$(wd "$dir" check 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a malformed threshold was accepted: $out"
  assert_contains "$out" "rss_mb" "the refusal did not name the bad key"
  assert_equals "$pid" "$(listener_pid "$dir")" "a malformed config restarted the server"
  pass "a malformed config is refused without touching the server"
}

test_watcher_runs_the_watchdog() {
  local dir old new rc port
  dir=$(make_case watcher)
  enable "$dir" 'rss_mb=1'
  start_server "$dir"
  old=$(cat "$dir/server.pid")
  port=$(port_of "$dir")
  printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$dir/home/state/z-stop.check.sh"
  chmod 0700 "$dir/home/state/z-stop.check.sh"
  FM_HOME="$dir/home" "$REGISTER" z-stop > /dev/null || fail "could not register the stop-cycle check"
  set +e
  FM_HOME="$dir/home" LAVISH_AXI_PORT="$port" FM_LAVISH_WATCHDOG_STOP_WAIT=3 FM_CHECK_INTERVAL=0 \
    FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    timeout 60 "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the watcher failed: $(cat "$dir/watch.err")"
  new=$(listener_pid "$dir") || fail "no server listens after the watcher cycle"
  STARTED_PIDS+=("$new")
  assert_not_equals "$old" "$new" "the watcher cycle did not run the watchdog"
  pass "the watcher's reconcile pass runs the watchdog when config/lavish-heap-watchdog is present"
}

fm_test_run \
  test_config_absent_is_inert \
  test_under_threshold_only_disables_core_dumps \
  test_over_threshold_idle_restarts_faithfully \
  test_feedback_session_defers \
  test_pending_prompt_defers \
  test_stale_feedback_round_does_not_block \
  test_recent_activity_defers \
  test_unhandled_lavish_capture_defers \
  test_non_lavish_listener_untouched \
  test_no_listener_is_quiet \
  test_term_refusing_server_is_never_killed \
  test_malformed_config_refuses \
  test_watcher_runs_the_watchdog
