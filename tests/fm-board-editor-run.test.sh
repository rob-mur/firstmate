#!/usr/bin/env bash
# Behavior tests for the throwaway prototype/board-editor/run: the captain's
# calls as a board.md listing plus one card file per call, kept across runs.
# A run never deletes a card. It records a saved answer once in the outbox,
# appends an acknowledgement to that card, and moves its line from "With
# captain" to "With firstmate". A card that fails the plain-language lint goes
# to "Broken" and is reported once per card version. The captain's order in
# "With captain" is kept. Every run reads a saved model (TUI_BOARD_CALLS_JSON),
# a stub lint (TUI_BOARD_LINT) and a scratch EDITOR script, so nothing reads or
# writes a real home.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-board-editor-run)
RUN="$ROOT/prototype/board-editor/run"

# A model with three calls: one main hold with options, one secondmate call
# with its options written inline, and one main worker question.
call_a='{"key":"hold-a","source":"main-hold","home":"main","task":"hold-a","title":"hold-a",
  "question":"Ship the cache now? It is green.","decision":true,"free_text":true,
  "options":[{"value":"now","label":"Ship it now"},{"value":"later","label":"Wait a week"}],
  "links":[],"prs":[],"blocked_by":[]}'
call_b='{"key":"cd.key-b","source":"secondmate","home":"cd","task":"cd-b","title":"cd-b","decision_key":"key-b",
  "question":"Where should the version go? (a, recommended) cd-pipeline/version, inside the folder CD owns; (b) a root VERSION file. Either way it is one line. Details: https://forge.example/rob/cd/pulls/885",
  "decision":true,"free_text":true,"options":[],"prs":[{"url":"https://forge.example/rob/cd/pulls/885","state":"open"}],
  "links":[{"url":"https://forge.example/rob/cd/pulls/885","label":""}],"blocked_by":[]}'
call_c='{"key":"w-c.ask","source":"main-worker","home":"main","task":"w-c","title":"w-c","decision_key":"ask",
  "question":"Cut three tickets?","decision":true,"free_text":true,"options":[],"links":[],"prs":[],"blocked_by":[]}'
call_d='{"key":"cd.key-d","source":"secondmate","home":"cd","task":"cd-d","title":"cd-d","decision_key":"key-d",
  "question":"Pin the runner image?","decision":true,"free_text":true,"options":[],"links":[],"prs":[],"blocked_by":[]}'

model() {  # <file> <call json>...  -> a saved model with those calls
  local out=$1
  shift
  printf '%s\n' "$@" | jq -s '{generated:"2026-11-18T12:00:00Z",calls:.,to_close:[],skipped:[],homes:[]}' >"$out"
}

# The scratch editor runs in the board folder and does what ED_ACTION says.
editor_script() {  # <dir>
  cat >"$1/ed.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${ED_ACTION:-none}" in
  none) ;;
  answer) printf '%s\n' "$ED_TEXT" >>"cards/$ED_KEY.md" ;;
  reverse)  # reverse the card lines under With captain
    python3 - <<'PY'
import re
lines = open("board.md").read().splitlines()
start = lines.index("## With captain") + 1
end = lines.index("## With firstmate")
idx = [i for i in range(start, end) if re.match(r"cards/", lines[i])]
cards = [lines[i] for i in idx][::-1]
for i, l in zip(idx, cards):
    lines[i] = l
open("board.md", "w").write("\n".join(lines) + "\n")
PY
    ;;
  snapshot) cp board.md "$ED_SNAPSHOT" ;;
  answer-fail) printf '%s\n' "$ED_TEXT" >>"cards/$ED_KEY.md"; exit 3 ;;
esac
EOF
  chmod +x "$1/ed.sh"
}

# The stub lint fails any text with the word WALL in it, like the plainspeak
# lint: one "- RULE ..." line per fault and exit 1; otherwise PLAINSPEAK OK.
lint_script() {  # <dir>
  cat >"$1/lint.sh" <<'EOF'
#!/bin/sh
text=$(cat)
case "$text" in
  *WALL*) printf '%s\n' '- LENGTH (40 words, limit 25): "a WALL of text"' ''; echo 'Rewrite the draft.'; exit 1 ;;
esac
echo "PLAINSPEAK OK"
EOF
}

