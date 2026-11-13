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
    # Other sessions a test says the server shows, one listing row per line.
    [ ! -s "$FM_HOME/lavish-sessions" ] || cat "$FM_HOME/lavish-sessions"
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
LONG_TITLE="Make the 'Already packed with serial' pack-screen warning readable on the smallest handheld scanner we support"
LONG_REASON="Queued, nothing blocking, waiting on the scanner vendor to confirm which firmware ships next quarter"
long_charted() {
  jq -cn --arg title "$LONG_TITLE" --arg reason "$LONG_REASON" '[
    {id:"long-gate",repo:"packsmith-app",title:$title,reason:$reason,dispatchable:true},
    {id:"long-warning",repo:"packsmith-app",title:("Repair: " + $title),reason:$reason,dispatchable:false,kind:"warning"}
  ]'
}

test_a_long_charted_row_renders_its_full_title_and_reason() {
  local home out
  home=$(make_home charted-long)
  out=$(render "$home" "$(long_charted)")
  printf '%s' "$out" | jq -e --arg title "$LONG_TITLE" --arg reason "$LONG_REASON" '
    (.charted | length) == 2
      and (.charted[0] | .title == $title and .sub == ($reason + " · packsmith-app")
        and [.badges[] | .text] == ["waiting"])
      and (.charted[1] | .title == ("Repair: " + $title)
        and .sub == ($reason + " · packsmith-app"))
  ' >/dev/null || fail "a long charted row did not render its full title and reason: $out"
  pass "a long charted row renders its full title and reason text"
}

find_chrome() {
  local c
  for c in "${FM_TEST_CHROME:-}" google-chrome google-chrome-stable chromium chromium-browser \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
    [ -n "$c" ] || continue
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
  done
  return 1
}

# Lay the built board out in a real browser at phone and desktop widths and
# measure every Charted Next title and reason line: none may clip its text, and
# the long ones must wrap rather than stay on one line.
test_a_long_charted_row_wraps_instead_of_clipping_in_a_browser() {
  local home chrome probe width dom measured
  if ! chrome=$(find_chrome); then
    echo "skip: no Chrome or Chromium found for the Charted Next layout check (set FM_TEST_CHROME)"
    return 0
  fi
  home=$(make_home charted-layout)
  render "$home" "$(long_charted)" >/dev/null
  probe="$home/probe.html"
  awk '{ sub(/<\/body>/, "<script>window.addEventListener(\"load\", function () { var rows = []; document.querySelectorAll(\"#bb-charted .bb-row\").forEach(function (r) { var line = function (c) { var n = r.querySelector(c); return {clipped: n.scrollWidth > n.clientWidth, height: n.getBoundingClientRect().height, lineHeight: parseFloat(getComputedStyle(n).lineHeight)}; }; rows.push({title: line(\".bb-row__title\"), sub: line(\".bb-row__sub\"), right: r.getBoundingClientRect().right}); }); var p = document.createElement(\"pre\"); p.id = \"layout-probe\"; p.textContent = JSON.stringify({rows: rows, viewport: document.documentElement.clientWidth, pageWidth: document.documentElement.scrollWidth}); document.body.appendChild(p); });</script></body>"); print }' \
    "$home/.lavish/bearings-board.html" > "$probe"
  for width in 500 1280; do
    dom=$("$chrome" --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
      --virtual-time-budget=5000 --window-size="$width,1200" --dump-dom "file://$probe" 2>/dev/null) \
      || fail "Chrome could not lay out the board at width $width"
    measured=$(printf '%s' "$dom" | node -e '
      let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
        const m = s.match(/<pre id="layout-probe">([\s\S]*?)<\/pre>/);
        const unescape = (t) => t.replace(/&quot;/g, "\"").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
        process.stdout.write(m ? unescape(m[1]) : "");
      });')
    [ -n "$measured" ] || fail "the layout probe did not report at width $width"
    printf '%s' "$measured" | jq -e '
      (.rows | length) == 2
        and all(.rows[]; (.title.clipped | not) and (.sub.clipped | not))
        and all(.rows[]; .title.height > (.title.lineHeight * 1.5))
        and all(.rows[]; .right <= $vw) and .pageWidth <= .viewport
    ' --argjson vw "$width" >/dev/null \
      || fail "a long charted row clipped or failed to wrap at width $width: $measured"
  done
  pass "a long charted row wraps its full text at phone and desktop widths in a browser"
}

