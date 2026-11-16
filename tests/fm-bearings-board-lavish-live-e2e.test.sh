#!/usr/bin/env bash
# tests/fm-bearings-board-lavish-live-e2e.test.sh - live drift guard proving
# the real lavish-axi still behaves the way bin/fm-bearings-board.sh's session
# liveness check is written against, and that a board rebuild serves new data
# to the open page without lavish-axi reloading it.
#
# Why this file exists: the build's "is this board actually live" verdict comes
# from what lavish-axi emits, which is a surface the vendor controls and changes
# without notice. The defect this guards was exactly that - opening a session
# the captain had ended from the browser EXITS 0 while refusing to reopen, so a
# build that trusted the exit status armed a poll against a dead session and the
# board read "not listening" with nobody watching it. A stubbed lavish-axi can
# only confirm the assumption already written into the stub, so the assumption
# itself needs a run against the real tool.
#
# The captain-ended state is reached through the same server route the browser's
# End session button calls, so no browser is needed and nothing here depends on
# a human. The artifact is a scratch page in a temporary directory, and the
# session it opens is ended again before the guard returns.
#
# The board refresh skips its passes while Lavish's saved session record says
# the board is ended, so the guard also proves `fm-bearings-board.sh ended`
# reads that record as ended after the captain ends it and live after a reopen.
#
# The no-reload half listens on the live-event socket the browser frame uses,
# with the ws module lavish-axi ships, and proves the listener works by
# rewriting the page itself as a control.
#
# Standard CI has no lavish-axi, so this reports a capability skip there. The
# portable counterpart in tests/fm-bearings-board.test.sh pins the build's logic
# in CI against a stub that reproduces these shapes. Run this guard after a
# lavish-axi upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_BEARINGS_LAVISH_LIVE lavish-axi jq curl

# A guard must never open a browser tab on the host running it: the board build's
# reopen and this guard's own session reads would each launch one otherwise.
export LAVISH_AXI_NO_OPEN=1

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=''
cleanup() {
  fm_test_reap_procevent_homes
  [ -z "$LAB" ] || {
    [ ! -f "$LAB/.lavish/bearings-board.html" ] \
      || lavish-axi end "$LAB/.lavish/bearings-board.html" >/dev/null 2>&1 || true
    rm -rf "$LAB"
  }
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown}"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings-lavish-live.XXXXXX") || fail "cannot create the guard lab"
LAB=$(cd -P -- "$LAB" && pwd -P)
mkdir -p "$LAB/state" "$LAB/data"
fm_test_track_procevent_home "$LAB" "$LAB/procevent-claims"

cat > "$LAB/payload.json" <<'JSON'
{
  "schema": "fm-bearings-board.v1",
  "home": "lavish-live-guard",
  "generated": "2026-01-01T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-live-guard-call",
      "type": "decision",
      "repo": "sample",
      "title": "Guard placeholder",
      "question": "Keep the guard placeholder?",
      "options": [{ "value": "yes", "label": "Yes" }],
      "no_link": true
    }
  ],
  "underway": [],
  "landed": [],
  "charted": []
}
JSON

run_board() {
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_DATA_OVERRIDE="$LAB/data" \
    FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" \
    "$ROOT/bin/fm-bearings-board.sh" "$@"
}

BOARD="$LAB/.lavish/bearings-board.html"
run_board build "$LAB/payload.json" >/dev/null 2>&1 || fail "the guard board did not build"
[ -f "$BOARD" ] || fail "the guard board was not published"

url=$(lavish-axi "$BOARD" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$url" in
  http://*/session/*) ;;
  *) fail "could not read the guard board session url: $url" ;;
