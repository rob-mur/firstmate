#!/usr/bin/env bash
# Behavior tests for the throwaway prototype/board-editor/run: the captain's
# calls as a board.md listing plus one card file per call, kept across runs.
# A run never deletes a card. It records a saved answer once in the outbox,
# appends an acknowledgement to that card, and moves its line from "With
# captain" to "With firstmate". As on the real board, a call that asks no
# question goes to "Broken" and is reported once per card version, and a hold
# deferred to a future date is listed under "Charted". A plain-language lint
# fault is only a "Check:" note: the card stays with the captain. An answer
# already in the outbox is never recorded again, also after the board and
# outbox move. The captain's order in "With captain" is kept. Every run reads a saved model (TUI_BOARD_CALLS_JSON),
# a stub lint (TUI_BOARD_LINT) and a scratch EDITOR script, so nothing reads or
# writes a real home.
#
# A call that links a Lavish page (page:<id>) gets a markdown copy of that page
# in the board folder, read from a fixture home (TUI_BOARD_HOME). Each line the
# captain adds is recorded once as a comment on the block above it and
# acknowledged under it, and a rebuild from a changed source keeps that text.
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
end = lines.index("## Broken")
idx = [i for i in range(start, end) if re.match(r"cards/", lines[i])]
cards = [lines[i] for i in idx][::-1]
for i, l in zip(idx, cards):
    lines[i] = l
open("board.md", "w").write("\n".join(lines) + "\n")
PY
    ;;
  snapshot) cp board.md "$ED_SNAPSHOT" ;;
  answer-fail) printf '%s\n' "$ED_TEXT" >>"cards/$ED_KEY.md"; exit 3 ;;
  page)  # in pages/$ED_PAGE.md, write $ED_TEXT under the line $ED_AFTER of block $ED_BLOCK
    python3 - <<'PY'
import os
path = f"pages/{os.environ['ED_PAGE']}.md"
lines = open(path).read().splitlines()
start = lines.index(f"<!-- block: {os.environ['ED_BLOCK']} -->")
at = next(i for i in range(start, len(lines)) if lines[i] == os.environ["ED_AFTER"])
lines[at + 1:at + 1] = os.environ["ED_TEXT"].split("\n")
open(path, "w").write("\n".join(lines) + "\n")
PY
    ;;
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

# A Lavish review page in the fixture home: a title, then items that each have
# a header, a text, a post/edit/skip pick and a note box.
page_item() {  # <id> <n> <text>
  cat <<EOF
<article class="c" id="$1">
  <header><span class="n">$2</span> <span class="where">app.py:1$2</span></header>
  <p>$3</p>
  <div class="pick">
    <label><input type="radio" name="choice-$1" value="post" checked> Post as written</label>
    <label><input type="radio" name="choice-$1" value="edit"> Post with my edit</label>
    <label><input type="radio" name="choice-$1" value="skip"> Skip</label>
  </div>
  <textarea name="note-$1" placeholder="Your note"></textarea>
</article>
EOF
}

page_source() {  # <dir> <item html>...  -> page rev in the fixture home, linked from call a
  local dir=$1 src="$1/home/.lavish/pages/rev"
  shift
  mkdir -p "$src" "$dir/home/state/pages/rev"
  { printf '<html><body>\n<h1>Review texts</h1>\n<p>Pick what to post.</p>\n'; printf '%s\n' "$@"; printf '</body></html>\n'; } \
    >"$src/page.html"
  printf '{"id":"rev","task":"hold-a","opened":"2026-11-18T12:00:00Z"}\n' >"$dir/home/state/pages/rev/page.json"
  model "$dir/model.json" "$(printf '%s' "$call_a" | jq -c '.links = [{"url":"page:rev","label":""}]')" "$call_b"
}