test_a_long_charted_row_renders_its_full_title_and_reason
test_a_long_charted_row_wraps_instead_of_clipping_in_a_browser

# Build a board with the given Captain's Call keys and run it under the drafts
# harness against a storage file shared across builds.
build_call_board() {  # <home> <keys-json> [charted-json] [underway-json]
  local home=$1 data="$1/payload.json"
  jq -n --argjson keys "$2" --argjson charted "${3:-[]}" --argjson underway "${4:-[]}" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, underway:$underway, landed:[], charted:$charted, charted_more:0, charted_warning_more:0,
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
      and ((.storage["fm-bearings-board.drafts.v1"] | fromjson | keys) == ["k1"])
  ' >/dev/null || fail "a rebuild lost or kept the wrong in-progress input: $out"
  pass "a rebuild keeps in-progress answers for surviving cards and drops departed ones"
}

# Run the built board under the browser harness: <home> <actions> [env...].
run_board() {  # <home> <actions>
  node "$ROOT/tests/assets/board-drafts-harness.mjs" "$1/.lavish/bearings-board.html" "$1/storage.json" "$2" \
    || fail "the board could not be exercised with: $2"
}

# Write the next payload (the current one through a jq filter) and print a
# command that rebuilds the board from it, for the harness's run action.
rebuild_command() {  # <home> <jq-filter>
  local home=$1
  jq "$2" "$home/payload.json" > "$home/next.json" || fail "the next payload could not be written"
  printf 'PATH=%q FM_HOME=%q FM_STATE_OVERRIDE=%q FM_DATA_OVERRIDE=%q FM_PROCEVENT_CLAIM_ROOT=%q LAVISH_AXI_STATE_DIR=%q %q build %q >/dev/null' \
    "$home/fakebin:$PATH" "$home" "$home/state" "$home/data" "$home/procevent-claims" \
    "$home/lavish-state" "$BOARD" "$home/next.json"
}

page_identity() {  # <home>
  local page="$1/.lavish/bearings-board.html"
  printf '%s %s' "$(stat -c %i "$page" 2>/dev/null || stat -f %i "$page")" "$(cksum < "$page")"
}

test_a_refresh_patches_changed_cards_without_reloading_or_touching_typed_text() {
  local home out before run
  home=$(make_home live-patch)
  build_call_board "$home" '["k1","k2","k3"]'
  before=$(page_identity "$home")
  run=$(rebuild_command "$home" '.captains_call |= (map(select(.key != "k3"))
    | map(if .key == "k2" then .title = "Card k2 reworded" else . end)
    + [.[0] | .key = "k4" | .title = "Card k4"] + [.[0] | .key = "k5" | .title = "Card k5"])')
  out=$(NO_STORAGE=1 FM_HARNESS_RUN="$run" run_board "$home" "go,type:k1,focus:k1,run,poll")
  printf '%s' "$out" | jq -e '
    (.cards | map(.key)) == ["k1","k2","k4","k5"]
      and .cards[0].selection == "a" and .cards[0].note == "typed k1"
      and .cards[0].hidden == false
      and .cards[1].title == "Card k2 reworded" and .cards[2].title == "Card k4"
      and .cards[1].hidden and .cards[2].hidden
      and .order.list == ["k1","k2","k4","k5"] and .order.deckShown
      and .sub == "4 items wait on you, captain"
      and .reloads == [] and .polls == 1
  ' >/dev/null || fail "a refresh disturbed the open card or reloaded the page: $out"
  [ "$(page_identity "$home")" = "$before" ] \
    || fail "the rebuild rewrote the page file, which makes Lavish reload the open page"
  pass "a refresh patches only the changed cards and keeps typed text, the open card and the page"
}

test_a_refresh_leaves_a_card_alone_while_it_is_being_edited() {
  local home out run
  home=$(make_home live-busy)
  build_call_board "$home" '["k1","k2"]'
  run=$(rebuild_command "$home" '.captains_call |= map(.title += " reworded")')
  out=$(NO_STORAGE=1 FM_HARNESS_RUN="$run" run_board "$home" "go,type:k1,focus:k2,run,poll")
  printf '%s' "$out" | jq -e '
    .cards[0].title == "Card k1" and .cards[0].note == "typed k1"
      and .cards[1].title == "Card k2" and .reloads == []
  ' >/dev/null || fail "a refresh replaced a card that was being edited: $out"
  out=$(NO_STORAGE=1 FM_HARNESS_RUN="$run" run_board "$home" "go,focus:k2,run,poll,blur,poll")
  printf '%s' "$out" | jq -e '
    .cards[0].title == "Card k1 reworded" and .cards[1].title == "Card k2 reworded"
      and .reloads == []
  ' >/dev/null || fail "a card left alone while focused never caught up once focus left: $out"
  pass "a refresh leaves a card alone while it is being edited and updates it once it is not"
}

