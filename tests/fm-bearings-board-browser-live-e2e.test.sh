#!/usr/bin/env bash
# tests/fm-bearings-board-browser-live-e2e.test.sh - live guard that clicks a
# built bearings board in a real headless Chrome.
#
# Why this file exists: the DOM shim in tests/assets/board-drafts-harness.mjs
# fires a button's click handler directly, so it cannot see a button that
# something else covers on screen. The full-screen page view once covered the
# board header, so the header that returns to the board home could not be
# clicked while a page was full screen, and the shim test still passed. Here
# the browser's own hit-testing decides what each click lands on.
#
# It builds a board with one card and one in-place page in a scratch home with
# a stubbed lavish-axi, opens the built file directly, and never touches a Lavish
# server. A second board starts with two cards and is rebuilt to one while
# open, the way the agent refreshes it after the captain sends an answer. It spends no model tokens, so it runs wherever node and a Chrome are
# installed and reports a capability skip elsewhere.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHROME=${FM_TEST_CHROME:-}
if [ -z "$CHROME" ]; then
  for c in google-chrome google-chrome-stable chromium chromium-browser; do
    if command -v "$c" >/dev/null 2>&1; then CHROME=$c; break; fi
  done
fi
fm_live_gate default-on FM_BEARINGS_BROWSER_LIVE node jq "${CHROME:-google-chrome}"

BOARD="$ROOT/bin/fm-bearings-board.sh"
CLICK="$ROOT/tests/assets/board-browser-click.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-browser)

pass() { printf 'ok - %s\n' "$1"; }

home="$TMP_ROOT/home"
fm_test_track_procevent_home "$home" "$home/procevent-claims"
mkdir -p "$home/state" "$home/data" "$home/lavish-state"
fakebin=$(fm_fakebin "$home")
# The build proves the board session is live before it arms its listener, so
# the stub reports the opened shape the real lavish-axi emits and lists the
# in-place page's session so the card's page link stays inside the board.
cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.80\n' ;;
  '')
    printf 'sessions[2]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$(cat "$FM_HOME/lavish-open")"
    [ ! -s "$FM_HOME/lavish-sessions" ] || cat "$FM_HOME/lavish-sessions"
    ;;
  poll)
    while [ "$SECONDS" -lt 120 ]; do sleep 1; done
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

page_dir="$home/.lavish/pages/understand-mr-872"
mkdir -p "$page_dir" "$home/state/pages/understand-mr-872"
printf '<p>Understand MR 872</p>\n' > "$page_dir/page.html"
jq -n '{id:"understand-mr-872",title:"Understand MR 872",opened:"2026-08-26T00:00:00Z",state:"live",replaces:[]}' \
  > "$home/state/pages/understand-mr-872/page.json"
printf '  %s,open,"http://127.0.0.1:4387/session/aaaa1111",0\n' "$(cd "$page_dir" && pwd -P)/page.html" \
  > "$home/lavish-sessions"
jq -n '{schema:"fm-bearings-board.v1", home:"browser-home", generated:"2026-08-26T00:00Z",
  prs_live:false, underway:[], landed:[], charted:[], charted_more:0, charted_warning_more:0,
  captains_call:[{key:"mr-872", type:"decision", title:"MR 872", repo:"r", about:"a",
    options:[], allow_freeform:true, pr_url:"https://example.test/o/r/merge_requests/872",
    links:[{url:"http://dev-1.tailf848b0.ts.net:4387/session/aaaa1111", label:"Understand page"}]}]}' \
  > "$home/payload.json"
build_board() {  # [build options] <payload>
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$@" >/dev/null
}
build_board "$home/payload.json" || fail "the board did not build"
[ -f "$home/.lavish/bearings-board.html" ] || fail "the board page was not built"

click_board() {  # <name> <steps>
  local profile="$TMP_ROOT/profile-$1" out
  mkdir -p "$profile"
  out=$(node "$CLICK" "$CHROME" "$home/.lavish/bearings-board.html" "$profile" "$2") \
    || fail "Chrome could not click through the board ($2): $out"
  printf '%s' "$out"
}

# From the home view, a shown page, and a full-screen page, a real click on the
# header lands on the header and brings the board home in place: no reload, no
# new tab, and no focus left on the header to hold off new board code.
out=$(click_board home "go,view,home,view")
printf '%s' "$out" | jq -e '
  .views[0].main and (.views[0].page | not)
    and .views[1].main and (.views[1].page | not) and .views[1].focus == ""
    and .reloads == 0 and .tabs == 1
' >/dev/null || fail "a header click on the board home did not stay home in place: $out"
pass "a real header click on the board home stays home in place"

out=$(click_board page "go,page,view,home,view")
printf '%s' "$out" | jq -e '
  .views[0].page and (.views[0].main | not)
    and (.views[1].page | not) and .views[1].main and .views[1].focus == ""
    and .reloads == 0 and .tabs == 1
' >/dev/null || fail "a real header click did not return from a shown page to the board home: $out"
pass "a real header click returns from a shown page to the board home"

out=$(click_board max "go,page,max,view,home,view")
printf '%s' "$out" | jq -e '
  .views[0].page and .views[0].max
    and (.views[1].page | not) and (.views[1].max | not) and .views[1].main and .views[1].focus == ""
    and .reloads == 0 and .tabs == 1
' >/dev/null || fail "a real header click did not return from a full-screen page to the board home: $out"
pass "a real header click returns from a full-screen page to the board home"

# After the captain answers a decision and sends it, the agent rebuilds the
# board without the answered card. When that leaves one decision, the header
# still brings up the priority list, from the cards and from a shown page,
# without reloading the board.
jq '.captains_call += [{key:"mr-873", type:"decision", title:"MR 873", question:"Merge MR 873?", repo:"r", about:"b",
  options:[], allow_freeform:true, free_text:true, pr_url:"https://example.test/o/r/merge_requests/873"}]' \
  "$home/payload.json" > "$home/payload-two.json"
{
  printf '#!/usr/bin/env bash\n'
  declare -p home fakebin BOARD
  declare -f build_board
  echo "build_board --no-reopen \"\$home/payload.json\""
} > "$TMP_ROOT/rebuild.sh"
chmod +x "$TMP_ROOT/rebuild.sh"
export BOARD_REBUILD="$TMP_ROOT/rebuild.sh"
for from in cards page; do
  build_board "$home/payload-two.json" || fail "the two-decision board did not build"
  if [ "$from" = cards ]; then steps="go,view,rebuild,view,home,view"; else steps="go,view,rebuild,page,view,home,view"; fi
  out=$(click_board "after-send-$from" "$steps")
  printf '%s' "$out" | jq -e --arg from "$from" '
    .views[0].deck and .views[0].cards == 2
      and .views[1].cards == 1
      and (if $from == "page" then .views[1].page else .views[1].deck end)
      and .views[2].main and (.views[2].page | not) and .views[2].list and (.views[2].deck | not)
      and .views[2].focus == "" and .reloads == 0 and .tabs == 1
  ' >/dev/null || fail "a real header click after a send left one decision did not show the priority list (from the $from): $out"
  pass "a real header click after a send left one decision shows the priority list (from the $from)"
done