fresh_page() {  # <name>  -> a scratch dir whose call a links page rev with items r1 and r2
  local dir
  dir=$(fresh "$1")
  page_source "$dir" "$(page_item r1 1 'Rename the flag.')" "$(page_item r2 2 'Add a test.')"
  printf '%s\n' "$dir"
}

comments() {  # <outbox>  -> count of comment lines
  [ -f "$1" ] || { echo 0; return; }
  jq -s '[.[] | select(.kind == "comment")] | length' "$1"
}

run_board() {  # <dir> [args...]  (ED_* in the environment)
  local dir=$1
  shift
  TUI_BOARD_HOME="$dir/home" TUI_BOARD_DIR="$dir/board" TUI_BOARD_OUTBOX="$dir/outbox.jsonl" \
    TUI_BOARD_CALLS_JSON="${MODEL:-$dir/model.json}" TUI_BOARD_LINT="${LINT:-$dir/lint.sh}" \
    EDITOR="$dir/ed.sh" "$RUN" "$@"
}

assert_line() {  # <whole line> <file> <msg>
  grep -xF -- "$1" "$2" >/dev/null || fail "$3"
}

section_of() {  # <board.md> <key>  -> captain, firstmate or absent
  awk -v k="cards/$2.md" '
    /^## With captain/ {s="captain"} /^## Broken/ {s="broken"} /^## Charted/ {s="charted"}
    /^## With firstmate/ {s="firstmate"}
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

test_lint_fault_is_a_note_not_broken() {
  local dir card MODEL
  dir=$(fresh lint-fail)
  MODEL="$dir/model-wall.json"
  model "$MODEL" "$call_a" "$(printf '%s' "$call_c" | jq -c '.question = "Cut three tickets? WALL is long."')"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "the run failed"
  card="$dir/board/cards/w-c.ask.md"
  assert_equals captain "$(section_of "$dir/board/board.md" w-c.ask)" "a real call that fails the lint stays with the captain"
  assert_line 'Check: LENGTH (40 words, limit 25): "a WALL of text"' "$card" "the card notes the lint fault"
  assert_no_regex "^Broken:|^Received by firstmate" "$card" "the card is not broken and not acknowledged"
  grep -q '^cards/w-c\.ask\.md .* - check: 1 note$' "$dir/board/board.md" || fail "the board line counts the notes"
  assert_absent "$dir/outbox.jsonl" "a lint fault reports nothing to firstmate"
  pass "a lint fault on a real call is a Check note on the card; the card stays with the captain"
}

test_not_a_question_goes_to_broken() {
  local dir card MODEL
  dir=$(fresh not-question)
  MODEL="$dir/model-statement.json"
  model "$MODEL" "$call_a" "$(printf '%s' "$call_c" | jq -c '.question = "Compact the fire point."')"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "the run failed"
  card="$dir/board/cards/w-c.ask.md"
  assert_equals broken "$(section_of "$dir/board/board.md" w-c.ask)" "a call that asks no question is in Broken"
  assert_equals captain "$(section_of "$dir/board/board.md" hold-a)" "a question is not"
  assert_line "Broken: this card does not ask a question. Firstmate rewrites it." "$card" "the card says why"
  assert_line "These cards do not ask a question. Firstmate rewrites them." "$dir/board/board.md" "the board says why"
  grep -Eqx "$ACK_RE" "$card" || fail "the card gets the same acknowledgement as an answer"
  assert_equals '["not a question"]' "$(jq -c 'select(.kind == "broken") | .faults' "$dir/outbox.jsonl")" \
    "it is reported to firstmate as not a question"
  pass "a call with no question mark goes to Broken, is reported, and is acknowledged"
}

test_no_duplicate_broken_report() {
  local dir card before MODEL
  dir=$(fresh broken-dedupe)
  MODEL="$dir/model-statement.json"
  model "$MODEL" "$(printf '%s' "$call_c" | jq -c '.question = "Cut three tickets."')"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "first run failed"
  card="$dir/board/cards/w-c.ask.md"
  before=$(cat "$card")
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "second run failed"
  assert_equals 1 "$(broken_reports "$dir/outbox.jsonl" w-c.ask)" "the same card version is reported once"
  assert_equals "$before" "$(cat "$card")" "the card keeps its acknowledgement"
  model "$MODEL" "$(printf '%s' "$call_c" | jq -c '.question = "Cut four tickets."')"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "third run failed"
  assert_equals 2 "$(broken_reports "$dir/outbox.jsonl" w-c.ask)" "a changed card that still asks nothing is a new report"
  model "$MODEL" "$call_c"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "fourth run failed"
  assert_equals captain "$(section_of "$dir/board/board.md" w-c.ask)" "a fixed card goes to the captain"
  assert_no_regex "^Broken:|^Received by firstmate" "$card" "a fixed card is rebuilt clean"
  assert_equals 2 "$(broken_reports "$dir/outbox.jsonl" w-c.ask)" "a fixed card reports nothing"
  pass "each broken card version is reported once; a fixed card goes back to the captain"
}

test_deferred_hold_is_charted() {
  local dir MODEL
  dir=$(fresh charted)
  MODEL="$dir/model-charted.json"
  model "$MODEL" "$call_a"
  jq '.skipped = [
      {key:"cd.later", home:"cd", task:"cd-later", title:"cd-later", question:"Compact the fire point?",
       why:"deferred until 2099-11-25"},
      {key:"hold-x", home:"main", task:"hold-x", title:"hold-x", question:null, why:"answered, not yet closed"}]' \
    "$MODEL" >"$MODEL.tmp" && mv "$MODEL.tmp" "$MODEL"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "the run failed"
  awk '/^## Charted/ {s=1; next} /^## / {s=0} s' "$dir/board/board.md" | grep -qx -- \
    '- cd.later  until 2099-11-25: Compact the fire point?  (cd)' || fail "a deferred hold is listed under Charted with its date"
  grep -q '^# Captain.s calls: 1 with you, 0 broken, 1 charted, 0 with firstmate' "$dir/board/board.md" ||
    fail "the header counts the charted hold"
  awk '/^## Not on the board now/ {s=1} s' "$dir/board/board.md" | grep -q 'cd.later' &&
    fail "a charted hold is not also under Not on the board now"
  awk '/^## Not on the board now/ {s=1} s' "$dir/board/board.md" | grep -q 'hold-x: answered' ||
    fail "other skipped entries stay under Not on the board now"
  assert_absent "$dir/board/cards/cd.later.md" "a charted hold gets no card while it waits"
  pass "a hold deferred to a future date is listed under Charted, not with the captain"
}