test_a_refresh_patches_changed_cards_without_reloading_or_touching_typed_text
test_a_refresh_leaves_a_card_alone_while_it_is_being_edited

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
       links:[{url:"https://example.test/o/r/issues/3", label:"Issue"}]},
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
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  out=$(node "$HARNESS" "$home/.lavish/bearings-board.html") \
    || fail "the built board could not be rendered"
  printf '%s' "$out" | jq -e '
    (.call | map({key, hrefs: [.links[].href]}) | sort_by(.key)) == [
      {key:"held-decision", hrefs:["https://example.test/o/r/pull/7",
        "https://example.test/o/r/issues/3"]},
      {key:"merge.some-task", hrefs:["https://example.test/o/r/pull/9"]},
      {key:"unheld-credential", hrefs:["https://example.test/console","https://example.test/mr/3"]}]
    and (.call[] | select(.key == "held-decision") | .links[1].text) == "Issue - https://example.test/o/r/issues/3"
    and (.call[] | select(.key == "unheld-credential") | .links[1].text) == "Merge request - https://example.test/mr/3"
  ' >/dev/null || fail "a card type did not render its links: $out"
  pass "decision, merge, and credential cards each render their PR and extra links"
}

# Lavish annotate mode is on by default and lets native controls act, but it
# turns a click on a plain <a href> into an annotation note. Every card link must
# carry data-lavish-action so a click opens it while annotate mode stays on.
test_every_card_link_opens_in_annotate_mode() {
  local home data out
  home=$(make_home link-actions)
  data="$home/payload.json"
  jq -n '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, underway:[], landed:[], charted:[], charted_more:0, charted_warning_more:0,
    captains_call:[
      {key:"held-decision", type:"decision", title:"A held decision", repo:"r", about:"a",
       options:[], allow_freeform:true, pr_url:"https://example.test/o/r/pull/7",
       links:[{url:"https://example.test/console", label:"Console"}]}]}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  out=$(node "$HARNESS" "$home/.lavish/bearings-board.html") \
    || fail "the built board could not be rendered"
  printf '%s' "$out" | jq -e '
    ([.call[].links[]] | length) == 2 and all(.call[].links[]; .action == true)
  ' >/dev/null || fail "a card link would open an annotation note instead of the link: $out"
  pass "every card link carries data-lavish-action so it opens in annotate mode"
}

# Register <id> as a live board page whose file is served from the home's page
# folder, and print that file's real path.
register_page() {  # <home> <id> <title>
  local home=$1 dir="$1/.lavish/pages/$2"
  mkdir -p "$dir" "$home/state/pages/$2"
  printf '<p>%s</p>\n' "$3" > "$dir/page.html"
  jq -n --arg id "$2" --arg title "$3" '{id:$id,title:$title,opened:"2026-08-26T00:00:00Z",state:"live"}' \
    > "$home/state/pages/$2/page.json"
  printf '%s/page.html\n' "$(cd "$dir" && pwd -P)"
}

# Build a board whose one card carries the links <links-jq> builds, then render it.
render_card_links() {  # <home> <links-jq>
  local home=$1 data="$1/payload.json" links
  links=$(jq -n -c "$2") || fail "the card links could not be built"
  jq -n --argjson links "$links" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, underway:[], landed:[], charted:[], charted_more:0, charted_warning_more:0,
    captains_call:[{key:"mr-872", type:"decision", title:"MR 872", repo:"r", about:"a",
      options:[], allow_freeform:true, pr_url:"https://example.test/o/r/merge_requests/872",
      links:$links}]}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# A Lavish page link on a card opens that page inside the board when the page is
