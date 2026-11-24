#!/usr/bin/env bash
# tests/fm-bearings-board-page-drafts-live-e2e.test.sh - live guard that the
# captain's unsent input in a page shown inside the bearings board survives
# everything that can redraw or reload that page.
#
# Why this file exists: the captain lost a page full of typed answers. Any
# change to the board file makes Lavish reload the board and every page frame
# in it, and a page's own script may draw its form again when its worker moves
# it on; both start the form empty. The DOM shims cannot see either, because
# the reload is Lavish's and the redraw is the page's.
#
# It builds a board with one in-place page in a scratch home with a stubbed
# lavish-axi, then shows it on a private Lavish server of its own: its own
# port (never 4387), its own LAVISH_AXI_STATE_DIR, and no browser tab opened
# on the host. Headless Chrome opens the session, types an answer and picks an
# option in the page, and then the page redraws its form, the board file is
# rewritten so Lavish reloads it, and the browser tab is reloaded. After each,
# the answer and the pick must still be on screen. Then the page queues the
# answer, the board must say it is queued but not sent and offer Send to
# agent, and pressing it must deliver the answer to the server. The server is stopped
# again before the guard returns. It spends no model tokens, so it runs
# wherever lavish-axi, node and a Chrome are installed and reports a
# capability skip elsewhere.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The board build reads the live state of each PR/MR a card links; keep it
# off the network.
export FM_BEARINGS_BOARD_PR_CHECK=0

CHROME=${FM_TEST_CHROME:-}
if [ -z "$CHROME" ]; then
  for c in google-chrome google-chrome-stable chromium chromium-browser; do
    if command -v "$c" >/dev/null 2>&1; then CHROME=$c; break; fi
  done
fi
fm_live_gate default-on FM_BEARINGS_PAGE_DRAFTS_LIVE lavish-axi node jq curl "${CHROME:-google-chrome}"

BOARD="$ROOT/bin/fm-bearings-board.sh"
DRIVE="$ROOT/tests/assets/board-page-drafts.mjs"
RELAY="$ROOT/.agents/skills/bearings/assets/lavish-relay.js"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-page-drafts)

pass() { printf 'ok - %s\n' "$1"; }

# A private Lavish server: a free port other than the shared 4387, a state
# directory of its own, and never a browser tab on the host.
LAVISH_REAL=$(command -v lavish-axi)
lavish_port=''
for _ in $(seq 1 50); do
  p=$((4600 + RANDOM % 400))
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then lavish_port=$p; break; fi
done
[ -n "$lavish_port" ] && [ "$lavish_port" != 4387 ] || fail "no free private port for the guard's Lavish server"
lavish_state="$TMP_ROOT/lavish-private"
mkdir -p "$lavish_state"
private_lavish() {
  LAVISH_AXI_PORT=$lavish_port LAVISH_AXI_STATE_DIR=$lavish_state LAVISH_AXI_NO_OPEN=1 \
    LAVISH_AXI_HOST=127.0.0.1 "$LAVISH_REAL" "$@"
}

home="$TMP_ROOT/home"
board_html="$home/.lavish/bearings-board.html"
stop_private_lavish() {
  [ ! -f "$board_html" ] || private_lavish end "$board_html" >/dev/null 2>&1 || true
  private_lavish stop >/dev/null 2>&1 || true
}
trap 'stop_private_lavish; fm_test_cleanup' EXIT
trap 'stop_private_lavish; fm_test_cleanup; exit 130' INT

fm_test_track_procevent_home "$home" "$home/procevent-claims"
mkdir -p "$home/state" "$home/data" "$home/lavish-state"
fakebin=$(fm_fakebin "$home")
# The build talks only to this stub, so it never reaches any Lavish server;
# the private server above shows the built board.
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

# The page, as bin/fm-board-page.sh lays one out: the relay beside it, loaded
# before the page's own script. Like a grill page, it reads its data file
# every half second, and it draws its whole form again whenever the data moves
# on. Its submit handler queues the answer only once the captain touched it.
page_dir="$home/.lavish/pages/drafts-page"
mkdir -p "$page_dir" "$home/state/pages/drafts-page"
cp "$RELAY" "$page_dir/lavish-relay.js"
printf 'window.PAGE_DATA = { version: 1, question: "Round 1: which way?" };\n' > "$page_dir/page.data.js"
cat > "$page_dir/page.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Drafts page</title></head>
<body>
<div id="rounds"></div>
<script src="lavish-relay.js"></script>
<script>
(function () {
  window.pageLoad = Math.random().toString(36).slice(2);
  window.pageRenders = 0;
  window.pageVersion = 0;
  function render(d) {
    var host = document.getElementById("rounds");
    host.innerHTML = '<form data-lavish-question="grill-round"><p></p>' +
      '<label><input type="radio" name="pick" value="left"> Left</label>' +
      '<label><input type="radio" name="pick" value="right"> Right</label>' +
      '<textarea name="answer" rows="4" cols="60"></textarea>' +
      '<button type="submit">Queue answer</button></form>';
    var form = host.querySelector("form");
    form.querySelector("p").textContent = d.question;
    var touched = false;
    form.addEventListener("input", function () { touched = true; });
    form.addEventListener("change", function () { touched = true; });
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      if (!touched || !window.lavish) return;
      var pick = form.querySelector("input[type=radio]:checked");
      window.lavish.queuePrompt("Answer: " + form.answer.value, {
        tag: "answer", text: form.answer.value, queueKey: "grill-round", element: form,
        data: { pick: pick ? pick.value : "", answer: form.answer.value }
      });
    });
    window.pageRenders++;
    window.pageVersion = d.version;
  }
  function poll() {
    var s = document.createElement("script");
    s.onload = s.onerror = function () {
      s.parentNode.removeChild(s);
      var d = window.PAGE_DATA;
      if (d && d.version !== window.pageVersion) render(d);
    };
    s.src = "page.data.js?r=" + Date.now();
    document.head.appendChild(s);
  }
  poll();
  setInterval(poll, 500);
})();
</script>
</body></html>
HTML
jq -n '{id:"drafts-page",title:"Drafts page",opened:"2026-11-16T00:00:00Z",state:"live",replaces:[]}' \
  > "$home/state/pages/drafts-page/page.json"