test_moved_board_and_outbox_record_nothing_new() {
  local dir moved
  dir=$(fresh moved)
  run_board "$dir" >/dev/null || fail "first run failed"
  ED_ACTION=answer ED_KEY=hold-a ED_TEXT=$'Drop them.\n\n    a. keep the pages\nThen ship.' run_board "$dir" >/dev/null ||
    fail "answer run failed"
  ED_ACTION=answer ED_KEY=w-c.ask ED_TEXT="Yes." run_board "$dir" >/dev/null || fail "second answer run failed"
  ED_ACTION=answer ED_KEY=hold-a ED_TEXT="Ship Friday." run_board "$dir" >/dev/null || fail "follow-up run failed"
  assert_equals 3 "$(jq -s '[.[] | select(.kind == "answer")] | length' "$dir/outbox.jsonl")" "three answers to start"
  moved="$TMP_ROOT/moved-to"
  mkdir -p "$moved"
  cp -r "$dir/board" "$moved/board"
  cp "$dir/outbox.jsonl" "$moved/outbox.jsonl"
  cp "$dir/model.json" "$dir/ed.sh" "$dir/lint.sh" "$moved/"
  run_board "$moved" >/dev/null || fail "run at the new place failed"
  run_board "$moved" >/dev/null || fail "second run at the new place failed"
  assert_equals "$(cat "$dir/outbox.jsonl")" "$(cat "$moved/outbox.jsonl")" "a moved board and outbox record nothing new"
  # The same move without the run's baselines (as an older board had none) also records nothing new.
  rm -rf "$moved/board/.seen"
  run_board "$moved" >/dev/null || fail "run without baselines failed"
  assert_equals "$(cat "$dir/outbox.jsonl")" "$(cat "$moved/outbox.jsonl")" "a board with no baselines records nothing new"
  pass "a board and outbox copied to a new place record no answer again"
}