# registered there, whether the page is served from the board's page folder or
# still runs from its own standalone folder, and never links out to Lavish.
test_a_registered_page_link_opens_in_the_board() {
  local home understand review standalone out
  home=$(make_home page-links)
  understand=$(register_page "$home" understand-mr-872 "Understand MR 872")
  review=$(register_page "$home" mr-review-mr-872 "Review MR 872")
  standalone="$home/scratch/understand-mr-872/page.html"
  mkdir -p "$(dirname "$standalone")" && : > "$standalone"
  {
    printf '  %s,open,"http://127.0.0.1:4387/session/aaaa1111",0\n' "$understand"
    printf '  %s,user-ended,"http://127.0.0.1:4387/session/bbbb2222",0,none\n' "$review"
    printf '  %s,open,"http://127.0.0.1:4387/session/cccc3333",0,agent-listener\n' "$standalone"
  } > "$home/lavish-sessions"
  out=$(render_card_links "$home" '[
    {url:"http://dev-1.tailf848b0.ts.net:4387/session/aaaa1111", label:"Understand page"},
    {url:"http://dev-1.tailf848b0.ts.net:4387/session/bbbb2222", label:"Review page"},
    {url:"http://dev-1.tailf848b0.ts.net:4387/session/cccc3333", label:"Old understand page"},
    {page:"mr-review-mr-872", label:"Review again"}]')
  printf '%s' "$out" | jq -e '
    .error == "" and (.call | length) == 1
      and (.call[0].links | map(.href)) == ["https://example.test/o/r/merge_requests/872"]
      and .call[0].pages == [
        {page:"understand-mr-872", text:"Understand page"},
        {page:"mr-review-mr-872", text:"Review page"}]
      and .call[0].notes == []
  ' >/dev/null || fail "a registered page link did not become an in-place page button: $out"
  ! grep -q '4387' "$home/.lavish/bearings-board.data.js" \
    || fail "the board data still carries a Lavish session url"
  pass "a card link to a registered page opens that page in the board, never a Lavish url"
}

# A Lavish page link whose page the board does not have says so in plain words.
test_an_unregistered_page_link_says_it_is_not_in_the_board() {
  local home out
  home=$(make_home page-notes)
  printf '  %s,open,"http://127.0.0.1:4387/session/dddd4444",0\n' "$home/elsewhere/understand-other/page.html" \
    > "$home/lavish-sessions"
  # Open the board first, so the server lists the board's own session.
  render_card_links "$home" '[]' >/dev/null
  out=$(render_card_links "$home" '[
    {url:"http://dev-1.tailf848b0.ts.net:4387/session/dddd4444", label:"Understand page"},
    {url:"http://dev-1.tailf848b0.ts.net:4387/session/eeee5555", label:"Review page"},
    {url:"http://dev-1.tailf848b0.ts.net:4387/session/0123456789abcdef", label:"Board"},
    {page:"understand-gone"}]')
  printf '%s' "$out" | jq -e '
    .error == "" and .call[0].pages == []
      and (.call[0].links | map(.href)) == ["https://example.test/o/r/merge_requests/872"]
      and .call[0].notes == [
        "Understand page - not in the board yet",
        "Review page - not in the board yet",
        "Lavish page - not in the board yet"]
  ' >/dev/null || fail "an unregistered page link was not shown as a plain note: $out"
  ! grep -q '4387' "$home/.lavish/bearings-board.data.js" \
    || fail "the board data still carries a Lavish session url"
  pass "a card link to a page the board does not have says it is not in the board yet"
}

# Clicking a card's page button shows that page inside the board's own tab.
test_a_card_page_button_shows_the_page_in_place() {
  local home page out
  home=$(make_home page-click)
  page=$(register_page "$home" understand-mr-872 "Understand MR 872")
  printf '  %s,open,"http://127.0.0.1:4387/session/aaaa1111",0\n' "$page" > "$home/lavish-sessions"
  render_card_links "$home" '[{url:"http://dev-1.tailf848b0.ts.net:4387/session/aaaa1111", label:"Understand page"}]' >/dev/null
  out=$(run_board "$home" "go,page:mr-872")
  printf '%s' "$out" | jq -e '
    .pageView.shown and .pageView.title == "Understand MR 872" and .opens == []
  ' >/dev/null || fail "the page button did not show the page inside the board: $out"
  pass "a card page button shows its page in place inside the board"
}

