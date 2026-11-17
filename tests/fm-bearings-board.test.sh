#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-board.sh: fail-closed payload validation,
# slot-injection round-trip through the built page, bind-before-arm, and
# idempotent re-arm of the stable board source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A lavish-axi stub that reproduces the shapes verified against the real
# lavish-axi 0.1.61, because the build's liveness verdict is read from what the
# vendor emits. The load-bearing shape is the refusal: opening a session the
# captain ended from the browser EXITS 0 while reporting `status: user-ended`,
# and that session is absent from the server's listing. `--reopen` restores it.
# Markers under lavish-state drive the fixture: `user-ended` makes the next
# plain open refuse, and `refuse-reopen` makes even --reopen leave it dead.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # Registered with tests/lib.sh, not with a shell array: make_home is called
  # inside a command substitution, so an array append here never reaches the
  # caller and every listener this suite started used to survive the run.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
state=${LAVISH_FAKE_STATE:?}
emit() {  # <canonical-file> <status>
  printf 'session:\n'
  printf '  file: %s\n' "$1"
  printf '  url: "http://127.0.0.1:4387/session/0123456789abcdef"\n'
  printf '  status: %s\n' "$2"
}
case "${1-}" in
  --version) printf '0.1.61\n'; exit 0 ;;
  poll)
    # A real blocking listener: it returns only when the trigger appears, so a
    # live owner in these tests is a live process rather than a timing artifact.
    # Both waits are bounded, so a listener that escapes its test cannot keep
    # spawning processes for as long as the host stays up.
    limit=${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}
    while [ ! -e "$state/poll-trigger" ]; do
      [ "$SECONDS" -lt "$limit" ] || exit 75
      sleep 0.05
    done
    printf 'session:\n  status: ended\n'
    if [ -e "$state/hold-after-terminal" ]; then
      : > "$state/terminal-emitted"
      while [ -e "$state/hold-after-terminal" ]; do
        [ "$SECONDS" -lt "$limit" ] || exit 75
        sleep 0.05
      done
    fi
    exit 0
    ;;
  '')
    if [ -e "$state/end-before-next-list" ]; then
      : > "$state/open"
      rm -f "$state/end-before-next-list"
    fi
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    if [ -s "$state/open" ]; then
      while IFS= read -r listed; do
        [ -n "$listed" ] || continue
        printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$listed"
      done < "$state/open"
    fi
    exit 0
    ;;
  end) : > "$state/open"; printf 'session:\n  status: ended\n'; exit 0 ;;
esac
file=$1
shift
printf '%s\n' "$*" >> "$state/open-calls"
# Record any open that would have been allowed to launch a browser.
[ "${LAVISH_AXI_NO_OPEN-}" = 1 ] || : > "$state/browser-allowed"
reopen=0
for arg in "$@"; do [ "$arg" != --reopen ] || reopen=1; done
real=$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")
if [ -e "$state/user-ended" ] && [ "$reopen" = 0 ]; then
  emit "$real" user-ended
  exit 0
fi
if [ -e "$state/refuse-reopen" ]; then
  emit "$real" user-ended
  exit 0
fi
rm -f -- "$state/user-ended"
printf '%s\n' "$real" > "$state/open"
jq -n --arg file "$real" \
  '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
  > "$state/state.json"
emit "$real" opened
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

end_session_as_captain() { : > "$1/lavish-state/user-ended"; : > "$1/lavish-state/open"; }

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_FAKE_STATE="$home/lavish-state" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    FM_BEARINGS_BOARD_REFRESH="${FM_BEARINGS_BOARD_REFRESH:-true}" \
    "$BOARD" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_page() {  # <home> <fm-board-page args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_FAKE_STATE="$home/lavish-state" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    FM_BOARD_PAGE_REFRESH=true "$ROOT/bin/fm-board-page.sh" "$@"
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# A realistic payload: a cross-origin full-identity decision key past the old
# 64-char cap, a merge card, a dispatchable charted row, and a string that
# tries to terminate the data block early.
write_valid_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "test-home",
  "generated": "2026-08-19T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice",
      "type": "decision",
      "repo": "sample",
      "title": "Perishable-first admission",
      "about": "A payload string that tries to break out: </script><b>x</b>",
      "decide": "Adopt it?",
      "options": [
        { "value": "yes", "label": "Adopt", "hint": "recommended" },
        { "value": "no", "label": "Keep current" }
      ],
      "allow_freeform": true,
      "links": [{ "url": "https://github.com/example/sample/pull/2", "label": "PR 2" }]
    },
    {
      "key": "merge.sample-task",
      "type": "merge",
      "repo": "sample",
      "title": "Merge: sample change",
      "detail": "validation green",
      "task_id": "sample-task",
      "pr_url": "https://github.com/example/sample/pull/1",
      "checks": "green",
      "risk": "low",
      "options": [
        { "value": "merge", "label": "Merge now" },
        { "value": "hold", "label": "Not yet" }
      ],
      "allow_freeform": true
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [
    { "id": "sample-queued", "repo": "sample", "title": "Queued work", "reason": "", "dispatchable": true }
  ],
  "charted_more": 0
}
EOF
}

# Extract the payload back out of the data file the build writes beside a
# board page.
extract_payload() {  # <board-path>
  local js
  js=$(cat "${1%.html}.data.js") || return 1
  js=${js#'window.FM_BEARINGS_BOARD_DATA = '}
  printf '%s\n' "${js%;}"
}

test_path_is_stable_and_home_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_board "$home" path)" = "$home/.lavish/bearings-board.html" ] \
    || fail "the board path is not the stable home-scoped location"
  pass "path prints the stable home-scoped board location"
}

test_build_refuses_malformed_payloads_before_touching_the_board() {
  local home data board rc out
  home=$(make_home refusal)
  board="$home/.lavish/bearings-board.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-bearings-board.v2"}\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-bearings-board.v1" "the schema refusal did not name the contract: $out"

  write_valid_payload "$data"
  jq '.captains_call[0].key = (reduce range(129) as $i (""; . + "x"))' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a 129-char captains_call key was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].dispatchable)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a charted row without a dispatchable boolean was accepted"

  write_valid_payload "$data"
  jq '.charted[0].kind = "alarm"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown charted kind was accepted"

  write_valid_payload "$data"
  jq '.charted[0].kind = "warning"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a dispatchable warning row was accepted"

  write_valid_payload "$data"
  jq '.charted_warning_more = -1' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a negative omitted-warning count was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].subject = {"artifact":"quota-axi","version":"0.1"}' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an invalid structured version subject was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].type = "verdict"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown captains_call type was accepted"

  write_valid_payload "$data"
  jq 'del(.captains_call[0].options[0].value)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option without an answer value was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options[0].label = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option with an empty label was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].repo)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a fleet row without an explicit repo marker was accepted"

  write_valid_payload "$data"
  jq '.underway = [{"id":"sample-task","repo":"sample","state":"working",
    "kind":"ship","doing":"implementing"}]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an underway row without an explicit name marker was accepted"

  for invalid_filed in "last Tuesday" "2026-13-01" "2026-08-14T99:30:00Z" "2026-02-29"; do
    write_valid_payload "$data"
    jq --arg filed "$invalid_filed" '.charted[0].filed = $filed' "$data" > "$data.tmp" \
      && mv "$data.tmp" "$data"
    set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
    [ "$rc" -ne 0 ] || fail "an invalid filed date was accepted: $invalid_filed"
  done

  write_valid_payload "$data"
  jq '.captains_call[0].allow_freeform = "yes"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-boolean renderer field was accepted"

  write_valid_payload "$data"
  jq '.captains_call[1].options = [] | .captains_call[1].allow_freeform = false' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unanswerable non-decision captains_call item was accepted"

  write_valid_payload "$data"
  jq '.captains_call[1].pr_url = "javascript:alert(1)"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Captain’s Call PR URL was accepted"

  write_valid_payload "$data"
  jq '.landed = [{
    "id": "sample-landed",
    "repo": "sample",
    "what": "Landed work",
    "owner": "firstmate",
    "pr_url": "data:text/html,unsafe"
  }]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Landed PR URL was accepted"

  assert_absent "$board" "a refused payload still produced a board"
  pass "build refuses malformed payloads before touching the board"
}