fresh() {  # <name>  -> a scratch dir with an editor, a lint, a model of calls a, b, c
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  editor_script "$dir"
  lint_script "$dir"
  model "$dir/model.json" "$call_a" "$call_b" "$call_c"
  printf '%s\n' "$dir"
}

run_board() {  # <dir> [args...]  (ED_* in the environment)
  local dir=$1
  shift
  TUI_BOARD_DIR="$dir/board" TUI_BOARD_OUTBOX="$dir/outbox.jsonl" \
    TUI_BOARD_CALLS_JSON="${MODEL:-$dir/model.json}" TUI_BOARD_LINT="${LINT:-$dir/lint.sh}" \
    EDITOR="$dir/ed.sh" "$RUN" "$@"
}

assert_line() {  # <whole line> <file> <msg>
  grep -xF -- "$1" "$2" >/dev/null || fail "$3"
}

section_of() {  # <board.md> <key>  -> captain, firstmate or absent
  awk -v k="cards/$2.md" '
    /^## With captain/ {s="captain"} /^## Broken/ {s="broken"} /^## With firstmate/ {s="firstmate"}
    /^## Not on/ {s=""}
    index($0, k) == 1 {print s; found=1; exit} END {if (!found) print "absent"}' "$1"
}

captain_keys() {  # <board.md>  -> keys under With captain, one per line
  awk '/^## With captain/ {s=1; next} /^## / {s=0} s && /^cards\// {sub(/^cards\//, ""); sub(/\.md .*/, ""); print}' "$1"
}

answers() {  # <outbox> <key>  -> count of answer lines for that key
  [ -f "$1" ] || { echo 0; return; }
  jq -s --arg k "$2" '[.[] | select(.kind == "answer" and .key == $k)] | length' "$1"
}

test_card_reads_well_in_vim() {
  local dir card
  dir=$(fresh layout)
  run_board "$dir" >/dev/null || fail "the run failed"
  card="$dir/board/cards/cd.key-b.md"
  assert_equals "<!-- card: cd.key-b | from: secondmate cd -->" "$(sed -n 1p "$card")" \
    "the identifiers sit on one line above the question"
  assert_equals "# Where should the version go?" "$(sed -n 3p "$card")" "the question is the heading"
  assert_line "  a) cd-pipeline/version, inside the folder CD owns (recommended)." "$card" \
    "an inline option gets its own labelled line, marked recommended"
  assert_line "  b) a root VERSION file." "$card" "each option is on its own line"
  assert_line "- Either way it is one line." "$card" "context is a bullet"
  assert_line "- https://forge.example/rob/cd/pulls/885 (open)" "$card" "the link is listed once with its state"
  assert_no_regex "^(About|Kind|Task|Key|Raised):" "$card" "the About block is gone"
  assert_line "  a) Ship it now." "$dir/board/cards/hold-a.md" "a hold's options are a labelled list"
  pass "a card has a one-line id, the question heading, bullets and one option per line"
}

test_cards_persist_across_runs() {
  local dir MODEL
  dir=$(fresh persist)
  run_board "$dir" >/dev/null || fail "first run failed"
  assert_present "$dir/board/cards/w-c.ask.md" "the first run makes a card per call"
  # The worker's call leaves the source and the main hold's question changes.
  MODEL="$dir/model2.json"
  model "$MODEL" "$(printf '%s' "$call_a" | jq -c '.question = "Ship the cache today? It is green."')" "$call_b"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "second run failed"
  assert_present "$dir/board/cards/w-c.ask.md" "a card is kept when its call leaves the source"
  assert_equals absent "$(section_of "$dir/board/board.md" w-c.ask)" \
    "a call that left while with the captain leaves the board"
  assert_line "# Ship the cache today?" "$dir/board/cards/hold-a.md" \
    "an unanswered card gets the new question"
  pass "card files survive runs; unanswered cards are refreshed; a gone call leaves the board"
}