# Full screen maximises the page in place: the same frame, never re-created,
# moved or re-pointed, and the same button, Esc on the board, or Esc pressed
# inside the page leaves it.
test_full_screen_keeps_the_same_page_frame() {
  local home page out leave
  home=$(make_home page-max)
  page=$(register_page "$home" understand-mr-872 "Understand MR 872")
  printf '  %s,open,"http://127.0.0.1:4387/session/aaaa1111",0\n' "$page" > "$home/lavish-sessions"
  render_card_links "$home" '[{url:"http://dev-1.tailf848b0.ts.net:4387/session/aaaa1111", label:"Understand page"}]' >/dev/null
  out=$(run_board "$home" "go,page:mr-872,snap,max,snap")
  printf '%s' "$out" | jq -e '
    .pageView.shown and .pageView.max and .pageView.maxPressed == "true"
      and .reloads == [] and .opens == [] and (.snaps | length) == 2
      and (.snaps[0] | length) == 1 and .snaps[0][0].hidden == false
      and .snaps[0][0].src == "pages/understand-mr-872/page.html"
      and .snaps[1] == .snaps[0]
  ' >/dev/null || fail "full screen did not keep the same page frame: $out"
  for leave in max esc pageesc; do
    out=$(run_board "$home" "go,page:mr-872,snap,max,$leave,snap")
    printf '%s' "$out" | jq -e '
      .pageView.shown and (.pageView.max | not) and .pageView.maxPressed == "false"
        and .reloads == [] and .snaps[1] == .snaps[0]
    ' >/dev/null || fail "$leave did not leave full screen with the same page frame: $out"
  done
  pass "full screen keeps the same page frame, and the button or Esc leaves it"
}

# Lavish's annotate mode lives in the board alone, so the board tells every
# in-place page whether it is on, passes a page's annotation to that page's
# agent with the element it names, and toggles the mode on a page's hotkey.
test_annotate_mode_reaches_in_place_pages_and_their_notes_reach_the_page_agent() {
  local home page out
  home=$(make_home page-annotate)
  page=$(register_page "$home" understand-mr-872 "Understand MR 872")
  printf '  %s,open,"http://127.0.0.1:4387/session/aaaa1111",0\n' "$page" > "$home/lavish-sessions"
  render_card_links "$home" '[{url:"http://dev-1.tailf848b0.ts.net:4387/session/aaaa1111", label:"Understand page"}]' >/dev/null
  out=$(run_board "$home" "frameload:understand-mr-872,annotate:on,go,page:mr-872,annotation:understand-mr-872,stranger,pagetoggle:understand-mr-872,annotate:off")
  printf '%s' "$out" | jq -e '
    .framePosts["understand-mr-872"] == [
      {type:"fm-board-page:annotate", enabled:false},
      {type:"fm-board-page:annotate", enabled:true},
      {type:"fm-board-page:annotate", enabled:false}]
  ' >/dev/null || fail "the in-place page was not told when annotate mode changed: $out"
  printf '%s' "$out" | jq -e '
    [.calls[] | select(.tag == "page")] == [{
      key:"", anchor:.calls[0].anchor, prompt:"unclear", tag:"page",
      text:"Understand MR 872: Why this change",
      data:{schema:"fm-board-page.v1", page:"understand-mr-872", tag:"annotation", text:"Why this change",
        data:{selector:"p#why", id:"why", tag:"p", text:"Why this change"}}}]
      and (.calls[0].anchor | startswith("#bb-page-frame-"))
  ' >/dev/null || fail "an annotation inside the page did not reach the page agent with its element: $out"
  printf '%s' "$out" | jq -e '
    .keys == [{type:"keydown", key:"i", ctrlKey:true, metaKey:false}]
  ' >/dev/null || fail "the hotkey pressed inside the page did not toggle annotate mode: $out"
  pass "annotate mode reaches in-place pages and each page note reaches that page's agent"
}

test_a_rebuild_keeps_in_progress_answers_and_drops_only_departed_cards
test_every_card_type_renders_its_links
test_every_card_link_opens_in_annotate_mode
test_a_registered_page_link_opens_in_the_board
test_an_unregistered_page_link_says_it_is_not_in_the_board
test_a_card_page_button_shows_the_page_in_place
test_full_screen_keeps_the_same_page_frame
test_annotate_mode_reaches_in_place_pages_and_their_notes_reach_the_page_agent

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

