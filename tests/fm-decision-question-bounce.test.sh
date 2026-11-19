#!/usr/bin/env bash
# Behavior tests for the watcher's needs-decision question bounce
# (bin/fm-watch.sh, check owned by bin/fm-bearings-card-check-lib.sh).
#
# A worker that raises a needs-decision as an instruction rather than a question
# would have its card held back off the captain's board. The watcher runs the
# same card check the board build runs the moment the line lands and steers the
# owning worker once, through its durable steering inbox, to re-raise it as a
# question. These tests pin:
#   1. The pdm sign-in line is bounced exactly once, with the re-raise rule,
#      and its status line is left untouched.
#   2. A repeat cycle does not re-bounce the same line, and a re-raised valid
#      question under the same key is not bounced.
#   3. A valid question is never bounced.
#   4. The board build holds back the same line with the same problem text the
#      bounce carries.
#   5. A no-mistakes ask-user gate escalation, whose shape the brief mandates,
#      is never bounced.
#   6. A question whose "?" comes after its inline options is a question: the
#      board does not hold it back and the watcher does not bounce it.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision-question-bounce-tests)

SIGNIN='needs-decision [key=signin]: open https://example.test/signin ... and approve the sign-in, before 09:04 UTC'
RULE='re-raise as needs-decision [key=signin] with one question ending in ?, lettered options, recommended first, full URL'
VALID_SIGNIN='needs-decision [key=signin]: Approve the sign-in at https://example.test/signin before 09:04 UTC? (a, recommended) approve (b) skip'
VALID_OTHER='needs-decision [key=other]: Ship the fix now? (a, recommended) ship https://example.test/pr/1 (b) wait'
TRAILING_ASK='needs-decision [key=stall]: The stall timer fired twice, how should pdm handle the retry: (a, recommended) back off 5m (b) retry now (c) give up?'

# A live ship task t1 in its own home, whose window the fake tmux lists.
bounce_case() {  # <name> -> case dir
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/config" "$dir/data"
  fm_write_meta "$dir/state/t1.meta" "window=test:fm-t1" "kind=ship" "harness=claude" "backend=tmux"
  printf '%s\n' "$dir"
}

# One watcher round over <dir>'s home: run until it surfaces the new status
# span and exits, then acknowledge the queued wake so the next round starts clean.
bounce_round() {  # <dir>
  local dir=$1 pid
  watch_bg "$dir/state" "$dir/fakebin" "$dir/watch.out" env \
    FM_HOME="$dir" FM_FAKE_TMUX_WINDOW=test:fm-t1 FM_SEND_SETTLE=0
  pid=$!
  wait_for_exit "$pid" 150 || fail "the watcher did not surface the needs-decision line: $(cat "$dir/watch.out")"
  ack_stopped_cycle "$dir/state" >/dev/null 2>&1 || true
}

steer_records() {  # <dir>
  find "$dir/state/t1.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | sort -V
}

steer_count() {  # <dir>
  steer_records "$1" | grep -c . || true
}

record_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

test_instruction_line_is_bounced_once_with_the_rule() {
  local dir status before body
  dir=$(bounce_case signin-bounce)
  status="$dir/state/t1.status"
  printf 'working: waiting on the pdm sign-in\n%s\n' "$SIGNIN" > "$status"
  before=$(cksum < "$status")

  bounce_round "$dir"
  [ "$(steer_count "$dir")" -eq 1 ] \
    || fail "the sign-in instruction was not bounced exactly once: $(steer_records "$dir")"
  body=$(record_body "$(steer_records "$dir")")
  assert_contains "$body" "$RULE" "the bounce does not carry the re-raise rule"
  assert_contains "$body" "missing question" "the bounce does not say why the line was held back"
  [ "$(cksum < "$status")" = "$before" ] || fail "the bounce rewrote the worker's status line: $(cat "$status")"
  grep -F "signal: $status" "$dir/watch.out" >/dev/null \
    || fail "the bounce swallowed the wake to firstmate: $(cat "$dir/watch.out")"

  # A later needs-decision span re-runs the check over every open decision: the
  # already-bounced sign-in line must not be steered again, and the new valid
  # question must not be steered at all.
  printf '%s\n' "$VALID_OTHER" >> "$status"
  bounce_round "$dir"
  [ "$(steer_count "$dir")" -eq 1 ] \
    || fail "a repeat cycle re-bounced the same line or bounced a valid question: $(steer_records "$dir")"

  # The worker re-raises the same key as a real question: no bounce.
  printf '%s\n' "$VALID_SIGNIN" >> "$status"
  bounce_round "$dir"
  [ "$(steer_count "$dir")" -eq 1 ] \
    || fail "a re-raised valid question under the same key was bounced: $(steer_records "$dir")"
  pass "a needs-decision instruction is bounced once with the re-raise rule, never twice, and a valid re-raise is left alone"
}