test_old_answer_without_baseline_not_recorded_again() {
  local dir card MODEL
  dir=$(fresh old-answer)
  run_board "$dir" >/dev/null || fail "first run failed"
  card="$dir/board/cards/cd.key-b.md"
  # An older run recorded this answer without the blank line the captain left in it, and kept no baseline.
  printf '%s\n' "Two things: do we want lavish pages?" "" "    a. drop them, use markdown" >>"$card"
  rm -f "$dir/board/.seen/cd.key-b.md" "$dir/board/.seen/cd.key-b.json"
  jq -cn '{at:"2026-11-18T12:53:00Z", prototype:true, kind:"answer", key:"cd.key-b", home:"cd", task:"cd-b",
           decision_key:"key-b", question:"Where should the version go?",
           text:"Two things: do we want lavish pages?\n    a. drop them, use markdown"}' >"$dir/outbox.jsonl"
  MODEL="$dir/model-gone.json"
  model "$MODEL" "$call_a"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "the run failed"
  assert_equals 1 "$(answers "$dir/outbox.jsonl" cd.key-b)" "the answer already in the outbox is not recorded again"
  assert_equals firstmate "$(section_of "$dir/board/board.md" cd.key-b)" "the answered card stays with firstmate"
  grep -q '^cards/cd\.key-b\.md  Where should the version go?  (cd)' "$dir/board/board.md" ||
    fail "its line names the question and home from the recorded answer"
  # A later note under the acknowledgement is still a new answer, with its home and task.
  printf '%s\n' "Ship Friday." >>"$card"
  MODEL="$MODEL" run_board "$dir" >/dev/null || fail "the follow-up run failed"
  assert_equals '{"text":"Ship Friday.","home":"cd","task":"cd-b"}' \
    "$(jq -c 'select(.kind == "answer") | {text, home, task}' "$dir/outbox.jsonl" | tail -n 1)" \
    "a new note is recorded with the home and task of the earlier answer"
  pass "an old card's answer that is already in the outbox is not recorded again"
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
  assert_equals captain "$(section_of "$dir/board/board.md" w-c.ask)" "a long sentence leaves the card with the captain"
  grep -q '^Check: LENGTH' "$dir/board/cards/w-c.ask.md" || fail "a long sentence fails the real lint as a note"
  assert_no_regex '^Check:' "$dir/board/cards/hold-a.md" "short plain sentences pass the real lint"
  pass "the real plainspeak lint notes a long sentence on its card"
}

test_real_lint_reads_wrapped_options_unwrapped() {
  local dir real=$HOME/.claude/skills/plainspeak-publish/scripts/lint MODEL q
  [ -f "$real" ] || { pass "skip: the plainspeak lint is not installed"; return; }
  case "$(sh "$real" </dev/null 2>&1 || true)" in PLAINSPEAK\ UNCHECKED*) pass "skip: the plainspeak lint did not run"; return ;; esac
  dir=$(fresh lint-wrap)
  # One option of 25 words, the limit: wrapped on the card it spans two lines, and its letter is not a word.
  q="Which way should the runner image go? (a) keep the image on the old host until the new one has run every job in the full test suite for one whole working week; (b) move it now."
  MODEL="$dir/model-wrap.json"
  model "$MODEL" "$(printf '%s' "$call_c" | jq -c --arg q "$q" '.question = $q')"
  MODEL="$MODEL" LINT="$real" run_board "$dir" >/dev/null || fail "the run failed"
  [ "$(grep -c '^  a) ' "$dir/board/cards/w-c.ask.md")" = 1 ] && grep -q '^     ' "$dir/board/cards/w-c.ask.md" ||
    fail "the option wraps on the card"
  assert_no_regex 'LENGTH' "$dir/board/cards/w-c.ask.md" "a wrapped option of 25 words passes"
  pass "the lint reads a wrapped option as one item without its letter"
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
  assert_contains "$out" "No card or page with key 'nope'" "an unknown key is named"
  pass "run <key> opens one card; an unknown key exits 2"
}