test_the_board_lists_every_decision_for_reordering_before_the_cards() {
  local home out
  home=$(make_home reorder)
  build_call_board "$home" '["k1","k2","k3"]'
  out=$(run_board "$home" "")
  printf '%s' "$out" | jq -e '
    .order.stepShown and (.order.deckShown | not)
      and .order.list == ["k1","k2","k3"]
      and .order.titles == ["Card k1","Card k2","Card k3"]
  ' >/dev/null || fail "the board did not open on the reorderable list: $out"
  out=$(run_board "$home" "down:k1,down:k1,down:k2,up:k2,go")
  printf '%s' "$out" | jq -e '
    (.order.stepShown | not) and .order.deckShown
      and .order.list == ["k2","k3","k1"]
      and (.cards | map(.key)) == ["k2","k3","k1"]
  ' >/dev/null || fail "the chosen order did not become the card order: $out"
  pass "the board opens on one reorderable list and deals the cards in the chosen order"
}

test_the_chosen_order_travels_with_the_answers_and_survives_a_refresh() {
  local home out
  home=$(make_home reorder-answers)
  build_call_board "$home" '["k1","k2","k3"]'
  run_board "$home" "down:k1,down:k1,go,type" >/dev/null
  out=$(run_board "$home" "submit:k1,submit:k3,submit:k2")
  printf '%s' "$out" | jq -e '
    (.calls | map(.data | {question, order, order_total}) | sort_by(.order)) == [
      {question:"k2", order:1, order_total:3},
      {question:"k3", order:2, order_total:3},
      {question:"k1", order:3, order_total:3}]
    and (.calls | all(.prompt | test("priority [123] of 3")))
    and (.calls | all(.data.schema == "fm-bearings-answer.v1"))
  ' >/dev/null || fail "answers did not carry the chosen order: $out"
  # A new tab keeps the order, goes straight to the cards, and the reorder
  # control is held while answers are queued.
  rm -f "$home/storage.json.session.json"
  out=$(run_board "$home" "load")
  printf '%s' "$out" | jq -e '
    (.cards | map(.key)) == ["k2","k3","k1"] and .order.deckShown and (.order.stepShown | not)
  ' >/dev/null || fail "the chosen order did not survive a refresh: $out"
  # A rebuild with an extra card puts the list back so the new card is placed.
  build_call_board "$home" '["k1","k2","k3","k4"]'
  out=$(run_board "$home" "")
  printf '%s' "$out" | jq -e '
    .order.stepShown and .order.list == ["k2","k3","k1","k4"]
  ' >/dev/null || fail "a new card was not offered for placement: $out"
  pass "answers carry their priority and the order survives a refresh and a rebuild"
}

test_the_order_survives_a_refresh_without_browser_storage() {
  local home out
  home=$(make_home reorder-nostorage)
  build_call_board "$home" '["k1","k2"]'
  NO_STORAGE=1 run_board "$home" "down:k1,go,load" >/dev/null
  out=$(NO_STORAGE=1 run_board "$home" "load")
  printf '%s' "$out" | jq -e '
    (.cards | map(.key)) == ["k2","k1"] and .order.deckShown
  ' >/dev/null || fail "a sandboxed refresh lost the chosen order: $out"
  pass "the chosen order is restored through Lavish's form state when storage is blocked"
}

test_the_board_lists_every_decision_for_reordering_before_the_cards
test_the_chosen_order_travels_with_the_answers_and_survives_a_refresh
test_the_order_survives_a_refresh_without_browser_storage

test_the_priority_list_ranks_tasks_and_decisions_and_is_sent_for_recording() {
  local home out
  home=$(make_home priority)
  build_call_board "$home" '["k1","k2"]' '[]' \
    '[{"repo":"r","name":"Build it","id":"t1","state":"working","doing":"tests","kind":"ship"}]'
  out=$(run_board "$home" "")
  printf '%s' "$out" | jq -e '
    .order.stepShown and .order.list == ["k1","k2","task:t1"]
      and (.cards | map(.key)) == ["k1","k2"]
  ' >/dev/null || fail "the list did not include the task under way: $out"
  out=$(run_board "$home" "up:task:t1,go")
  printf '%s' "$out" | jq -e '
    .order.list == ["k1","task:t1","k2"] and (.cards | map(.key)) == ["k1","k2"]
      and (.calls | map(select(.data.schema == "fm-bearings-priority.v1")) | length) == 1
      and (.calls | map(select(.data.schema == "fm-bearings-priority.v1"))[0].data.keys) == ["k1","t1","k2"]
  ' >/dev/null || fail "the priority was not sent with the chosen order: $out"
  pass "the board ranks tasks and decisions together and sends the priority for recording"
}

test_the_priority_list_ranks_tasks_and_decisions_and_is_sent_for_recording