test_answer_moves_card_to_firstmate_with_ack() {
  local dir card
  dir=$(fresh answer)
  run_board "$dir" >/dev/null || fail "first run failed"
  ED_ACTION=answer ED_KEY=hold-a ED_TEXT="b" run_board "$dir" >/dev/null || fail "answer run failed"
  card="$dir/board/cards/hold-a.md"
  assert_equals 1 "$(answers "$dir/outbox.jsonl" hold-a)" "the answer is recorded once"
  assert_equals later "$(jq -r 'select(.kind == "answer") | .option' "$dir/outbox.jsonl")" "the letter picks the option"
  assert_line "b" "$card" "the captain's answer stays in the card"
  grep -Eqx 'Received by firstmate at [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} UTC - waiting on firstmate\.' "$card" ||
    fail "the card says firstmate received it"
  assert_equals firstmate "$(section_of "$dir/board/board.md" hold-a)" "the card moves to With firstmate"
  assert_equals captain "$(section_of "$dir/board/board.md" cd.key-b)" "the other cards stay with the captain"
  pass "a saved answer is recorded, acknowledged in the card, and its line moves to With firstmate"
}

test_no_duplicate_outbox_lines() {
  local dir card before
  dir=$(fresh dedupe)
  run_board "$dir" >/dev/null || fail "first run failed"
  ED_ACTION=answer ED_KEY=cd.key-b ED_TEXT="a, but keep it short" run_board "$dir" >/dev/null || fail "answer run failed"
  card="$dir/board/cards/cd.key-b.md"
  before=$(cat "$card")
  run_board "$dir" >/dev/null || fail "third run failed"
  run_board "$dir" >/dev/null || fail "fourth run failed"
  assert_equals 1 "$(answers "$dir/outbox.jsonl" cd.key-b)" "later runs do not record the answer again"
  assert_equals "$before" "$(cat "$card")" "later runs leave an answered card alone"
  assert_equals firstmate "$(section_of "$dir/board/board.md" cd.key-b)" "it stays with firstmate"
  ED_ACTION=answer ED_KEY=cd.key-b ED_TEXT="One more thing: ship Friday." run_board "$dir" >/dev/null ||
    fail "follow-up run failed"
  assert_equals 2 "$(answers "$dir/outbox.jsonl" cd.key-b)" "a new note after the acknowledgement is a new answer"
  assert_equals "One more thing: ship Friday." \
    "$(jq -r 'select(.kind == "answer") | .text' "$dir/outbox.jsonl" | tail -n 1)" "it records only the new text"
  assert_equals 2 "$(grep -c '^Received by firstmate at' "$card")" "each answer gets one acknowledgement"
  pass "each answer reaches the outbox exactly once across runs"
}

test_answer_saved_between_runs_is_recorded_at_start() {
  local dir
  dir=$(fresh between)
  run_board "$dir" >/dev/null || fail "first run failed"
  printf 'Yes, cut them.\n' >>"$dir/board/cards/w-c.ask.md"
  ED_ACTION=snapshot ED_SNAPSHOT="$dir/seen-board.md" run_board "$dir" >/dev/null || fail "second run failed"
  assert_equals firstmate "$(section_of "$dir/seen-board.md" w-c.ask)" \
    "the board the captain opens already shows it with firstmate"
  assert_equals 1 "$(answers "$dir/outbox.jsonl" w-c.ask)" "the answer is recorded once"
  # An editor that exits nonzero records nothing then; the next run records it.
  ED_ACTION=answer-fail ED_KEY=cd.key-b ED_TEXT="Ship it." run_board "$dir" >/dev/null &&
    fail "a failed editor makes the run fail"
  assert_equals 0 "$(answers "$dir/outbox.jsonl" cd.key-b)" "a failed editor records nothing"
  run_board "$dir" >/dev/null || fail "run after the failed editor failed"
  assert_equals 1 "$(answers "$dir/outbox.jsonl" cd.key-b)" "the next run records the saved answer"
  pass "an answer saved outside a run is recorded and moved at the start of the next run"
}