ACK_RE='Received by firstmate at [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} UTC - waiting on firstmate\.'

line_after() {  # <file> <whole line>  -> the line under the first match
  awk -v l="$2" 'hit {print; exit} $0 == l {hit=1}' "$1"
}

test_page_converts_to_markdown_linked_from_card() {
  local dir page
  dir=$(fresh_page page-convert)
  run_board "$dir" >/dev/null || fail "the run failed"
  page="$dir/board/pages/rev.md"
  assert_line "- Page: pages/rev.md" "$dir/board/cards/hold-a.md" "the card links the markdown page"
  assert_present "$page" "the run writes the page into the board folder"
  grep -q '^<!-- page: rev | task: hold-a | opened: 2026-11-18T12:00:00Z | from: .lavish/pages/rev/page.html (version [0-9a-f]*) -->$' "$page" ||
    fail "the first line names the page, its task and its source version"
  assert_line "<!-- block: r1 -->" "$page" "each item is a block with its stable id"
  assert_line "<!-- block: r2 -->" "$page" "every item gets a block"
  assert_equals "## 1 · app.py:11" "$(line_after "$page" "<!-- block: r1 -->")" "the item header is the block heading"
  assert_line "Rename the flag." "$page" "the item text is kept"
  assert_line "  a) Post as written (default)" "$page" "the pick lists its options with letters"
  assert_line "  c) Skip" "$page" "every option gets a letter"
  assert_equals 1 "$(grep -c '^- PROTOTYPE: this page is a file' "$page")" "the page explains itself once"
  assert_absent "$dir/outbox.jsonl" "a fresh page that passes the lint reports nothing"
  pass "a linked Lavish page becomes a markdown page with one block per item, linked from its card"
}

test_page_comment_recorded_once_on_its_block() {
  local dir page before
  dir=$(fresh_page page-comment)
  run_board "$dir" >/dev/null || fail "first run failed"
  page="$dir/board/pages/rev.md"
  ED_ACTION=page ED_PAGE=rev ED_BLOCK=r1 ED_AFTER="Rename the flag." ED_TEXT="Call it the cache flag." \
    run_board "$dir" >/dev/null || fail "comment run failed"
  assert_equals 1 "$(comments "$dir/outbox.jsonl")" "the comment is recorded"
  assert_equals '{"page":"rev","task":"hold-a","block":"r1","text":"Call it the cache flag.","after":"Rename the flag."}' \
    "$(jq -c 'select(.kind == "comment") | {page, task, block, text, after}' "$dir/outbox.jsonl")" \
    "the record names the page, the block and the line it answers"
  line_after "$page" "Call it the cache flag." | grep -Eqx "$ACK_RE" || fail "the acknowledgement sits under the comment"
  before=$(cat "$page")
  run_board "$dir" >/dev/null || fail "third run failed"
  run_board "$dir" >/dev/null || fail "fourth run failed"
  assert_equals 1 "$(comments "$dir/outbox.jsonl")" "later runs do not record it again"
  assert_equals "$before" "$(cat "$page")" "later runs leave the page alone"
  pass "a captain comment is recorded once against its block and acknowledged under it"
}