priority_calls='[.calls[] | select(.data.schema == "fm-bearings-priority.v1") | .data.keys]'

test_a_refresh_merges_the_restored_order_with_new_and_departed_decisions() {
  local home out
  home=$(make_home order-merge)
  build_call_board "$home" '["k1","k2","k3"]'
  NO_STORAGE=1 run_board "$home" "down:k1,go,load,send" >/dev/null
  build_call_board "$home" '["k1","k2","k3","k4"]'
  out=$(NO_STORAGE=1 run_board "$home" "load")
  printf '%s' "$out" | jq -e '.order.list == ["k2","k1","k3","k4"] and .order.stepShown' >/dev/null \
    || fail "a new decision reset the restored order instead of joining its end: $out"
  NO_STORAGE=1 run_board "$home" "load,down:k2,down:k2,go,send" >/dev/null
  build_call_board "$home" '["k2","k3","k4"]'
  out=$(NO_STORAGE=1 run_board "$home" "load")
  printf '%s' "$out" | jq -e '.order.list == ["k3","k2","k4"] and (.cards | map(.key)) == ["k3","k2","k4"]' >/dev/null \
    || fail "a departed decision reset the order of the others: $out"
  pass "a refresh keeps the restored order, adds new decisions at the end, and drops departed ones"
}

test_the_priority_is_sent_only_when_the_order_changes() {
  local home out
  home=$(make_home order-send)
  build_call_board "$home" '["k1","k2","k3"]'
  out=$(run_board "$home" "open:k2")
  printf '%s' "$out" | jq -e "($priority_calls | length) == 0 and (.cards | map(.key)) == [\"k1\",\"k2\",\"k3\"]" >/dev/null \
    || fail "opening a card with the order unchanged sent a priority: $out"
  rm -f "$home/storage.json" "$home/storage.json.session.json"
  out=$(run_board "$home" "down:k1,open:k1")
  printf '%s' "$out" | jq -e "$priority_calls == [[\"k2\",\"k1\",\"k3\"]]" >/dev/null \
    || fail "opening a card after a reorder did not send the new order exactly once: $out"
  rm -f "$home/storage.json" "$home/storage.json.session.json"
  out=$(run_board "$home" "down:k1,down:k1")
  printf '%s' "$out" | jq -e "$priority_calls == [[\"k2\",\"k3\",\"k1\"]]" >/dev/null \
    || fail "a reorder left on the list was not sent once after the pause: $out"
  rm -f "$home/storage.json" "$home/storage.json.session.json"
  out=$(run_board "$home" "down:k1,up:k1,go")
  printf '%s' "$out" | jq -e "($priority_calls | length) == 0" >/dev/null \
    || fail "a reorder that ended on the recorded order still sent a priority: $out"
  pass "the priority is sent once per change, after a pause on the list, and never for an unchanged order"
}

test_a_queued_priority_is_queued_again_with_the_order_after_a_rebuild() {
  local home out
  home=$(make_home order-requeue)
  build_call_board "$home" '["k1","k2","k3"]'
  NO_STORAGE=1 run_board "$home" "down:k1,go,load" >/dev/null
  build_call_board "$home" '["k1","k2","k3","k4"]'
  out=$(NO_STORAGE=1 run_board "$home" "load")
  printf '%s' "$out" | jq -e "$priority_calls == [[\"k2\",\"k1\",\"k3\",\"k4\"]] and (.queue | index(\"question:board-priority\")) != null" >/dev/null \
    || fail "a priority queued before the rebuild was not queued again with the merged order: $out"
  pass "a priority still queued at a rebuild is queued again with the merged order"
}

test_each_card_has_a_stable_id_so_its_queued_badge_stays_on_it() {
  local home out
  home=$(make_home card-ids)
  build_call_board "$home" '["k1","status.mate.x_y"]'
  NO_STORAGE=1 run_board "$home" "go,type,submit:status.mate.x_y,load" >/dev/null
  build_call_board "$home" '["k0","k1","status.mate.x_y"]'
  out=$(NO_STORAGE=1 run_board "$home" "load")
  printf '%s' "$out" | jq -e '
    (.ids | length) == 3 and (.ids | unique | length) == 3 and all(.ids[]; test("^[A-Za-z][A-Za-z0-9_-]*$"))
      and ([.cards[] | select(.queued) | .key] == ["status.mate.x_y"])
  ' >/dev/null || fail "a queued badge moved off its card when the deck changed: $out"
  pass "every card form has its own stable id, so a queued badge stays on its card after a rebuild"
}