test_valid_question_is_never_bounced() {
  local dir
  dir=$(bounce_case valid-question)
  printf '%s\n' "$VALID_SIGNIN" > "$dir/state/t1.status"
  bounce_round "$dir"
  [ "$(steer_count "$dir")" -eq 0 ] || fail "a valid question was bounced: $(steer_records "$dir")"
  pass "a needs-decision that asks one question with options and a link is not bounced"
}

test_ask_user_gate_line_is_never_bounced() {
  local dir
  dir=$(bounce_case ask-user-gate)
  printf 'needs-decision [at=1] [key=nm-01abc-review]: ask-user findings=f1,f2 file=%s/data/t1/nm-01abc-findings.txt\n' \
    "$dir" > "$dir/state/t1.status"
  bounce_round "$dir"
  [ "$(steer_count "$dir")" -eq 0 ] || fail "a mandated ask-user gate escalation was bounced: $(steer_records "$dir")"
  pass "a no-mistakes ask-user gate escalation is left for firstmate, not bounced"
}

# The real board pipeline over <dir>'s home: snapshot, payload, build. The
# Lavish stub refuses every call, so the build never reaches a server; it has
# already filed its held-back cards in state/board-cards-to-fix by then.
board_build() {  # <dir>
  local dir=$1 boardbin
  boardbin="$dir/boardbin"
  mkdir -p "$boardbin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$boardbin/lavish-axi"
  chmod +x "$boardbin/lavish-axi"
  (
    export PATH="$boardbin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
      FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_BEARINGS_BOARD_PR_CHECK=0 FM_BEARINGS_BOARD_MR_CHECK=0 \
      LAVISH_AXI_STATE_DIR="$dir/lavish-state" FM_BEARINGS_BOARD_REFRESH=false
    "$ROOT/bin/fm-bearings-snapshot.sh" --json \
      | "$ROOT/bin/fm-bearings-board-payload.sh" --snapshot - > "$dir/payload.json" \
      && { "$ROOT/bin/fm-bearings-board.sh" build "$dir/payload.json" >/dev/null 2>&1 || true; }
  ) || fail "the board pipeline could not build a payload"
}

test_board_and_bounce_agree_on_the_problem() {
  local dir body problem
  dir=$(bounce_case board-agrees)
  printf '%s\n' "$SIGNIN" > "$dir/state/t1.status"
  bounce_round "$dir"
  body=$(record_body "$(steer_records "$dir")")
  board_build "$dir"
  problem=$(awk -F '\t' '$1 == "t1" && $2 == "status.t1.signin" { print $3 }' "$dir/state/board-cards-to-fix" 2>/dev/null)
  [ -n "$problem" ] || fail "the board did not hold back the sign-in card: $(cat "$dir/state/board-cards-to-fix" 2>&1)"
  assert_contains "$body" "$problem" "the bounce and the board disagree about the sign-in line"
  pass "the board holds back the sign-in line with the same problem the bounce sends the worker"
}

test_question_mark_after_inline_options_is_a_question() {
  local dir
  dir=$(bounce_case trailing-ask)
  printf '%s\n' "$TRAILING_ASK" > "$dir/state/t1.status"
  bounce_round "$dir"
  [ "$(steer_count "$dir")" -eq 0 ] \
    || fail "a question ending in ? after its inline options was bounced: $(record_body "$(steer_records "$dir")")"
  board_build "$dir"
  [ "$(jq -r '.captains_call[] | select(.key == "status.t1.stall") | .question' "$dir/payload.json")" \
    = "The stall timer fired twice, how should pdm handle the retry?" ] \
    || fail "the board card lost the question mark after the options: $(jq -c '.captains_call' "$dir/payload.json")"
  if grep -F "status.t1.stall" "$dir/state/board-cards-to-fix" >/dev/null 2>&1; then
    fail "the board held back a question ending in ? after its inline options: $(cat "$dir/state/board-cards-to-fix")"
  fi
  pass "a question whose ? follows its inline options reaches the board and is not bounced"
}

fm_test_run \
  test_instruction_line_is_bounced_once_with_the_rule \
  test_valid_question_is_never_bounced \
  test_ask_user_gate_line_is_never_bounced \
  test_board_and_bounce_agree_on_the_problem \
  test_question_mark_after_inline_options_is_a_question