test_build_injects_binds_then_arms() {
  local home data board out sid
  home=$(make_home build)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build "$data") || fail "a valid payload did not build"
  assert_contains "$out" "board: $board" "build did not report the board path: $out"
  assert_contains "$out" "served: $board" "build did not establish the Lavish session: $out"
  assert_contains "$out" "bound: " "build did not report the answer binding: $out"
  assert_contains "$out" "armed: " "the first build did not arm the board source: $out"
  assert_present "$board" "build reported success without a board"

  # Round-trip: apart from the reconcile choice the build adds to every
  # decision card, the empty list of pages shown in place, the stamp of the
  # board code that built it, and the stamp of the data itself (which the
  # stamp file beside the board names too), the payload extracted from the
  # built page is the same JSON
  # document, and the escaped </script> string can no longer terminate the
  # data block.
  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the built board does not carry parseable payload JSON"
  jq -S '.captains_call = [.captains_call[]
      | .options = [.options[] | select(.value != "reconcile")]]
      | if .pages == [] then del(.pages) else . end
      | if (.board_code | type) == "string" and .board_code != "" then del(.board_code) else . end
      | if (.data_stamp | type) == "string" and .data_stamp != "" then del(.data_stamp) else . end' \
    "$home/extracted.json" > "$home/stripped.json"
  [ "$(cat "$home/.lavish/bearings-board.stamp.js" 2>/dev/null)" = \
    "window.FM_BEARINGS_BOARD_STAMP = \"$(jq -r .data_stamp "$home/extracted.json")\";" ] \
    || fail "the stamp file does not name the stamp of the data it was published with"
  jq -S '.captains_call = [.captains_call[]
      | .options = [.options[] | select(.value != "reconcile")]]' \
    "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/stripped.json" >/dev/null \
    || fail "the injected payload does not round-trip to the input document"
  grep -qF '</script><b>' "$board" "${board%.html}.data.js" \
    && fail "a payload string embedded a live closing script tag in the page"

  sid=$(run_lavish_source_id "$home" "$board")
  assert_contains "$out" "bound: $sid" "the binding does not name the board source: $out"
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the board source is not bound any-origin"
  run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "the board source is not registered after build"
  pass "build injects the payload, binds any-origin, then arms the source"
}

test_registration_cannot_consume_before_any_origin_binding() {
  local home data origin key hold board sid show
  home=$(make_home order-proof)
  data="$home/payload.json"
  origin=order-proof-review
  key=captain-choice
  hold="$origin-decision-$key"
  board="$home/.lavish/bearings-board.html"

  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/$origin.meta" "project=$home/projects/sample" "kind=scout"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the order proof" --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not create the order-proof captain hold"

  write_valid_payload "$data"
  jq --arg hold "$hold" '.captains_call[0].key = $hold' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"

  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ -z "${1:-}" ]; then
  printf 'sessions[1]{file,status,url,pending_prompts}:\n'
  [ ! -s "$FM_HOME/order-open" ] \
    || printf '  %s,open,"http://127.0.0.1/session/order",0\n' "$(cat "$FM_HOME/order-open")"
  exit 0
fi
if [ "${1:-}" != poll ]; then
  real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
  printf '%s\n' "$real" > "$FM_HOME/order-open"
  mkdir -p "$LAVISH_AXI_STATE_DIR"
  jq -n --arg file "$real" \
    '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:14387/session/0123456789abcdef"}}}' \
    > "$LAVISH_AXI_STATE_DIR/state.json"
  printf 'session:\n  status: opened\n'
  exit 0
fi
cat <<EOF
session:
  status: feedback
  session_ended: false
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Order proof: yes\\n\\nContext data:\\n{\\n  \\"schema\\": \\"fm-bearings-answer.v1\\",\\n  \\"question\\": \\"$ORDER_PROOF_HOLD\\",\\n  \\"selection\\": \\"yes\\",\\n  \\"note\\": \\"\\"\\n}","form",choice,"Order proof: yes"
EOF
SH
  chmod +x "$home/fakebin/lavish-axi"

  ORDER_PROOF_HOLD="$hold" run_board "$home" build "$data" >/dev/null \
    || fail "the order-proof board build failed"

  # Arm starts the listener, which captures the answer and closes the hold on
  # its own schedule after build returns.
  for _ in $(seq 1 100); do
    show=$(cd "$home" && tasks-axi show "$hold" --full) \
      || fail "the order-proof captain hold disappeared"
    case "$show" in *"state: done"*) break ;; esac
    sleep 0.1
  done
  assert_contains "$show" "state: done" \
    "registration consumed its answer before the any-origin binding existed"
  assert_contains "$show" "Resolution mode: answered" \
    "the answer was not closed through the real keyed-answer intake"
  sid=$(run_lavish_source_id "$home" "$board")
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the order-proof source did not retain its any-origin binding"
  pass "registration can consume answers only after any-origin binding exists"
}

test_build_does_not_bind_or_arm_when_session_start_fails() {
  local home data rc sid
  home=$(make_home serve-failure)
  data="$home/payload.json"
  write_valid_payload "$data"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e
  run_board "$home" build "$data" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build continued after Lavish session establishment failed"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board before its Lavish session existed"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board before its Lavish session existed"
  pass "build establishes the Lavish session before binding and arming"
}

run_lavish_source_id() {  # <home> <artifact>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$2"
}

test_rebuild_is_idempotent_and_does_not_double_arm() {
  local home data board out records
  home=$(make_home rearm)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"

  jq '.generated = "2026-08-19T01:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  # Lavish reloads the open page whenever the page file changes, so a rebuild
  # must leave that file exactly as it was: same file, same bytes.
  page_before="$(stat -c %i "$board" 2>/dev/null || stat -f %i "$board") $(cksum < "$board")"
  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: " "the rebuild re-armed an already registered source: $out"
  extract_payload "$board" | jq -e '.generated == "2026-08-19T01:00Z"' >/dev/null \
    || fail "the rebuild did not refresh the board payload in place"
  [ "$(stat -c %i "$board" 2>/dev/null || stat -f %i "$board") $(cksum < "$board")" = "$page_before" ] \
    || fail "the rebuild rewrote the page file, which reloads the captain's open page"
  records=$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "rebuilding left $records source registrations instead of 1"
  pass "rebuild refreshes the board in place without double-arming"
}

