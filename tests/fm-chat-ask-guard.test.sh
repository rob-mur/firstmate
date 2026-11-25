#!/usr/bin/env bash
# Behavior tests for the Claude Stop hook that keeps a captain ask out of
# chat-only limbo.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-chat-ask-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-chat-ask-guard)
PRIMARY="$TMP_ROOT/primary"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

make_home() {
  mkdir -p "$1/bin" "$1/state"
  printf '# fixture\n' > "$1/AGENTS.md"
  git -C "$1" init -q
}
make_home "$PRIMARY"

# invoke_guard <root> <state> <config> [env assignments...]
# The hook payload is on stdin. The exit status is the hook's.
# FM_CHAT_ASK_CALLS_CMD points at a board stub, so no real home is read.
invoke_guard() {
  local root=$1 state=$2 config=$3
  shift 3
  : > "$OUT"
  : > "$ERR"
  env -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME -u GROK_SESSION_ID \
    -u GROK_WORKSPACE_ROOT \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    FM_CHAT_ASK_CALLS_CMD="$CASE_CALLS" \
    "$@" \
    "$GUARD" >"$OUT" 2>"$ERR"
}

# prepare_case <name>: fresh state, config, transcript, and an empty board.
prepare_case() {
  local dir="$TMP_ROOT/cases/$1"
  CASE_STATE="$dir/state"
  CASE_CONFIG="$dir/config"
  CASE_TRANSCRIPT="$dir/transcript.jsonl"
  CASE_CALLS="$dir/calls.sh"
  mkdir -p "$CASE_STATE" "$CASE_CONFIG"
  : > "$CASE_TRANSCRIPT"
  set_board '{"calls":[]}'
}

# set_board <json>: the stub board prints this captain-calls document.
set_board() {
  printf '#!/usr/bin/env bash\ncat <<'"'"'JSON'"'"'\n%s\nJSON\n' "$1" > "$CASE_CALLS"
  chmod +x "$CASE_CALLS"
}

# Transcript writers, in the Claude JSONL shapes the hook reads.
prompt() {
  jq -nc --arg uuid "$1" --arg text "$2" \
    '{type:"user", uuid:$uuid, message:{role:"user", content:$text}}' >> "$CASE_TRANSCRIPT"
}
say() {
  jq -nc --arg text "$1" \
    '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$text}]}}' >> "$CASE_TRANSCRIPT"
}
run_bash() {
  jq -nc --arg cmd "$1" \
    '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", id:"t1", name:"Bash", input:{command:$cmd}}]}}' \
    >> "$CASE_TRANSCRIPT"
  jq -nc '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"t1", content:"ok"}]}}' \
    >> "$CASE_TRANSCRIPT"
}
stop_feedback() {
  jq -nc '{type:"user", isMeta:true, message:{role:"user", content:"Stop hook feedback:\nfm-chat-ask-guard: ..."}}' \
    >> "$CASE_TRANSCRIPT"
}

payload() {
  printf '{"session_id":"s1","stop_hook_active":%s,"transcript_path":"%s"}\n' \
    "${1:-false}" "$CASE_TRANSCRIPT"
}

assert_silent() {
  local label=$1
  [ ! -s "$OUT" ] || fail "$label wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label wrote stderr: $(cat "$ERR")"
}

assert_block() {
  local label=$1 needle=$2
  jq -e --arg needle "$needle" \
    '.decision == "block" and (.reason | contains($needle)) and (.reason | contains("fm-captain-hold.sh hold"))' \
    "$OUT" >/dev/null 2>&1 \
    || fail "$label did not block with '$needle' and the hold command: $(cat "$OUT") $(cat "$ERR")"
  [ ! -s "$ERR" ] || fail "$label wrote stderr: $(cat "$ERR")"
}

# expect <silent|block> <label> <final message> [needle]
expect() {
  local want=$1 label=$2 message=$3 needle=${4:-} rc=0
  prepare_case "$label"
  prompt "p-$label" "status?"
  say "$message"
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label must exit 0, got $rc: $(cat "$ERR")"
  if [ "$want" = block ]; then
    assert_block "$label" "$needle"
  else
    assert_silent "$label"
  fi
}