test_page_letter_picks_option() {
  local dir
  dir=$(fresh_page page-pick)
  run_board "$dir" >/dev/null || fail "first run failed"
  ED_ACTION=page ED_PAGE=rev ED_BLOCK=r2 ED_AFTER="Add a test." ED_TEXT='c' run_board "$dir" >/dev/null ||
    fail "pick run failed"
  assert_equals '{"block":"r2","text":"c","pick":{"name":"choice-r2","value":"skip","label":"Skip"},"note_field":"note-r2"}' \
    "$(jq -c 'select(.kind == "comment") | {block, text, pick, note_field}' "$dir/outbox.jsonl")" \
    "the letter picks that item's option"
  pass "a letter on its own line in an item picks that item's option"
}

test_page_rebuild_keeps_captain_text() {
  local dir page
  dir=$(fresh_page page-rebuild)
  run_board "$dir" >/dev/null || fail "first run failed"
  page="$dir/board/pages/rev.md"
  ED_ACTION=page ED_PAGE=rev ED_BLOCK=r1 ED_AFTER="Rename the flag." ED_TEXT="Call it the cache flag." \
    run_board "$dir" >/dev/null || fail "comment run failed"
  ED_ACTION=page ED_PAGE=rev ED_BLOCK=r2 ED_AFTER="Add a test." ED_TEXT="b" run_board "$dir" >/dev/null ||
    fail "pick run failed"
  # The source changes: r1 gets new text, r2 is gone, r3 is new.
  page_source "$dir" "$(page_item r1 1 'Rename the flag now.')" "$(page_item r3 3 'Drop the shim.')"
  run_board "$dir" >/dev/null || fail "rebuild run failed"
  assert_line "Rename the flag now." "$page" "the rebuild shows the new source text"
  assert_line "<!-- block: r3 -->" "$page" "the rebuild adds the new item"
  assert_line "Call it the cache flag." "$page" "the captain's comment survives the rebuild"
  awk '/^<!-- block: r1 -->$/ {s=1; next} /^<!-- block: / {s=0} s && /^Call it the cache flag\.$/ {f=1} END {exit !f}' "$page" ||
    fail "the comment stays in its block"
  line_after "$page" "Call it the cache flag." | grep -Eqx "$ACK_RE" || fail "its acknowledgement stays under it"
  assert_line "## Comments on parts no longer on the page" "$page" "a comment on a gone item is kept apart"
  awk '/^## Comments on parts no longer on the page$/ {s=1} s && $0 == "<!-- block: r2 -->" {b=1} b && $0 == "b" {f=1} END {exit !f}' "$page" ||
    fail "the gone item's comment keeps its block id"
  assert_equals 2 "$(comments "$dir/outbox.jsonl")" "the rebuild records nothing new"
  run_board "$dir" >/dev/null || fail "run after the rebuild failed"
  assert_equals 2 "$(comments "$dir/outbox.jsonl")" "the run after a rebuild records nothing new"
  pass "a rebuild from a changed source keeps the captain's text and its acknowledgements"
}

test_page_slash_marker_without_baseline() {
  local dir page
  dir=$(fresh_page page-marker)
  run_board "$dir" >/dev/null || fail "first run failed"
  page="$dir/board/pages/rev.md"
  rm -f "$dir/board/.seen/pages/rev.md"
  printf '%s\n' "// Ship r2 last." >>"$page"
  run_board "$dir" >/dev/null || fail "marker run failed"
  assert_equals '{"block":"r2","text":"Ship r2 last."}' \
    "$(jq -c 'select(.kind == "comment") | {block, text}' "$dir/outbox.jsonl")" \
    "a // line is the captain's even with no earlier copy of the page"
  pass "a line that starts with // is read as the captain's when there is no baseline"
}