# The page loads its data file by name while rebuilds replace it, so every
# read during a rebuild must see a whole data file, never a missing or half
# written one, and a rebuild must replace the file rather than write into it.
test_rebuild_replaces_the_data_file_whole() {
  local home data board board_data stop bad reader inode_before i leftovers
  home=$(make_home atomic)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  board_data="$home/.lavish/bearings-board.data.js"
  write_valid_payload "$data"
  # Pad the payload so a write in place would be visible to a reader mid-way.
  jq '.charted += [range(0; 400) | {id: "pad-\(.)", repo: "sample", title: ("padding row \(.) " * 4), reason: "", dispatchable: false}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  assert_present "$board_data" "the build did not write the data file"

  stop="$home/stop-reader"
  bad="$home/bad-reads"
  : > "$bad"
  (
    local body
    while [ ! -e "$stop" ]; do
      if ! body=$(cat -- "$board_data" 2>/dev/null); then
        echo "missing" >> "$bad"
        continue
      fi
      case "$body" in
        'window.FM_BEARINGS_BOARD_DATA = {'*'};') ;;
        *) echo "partial:${#body}" >> "$bad" ;;
      esac
    done
  ) &
  reader=$!
  for i in 1 2 3 4 5 6; do
    inode_before=$(stat -c %i "$board_data" 2>/dev/null || stat -f %i "$board_data")
    jq --arg g "2026-08-19T0$i:00Z" '.generated = $g' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
    run_board "$home" build "$data" >/dev/null || { : > "$stop"; wait "$reader"; fail "rebuild $i failed"; }
    [ "$(stat -c %i "$board_data" 2>/dev/null || stat -f %i "$board_data")" != "$inode_before" ] \
      || { : > "$stop"; wait "$reader"; fail "rebuild $i wrote into the data file instead of replacing it whole"; }
  done
  : > "$stop"
  wait "$reader"
  [ ! -s "$bad" ] || fail "a reader saw the data file missing or half written during a rebuild: $(sort "$bad" | uniq -c | tr '\n' ' ')"
  extract_payload "$board" | jq -e '.generated == "2026-08-19T06:00Z"' >/dev/null \
    || fail "the last rebuild's payload is not the one the data file carries"
  leftovers=$(find "$home/.lavish" -name '.board*' | wc -l | tr -d ' ')
  [ "$leftovers" = 0 ] || fail "rebuilds left $leftovers staging files beside the board"
  pass "a rebuild replaces the data file whole, so a reader never sees it missing or half written"
}

