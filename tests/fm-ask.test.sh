#!/usr/bin/env bash
# Behavior tests for bin/fm-ask.sh, the read-only `ask` verb (docs/supervision-host.md
# "Ask"). The engine is a stub claude that records its arguments, so the real
# argument construction, durable records, and exit codes are proven without a model.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$ROOT/bin/fm-supervision-engine-lib.sh"

ASK="$ROOT/bin/fm-ask.sh"
TMP_ROOT=$(fm_test_tmproot fm-ask)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

STUB="$TMP_ROOT/claude-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_TEST_ENGINE_ARGS"
[ "${FM_TEST_ENGINE_FAIL:-}" != 1 ] || { echo 'engine exploded' >&2; exit 1; }
printf '{"type":"result","subtype":"success","is_error":false,"result":"stub answer for the captain","total_cost_usd":0.02,"num_turns":3,"usage":{"input_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3,"output_tokens":4}}'
SH
chmod +x "$STUB"
ARGS="$TMP_ROOT/engine-args"

ask() {  # <args...>
  FM_HOME="$HOME_DIR" FM_SUPERVISION_ENGINE_CLAUDE_BIN=$STUB FM_TEST_ENGINE_ARGS="$ARGS" bash "$ASK" "$@"
}

latest_record() { find "$HOME_DIR/state/ask" -mindepth 1 -maxdepth 1 -type d -printf "%T@ %p/\n" | sort -n | tail -1 | cut -d" " -f2-; }

test_answer_and_durable_record() {
  local out rec
  out=$(ask 'is anything waiting on me?')
  assert_equals 'stub answer for the captain' "$out" 'the engine answer is printed'
  rec=$(latest_record)
  assert_equals 'is anything waiting on me?' "$(cat "$rec/request")" 'the question is recorded'
  assert_equals 'stub answer for the captain' "$(cat "$rec/answer")" 'the answer is recorded'
  assert_contains "$(cat "$rec/meta")" 'status=answered' 'the record closes as answered'
  assert_contains "$(cat "$rec/meta")" 'turns=3' 'the record carries the turn count'
  assert_contains "$(cat "$rec/message")" "Home: $(cd "$HOME_DIR" && pwd -P)" 'the message names the home'
  assert_contains "$(cat "$rec/message")" 'Question: is anything waiting on me?' 'the message carries the question'
  pass 'an ask is answered and recorded'
}

test_engine_gets_the_read_only_tool_set() {
  local args
  ask 'anything?' >/dev/null
  args=$(cat "$ARGS")
  assert_contains "$args" 'Read,Bash' 'the tool set is narrowed to Read and Bash'
  assert_contains "$args" 'Bash(grep:*)' 'a read command is allowed'
  assert_not_contains "$args" 'Edit' 'no edit tool is offered'
  assert_not_contains "$args" 'Write' 'no write tool is offered'
  assert_not_contains "$args" 'Bash(rm' 'no delete command is allowed'
  assert_contains "$args" '--permission-mode' 'the engine runs without prompting'
  assert_contains "$args" 'dontAsk' 'the engine runs without prompting'
  pass 'the engine tool set is read-only'
}

test_branch_session_tool_set_is_unchanged() {
  local args
  : > "$TMP_ROOT/prompt"
  : > "$TMP_ROOT/message"
  (
    FM_ROOT="$TMP_ROOT" FM_HOME="$HOME_DIR" STATE="$HOME_DIR/state"
    FM_SUPERVISION_ENGINE_CLAUDE_BIN=$STUB FM_TEST_ENGINE_ARGS="$ARGS"
    export FM_ROOT FM_HOME STATE FM_SUPERVISION_ENGINE_CLAUDE_BIN FM_TEST_ENGINE_ARGS
    fm_supervision_engine_turn claude sonnet "$TMP_ROOT/prompt" "$TMP_ROOT/message" sess-1 new 30 "$TMP_ROOT/result" "$TMP_ROOT/errors"
  )
  args=$(cat "$ARGS")
  assert_contains "$args" 'Bash,Read' 'the branch session keeps its Bash,Read tools'
  assert_not_contains "$args" 'Bash(' 'the branch session has no command patterns'
  pass 'the supervision branch tool set is unchanged by the override'
}

test_requires_explicit_home() {
  local rc=0
  env -u FM_HOME bash "$ASK" 'anything?' >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" 'an ask without FM_HOME is a usage error'
  rc=0
  ask '   ' >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" 'an empty question is a usage error'
  pass 'an ask needs an explicit home and a question'
}

test_engine_failure_is_reported() {
  local rc=0 rec
  FM_TEST_ENGINE_FAIL=1 ask 'anything?' >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" 'an engine failure exits 1'
  rec=$(latest_record)
  assert_contains "$(cat "$rec/meta")" 'status=failed' 'the record closes as failed'
  assert_contains "$(cat "$rec/errors")" 'engine exploded' 'the engine diagnostic is kept'
  pass 'an engine failure is reported, not answered'
}

test_async_ask_and_outcome() {
  local id i rc out
  id=$(ask --async 'anything?')
  assert_not_equals '' "$id" 'an async ask prints its id'
  i=0
  rc=3
  while [ "$rc" -eq 3 ] && [ "$i" -lt 100 ]; do
    rc=0
    out=$(FM_HOME="$HOME_DIR" bash "$ASK" outcome "$id" 2>/dev/null) || rc=$?
    [ "$rc" -ne 3 ] || sleep 0.2
    i=$((i + 1))
  done
  assert_equals 0 "$rc" 'the outcome is answered'
  assert_equals 'stub answer for the captain' "$out" 'the outcome is the answer'
  rc=0
  FM_HOME="$HOME_DIR" bash "$ASK" outcome no-such-ask >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" 'an unknown ask is an error'
  pass 'an async ask is read back through outcome'
}

