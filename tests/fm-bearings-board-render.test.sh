#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # A build starts a listener for the board it publishes. Registered with
  # tests/lib.sh, not with a shell array: make_home runs inside a command
  # substitution, where an array append never reaches the caller.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits, and records that
  # session in this home's own store. The listener resolves its server from that
  # store; the machine-wide default has no session for this board.
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
    # The build's listening sample can land before this process resolves a
    # session. Recording entry makes that gap observable: a claim that dies
    # without reaching poll is not a listener.
    printf 'entered\n' > "$FM_HOME/stub-poll"
    # Bounded, so a listener that escapes its test stops on its own.
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

# The build treats a claimed runner as listening before that runner resolves a
# Lavish session. Wait until the stub poll is entered or the source is no longer
# live, and require both: a claim that dies in the gap is the flake.
require_listener_reached_poll() {  # <home>
  local home=$1 i=0 owner=''
  while [ "$i" -lt 40 ]; do
    i=$((i + 1))
    owner=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
      LAVISH_AXI_STATE_DIR="$home/lavish-state" \
      "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
      | awk 'NR > 1 { print $3; exit }')
    if [ -s "$home/stub-poll" ] && [ "$owner" = live ]; then
      return 0
    fi
    case "$owner" in
      none|orphaned)
        if [ -s "$home/stub-poll" ]; then
          fail "the board listener reached the Lavish poll and then exited (owner: $owner)"
        fi
        fail "the board listener exited before it reached the Lavish poll (owner: $owner)"
        ;;
    esac
    sleep 0.05
  done
  fail "the board listener did not reach the Lavish poll (owner: ${owner:-none})"
}

# Build the board from <underway-json> plus <charted-json> and return what the
# renderer produced.
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more] [calls-json]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" --argjson calls "${6:-[]}" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:$calls, underway:$underway, landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}"
}

test_full_snapshot_question_reaches_the_rendered_decision() {
  local home a b reason snapshot calls out
  home=$(make_home full-decision-question)
  a='A: retain the existing workflow through the complete staged verification and preserve all current integrations until each dependency has reported its result.'
  b='B: defer the independent migration until the remaining review has finished, keeping the full fallback route and the final café / 東京 approval.'
  reason="Which route should proceed? $a $b"
  cat > "$home/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] scope-call - Choose rollout scope (repo: sample) (kind: captain) (hold: $reason) (hold-kind: captain)

## Done
EOF
  snapshot=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bearings-snapshot.sh" --json) \
    || fail "the decision snapshot failed"
  # Composition consumes the complete recorded question directly. Options are
  # authored explicitly here, never inferred by parsing the stored prose.
  calls=$(printf '%s' "$snapshot" | jq '[.decisions_open[] | {
    key:.key,type:"decision",repo:"sample",title:"Rollout scope",decide:.question,
    options:[{value:"a",label:"Retain the workflow"},{value:"b",label:"Defer the migration"}]}]')
  out=$(render_board "$home" '[]' '[]' 0 0 "$calls")
  printf '%s' "$out" | jq -e --arg question "Choose rollout scope: $reason" --arg a "$a" --arg b "$b" '
    .error == "" and (.captains_call | length) == 1
      and (.captains_call[0] | contains($question) and contains($a) and contains($b))
  ' >/dev/null || fail "the rendered call lost its full question or final option: $out"
  pass "the complete snapshot question and options reach rendered decision text"
}

test_full_snapshot_question_reaches_the_rendered_decision

# Build a board with the given Captain's Call keys and run it under the drafts
# harness against a storage file shared across builds.
build_call_board() {  # <home> <keys-json> [charted-json]
  local home=$1 data="$1/payload.json"
  jq -n --argjson keys "$2" --argjson charted "${3:-[]}" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, underway:[], landed:[], charted:$charted, charted_more:0, charted_warning_more:0,
    captains_call:[$keys[] | {key:., type:"decision", title:("Card " + .), repo:"r",
      about:"a", decide:"d", allow_freeform:true,
      options:[{value:"a",label:"A"},{value:"b",label:"B"}]}]}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
}

test_a_rebuild_keeps_in_progress_answers_and_drops_only_departed_cards() {
  local home out
  home=$(make_home drafts)
  build_call_board "$home" '["k1","k2"]'
  node "$ROOT/tests/assets/board-drafts-harness.mjs" "$home/.lavish/bearings-board.html" "$home/storage.json" type >/dev/null \
    || fail "the first board could not be filled in"
  build_call_board "$home" '["k1","k3"]'
  out=$(node "$ROOT/tests/assets/board-drafts-harness.mjs" "$home/.lavish/bearings-board.html" "$home/storage.json") \
    || fail "the rebuilt board could not be rendered"
  printf '%s' "$out" | jq -e '
    (.cards | map(.key)) == ["k1","k3"]
      and .cards[0].selection == "a" and .cards[0].note == "typed k1"
      and .cards[1].selection == "" and .cards[1].note == ""
      and ((.storage | to_entries[0].value | fromjson | keys) == ["k1"])
  ' >/dev/null || fail "a rebuild lost or kept the wrong in-progress input: $out"
  pass "a rebuild keeps in-progress answers for surviving cards and drops departed ones"
}