test_build_refuses_a_template_that_does_not_load_the_data() {
  local home data rc out
  home=$(make_home badslot)
  data="$home/payload.json"
  write_valid_payload "$data"
  printf '<html><body>no data file</body></html>\n' > "$home/broken-template.html"
  set +e
  out=$(FM_BEARINGS_BOARD_TEMPLATE="$home/broken-template.html" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a template that never loads the board data was accepted"
  assert_contains "$out" "board data file" "the template refusal did not say why: $out"
  assert_absent "$home/.lavish/bearings-board.html" "a refused template still produced a board"
  assert_absent "$home/.lavish/bearings-board.data.js" "a refused template still produced board data"
  pass "build refuses a template that does not load the board data file exactly once"
}

# A home that carries its own Firstmate code has its board installed by that
# code alone. A build from another code root, such as a secondmate on an older
# release, must not install its own template there: Lavish reloads the open
# board whenever the page file changes, and an older template can lack
# features the captain is using.
give_home_own_code() {  # <home> [<marker>]
  cp -R "$ROOT/bin" "$1/bin"
  mkdir -p "$1/.agents/skills"
  cp -R "$ROOT/.agents/skills/bearings" "$1/.agents/skills/bearings"
  [ -n "${2-}" ] || return 0
  awk -v mark="$2" '{ print } $0 == "<body>" { print "<!-- " mark " -->" }' \
    "$ROOT/.agents/skills/bearings/assets/board-template.html" > "$1/template.tmp"
  mv "$1/template.tmp" "$1/.agents/skills/bearings/assets/board-template.html"
}

test_build_refuses_another_code_roots_template_in_a_home_with_its_own_code() {
  local home data board rc out
  home=$(make_home stale-root)
  give_home_own_code "$home" "this home's own board code"
  data="$home/payload.json"
  write_valid_payload "$data"
  board="$home/.lavish/bearings-board.html"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_FAKE_STATE="$home/lavish-state" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    FM_BEARINGS_BOARD_REFRESH=true "$home/bin/fm-bearings-board.sh" build "$data" >/dev/null \
    || fail "the home's own code did not build its board"
  grep -q "this home's own board code" "$board" || fail "the fixture board does not carry its home's own markup"
  cp "$board" "$home/page-before.html"
  cp "${board%.html}.app.js" "$home/app-before.js"
  cp "${board%.html}.data.js" "$home/data-before.js"
  jq '.generated = "2026-08-19T07:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a build from another code root installed its template in a home with its own code"
  assert_contains "$out" "$ROOT" "the refusal did not name the building code root: $out"
  assert_contains "$out" "$home" "the refusal did not name the home: $out"
  cmp -s "$home/page-before.html" "$board" || fail "a refused build rewrote the board page, which reloads it"
  cmp -s "$home/app-before.js" "${board%.html}.app.js" || fail "a refused build replaced the board code"
  cmp -s "$home/data-before.js" "${board%.html}.data.js" || fail "a refused build replaced the board data"
  grep -F "$ROOT" "$home/state/.board-refresh.log" 2>/dev/null | grep -qF "$home" \
    || fail "the refusal was not logged naming both roots: $(cat "$home/state/.board-refresh.log" 2>/dev/null)"
  [ -z "$(find "$home/.lavish" -name '.board*')" ] || fail "a refused build left staging files beside the board"
  pass "a build from another code root is refused in a home with its own different template, and the page is untouched"
}

test_build_from_another_code_root_installs_a_matching_template() {
  local home data out
  home=$(make_home same-template)
  give_home_own_code "$home"
  data="$home/payload.json"
  write_valid_payload "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "a build whose template matches the home's own was refused: $out"
  cmp -s <(sed '/^<script src="bearings-board.app.js"><\/script>$/d' "$home/.lavish/bearings-board.html") \
    <(awk '$0 == "<script>" { skip = 1; next } $0 == "</script>" { skip = 0; next } !skip' \
      "$home/.agents/skills/bearings/assets/board-template.html") \
    || fail "the matching template was not installed as the board page"
  pass "a build from another code root installs when its template matches the home's own"
}

test_build_installs_into_a_home_without_its_own_code() {
  local home data out
  home=$(make_home data-only)
  mkdir -p "$home/.agents/skills/bearings/assets"
  printf '<html>an unrelated template</html>\n' > "$home/.agents/skills/bearings/assets/board-template.html"
  data="$home/payload.json"
  write_valid_payload "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "a home with no code of its own refused the build: $out"
  [ -f "$home/.lavish/bearings-board.html" ] || fail "a home with no code of its own got no board"
  pass "a home with no code of its own takes the build from the code root that serves it"
}

test_charted_kind_is_optional_and_accepts_both_values() {
  local home data
  home=$(make_home chartedkind)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.charted = [
        {"id":"a","repo":"sample","title":"Queued","reason":"","dispatchable":true},
        {"id":"b","repo":"sample","title":"Queued too","reason":"gated","dispatchable":true,"kind":"queued"},
        {"id":"c","repo":"sample","title":"Integrity notice","reason":"main inventory","dispatchable":false,"kind":"warning"}
      ] | .charted_warning_more = 2' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null \
    || fail "an omitted, queued, and warning charted kind was refused"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.charted[] | .kind // "queued"]) == ["queued", "queued", "warning"]
      and .charted_warning_more == 2
  ' >/dev/null || fail "the built board did not carry the charted kinds and omitted-warning count it was given"
  pass "charted kind is optional and accepts queued and warning"
}

test_build_lists_live_pages_and_refuses_payload_pages() {
  local home data rc out
  home=$(make_home pages)
  data="$home/payload.json"
  write_valid_payload "$data"
  mkdir -p "$home/state/pages/p1" "$home/state/pages/p2" "$home/state/pages/p3" "$home/state/pages/bad"
  printf '%s\n' '{"id":"p2","title":"Second","opened":"2026-01-02T00:00:00Z","state":"live"}' > "$home/state/pages/p2/page.json"
  printf '%s\n' '{"id":"p1","title":"First","opened":"2026-01-01T00:00:00Z","state":"live"}' > "$home/state/pages/p1/page.json"
  printf '%s\n' '{"id":"p3","title":"Gone","opened":"2026-01-01T00:00:00Z","state":"ended"}' > "$home/state/pages/p3/page.json"
  printf '%s\n' '{"id":"../x","title":"Bad","opened":"2026-01-01T00:00:00Z","state":"live"}' > "$home/state/pages/bad/page.json"
  run_board "$home" build "$data" >/dev/null || fail "a board with registered pages did not build"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    .pages == [
      {"id":"p1","title":"First","href":"pages/p1/page.html"},
      {"id":"p2","title":"Second","href":"pages/p2/page.html"}
    ]' >/dev/null || fail "the board data did not list exactly the live pages in opening order"

  jq '.pages = [{"id":"x","title":"X","href":"https://example.com"}]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a payload that authors pages was accepted: $out"
  pass "build lists only live registered pages and refuses a payload that authors them"
}


# --- part 1: never arm a poll on an ended session ---------------------------

test_build_reopens_a_session_the_captain_ended() {
  local home data board out sid claim old_pid old_token new_pid new_token
  home=$(make_home ended-session)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  sid=$(run_lavish_source_id "$home" "$board")
  claim="$home/procevent-claims/$sid.claim"
  old_pid=$(sed -n '2p' "$claim")
  old_token=$(sed -n '3p' "$claim")

  # The reported case: the captain ends the board from the browser, so opening
  # it again keeps the same session id, reports it ended, and EXITS 0. A build
  # that trusts the exit status arms a poll nothing can ever attach to.
  : > "$home/lavish-state/hold-after-terminal"
  : > "$home/lavish-state/poll-trigger"
  for _ in $(seq 1 100); do
    [ -e "$home/lavish-state/terminal-emitted" ] && break
    sleep 0.05
  done
  [ -e "$home/lavish-state/terminal-emitted" ] \
    || fail "the old listener did not receive its terminal result"
  rm -f "$home/lavish-state/poll-trigger"
  end_session_as_captain "$home"
  out=$(run_board "$home" build "$data") || fail "the rebuild refused a recoverable ended session"
  rm -f "$home/lavish-state/hold-after-terminal"
  assert_contains "$out" "session: reopened" \
    "the rebuild did not reopen the ended session: $out"
  [ ! -e "$home/lavish-state/user-ended" ] \
    || fail "the rebuild reported success while the session was still ended"
  new_pid=$(sed -n '2p' "$claim")
  new_token=$(sed -n '3p' "$claim")
  [ "$new_pid" != "$old_pid" ] || [ "$new_token" != "$old_token" ] \
    || fail "the rebuild accepted the pre-reopen source generation"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the reopened board has no live listener"
  pass "a board build reopens a session the captain ended instead of arming a dead one"
}

test_rebuild_of_a_live_session_never_opens_another_tab() {
  local home data board
  home=$(make_home no-new-tab)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  run_board "$home" build "$data" >/dev/null || fail "the rebuild failed"
  [ "$(wc -l < "$home/lavish-state/open-calls")" -eq 2 ] \
    || fail "expected one establish call per build: $(cat "$home/lavish-state/open-calls")"
  ! grep -qv -e '--no-open' "$home/lavish-state/open-calls" \
    || fail "a rebuild establish call could open a new browser tab: $(cat "$home/lavish-state/open-calls")"
  ! grep -q -e '--reopen' "$home/lavish-state/open-calls" \
    || fail "a live session was reopened"
  pass "a board rebuild of a live session passes --no-open so no new tab opens"
}

test_build_reopens_when_an_opened_session_ends_before_listing() {
  local home data out board sid
  home=$(make_home establish-list-race)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  : > "$home/lavish-state/end-before-next-list"
  out=$(run_board "$home" build "$data") || fail "the raced session build failed: $out"
  assert_contains "$out" "session: reopened" \
    "the build trusted an opened response after the server no longer listed it: $out"
  sid=$(run_lavish_source_id "$home" "$board")
  [ -s "$home/lavish-state/open" ] || fail "the raced session was not live before arming"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the replacement session did not receive a live listener"
  pass "build reopens a session that ends between establish and listing"
}

test_build_refuses_to_arm_when_the_session_stays_ended() {
  local home data rc out sid
  home=$(make_home dead-session)
  data="$home/payload.json"
  write_valid_payload "$data"
  # An ended session that will not come back: the build must stop rather than
  # register a poll against it.
  : > "$home/lavish-state/refuse-reopen"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build armed a poll on a session that stayed ended: $out"
  assert_contains "$out" "ended session" "the refusal did not say why: $out"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board to a session that stayed ended"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board against a session that stayed ended"
  pass "build refuses to arm a poll on a session that stays ended"
}

test_build_starts_a_listener_for_an_already_armed_board() {
  local home data board out sid claim
  home=$(make_home relisten)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  sid=$(run_lavish_source_id "$home" "$board")

  # Registered is not listening: drop the listener the way a crashed generation
  # would, then rebuild. `already-armed` must not be the end of the story.
  claim="$home/procevent-claims/$sid.claim"
  assert_present "$claim" "the first build left no listener to lose"
  kill -KILL -"$(sed -n '2p' "$claim")" 2>/dev/null || true
  kill -KILL "$(sed -n '2p' "$claim")" 2>/dev/null || true
  sleep 1

  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: $sid" "the rebuild re-registered the source: $out"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the rebuilt board is registered but nothing is listening"
  pass "a rebuild starts a listener when an already-armed board has none"
}

test_a_waiting_page_agent_restarts_the_board_listener() {
  local home data board sid claim dir out
  home=$(make_home page-wait-listens)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the build failed"
  sid=$(run_lavish_source_id "$home" "$board")
  dir=$(run_page "$home" dir p1) || fail "page dir failed"
  printf '<html></html>\n' > "$dir/page.html"
  run_page "$home" open p1 --title P1 >/dev/null || fail "page open failed"

  # The listener exits after each result it captures; drop it the same way.
  claim="$home/procevent-claims/$sid.claim"
  assert_present "$claim" "the build left no listener to lose"
  kill -KILL -"$(sed -n '2p' "$claim")" 2>/dev/null || true
  kill -KILL "$(sed -n '2p' "$claim")" 2>/dev/null || true
  sleep 1
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" != live ] \
    || fail "the listener survived being killed"

  out=$(run_page "$home" wait p1 --timeout-s 1) || fail "page wait failed"
  assert_contains "$out" "status: timeout" "page wait reported something it was not sent: $out"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "a page agent waited while nothing listened for its page actions"
  pass "a page agent that waits restarts the board listener so its actions arrive at once"
}

# --- the stable board link ---------------------------------------------------

test_url_refuses_before_any_board_is_built() {
  local home rc out
  home=$(make_home url-unbuilt)
  set +e
  out=$(run_board "$home" url 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "url printed a link for a board that was never built: $out"
  assert_contains "$out" "no board has been built" "the refusal did not say why: $out"
  [ ! -e "$home/lavish-state/open" ] || fail "url opened a Lavish session with no board"
  pass "url refuses before any board is built"
}

test_url_prints_only_the_live_link_without_a_browser() {
  local home data board out err sid
  home=$(make_home url-live)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  rm -f "$home/lavish-state/browser-allowed"
  cp "$board" "$home/board-before"
  out=$(FM_BEARINGS_BOARD_REFRESH="touch $home/refresh-kicked" run_board "$home" url 2>"$home/url.err") \
    || fail "url failed on a live board: $(cat "$home/url.err")"
  err=$(cat "$home/url.err")
  [ "$out" = "http://127.0.0.1:4387/session/0123456789abcdef" ] \
    || fail "url did not print exactly the listed board link: $out"
  case "$err" in *reopened*) fail "url reported a reopen for a live board: $err" ;; esac
  [ ! -e "$home/lavish-state/browser-allowed" ] || fail "url let Lavish open a browser"
  cmp -s "$board" "$home/board-before" || fail "url rebuilt the board instead of only serving it"
  [ ! -e "$home/refresh-kicked" ] || fail "url started a refresh for a board that was already live"
  sid=$(run_lavish_source_id "$home" "$board")
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "url left the live board without a listener"
  pass "url prints only the live board link, without a browser or a rebuild"
}

test_url_reopens_a_board_the_captain_ended() {
  local home data board out err sid claim old_pid old_token
  home=$(make_home url-ended)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  sid=$(run_lavish_source_id "$home" "$board")
  claim="$home/procevent-claims/$sid.claim"
  old_pid=$(sed -n '2p' "$claim")
  old_token=$(sed -n '3p' "$claim")

  # The captain closed the board: the old listener sees the end, and a plain
  # open now refuses. Asking for the link must bring the same board back with
  # somewhere for its answers to go.
  : > "$home/lavish-state/poll-trigger"
  sleep 0.5
  rm -f "$home/lavish-state/poll-trigger"
  end_session_as_captain "$home"
  out=$(FM_BEARINGS_BOARD_REFRESH="touch $home/refresh-kicked" run_board "$home" url 2>"$home/url.err") \
    || fail "url refused a recoverable ended board: $(cat "$home/url.err")"
  err=$(cat "$home/url.err")
  [ "$out" = "http://127.0.0.1:4387/session/0123456789abcdef" ] \
    || fail "url did not print the reopened board link: $out"
  assert_contains "$err" "reopened: yes" "url did not report the reopen: $err"
  [ -s "$home/lavish-state/open" ] || fail "url printed a link while the session stayed ended"
  [ -e "$home/refresh-kicked" ] || fail "url did not start a refresh to bring the reopened board current"
  [ "$(sed -n '2p' "$claim")" != "$old_pid" ] || [ "$(sed -n '3p' "$claim")" != "$old_token" ] \
    || fail "url kept the pre-reopen source generation"
  [ "$(run_procevent "$home" list | awk -v id="$sid" 'NR > 1 && $1 == id { print $3 }')" = live ] \
    || fail "the reopened board has no live listener"
  pass "url reopens a board the captain ended and re-arms its answers"
}

test_url_refuses_when_the_board_stays_ended() {
  local home data rc out
  home=$(make_home url-dead)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  end_session_as_captain "$home"
  : > "$home/lavish-state/refuse-reopen"
  set +e
  out=$(run_board "$home" url 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "url succeeded on a board that stayed ended"
  [ -z "$out" ] || fail "url printed a link to a board that stayed ended: $out"
  pass "url prints no link when the board cannot be brought back"
}

# --- whether anyone can see the board ------------------------------------------

# Write Lavish's saved session record with one session per <status> for <file>.
write_lavish_state() {  # <home> <file> <status...>
  local home=$1 file=$2 n=0
  shift 2
  printf '{"sessions":{}}\n' > "$home/lavish-state/state.json"
  for status in "$@"; do
    n=$((n + 1))
    jq --arg id "s$n" --arg file "$file" --arg status "$status" \
      '.sessions[$id] = {file: $file, status: $status, url: "http://127.0.0.1:4387/session/\($id)"}' \
      "$home/lavish-state/state.json" > "$home/lavish-state/state.tmp" \
      && mv "$home/lavish-state/state.tmp" "$home/lavish-state/state.json"
  done
}

board_ended() {  # <home>
  run_board "$1" ended >/dev/null 2>&1
}

test_ended_reads_the_saved_session_record_without_the_server() {
  local home data real
  home=$(make_home ended-record)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  real=$(cd "$home/.lavish" && pwd -P)/bearings-board.html
  : > "$home/lavish-state/open-calls"
  write_lavish_state "$home" "$real" ended user-ended
  board_ended "$home" || fail "a board whose every session ended was not reported ended"
  write_lavish_state "$home" "$real" ended open
  ! board_ended "$home" || fail "a board with an open session was reported ended"
  write_lavish_state "$home" "$real" feedback
  ! board_ended "$home" || fail "a board waiting on feedback was reported ended"
  write_lavish_state "$home" "$home/other.html" ended
  ! board_ended "$home" || fail "another page's ended session ended this board"
  printf '{"pages":[]}\n' > "$home/lavish-state/state.json"
  ! board_ended "$home" || fail "an unfamiliar record was read as ended"
  printf 'not json\n' > "$home/lavish-state/state.json"
  ! board_ended "$home" || fail "an unreadable record was read as ended"
  rm -f "$home/lavish-state/state.json"
  ! board_ended "$home" || fail "a missing record was read as ended"
  [ ! -s "$home/lavish-state/open-calls" ] || fail "ended called the Lavish server"
  pass "ended reports an ended board only from a saved record it understands, without the server"
}

# --- part 2: a landed subject is not a live call ----------------------------

test_build_drops_decision_cards_whose_subject_already_landed() {
  local home data board out
  home=$(make_home landed-cards)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  jq '.captains_call = [
        {"key":"landed-by-task","type":"decision","repo":"sample","title":"Already shipped",
         "options":[{"value":"yes","label":"Yes"}]},
        {"key":"timeout-reattach","type":"decision","repo":"sample","title":"Already merged",
         "pr_url":"https://github.com/sample/sample/pull/7",
         "options":[{"value":"yes","label":"Yes"}]},
        {"key":"quota-version","type":"decision","repo":"sample","title":"Old quota release",
         "subject":{"artifact":"quota-axi","version":"0.1.37"},
         "options":[{"value":"yes","label":"Yes"}]},
        {"key":"still-open","type":"decision","repo":"sample","title":"Genuinely open","question":"Adopt the new quota release?",
         "subject":{"artifact":"quota-axi","version":"0.2.0"},
         "options":[{"value":"yes","label":"Yes"}],"no_link":true}
      ]
      | .landed = [
        {"id":"landed-by-task","repo":"sample","what":"shipped it","owner":"crew"},
        {"id":"some-other-task","repo":"sample","what":"merged timeout reattach","owner":"crew",
         "pr_url":"https://github.com/sample/sample/pull/7"},
        {"id":"quota-release","repo":"sample","what":"published quota-axi","owner":"crew",
         "subject":{"artifact":"quota-axi","version":"0.1.38"}},
        {"id":"unrelated\nstill-open","repo":"sample","what":"unrelated multiline identity","owner":"crew"}
      ]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_board "$home" build "$data" 2>&1) || fail "the hygiene build failed: $out"
  assert_contains "$out" "dropped-landed-card: landed-by-task" \
    "the build did not report dropping the landed work item card: $out"
  assert_contains "$out" "dropped-landed-card: timeout-reattach" \
    "the build did not report dropping the merged timeout/reattach card: $out"
  assert_contains "$out" "dropped-landed-card: quota-version" \
    "the build did not report dropping the superseded quota-axi version card: $out"
  extract_payload "$board" | jq -e '[.captains_call[].key] == ["still-open"]' >/dev/null \
    || fail "the board dropped an open card or kept one whose subject already landed"
  pass "build drops decision cards whose subject already landed and keeps open ones"
}