test_prompt_is_prefix_stable() {
  local a b
  a=$(env -u FM_HOME bash "$ASK" --print-prompt)
  b=$(FM_HOME="$HOME_DIR" bash "$ASK" --print-prompt)
  assert_equals "$a" "$b" 'the prompt does not depend on the home'
  assert_contains "$a" 'read-only' 'the prompt states the read-only rule'
  assert_not_contains "$a" "$HOME_DIR" 'the prompt carries no home path'
  pass 'the ask prompt is byte-stable across homes'
}

test_answer_and_durable_record() {
  local out rec
  out=$(ask 'is anything waiting on me?')
  assert_equals 'stub answer for the captain' "$out" 'the engine answer is printed'
  rec=$(latest_record)
  assert_equals 'is anything waiting on me?' "$(cat "$rec/request")" 'the question is recorded'
  assert_equals 'stub answer for the captain' "$(cat "$rec/answer")" 'the answer is recorded'
  assert_contains "$(cat "$rec/meta")" 'status=answered' 'the record closes as answered'
  assert_contains "$(cat "$rec/meta")" 'turns=3' 'the record carries the turn count'
  assert_contains "$(cat "$rec/message")" "Home: $(cd "$HOME_DIR" && pwd -P)" 'the message names the home'
  assert_contains "$(cat "$rec/message")" 'Question: is anything waiting on me?' 'the message carries the question'
  pass 'an ask is answered and recorded'
}

test_engine_gets_the_read_only_tool_set() {
  local args
  ask 'anything?' >/dev/null
  args=$(cat "$ARGS")
  assert_contains "$args" 'Read,Bash' 'the tool set is narrowed to Read and Bash'
  assert_contains "$args" 'Bash(grep:*)' 'a read command is allowed'
  assert_not_contains "$args" 'Edit' 'no edit tool is offered'
  assert_not_contains "$args" 'Write' 'no write tool is offered'
  assert_not_contains "$args" 'Bash(rm' 'no delete command is allowed'
  assert_contains "$args" '--permission-mode' 'the engine runs without prompting'
  assert_contains "$args" 'dontAsk' 'the engine runs without prompting'
  pass 'the engine tool set is read-only'
}

test_branch_session_tool_set_is_unchanged() {
  local args
  : > "$TMP_ROOT/prompt"
  : > "$TMP_ROOT/message"
  (
    FM_ROOT="$TMP_ROOT" FM_HOME="$HOME_DIR" STATE="$HOME_DIR/state"
    FM_SUPERVISION_ENGINE_CLAUDE_BIN=$STUB FM_TEST_ENGINE_ARGS="$ARGS"
    export FM_ROOT FM_HOME STATE FM_SUPERVISION_ENGINE_CLAUDE_BIN FM_TEST_ENGINE_ARGS
    fm_supervision_engine_turn claude sonnet "$TMP_ROOT/prompt" "$TMP_ROOT/message" sess-1 new 30 "$TMP_ROOT/result" "$TMP_ROOT/errors"
  )
  args=$(cat "$ARGS")
  assert_contains "$args" 'Bash,Read' 'the branch session keeps its Bash,Read tools'
  assert_not_contains "$args" 'Bash(' 'the branch session has no command patterns'
  pass 'the supervision branch tool set is unchanged by the override'
}

test_requires_explicit_home() {
  local rc=0
  env -u FM_HOME bash "$ASK" 'anything?' >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" 'an ask without FM_HOME is a usage error'
  rc=0
  ask '   ' >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" 'an empty question is a usage error'
  pass 'an ask needs an explicit home and a question'
}

test_engine_failure_is_reported() {
  local rc=0 rec
  FM_TEST_ENGINE_FAIL=1 ask 'anything?' >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" 'an engine failure exits 1'
  rec=$(latest_record)
  assert_contains "$(cat "$rec/meta")" 'status=failed' 'the record closes as failed'
  assert_contains "$(cat "$rec/errors")" 'engine exploded' 'the engine diagnostic is kept'
  pass 'an engine failure is reported, not answered'
}

test_async_ask_and_outcome() {
  local id i rc out
  id=$(ask --async 'anything?')
  assert_not_equals '' "$id" 'an async ask prints its id'
  i=0
  rc=3
  while [ "$rc" -eq 3 ] && [ "$i" -lt 100 ]; do
    rc=0
    out=$(FM_HOME="$HOME_DIR" bash "$ASK" outcome "$id" 2>/dev/null) || rc=$?
    [ "$rc" -ne 3 ] || sleep 0.2
    i=$((i + 1))
  done
  assert_equals 0 "$rc" 'the outcome is answered'
  assert_equals 'stub answer for the captain' "$out" 'the outcome is the answer'
  rc=0
  FM_HOME="$HOME_DIR" bash "$ASK" outcome no-such-ask >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" 'an unknown ask is an error'
  pass 'an async ask is read back through outcome'
}

test_prompt_is_prefix_stable() {
  local a b
  a=$(env -u FM_HOME bash "$ASK" --print-prompt)
  b=$(FM_HOME="$HOME_DIR" bash "$ASK" --print-prompt)
  assert_equals "$a" "$b" 'the prompt does not depend on the home'
  assert_contains "$a" 'read-only' 'the prompt states the read-only rule'
  assert_not_contains "$a" "$HOME_DIR" 'the prompt carries no home path'
  pass 'the ask prompt is byte-stable across homes'
}

test_answer_and_durable_record
test_engine_gets_the_read_only_tool_set
test_branch_session_tool_set_is_unchanged
test_requires_explicit_home
test_engine_failure_is_reported
test_async_ask_and_outcome
test_prompt_is_prefix_stable