# Run the built board under the browser harness: <home> <actions> [env...].
run_board() {  # <home> <actions>
  node "$ROOT/tests/assets/board-drafts-harness.mjs" "$1/.lavish/bearings-board.html" "$1/storage.json" "$2" \
    || fail "the board could not be exercised with: $2"
}

test_every_card_type_renders_its_links() {
  local home data out
  home=$(make_home card-links)
  data="$home/payload.json"
  jq -n '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, underway:[], landed:[], charted:[], charted_more:0, charted_warning_more:0,
    captains_call:[
      {key:"held-decision", type:"decision", title:"A held decision", repo:"r", about:"a",
       options:[], allow_freeform:true, pr_url:"https://example.test/o/r/pull/7",
       links:[{url:"http://dev-1.tailf848b0.ts.net:4387/session/abc", label:"Review page"}]},
      {key:"merge.some-task", type:"merge", title:"A merge", repo:"r", risk:"low",
       options:[{value:"merge",label:"Merge now"}], pr_url:"https://example.test/o/r/pull/9"},
      {key:"unheld-credential", type:"credential", title:"A credential", repo:"r",
       options:[{value:"done",label:"Done"}],
       links:[{url:"https://example.test/console"},
              {url:"https://example.test/mr/3", label:"Merge request"}]}]}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null 2>&1 || fail "the board did not build"
  require_listener_reached_poll "$home"
  out=$(node "$HARNESS" "$home/.lavish/bearings-board.html") \
    || fail "the built board could not be rendered"
  printf '%s' "$out" | jq -e '
    (.call | map({key, hrefs: [.links[].href]}) | sort_by(.key)) == [
      {key:"held-decision", hrefs:["https://example.test/o/r/pull/7",
        "http://dev-1.tailf848b0.ts.net:4387/session/abc"]},
      {key:"merge.some-task", hrefs:["https://example.test/o/r/pull/9"]},
      {key:"unheld-credential", hrefs:["https://example.test/console","https://example.test/mr/3"]}]
    and (.call[] | select(.key == "held-decision") | .links[1].text) == "Review page - http://dev-1.tailf848b0.ts.net:4387/session/abc"
    and (.call[] | select(.key == "unheld-credential") | .links[1].text) == "Merge request - https://example.test/mr/3"
  ' >/dev/null || fail "a card type did not render its links: $out"
  pass "decision, merge, and credential cards each render their PR and extra links"
}

test_a_rebuild_keeps_in_progress_answers_and_drops_only_departed_cards
test_every_card_type_renders_its_links

test_board_renders_only_the_captains_call() {
  local home out
  home=$(make_home only-call)
  out=$(render_board "$home" \
    '[{"id":"u1","name":"Underway one","repo":"r","state":"working","doing":"x","kind":"task"}]' \
    '[{"id":"c1","repo":"r","title":"Charted one","reason":"queued","dispatchable":true}]' 0 0 \
    '[{"key":"k1","type":"decision","title":"Decide","repo":"r","options":[],"allow_freeform":true}]')
  printf '%s' "$out" | jq -e '
    .error == "" and (.captains_call | length) == 1
      and .stats == [] and .underway == [] and .charted == []
  ' >/dev/null || fail "the board rendered more than the Captain's Call: $out"
  if grep -q 'Recently Landed\|Charted Next\|id="bb-underway"' "$home/.lavish/bearings-board.html"; then
    fail "the built board still carries a non-decision section"
  fi
  pass "the board renders only the Captain's Call decision box"
}

test_a_long_title_and_about_render_in_full() {
  local home out title about
  home=$(make_home long-text)
  title=$(printf 'T%.0s' $(seq 1 200))
  about=$(printf 'A%.0s' $(seq 1 400))
  out=$(render_board "$home" '[]' '[]' 0 0 "$(jq -n --arg t "$title" --arg a "$about" \
    '[{key:"k1",type:"decision",title:$t,about:$a,repo:"r",options:[],allow_freeform:true}]')")
  printf '%s' "$out" | jq -e --arg t "$title" --arg a "$about" '
    .error == "" and (.captains_call[0] | contains($t) and contains($a))
  ' >/dev/null || fail "a long title or about was cut: $out"
  pass "a long decision title and about text render without a cut"
}

test_board_renders_only_the_captains_call
test_a_long_title_and_about_render_in_full