test_build_keeps_a_decision_absent_from_the_main_backlog() {
  local home data board out
  home=$(make_home remote-decision-card)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  write_valid_payload "$data"
  jq '.captains_call = [{
        "key":"remote-mate-call","type":"decision","repo":"sample",
        "title":"Remote secondmate decision","question":"Approve the remote call?",
        "options":[{"value":"yes","label":"Yes"}],"no_link":true
      }]
      | .landed = []' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  out=$(run_board "$home" build "$data" 2>&1) || fail "the remote-card build failed: $out"
  assert_not_contains "$out" "dropped-landed-card: remote-mate-call" \
    "an absent remote card was reported as landed: $out"
  extract_payload "$board" | jq -e '
    [.captains_call[] | select(.key == "remote-mate-call")] | length == 1
  ' >/dev/null || fail "the hygiene check dropped a decision absent from the main backlog"
  pass "build keeps remote decisions absent from the main backlog"
}

# --- part 3: every decision card offers reconcile ---------------------------

test_build_fails_when_reconcile_cannot_establish_a_listener() {
  local home data out rc sid
  home=$(make_home no-listener)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "could not establish the listener fixture"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  cat > "$home/fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/ps"
  set +e
  out=$(FM_PROC_ROOT_OVERRIDE="$home/no-proc" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  rm -f "$home/fakebin/ps"
  [ "$rc" -ne 0 ] || fail "a build with an uncertain listener reported success: $out"
  assert_contains "$out" "source $sid is not listening after reconcile" \
    "the refusal did not name the source: $out"
  assert_contains "$out" "observed owner: uncertain" \
    "the refusal did not name the observed owner: $out"
  pass "build fails when reconcile cannot prove a live listener"
}

test_every_decision_card_carries_the_reconcile_choice() {
  local home data board
  home=$(make_home reconcile-option)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the reconcile-option build failed"
  extract_payload "$board" | jq -e '
    ([.captains_call[] | select(.type == "decision")] | length) > 0
    and ([.captains_call[]
      | select(.type == "decision")
      | ([.options[] | select(.value == "reconcile")] | length) == 1
        and ([.options[] | select(.value == "reconcile") | .label | length > 0] | all)] | all)
  ' >/dev/null || fail "a decision card was published without the reconcile choice"
  extract_payload "$board" | jq -e '
    ([.captains_call[] | select(.type != "decision")
      | .options[] | select(.value == "reconcile")] | length) == 0
  ' >/dev/null || fail "reconcile was injected into a non-decision card"
  pass "every decision card carries exactly one reconcile choice"
}

# A decision answered on its own page carries no options and no free text;
# the build still accepts it and gives it only the reconcile choice, labelled
# plainly so it never reads as one of the decision's own options.
test_a_page_backed_decision_gets_only_the_plain_reconcile_choice() {
  local home data board
  home=$(make_home reconcile-page-backed)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  jq '.captains_call[0].options = [] | .captains_call[0].allow_freeform = false
      | .captains_call[0].links = ((.captains_call[0].links // []) + [{"label":"Decision page","page":"decision-page"}])' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null || fail "a decision with no options and no free text was refused"
  extract_payload "$board" | jq -e '
    .captains_call[0].options == [{value: "reconcile",
      label: "Already settled? Re-check and close it",
      hint: .captains_call[0].options[0].hint}]
  ' >/dev/null || fail "the page-backed decision did not get only the plainly labelled reconcile choice: $(extract_payload "$board" | jq -c '.captains_call[0].options')"
  pass "a decision answered on its page builds with only the plainly labelled reconcile choice"
}

test_build_refuses_a_payload_that_occupies_the_reconcile_value() {
  local home data rc out
  home=$(make_home reconcile-reserved)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call[0].options += [{"value":"reconcile","label":"Something else"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a payload occupying the reserved reconcile value was accepted"
  assert_absent "$home/.lavish/bearings-board.html" "a refused payload still produced a board"
  pass "build refuses a payload that occupies the reserved reconcile value"
}

test_build_refuses_a_nondecision_reconcile_value() {
  local home data rc out
  home=$(make_home merge-reconcile-reserved)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call[1].options += [{"value":"reconcile","label":"Merge action"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e
  out=$(run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a merge card occupying the reconcile value was accepted"
  assert_absent "$home/.lavish/bearings-board.html" "a refused merge card still produced a board"
  pass "build reserves reconcile across non-decision cards"
}

# A Captain's Call card must state its decision: a question the captain is
# asked and the choices that answer it. A card missing either never reaches the
# captain: it is named on stderr, left out of Captain's Call, and listed in the
# build's `cards_to_fix` and the home's state/board-cards-to-fix record with its
# owning task, key and problem, while every other card builds. One bad card
# never stops the board.
expect_flagged_build() {  # <home> <data> <key> <field> <what>
  local out rc
  set +e; out=$(run_board "$1" build "$2" 2>&1); rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "$5: one card that does not state its decision stopped the whole board: $out"
  assert_contains "$out" "undecided-card: $3: missing $4" "$5: stderr did not name the card and its missing field: $out"
  assert_contains "$out" "held back Captain's Call cards with no explicit decision" "$5: the build did not report the held-back card: $out"
  extract_payload "$1/.lavish/bearings-board.html" | jq -e --arg k "$3" --arg f "missing $4" '
    ([.captains_call[] | select(.key == $k)] == [])
    and ([.captains_call[] | has("problem")] | any | not)
    and ([.cards_to_fix[] | select(.key == $k) | .problem | strings | startswith($f)] == [true])
    and ([.cards_to_fix[] | select(.key == $k) | .task | strings | length > 0] == [true])
    and ([.cards_to_fix[] | select(.key != $k)] == [])
    and (.captains_call | length) > 0
  ' >/dev/null || fail "$5: the board did not hold back that card alone: $(extract_payload "$1/.lavish/bearings-board.html" | jq -c '{call: [.captains_call[] | {key, problem}], fix: .cards_to_fix}')"
  awk -F '\t' -v k="$3" -v f="missing $4" '$2 == k && index($3, f) == 1 { n++ } END { exit !(n == 1 && NR == 1) }' \
    "$1/state/board-cards-to-fix" \
    || fail "$5: the home's cards-to-fix record does not name that card alone: $(cat "$1/state/board-cards-to-fix" 2>&1)"
}

test_build_flags_a_card_with_no_explicit_decision_and_builds_the_rest() {
  local home data
  home=$(make_home no-explicit-decision)
  data="$home/payload.json"

  # No question at all: the generator dropped it, and the title is a statement.
  write_valid_payload "$data"
  jq '.captains_call += [{"key":"fos-pr20-merge-status","type":"decision","repo":"fos",
    "title":"fos PR 20 merge status","about":"Merged upstream.",
    "options":[{"value":"approve","label":"Approve"},{"value":"decline","label":"Decline"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  expect_flagged_build "$home" "$data" fos-pr20-merge-status question "a card with no question"

  # A prompt that is a statement, not a question.
  write_valid_payload "$data"
  jq '.captains_call += [{"key":"runner-image-pr63-waive","type":"decision","repo":"runner",
    "title":"Runner image PR 63","question":"The image check is red on PR 63.",
    "options":[{"value":"approve","label":"Approve"},{"value":"decline","label":"Decline"}],
    "links":[{"url":"https://github.com/example/runner/pull/63","label":"PR 63"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  expect_flagged_build "$home" "$data" runner-image-pr63-waive question "a card whose prompt is not a question"

  # An empty question over a free-text box: a box alone does not say what to decide.
  write_valid_payload "$data"
  jq '.captains_call += [{"key":"mr872-approve","type":"decision","repo":"cd",
    "title":"MR 872","question":"","options":[],"allow_freeform":true,"free_text":true,"no_link":true}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  expect_flagged_build "$home" "$data" mr872-approve question "a card with an empty question"

  # A real question with no options and no free-text answer: nothing answers it.
  write_valid_payload "$data"
  jq '.captains_call[0].options = [] | .captains_call[0].allow_freeform = false' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  expect_flagged_build "$home" "$data" \
    sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice options \
    "a question card with no way to answer it"

  # A flag is the build's own: a payload that authors one, or an authored fix
  # list, has it cleared, and a board with no card to fix leaves no record.
  write_valid_payload "$data"
  jq '.captains_call[0].problem = "authored" | .cards_to_fix = [{"key":"x","task":"x","problem":"authored"}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null 2>&1 || fail "a payload authoring a flag on a sound card was refused"
  extract_payload "$home/.lavish/bearings-board.html" \
    | jq -e '([.captains_call[] | has("problem")] | any | not) and (.captains_call | length) == 2 and (has("cards_to_fix") | not)' >/dev/null \
    || fail "an authored flag on a card that states its decision reached the board"
  assert_absent "$home/state/board-cards-to-fix" "a board with no card to fix left a cards-to-fix record"
  pass "build holds back a Captain's Call card with no explicit question or no way to answer it, naming it, and builds every other card"
}

test_build_accepts_explicit_decisions_and_in_person_actions() {
  local home data
  home=$(make_home explicit-decision)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call += [
    {"key":"ship-it","type":"decision","repo":"sample","title":"Ship it",
     "question":"Ship the release today?",
     "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}],
     "links":[{"url":"https://github.com/example/sample/releases","label":"Releases"}]},
    {"key":"cd-872-874-dismiss","type":"decision","repo":"cd","title":"Dismiss stale reviews",
     "question":"Dismiss review 623 on MR 872 and review 624 on MR 874.",
     "options":[{"value":"done","label":"Done"},
                {"value":"not-done","label":"Not done (say why)","hint":"Say why in the answer box"}],
     "allow_freeform":true,"pr_url":"https://gitlab.com/example/cd/-/merge_requests/872"},
    {"key":"pick-a-name","type":"decision","repo":"sample","title":"Public name",
     "question":"Which public name should the tool ship under?","options":[],"allow_freeform":true,
     "free_text":true,"no_link":true}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null 2>&1 \
    || fail "build refused explicit question and in-person action cards"
  extract_payload "$home/.lavish/bearings-board.html" \
    | jq -e '[.captains_call[].key] | index("ship-it") != null and index("cd-872-874-dismiss") != null
             and index("pick-a-name") != null' >/dev/null \
    || fail "an explicit decision card did not reach the board"
  pass "build accepts an explicit question card, an open question answered in free text, and an in-person action card"
}

# A decision card offers the decision's own recorded values and something to
# click. A card whose hold recorded no choices, or that has no link, is flagged
# naming exactly what to re-hold with; a declared free-text question and a
# --no-link opt-out pass, and the generator's own status cards keep passing.
test_build_flags_a_card_without_recorded_choices_or_a_link() {
  local home data rc out
  home=$(make_home no-choices-no-link)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call += [
    {"key":"guessed-choices","type":"decision","repo":"cd","title":"Keep the grill?",
     "question":"Keep the second grill round?","options_inferred":true,
     "options":[{"value":"approve","label":"Approve"},{"value":"decline","label":"Decline"}],
     "links":[{"url":"https://gitlab.com/example/cd/-/merge_requests/697","label":"MR 697"}]},
    {"key":"nothing-to-click","type":"decision","repo":"cd","title":"Dismiss the reviews?",
     "question":"Dismiss the stale reviews?",
     "options":[{"value":"dismiss","label":"Dismiss both"},{"value":"keep","label":"Keep them"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "a card with guessed choices and a card with no link stopped the whole board: $out"
  assert_contains "$out" "undecided-card: guessed-choices: missing options (no recorded choices: re-hold with --option <value>=<label> or --free-text)" \
    "the guessed-choices refusal did not say what to add: $out"
  assert_not_contains "$out" "guessed-choices: missing options (no recorded choices: re-hold with --option <value>=<label> or --free-text), link" \
    "a linked card was refused for its link: $out"
  assert_contains "$out" "undecided-card: nothing-to-click: missing link (no link: re-hold with --link <url|page:id> or --no-link)" \
    "the no-link refusal did not say what to add: $out"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.cards_to_fix[] | select(.key == "guessed-choices" or .key == "nothing-to-click") | .problem | strings] | length) == 2
    and ([.captains_call[] | select(.key == "guessed-choices" or .key == "nothing-to-click")] == [])
    and ([.captains_call[] | select(.key == "merge.sample-task") | has("problem")] == [false])
  ' >/dev/null || fail "the board did not hold back exactly the two cards: $(extract_payload "$home/.lavish/bearings-board.html" | jq -c '{call: [.captains_call[] | {key, problem}], fix: .cards_to_fix}')"

  write_valid_payload "$data"
  jq '.captains_call += [
    {"key":"name-it","type":"decision","repo":"sample","title":"Public name",
     "question":"Which public name should the tool ship under?","options":[],"allow_freeform":true,
     "free_text":true,"no_link":true},
    {"key":"worker-asks","type":"decision","repo":"sample","title":"Worker question",
     "question":"Use the staging database?","options_inferred":true,"from_status":true,
     "options":[{"value":"approve","label":"Approve"},{"value":"decline","label":"Decline"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data" 2>&1) \
    || fail "a declared free-text call with --no-link or a generator status card was refused: $out"
  assert_not_contains "$out" "undecided-card" "a declared free-text call or a generator status card was flagged: $out"
  extract_payload "$home/.lavish/bearings-board.html" \
    | jq -e '[.captains_call[].key] | index("name-it") != null and index("worker-asks") != null' >/dev/null \
    || fail "an opted-out or generator card did not reach the board"
  pass "build holds back a card with no recorded choices or no link by what to add, and passes the opt-outs and generator cards"
}

# A live page about a task links that task's card in place, whether its record
# names the task (fm-board-page.sh open --task) or the card names the page id;
# a Waiting or Charted row about it gains the page in its expandable context.
test_a_page_about_a_task_links_its_card_and_context_in_place() {
  local home data dir out
  home=$(make_home page-links)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null 2>&1 || fail "the first build failed"
  dir=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-board-page.sh" dir cd-697-698-grill) \
    || fail "the page folder was not given"
  printf '<html></html>\n' > "$dir/page.html"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_BOARD_PAGE_REFRESH=true \
    "$ROOT/bin/fm-board-page.sh" open cd-697-698-grill --title "CD grill" --task cd-grill >/dev/null \
    || fail "the page did not open with a task"
  jq '.captains_call += [
    {"key":"cd-grill","type":"decision","repo":"cd","title":"Grill outcome",
     "question":"Keep both grill rounds?",
     "options":[{"value":"keep","label":"Keep both"},{"value":"drop","label":"Drop the second"}]},
    {"key":"cd-follow-up","type":"decision","repo":"cd","title":"Grill follow-up",
     "question":"Act on the findings on cd-697-698-grill now?",
     "options":[{"value":"now","label":"Now"},{"value":"later","label":"Later"}]}]
    | .waiting = [{"key":"cd-wait","repo":"cd","title":"Grill wait","reason":"After the grill",
                   "context":{"task":"cd-grill","reason":"After the grill"}}]
    | .charted += [{"id":"cd-next","repo":"cd","title":"Next","reason":"","dispatchable":true,
                    "context":{"task":"cd-next","notes":["Read cd-697-698-grill first."]}}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "the cards about a live page were refused: $out"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.captains_call[] | select(.key == "cd-grill") | .links[]] == [{"page":"cd-697-698-grill","label":"CD grill"}])
    and ([.captains_call[] | select(.key == "cd-follow-up") | .links[]] == [{"page":"cd-697-698-grill","label":"CD grill"}])
    and (.waiting[0].context.page == {"id":"cd-697-698-grill","title":"CD grill"})
    and ([.charted[] | select(.id == "cd-next") | .context.page] == [{"id":"cd-697-698-grill","title":"CD grill"}])
    and (.pages == [{"id":"cd-697-698-grill","title":"CD grill","href":"pages/cd-697-698-grill/page.html"}])
  ' >/dev/null || fail "a card or row about the live page did not link it in place: $(extract_payload "$home/.lavish/bearings-board.html" | jq -c '{c: [.captains_call[] | {key, links}], w: .waiting, ch: .charted, pages}')"
  pass "a live page about a task links its card and its Waiting and Charted context in place"
}

test_path_is_stable_and_home_scoped
test_build_flags_a_card_without_recorded_choices_or_a_link
test_a_page_about_a_task_links_its_card_and_context_in_place
test_build_flags_a_card_with_no_explicit_decision_and_builds_the_rest
test_build_accepts_explicit_decisions_and_in_person_actions
test_build_refuses_malformed_payloads_before_touching_the_board
test_charted_kind_is_optional_and_accepts_both_values
test_build_lists_live_pages_and_refuses_payload_pages
test_build_injects_binds_then_arms
test_registration_cannot_consume_before_any_origin_binding
test_build_does_not_bind_or_arm_when_session_start_fails
test_rebuild_is_idempotent_and_does_not_double_arm
test_rebuild_replaces_the_data_file_whole
test_build_refuses_a_template_that_does_not_load_the_data
test_build_refuses_another_code_roots_template_in_a_home_with_its_own_code
test_build_from_another_code_root_installs_a_matching_template
test_build_installs_into_a_home_without_its_own_code
test_build_reopens_a_session_the_captain_ended
test_rebuild_of_a_live_session_never_opens_another_tab
test_build_reopens_when_an_opened_session_ends_before_listing
test_build_refuses_to_arm_when_the_session_stays_ended
test_build_starts_a_listener_for_an_already_armed_board
test_a_waiting_page_agent_restarts_the_board_listener
test_url_refuses_before_any_board_is_built
test_url_prints_only_the_live_link_without_a_browser
test_url_reopens_a_board_the_captain_ended
test_url_refuses_when_the_board_stays_ended
test_ended_reads_the_saved_session_record_without_the_server
test_build_drops_decision_cards_whose_subject_already_landed
test_build_keeps_a_decision_absent_from_the_main_backlog
test_build_fails_when_reconcile_cannot_establish_a_listener
test_every_decision_card_carries_the_reconcile_choice
test_a_page_backed_decision_gets_only_the_plain_reconcile_choice
test_build_refuses_a_payload_that_occupies_the_reconcile_value
test_build_refuses_a_nondecision_reconcile_value