test_captain_order_is_kept() {
  local dir MODEL
  dir=$(fresh order)
  run_board "$dir" >/dev/null || fail "first run failed"
  assert_equals "hold-a cd.key-b w-c.ask" "$(captain_keys "$dir/board/board.md" | xargs)" "source order at first"
  ED_ACTION=reverse run_board "$dir" >/dev/null || fail "reorder run failed"
  assert_equals '["w-c.ask","cd.key-b","hold-a"]' \
    "$(jq -c 'select(.kind == "order") | .keys' "$dir/outbox.jsonl")" "the new order is recorded"
  MODEL="$dir/model2.json"
  model "$MODEL" "$call_a" "$call_b" "$call_c" "$call_d"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "third run failed"
  assert_equals "w-c.ask cd.key-b hold-a cd.key-d" "$(captain_keys "$dir/board/board.md" | xargs)" \
    "the captain's order is kept and a new call goes last"
  ED_ACTION=answer ED_KEY=cd.key-b ED_TEXT="a" MODEL="$MODEL" run_board "$dir" >/dev/null || fail "answer run failed"
  assert_equals "w-c.ask hold-a cd.key-d" "$(captain_keys "$dir/board/board.md" | xargs)" \
    "an answered card leaves the order; the rest keep theirs"
  assert_equals 1 "$(jq -s '[.[] | select(.kind == "order")] | length' "$dir/outbox.jsonl")" \
    "an unchanged order is not recorded again"
  pass "the captain's order in With captain is kept across runs"
}

test_passing_card_stays_with_captain() {
  local dir
  dir=$(fresh lint-pass)
  run_board "$dir" >/dev/null || fail "the run failed"
  assert_equals captain "$(section_of "$dir/board/board.md" hold-a)" "a passing card is with the captain"
  assert_no_regex "^Broken:|^Received by firstmate" "$dir/board/cards/hold-a.md" "a passing card has no faults and no acknowledgement"
  assert_absent "$dir/outbox.jsonl" "a passing card reports nothing"
  pass "a card that passes the lint stays with the captain and reports nothing"
}

broken_reports() {  # <outbox> <key>
  [ -f "$1" ] || { echo 0; return; }
  jq -s --arg k "$2" '[.[] | select(.kind == "broken" and .key == $k)] | length' "$1"
}

test_failing_card_goes_to_broken() {
  local dir card MODEL
  dir=$(fresh lint-fail)
  MODEL="$dir/model-wall.json"
  model "$MODEL" "$call_a" "$(printf '%s' "$call_c" | jq -c '.question = "Cut three tickets? WALL is long."')"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "the run failed"
  card="$dir/board/cards/w-c.ask.md"
  assert_equals broken "$(section_of "$dir/board/board.md" w-c.ask)" "a failing card is in Broken"
  assert_equals captain "$(section_of "$dir/board/board.md" hold-a)" "a passing card is not"
  assert_line "Broken: this card fails the plain-language check. Firstmate rewrites it." "$card" "the card says it is broken"
  assert_line '- LENGTH (40 words, limit 25): "a WALL of text"' "$card" "the card lists its faults"
  assert_line '    LENGTH (40 words, limit 25): "a WALL of text"' "$dir/board/board.md" "the board lists its faults"
  grep -Eqx 'Received by firstmate at [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} UTC - waiting on firstmate\.' "$card" ||
    fail "the card gets the same acknowledgement as an answer"
  assert_equals 1 "$(broken_reports "$dir/outbox.jsonl" w-c.ask)" "it is reported to firstmate"
  assert_equals '["LENGTH (40 words, limit 25): \"a WALL of text\""]' \
    "$(jq -c 'select(.kind == "broken") | .faults' "$dir/outbox.jsonl")" "the report holds the faults"
  pass "a failing card goes to Broken with its faults, is reported, and is acknowledged"
}

test_no_duplicate_broken_report() {
  local dir card before MODEL
  dir=$(fresh lint-dedupe)
  MODEL="$dir/model-wall.json"
  model "$MODEL" "$(printf '%s' "$call_c" | jq -c '.question = "Cut three tickets? WALL is long."')"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "first run failed"
  card="$dir/board/cards/w-c.ask.md"
  before=$(cat "$card")
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "second run failed"
  assert_equals 1 "$(broken_reports "$dir/outbox.jsonl" w-c.ask)" "the same card version is reported once"
  assert_equals "$before" "$(cat "$card")" "the card keeps its acknowledgement"
  model "$MODEL" "$(printf '%s' "$call_c" | jq -c '.question = "Cut four tickets? WALL is long."')"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "third run failed"
  assert_equals 2 "$(broken_reports "$dir/outbox.jsonl" w-c.ask)" "a changed card that still fails is a new report"
  model "$MODEL" "$call_c"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "fourth run failed"
  assert_equals captain "$(section_of "$dir/board/board.md" w-c.ask)" "a fixed card goes to the captain"
  assert_no_regex "^Broken:|^Received by firstmate" "$card" "a fixed card is rebuilt clean"
  assert_equals 2 "$(broken_reports "$dir/outbox.jsonl" w-c.ask)" "a fixed card reports nothing"
  pass "each broken card version is reported once; a fixed card goes back to the captain"
}