test_page_missing_source_is_named() {
  local dir
  dir=$(fresh page-missing)
  model "$dir/model.json" "$(printf '%s' "$call_a" | jq -c '.links = [{"url":"page:gone","label":""}]')"
  run_board "$dir" >/dev/null || fail "the run failed"
  assert_line "- Page: page:gone (not found)" "$dir/board/cards/hold-a.md" "a page link with no source says so"
  assert_absent "$dir/board/pages/gone.md" "no page is made without a source"
  pass "a page link with no source is named in the card and makes no page"
}

test_broken_page_reported_once_and_ack_survives_rebuild() {
  local dir page
  dir=$(fresh page-broken)
  page_source "$dir" "$(page_item r1 1 'Rename the flag. WALL is long.')" "$(page_item r2 2 'Add a test.')"
  run_board "$dir" >/dev/null || fail "first run failed"
  page="$dir/board/pages/rev.md"
  assert_line "Check: 1 part of this page fails the plain-language check. Firstmate rewrites it." "$page" \
    "the page says how many parts fail"
  assert_equals '> Check: LENGTH (40 words, limit 25): "a WALL of text"' "$(line_after "$page" "<!-- block: r1 -->")" \
    "the failing part lists its fault"
  assert_equals 1 "$(broken_reports "$dir/outbox.jsonl" page:rev)" "the broken page is reported"
  assert_equals '{"r1":["LENGTH (40 words, limit 25): \"a WALL of text\""]}' \
    "$(jq -c 'select(.kind == "broken") | .blocks' "$dir/outbox.jsonl")" "the report holds the faults by block"
  # A rebuild of the same source version (here forced) writes the check line afresh.
  jq '.source = "forced"' "$dir/board/.seen/pages/rev.json" >"$dir/rev.json" && mv "$dir/rev.json" "$dir/board/.seen/pages/rev.json"
  run_board "$dir" >/dev/null || fail "rebuild run failed"
  line_after "$page" "Check: 1 part of this page fails the plain-language check. Firstmate rewrites it." |
    grep -Eqx "$ACK_RE" || fail "the acknowledgement is back under the check line"
  assert_equals 1 "$(broken_reports "$dir/outbox.jsonl" page:rev)" "the same version is not reported again"
  pass "a broken page is reported once per version and keeps its acknowledgement through a rebuild"
}

test_default_board_location() {
  local dir
  dir=$(fresh default-home)
  env -u TUI_BOARD_DIR -u TUI_BOARD_OUTBOX HOME="$dir/h" TUI_BOARD_HOME="$dir/home" \
    TUI_BOARD_CALLS_JSON="$dir/model.json" TUI_BOARD_LINT="$dir/lint.sh" EDITOR="$dir/ed.sh" \
    ED_ACTION=answer ED_KEY=hold-a ED_TEXT="b" "$RUN" >/dev/null || fail "the run failed"
  assert_present "$dir/h/.local/share/fm-board-prototype/board/board.md" "the board goes under ~/.local/share"
  assert_equals 1 "$(answers "$dir/h/.local/share/fm-board-prototype/outbox.jsonl" hold-a)" \
    "the outbox goes next to it"
  pass "with no overrides the board and outbox live under ~/.local/share/fm-board-prototype"
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
  test_lint_fault_is_a_note_not_broken \
  test_not_a_question_goes_to_broken \
  test_no_duplicate_broken_report \
  test_deferred_hold_is_charted \
  test_moved_board_and_outbox_record_nothing_new \
  test_old_answer_without_baseline_not_recorded_again \
  test_missing_lint_is_unchecked_not_passed \
  test_real_lint_flags_a_long_sentence \
  test_real_lint_reads_wrapped_options_unwrapped \
  test_one_card_and_unknown_key \
  test_page_converts_to_markdown_linked_from_card \
  test_page_comment_recorded_once_on_its_block \
  test_page_letter_picks_option \
  test_page_rebuild_keeps_captain_text \
  test_page_slash_marker_without_baseline \
  test_page_missing_source_is_named \
  test_broken_page_reported_once_and_ack_survives_rebuild \
  test_default_board_location