test_a_refresh_merges_the_restored_order_with_new_and_departed_decisions
test_the_priority_is_sent_only_when_the_order_changes
test_a_queued_priority_is_queued_again_with_the_order_after_a_rebuild
test_each_card_has_a_stable_id_so_its_queued_badge_stays_on_it

test_waiting_holds_render_below_the_decisions_and_a_card_leads_with_its_question() {
  local home out data
  home=$(make_home waiting)
  build_call_board "$home" '["k1"]'
  data="$home/payload.json"
  jq '.captains_call[0] += {question: "Which route should proceed?"} | del(.captains_call[0].about)
      | .waiting = [{key:"w1", title:"Forge ops", reason:"Parked for the weekend; resume Monday", repo:null}]' \
    "$data" > "$data.new" && mv "$data.new" "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board with a waiting group did not build"
  out=$(node "$HARNESS" "$home/.lavish/bearings-board.html") || fail "the board could not be rendered"
  printf '%s' "$out" | jq -e '
    .error == "" and .waiting.shown
      and (.waiting.rows | length) == 1
      and (.waiting.rows[0] | contains("Forge ops") and contains("Parked for the weekend"))
      and (.captains_call | length) == 1
      and (.captains_call[0] | contains("Which route should proceed?") and contains("Card k1"))
      and (.captains_call[0] | contains("Parked for the weekend") | not)
  ' >/dev/null || fail "the waiting group or the question lead did not render: $out"
  out=$(render_board "$home" '[]' '[]' 0 0 '[]')
  printf '%s' "$out" | jq -e '.waiting.shown | not' >/dev/null || fail "an empty waiting group was shown: $out"
  pass "waiting holds render below the decisions and a decision card leads with its question"
}

test_waiting_holds_render_below_the_decisions_and_a_card_leads_with_its_question

test_the_bearings_header_links_back_to_the_board() {
  local home page
  home=$(make_home headerlink)
  build_call_board "$home" '["k1"]'
  page="$home/.lavish/bearings-board.html"
  [ -f "$page" ] || fail "the board page was not built"
  # The header brand is a real link to the stable board page, so a page opened
  # from the board returns to it on click.
  tr '\n' ' ' < "$page" | grep -Eq '<header[^>]*>[[:space:]]*<div[^>]*>[[:space:]]*<a [^>]*href="bearings-board\.html"[^>]*>.*<span class="bb-brand__wm">bearings</span>[[:space:]]*</a>' \
    || fail "the bearings header is not a link back to the board"
  pass "the bearings header links back to the board page"
}

test_the_bearings_header_links_back_to_the_board

test_card_links_wrap_and_the_about_text_is_readable_and_unclipped() {
  local home page css
  home=$(make_home cardlayout)
  build_call_board "$home" '["k1"]'
  page="$home/.lavish/bearings-board.html"
  [ -f "$page" ] || fail "the board page was not built"
  css=$(cat "$page")
  # Each card link sits on its own line and wraps; a long URL breaks rather
  # than being clipped.
  printf '%s' "$css" | grep -E '^\.bb-decision__link ' | grep -Eq 'display: *block' \
    || fail "a card link is not its own block"
  if printf '%s' "$css" | grep -E '^\.bb-decision__link ' | grep -Eq 'nowrap|ellipsis|overflow: *hidden'; then
    fail "a card link is still clipped"
  fi
  printf '%s' "$css" | grep -E '^\.bb-decision__link ' | grep -Eq 'overflow-wrap: *anywhere' \
    || fail "a long card link does not break"
  # The about text is shown in full and is not smaller than the card title is large.
  if printf '%s' "$css" | grep -E '^\.bb-ctx__v ' | grep -Eq 'ellipsis|line-clamp|nowrap|overflow: *hidden'; then
    fail "the about text is clipped"
  fi
  printf '%s' "$css" | grep -E '^\.bb-ctx__v ' | grep -Eq 'font-size: *var\(--fs-base\)' \
    || fail "the about text is not base size"
  printf '%s' "$css" | grep -E '^\.bb-decision__title ' | grep -Eq 'font-size: *var\(--fs-base\)' \
    || fail "the card title is still oversized"
  pass "card links wrap one per line and the about text is full and readable"
}

test_card_links_wrap_and_the_about_text_is_readable_and_unclipped