test_ask_blocks() {
  expect block ask-question "The fix is ready on its branch. Shall I merge it now?" "Shall I merge it now?"
  expect block ask-your-call "Two options are open: rebase or recreate the branch. Your call." "Your call."
  expect block ask-please-run "The gitlab token expired. Please run glab auth login in a terminal." "Please run"
  expect block ask-want-me "Want me to update firstmate on the other machine too?" "Want me to update"
  expect block ask-you-need "Before the release you need to approve the draft MRs." "you need to approve"
  pass "a final message that asks the captain for something blocks once and names the hold command"
}

test_answered_labels_pass() {
  local form
  form=$(printf '%s\n' \
    "Here are suggested answers for the interview form." \
    "" \
    "**What do you like most about your job?**" \
    "The team and the variety of problems I get to solve." \
    "" \
    "**What would you change about your role?**" \
    "More time for deep work and fewer context switches." \
    "" \
    "- **Where do you see yourself in two years?** Leading a small platform team." \
    "" \
    "## Do you feel supported by your manager?" \
    "Yes, with regular one-to-ones and clear feedback.")
  expect silent answered-form-labels "$form"
  expect block trailing-plain-ask "$form

Shall I merge it?" "Shall I merge it?"
  expect block trailing-bold-label "$form

**Shall I send these to your manager?**" "Shall I send these to your manager?"
  pass "a bold or heading question with an answer under it passes; a trailing plain ask or unanswered bold label still blocks"
}