test_missing_lint_is_unchecked_not_passed() {
  local dir
  dir=$(fresh lint-missing)
  LINT="$dir/no-such-lint" run_board "$dir" >/dev/null || fail "the run failed"
  assert_line "- The plain-language check did not run. No card on this board has a check." "$dir/board/board.md" \
    "the board says the cards are unchecked"
  assert_equals captain "$(section_of "$dir/board/board.md" hold-a)" "an unchecked card is not marked broken"
  pass "a missing lint leaves the cards unchecked, and the board says so"
}

test_real_lint_flags_a_long_sentence() {
  local dir real=$HOME/.claude/skills/plainspeak-publish/scripts/lint MODEL long
  [ -f "$real" ] || { pass "skip: the plainspeak lint is not installed"; return; }
  dir=$(fresh lint-real)
  long="It is green and done, and the gate fired because the change edits the pipeline that the fix itself runs in, so it waits for deploy and acceptance."
  MODEL="$dir/model-long.json"
  model "$MODEL" "$call_a" "$(printf '%s' "$call_c" | jq -c --arg q "Cut three tickets? $long" '.question = $q')"
  MODEL="$MODEL" LINT="$real" run_board "$dir" >/dev/null || fail "the run failed"
  out=$(sh "$real" </dev/null 2>&1 || true)
  case "$out" in PLAINSPEAK\ UNCHECKED*) pass "skip: the plainspeak lint did not run"; return ;; esac
  assert_equals broken "$(section_of "$dir/board/board.md" w-c.ask)" "a long sentence fails the real lint"
  assert_equals captain "$(section_of "$dir/board/board.md" hold-a)" "short plain sentences pass the real lint"
  pass "the real plainspeak lint marks a long sentence broken"
}

test_card_with_firstmate_stays_after_its_call_leaves() {
  local dir MODEL
  dir=$(fresh gone)
  run_board "$dir" >/dev/null || fail "first run failed"
  ED_ACTION=answer ED_KEY=w-c.ask ED_TEXT="Yes." run_board "$dir" >/dev/null || fail "answer run failed"
  MODEL="$dir/model2.json"
  model "$MODEL" "$call_a"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "third run failed"
  assert_equals firstmate "$(section_of "$dir/board/board.md" w-c.ask)" "it stays with firstmate"
  grep -q "^cards/w-c\.ask\.md .*Cut three tickets?.* sent [0-9]" "$dir/board/board.md" ||
    fail "its line keeps the question from the last source record"
  assert_equals absent "$(section_of "$dir/board/board.md" cd.key-b)" "an unanswered gone call leaves the board"
  pass "a card with firstmate stays listed after its call leaves the source"
}

test_one_card_and_unknown_key() {
  local dir out
  dir=$(fresh single)
  ED_ACTION=none run_board "$dir" hold-a >/dev/null || fail "run <key> failed"
  local code=0
  out=$(run_board "$dir" nope 2>&1) || code=$?
  expect_code 2 "$code" "an unknown key exits 2"
  assert_contains "$out" "No card with key 'nope'" "an unknown key is named"
  pass "run <key> opens one card; an unknown key exits 2"
}

fm_test_run \
  test_card_reads_well_in_vim \
  test_cards_persist_across_runs \
  test_answer_moves_card_to_firstmate_with_ack \
  test_no_duplicate_outbox_lines \
  test_answer_saved_between_runs_is_recorded_at_start \
  test_captain_order_is_kept \
  test_card_with_firstmate_stays_after_its_call_leaves \
  test_passing_card_stays_with_captain \
  test_failing_card_goes_to_broken \
  test_no_duplicate_broken_report \
  test_missing_lint_is_unchecked_not_passed \
  test_real_lint_flags_a_long_sentence \
  test_one_card_and_unknown_key