esac
key=${url##*/}
base=${url%/session/*}

# End it exactly as the browser's End session button does.
curl -fsS -X POST "$base/api/$key/end" >/dev/null 2>&1 \
  || fail "could not end the guard board session as the captain"

# ASSUMPTION UNDER GUARD: this exits 0 while reporting the session is not live.
set +e
ended_out=$(lavish-axi "$BOARD" 2>&1)
ended_rc=$?
set -e
[ "$ended_rc" -eq 0 ] \
  || fail "lavish-axi ${VERSION:-version-unknown} now exits $ended_rc on a captain-ended session; the board build's liveness check must be revisited"
ended_status=$(printf '%s\n' "$ended_out" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"')
[ "$ended_status" != opened ] \
  || fail "lavish-axi ${VERSION:-version-unknown} silently reopened a captain-ended session; the board build's liveness check must be revisited"
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  && fail "lavish-axi ${VERSION:-version-unknown} still lists a captain-ended session as open; the board build's liveness check must be revisited"
pass "lavish-axi ${VERSION:-version-unknown} reports a captain-ended session without reopening it and without failing"

# The automatic refresh skips its passes on the strength of Lavish's saved
# session record, so that record must still read as ended here.
run_board ended \
  || fail "lavish-axi ${VERSION:-version-unknown} no longer records a captain-ended session as ended in its saved state; the board refresh's no-viewer skip must be revisited"
pass "lavish-axi ${VERSION:-version-unknown} saves a captain-ended session as ended, so the refresh can skip it"

# THE BEHAVIOR UNDER GUARD: the build must not accept that, and must recover.
out=$(run_board build "$LAB/payload.json" 2>&1) \
  || fail "the board build refused a recoverable captain-ended session: $out"
case "$out" in
  *"session: reopened"*) ;;
  *) fail "the board build did not reopen the captain-ended session: $out" ;;
esac
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  || fail "the board build reported success while the session was still not live"
pass "the board build reopens a captain-ended session against real lavish-axi instead of arming a dead one"
run_board ended \
  && fail "lavish-axi ${VERSION:-version-unknown} still records the reopened session as ended in its saved state; the board refresh would never refresh it"
pass "lavish-axi ${VERSION:-version-unknown} saves a reopened session as live, so the refresh resumes"

# THE SECOND BEHAVIOR UNDER GUARD: a rebuild must never reload the captain's open
# page. Lavish watches the artifact file and tells every open frame to reload
# when it changes, which cuts off whatever the captain is typing, so a rebuild
# rewrites only the data file beside the page and the page patches its cards in
# place. This listens on the same live-event socket the browser frame does.
command -v node >/dev/null 2>&1 || fail "node is required to listen for Lavish's live events"
ws_module=$(dirname "$(readlink -f "$(command -v lavish-axi)")")/../node_modules/ws
[ -d "$ws_module" ] || ws_module=$(dirname "$(readlink -f "$(command -v lavish-axi)")")/../lib/node_modules/lavish-axi/node_modules/ws
[ -d "$ws_module" ] \
  || fail "lavish-axi ${VERSION:-version-unknown} no longer ships the ws module this guard listens with"
url=$(lavish-axi "$BOARD" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
key=${url##*/}
base=${url%/session/*}
events="$LAB/live-events"
: > "$events"
cat > "$LAB/listen.cjs" <<'JS'
const [, , wsModule, base, key, out] = process.argv;
const WebSocket = require(wsModule);
const fs = require("node:fs");
const sock = new WebSocket(base.replace(/^http/, "ws") + "/events/" + encodeURIComponent(key), { headers: { Origin: base } });
sock.on("open", () => fs.appendFileSync(out, "open\n"));
sock.on("message", (m) => { try { fs.appendFileSync(out, JSON.parse(String(m)).type + "\n"); } catch {} });
sock.on("error", (e) => { fs.appendFileSync(out, "error " + e.message + "\n"); process.exit(1); });
setTimeout(() => process.exit(0), 60000);
JS
node "$LAB/listen.cjs" "$ws_module" "$base" "$key" "$events" &
listener=$!
for _ in $(seq 1 50); do grep -qx open "$events" && break; sleep 0.1; done
grep -qx open "$events" || { kill "$listener" 2>/dev/null; fail "could not listen for the guard board's live events: $(cat "$events")"; }

jq '.captains_call[0].title = "Guard placeholder reworded"' "$LAB/payload.json" > "$LAB/next.json"
out=$(run_board build --no-reopen "$LAB/next.json" 2>&1) \
  || { kill "$listener" 2>/dev/null; fail "the guard board rebuild failed: $out"; }
sleep 2
if grep -qx reload "$events"; then
  kill "$listener" 2>/dev/null
  fail "a board rebuild made lavish-axi ${VERSION:-version-unknown} reload the open page"
fi
curl -fsS "$base/artifact/$key/bearings-board.data.js" | grep -qF 'Guard placeholder reworded' \
  || { kill "$listener" 2>/dev/null; fail "lavish-axi ${VERSION:-version-unknown} does not serve the rebuilt board data beside the page"; }

# The control: rewriting the page itself does reload it, so the silence above
# was the listener hearing nothing rather than hearing nothing at all.
cp "$BOARD" "$LAB/page.copy" && cat "$LAB/page.copy" > "$BOARD"
for _ in $(seq 1 50); do grep -qx reload "$events" && break; sleep 0.1; done
kill "$listener" 2>/dev/null
grep -qx reload "$events" \
  || fail "lavish-axi ${VERSION:-version-unknown} sent no reload even when the page changed, so the no-reload check proved nothing"
pass "a board rebuild serves new data to the open page without lavish-axi ${VERSION:-version-unknown} reloading it"

# THE STABLE LINK UNDER GUARD: Lavish names the session from the board's real
# path, so the link the captain bookmarked survives the captain ending the
# session, and `url` brings that same link back live without a rebuild.
curl -fsS -X POST "$base/api/$key/end" >/dev/null 2>&1 \
  || fail "could not end the guard board session as the captain a second time"
url_err="$LAB/url.err"
again=$(run_board url 2>"$url_err") \
  || fail "the board url command refused a recoverable captain-ended session: $(cat "$url_err")"
[ "$again" = "$url" ] \
  || fail "lavish-axi ${VERSION:-version-unknown} gave the reopened board a different link ($again, was $url); the stable board link must be revisited"
grep -qx 'reopened: yes' "$url_err" || fail "the board url command did not report reopening the ended session"
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  || fail "the board url command printed a link while the session was still not live"
pass "the board url command restores the same stable link against real lavish-axi after the captain ends the session"