test_recap_passes() {
  expect silent recap "The gitconfig fix landed on main. The board now shows 3 calls, and nothing needs your decision right now."
  expect silent recap-own-question "Why did the build break? A missing jq on the runner; I fixed it and CI is green."
  expect silent recap-code "Ran \`shall I --help\`. Output:
\`\`\`
do you want to continue? [y/N]
\`\`\`
All tests pass."
  expect silent recap-relayed-question "I've sent your PR question to the worker: why not reuse the parser?"
  expect silent recap-relayed-pick "I've passed your pick to the worker, so it needs your review only once it lands."
  pass "a pure recap, a rhetorical or relayed question, and asks inside code do not block"
}

test_shipshape_passes() {
  expect silent shipshape "Captain, shipshape."
  expect silent shipshape-padded "  Captain, shipshape.
"
  pass "the exact no-op reply passes"
}

test_payload_message_is_preferred() {
  local rc=0
  prepare_case payload-message
  prompt p1 "status?"
  say "Shall I merge it?"
  jq -nc --arg t "$CASE_TRANSCRIPT" \
    '{session_id:"s1", transcript_path:$t, last_assistant_message:"Captain, shipshape."}' \
    | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "payload message case exited $rc"
  assert_silent "payload last_assistant_message"
  pass "the payload's last_assistant_message is the message judged when present"
}

test_covered_by_hold_passes() {
  local rc=0
  prepare_case covered-hold
  prompt p1 "what about the snrs thing?"
  run_bash "FM_HOME=/x '/x/bin/fm-captain-hold.sh' hold snrs-123 --reason 'Ship the snrs fix?' --title 'snrs fix'"
  say "I held a card for it. Shall I ship the snrs fix?"
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "covered by hold exited $rc"
  assert_silent "ask covered by a hold this turn"

  # A hold from an earlier turn does not cover a new turn's ask.
  prompt p2 "and the gitconfig?"
  say "Shall I push the gitconfig change?"
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  assert_block "ask after an earlier turn's hold" "gitconfig"
  pass "a hold run in the same turn covers the ask, and only that turn"
}

test_covered_by_open_call_passes() {
  local rc=0
  expect block uncovered-url "Ready for review: https://gitlab.example/g/p/-/merge_requests/7 - want me to merge it?" "want me to merge"
  prepare_case covered-url
  set_board '{"calls":[{"task":"mr-7","question":"Merge MR 7?","links":[{"url":"https://gitlab.example/g/p/-/merge_requests/7","label":"MR"}]}]}'
  prompt p1 "status?"
  say "Ready for review: https://gitlab.example/g/p/-/merge_requests/7 - want me to merge it?"
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  assert_silent "ask naming an open call's URL"

  prepare_case covered-task
  set_board '{"calls":[{"task":"fm-update","question":"Update firstmate?","links":[]}]}'
  prompt p1 "status?"
  say "The firstmate update is still waiting (fm-update). Shall I run it?"
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  assert_silent "ask naming an open call's task id"

  prepare_case covered-number
  set_board '{"calls":[{"task":"mr-7","question":"Post the held comments?","links":[{"url":"https://gitlab.example/g/p/-/merge_requests/821","label":"MR"}]}]}'
  prompt p1 "status?"
  say "Still waiting on you: which comments to post on MR 821."
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  assert_silent "ask naming an open call's MR number"

  # A different number, or a task id inside a longer word, is not coverage.
  prompt p2 "and MR 82?"
  say "Still waiting on you: which comments to post on MR 82 (see mr-70)."
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  assert_block "ask naming only a near-miss number" "MR 82"
  pass "an ask that names an open board call's URL, task id, or MR number passes"
}

test_no_repeat_block() {
  local rc=0
  prepare_case no-repeat
  prompt p1 "status?"
  say "Shall I merge it?"
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  assert_block "first stop" "Shall I merge it?"

  # The session answers the block without holding; the same turn ends again.
  stop_feedback
  say "Shall I merge it? (an open card already covers it)"
  payload true | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "repeat stop exited $rc"
  assert_silent "second stop in the same turn"
  payload true | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  assert_silent "third stop in the same turn"

  # The next genuine prompt is a new turn and may block once again.
  prompt p2 "and the other one?"
  say "Do you want the other one merged too?"
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  assert_block "next turn" "Do you want"

  # Without a transcript the message itself keys the block.
  prepare_case no-transcript
  jq -nc '{session_id:"s9", last_assistant_message:"Shall I merge it?"}' > "$TMP_ROOT/p9"
  invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" < "$TMP_ROOT/p9" || rc=$?
  assert_block "no transcript, first" "Shall I"
  invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" < "$TMP_ROOT/p9" || rc=$?
  assert_silent "no transcript, repeat"
  pass "a turn blocks at most once, and the next turn can block again"
}

test_opt_out_and_scope_are_silent() {
  local rc=0 second="$TMP_ROOT/second"
  prepare_case opt-out
  printf '# guard\noff\n' > "$CASE_CONFIG/chat-ask-guard"
  prompt p1 "status?"
  say "Shall I merge it?"
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  assert_silent "config off"

  make_home "$second"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  prepare_case secondmate
  prompt p1 "status?"
  say "Shall I merge it?"
  payload | invoke_guard "$second" "$second/state" "$CASE_CONFIG" || rc=$?
  assert_silent "secondmate home"
  [ ! -e "$second/state/.chat-ask-guard.json" ] || fail "a secondmate home wrote guard state"

  prepare_case grok
  prompt p1 "status?"
  say "Shall I merge it?"
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" GROK_HOOK_EVENT=stop || rc=$?
  assert_silent "grok"

  prepare_case junk
  printf 'not json\n' | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "junk payload exited $rc"
  assert_silent "junk payload"
  pass "the opt-out file, a secondmate home, grok, and a junk payload stay silent"
}

test_tracked_stop_hook_is_synchronous_and_grok_inert() {
  local matches
  matches=$(jq '[.hooks.Stop[].hooks[]
      | select(.command | contains("/bin/fm-chat-ask-guard.sh"))
      | select(.asyncRewake | not)
      | select(.command | contains("${GROK_AGENT:-}${GROK_HOOK_EVENT:-}"))]
    | length' "$ROOT/.claude/settings.json") \
    || fail "tracked Stop hooks could not be read"
  [ "$matches" -eq 1 ] || fail "expected one synchronous grok-inert Stop hook for fm-chat-ask-guard.sh, saw $matches"
  pass "tracked Claude Stop settings run fm-chat-ask-guard.sh once, synchronously, and inert under grok"
}

fm_test_run \
  test_ask_blocks \
  test_answered_labels_pass \
  test_recap_passes \
  test_shipshape_passes \
  test_payload_message_is_preferred \
  test_covered_by_hold_passes \
  test_covered_by_open_call_passes \
  test_no_repeat_block \
  test_opt_out_and_scope_are_silent \
  test_tracked_stop_hook_is_synchronous_and_grok_inert