jq -n '{schema:"fm-bearings-board.v1", home:"drafts-home", generated:"2026-11-16T00:00Z",
  prs_live:false, underway:[], landed:[], charted:[], charted_more:0, charted_warning_more:0,
  captains_call:[{key:"drafts-call", type:"decision", title:"Drafts call", repo:"r", about:"a",
    question:"Keep the guard placeholder?", options:[{value:"yes", label:"Yes"}], no_link:true}]}' \
  > "$home/payload.json"
PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
  "$BOARD" build "$home/payload.json" >/dev/null || fail "the board did not build"
[ -f "$board_html" ] || fail "the board page was not built"

url=$(private_lavish "$board_html" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$url" in
  "http://127.0.0.1:$lavish_port/session/"*) ;;
  *) fail "the private Lavish server did not open the board on port $lavish_port: $url" ;;
esac

profile="$TMP_ROOT/profile"
mkdir -p "$profile"
out=$(node "$DRIVE" "$CHROME" "$url" "$profile" "$board_html" "$page_dir" \
  "type,view,rerender,view,reload,view,refresh,view,queue,bar,send,bar") \
  || fail "Chrome could not drive the page inside the board: $out"

# The first view proves the typing landed; each later view must still hold
# it, and must show that the redraw or reload really happened.
printf '%s' "$out" | jq -e '
  .views[0].answer == .answer and .views[0].pick == "right"
' >/dev/null || fail "the guard could not type into the page: $out"

printf '%s' "$out" | jq -e '
  .views[1].load == .views[0].load and .views[1].renders > .views[0].renders
    and .views[1].version == 2
' >/dev/null || fail "the page did not draw its form again when its data moved on: $out"
printf '%s' "$out" | jq -e '.views[1].answer == .answer and .views[1].pick == "right"' >/dev/null \
  || fail "a page drawing its form again wiped the captain's unsent answer: $out"
pass "a page drawing its form again keeps the captain's unsent answer"

printf '%s' "$out" | jq -e '.views[2].load != .views[1].load' >/dev/null \
  || fail "rewriting the board file did not make Lavish reload the page: $out"
printf '%s' "$out" | jq -e '.views[2].answer == .answer and .views[2].pick == "right"' >/dev/null \
  || fail "Lavish reloading the board wiped the captain's unsent page answer: $out"
pass "Lavish reloading the board keeps the captain's unsent page answer"

printf '%s' "$out" | jq -e '.views[3].load != .views[2].load' >/dev/null \
  || fail "reloading the browser tab did not reload the page: $out"
printf '%s' "$out" | jq -e '.views[3].answer == .answer and .views[3].pick == "right"' >/dev/null \
  || fail "reloading the browser tab wiped the captain's unsent page answer: $out"
pass "reloading the browser tab keeps the captain's unsent page answer"

printf '%s' "$out" | jq -e '.tabs == 1' >/dev/null || fail "the board or page opened another tab: $out"
pass "nothing opened another tab"

# A page answer queued in Lavish is not with the agent until Send, and the
# Send control Lavish draws is outside the page, so the board must say so
# under the page bar and offer its own Send.
printf '%s' "$out" | jq -e '
  .bars[0].visible and (.bars[0].text | test("queued but not sent")) and .bars[0].send
' >/dev/null || fail "a queued page answer gave the captain no notice or Send under the page bar: $out"
pass "a queued page answer shows a notice with Send to agent under the page bar"

printf '%s' "$out" | jq -e '(.bars[1].text | test("queued but not sent") | not) and (.bars[1].send | not)' >/dev/null \
  || fail "the notice still said the page answer was unsent after Send: $out"
sent=$(timeout 60 env LAVISH_AXI_PORT="$lavish_port" LAVISH_AXI_STATE_DIR="$lavish_state" LAVISH_AXI_NO_OPEN=1 \
  LAVISH_AXI_HOST=127.0.0.1 "$LAVISH_REAL" poll "$board_html" --timeout-ms 30000 2>&1) || true
case "$sent" in
  *"half-written answer the captain has not sent"*fm-board-page.v1*|*fm-board-page.v1*"half-written answer the captain has not sent"*) ;;
  *) fail "Send to agent under the page bar did not deliver the page answer: $sent" ;;
esac
pass "Send to agent under the page bar delivers the queued page answer"
