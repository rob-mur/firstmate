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
  # Forge tools that never reach the network: glab answers an MR read from
  # $home/forge/gitlab-<host_path with / as _>-<number> and every other read
  # fails, so a build's live link read finds nothing unless a test writes it.
  mkdir -p "$home/forge"
  cat > "$fakebin/glab" <<SH
#!/usr/bin/env bash
[ "\${1-} \${2-}" = "mr view" ] || exit 1
number=\$3 project=''
while [ "\$#" -gt 0 ]; do [ "\$1" = -R ] && project=\$2; shift; done
f="$home/forge/gitlab-\$(printf '%s' "\${project#https://}" | tr '/' '_')-\$number"
[ -f "\$f" ] || exit 1
cat "\$f"
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/gh"
  cp "$fakebin/gh" "$fakebin/gh-axi"
  cp "$fakebin/gh" "$fakebin/tea"
  chmod +x "$fakebin/glab" "$fakebin/gh" "$fakebin/gh-axi" "$fakebin/tea"
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

  write_valid_payload "$data"
  jq '.underway = [{"id":"sample-task","repo":"sample","name":"Sample task","state":"working",
    "kind":"ship","doing":"MR !9: waiting on CI","pr_url":"javascript:alert(1)"}]' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Under way MR URL was accepted"

  assert_absent "$board" "a refused payload still produced a board"
  pass "build refuses malformed payloads before touching the board"
}

test_a_refusal_names_the_first_failing_item_and_its_fields() {
  local home data rc out
  home=$(make_home refusal-names)
  data="$home/payload.json"

  # A card appended through the copy overlay's captains_call_extra without a
  # type or repo, followed by a charted row with a bad filed date.
  write_valid_payload "$data"
  jq '.captains_call += [{"key":"extra-card","title":"Extra","options":[]}]
    | .charted[0].filed = "last Tuesday"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a card without a type or repo was accepted"
  assert_contains "$out" 'captains_call[2] (key "extra-card"): missing required field "type"; missing required field "repo"' \
    "the refusal did not name the failing card and its missing fields: $out"
  assert_contains "$out" "(and 1 more failing item)" "the refusal did not count the other failing item: $out"
  assert_not_contains "$out" "last Tuesday" "the refusal named more than the first failing item: $out"

  write_valid_payload "$data"
  jq '.charted[0].filed = "last Tuesday"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an invalid filed date was accepted"
  assert_contains "$out" 'charted[0] (id "sample-queued"): invalid field "filed"' \
    "the refusal did not name the failing row and field: $out"
  assert_not_contains "$out" "more failing" "a single failing item was counted as more: $out"

  write_valid_payload "$data"
  jq 'del(.home)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a payload without a home was accepted"
  assert_contains "$out" 'payload: missing required field "home"' "the refusal did not name the payload field: $out"
  pass "a refused build names the first failing item and its missing or invalid fields"
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

# An Under way row may link the PR or MR its task works on.
test_an_underway_row_may_link_its_mr() {
  local home data
  home=$(make_home underwaymr)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.underway = [{"id":"sample-task","repo":"sample","name":"Sample task","state":"working",
    "kind":"ship","doing":"MR !9: waiting on CI",
    "pr_url":"https://gitlab.example.com/grp/sample/-/merge_requests/9"}]' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  run_board "$home" build "$data" >/dev/null || fail "an Under way row with an HTTPS MR link was refused"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    .underway[0].pr_url == "https://gitlab.example.com/grp/sample/-/merge_requests/9"
  ' >/dev/null || fail "the built board did not carry the Under way MR link"
  pass "an Under way row may link its MR"
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

# A markdown page (an understand page drawn as md, as understand-mr821 is) has
# page.md and no page.html in its folder, so the board links that page.md; a
# folder with page.html keeps linking it.
test_build_links_a_markdown_only_page_to_its_page_md() {
  local home data id
  home=$(make_home md-pages)
  data="$home/payload.json"
  write_valid_payload "$data"
  for id in md-only both html-only; do
    mkdir -p "$home/state/pages/$id" "$home/.lavish/pages/$id"
    printf '{"id":"%s","title":"%s","opened":"2026-01-01T00:00:00Z","state":"live"}\n' "$id" "$id" \
      > "$home/state/pages/$id/page.json"
  done
  printf '# Understand\n' > "$home/.lavish/pages/md-only/page.md"
  printf '# Understand\n' > "$home/.lavish/pages/both/page.md"
  printf '<html></html>\n' > "$home/.lavish/pages/both/page.html"
  printf '<html></html>\n' > "$home/.lavish/pages/html-only/page.html"
  run_board "$home" build "$data" >/dev/null || fail "a board with a markdown page did not build"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    [.pages[] | {id, href}] == [
      {"id":"both","href":"pages/both/page.html"},
      {"id":"html-only","href":"pages/html-only/page.html"},
      {"id":"md-only","href":"pages/md-only/page.md"}
    ]' >/dev/null || fail "a markdown-only page was not linked to its page.md: $(extract_payload "$home/.lavish/bearings-board.html" | jq -c .pages)"
  pass "build links a markdown-only page to its page.md and keeps page.html otherwise"
}


# A page whose worker last reported a day after the page was last written:
# the card linking it is held back, page-backed or not; a page rebuilt at
# that report passes.
setup_page_with_worker() {  # <home> <page-id> <task> <page-age-seconds>
  local now stamp
  now=$(date +%s)
  mkdir -p "$1/state/pages/$2" "$1/.lavish/pages/$2"
  printf '{"id":"%s","title":"MR 900 understanding","opened":"2026-01-01T00:00:00Z","state":"live","task":"%s"}\n' \
    "$2" "$3" > "$1/state/pages/$2/page.json"
  printf '<html>not-yet-checked</html>\n' > "$1/.lavish/pages/$2/page.html"
  stamp=$(date -u -r "$((now - $4))" +%Y%m%d%H%M.%S 2>/dev/null || date -u -d "@$((now - $4))" +%Y%m%d%H%M.%S)
  TZ=UTC touch -t "$stamp" "$1/.lavish/pages/$2/page.html"
  printf 'working [at=%s]: building the page\npaused [at=%s]: all saves judged\n' \
    "$((now - 172800))" "$now" > "$1/state/$3.status"
}

add_page_card() {  # <data> <key> <page-id> <with-options-0-or-1>
  jq --arg k "$2" --arg p "$3" --argjson o "$4" '.captains_call += [{"key":$k,"type":"decision","repo":"aegis",
    "title":"MR 900 understanding page","question":"Will you answer the open questions on the page?",
    "options":(if $o == 1 then [{"value":"a","label":"Answer now"},{"value":"b","label":"Leave it"}] else [] end),
    "links":[{"page":$p,"label":"MR 900 understanding page"}]}]' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

test_build_flags_a_card_whose_page_missed_its_workers_last_report() {
  local home data
  home=$(make_home stale-page)
  data="$home/payload.json"
  setup_page_with_worker "$home" aegis-900-understand aegis-900-understand 86400
  write_valid_payload "$data"
  add_page_card "$data" captain-mr900-page aegis-900-understand 1
  expect_flagged_build "$home" "$data" captain-mr900-page "" "a card linking a stale page" \
    "stale page (aegis-900-understand was not rebuilt after its worker last reported"
  write_valid_payload "$data"
  add_page_card "$data" captain-mr900-page aegis-900-understand 0
  expect_flagged_build "$home" "$data" captain-mr900-page "" "a page-backed card linking a stale page" \
    "stale page (aegis-900-understand"
  pass "build holds back a card whose linked page was not rebuilt since its worker last reported"
}

test_build_keeps_a_card_whose_page_was_rebuilt_at_its_workers_last_report() {
  local home data out
  home=$(make_home fresh-page)
  data="$home/payload.json"
  setup_page_with_worker "$home" aegis-900-understand aegis-900-understand 30
  write_valid_payload "$data"
  add_page_card "$data" captain-mr900-page aegis-900-understand 1
  out=$(run_board "$home" build "$data" 2>&1) || fail "a board with a freshly rebuilt page did not build: $out"
  case $out in *undecided-card*) fail "a card linking a freshly rebuilt page was held back: $out" ;; esac
  extract_payload "$home/.lavish/bearings-board.html" \
    | jq -e '[.captains_call[] | select(.key == "captain-mr900-page")] | length == 1' >/dev/null \
    || fail "a card linking a freshly rebuilt page did not reach Captain's Call"
  assert_absent "$home/state/board-cards-to-fix" "a freshly rebuilt page left a cards-to-fix record"
  pass "build keeps a card whose linked page was rebuilt at its worker's last report"
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
expect_flagged_build() {  # <home> <data> <key> <field> <what> [<problem-prefix>]
  local out rc want=${6:-missing $4}
  set +e; out=$(run_board "$1" build "$2" 2>&1); rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "$5: one card that does not state its decision stopped the whole board: $out"
  assert_contains "$out" "undecided-card: $3: $want" "$5: stderr did not name the card and its missing field: $out"
  assert_contains "$out" "held back Captain's Call cards with no explicit decision" "$5: the build did not report the held-back card: $out"
  extract_payload "$1/.lavish/bearings-board.html" | jq -e --arg k "$3" --arg f "$want" '
    ([.captains_call[] | select(.key == $k)] == [])
    and ([.captains_call[] | has("problem")] | any | not)
    and ([.cards_to_fix[] | select(.key == $k) | .problem | strings | startswith($f)] == [true])
    and ([.cards_to_fix[] | select(.key == $k) | .task | strings | length > 0] == [true])
    and ([.cards_to_fix[] | select(.key != $k)] == [])
    and (.captains_call | length) > 0
  ' >/dev/null || fail "$5: the board did not hold back that card alone: $(extract_payload "$1/.lavish/bearings-board.html" | jq -c '{call: [.captains_call[] | {key, problem}], fix: .cards_to_fix}')"
  awk -F '\t' -v k="$3" -v f="$want" '$2 == k && index($3, f) == 1 { n++ } END { exit !(n == 1 && NR == 1) }' \
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

# A question that offers lettered "(a)"/"(b)" choices the option reader could
# not read is held back naming them, not shown with only the reconcile choice;
# marks in a sentence that does not ask are references, not choices.
test_build_flags_a_card_whose_lettered_choices_were_not_read() {
  local home data out
  home=$(make_home unread-letter-marks)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call += [{"key":"status.lane.pick","type":"decision","repo":null,
    "title":"lane","question":"Go with (a) or (b)?","from_status":true,
    "allow_freeform":true,"context":{"task":"lane","reason":"Go with (a, recommended) or (b)? See the report."},
    "options":[]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  expect_flagged_build "$home" "$data" status.lane.pick "options (the question offers lettered (a)/(b) choices but the card offers no options" \
    "a status card whose lettered choices became no options"

  write_valid_payload "$data"
  jq '.captains_call += [{"key":"status.lane.pick","type":"decision","repo":null,
    "title":"lane","question":"Ship it now?","from_status":true,
    "allow_freeform":true,"context":{"task":"lane","reason":"It was fixed in step (a) or step (b). Ship it now?"},
    "options":[]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "a card whose lettered marks only refer back did not build: $out"
  assert_not_contains "$out" "undecided-card: status.lane.pick" "a card whose lettered marks only refer back was held back: $out"
  pass "the board holds back a question whose lettered choices were not read, not one that only refers back"
}

# A hold reason that leads with a colon list cuts its heading to the list's
# lead ("Four calls"), but the question it ends on still asks: the card builds.
# A reason that asks nowhere is still held back for its question.
test_build_reads_a_question_anywhere_in_the_reason() {
  local home data out
  home=$(make_home question-anywhere)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call += [{"key":"cd-636-update-decisions","type":"decision","repo":"cd",
    "title":"cd 636 update decisions","question":"Four calls",
    "about":"Four calls: 1) Keep the cache. 2) Drop the flag. 3) Pin the image. 4) Split the job. Do you accept all four recommendations?",
    "context":{"task":"cd-636-update-decisions","reason":"Four calls: 1) Keep the cache. 2) Drop the flag. 3) Pin the image. 4) Split the job. Do you accept all four recommendations?"},
    "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}],"no_link":true}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "a reason whose question follows a colon list did not build: $out"
  assert_not_contains "$out" "undecided-card: cd-636-update-decisions" "a reason whose question follows a colon list was held back: $out"

  write_valid_payload "$data"
  jq '.captains_call += [{"key":"cd-636-update-decisions","type":"decision","repo":"cd",
    "title":"cd 636 update decisions","question":"Four calls",
    "about":"Four calls: 1) Keep the cache. 2) Drop the flag. 3) Pin the image. 4) Split the job.",
    "context":{"task":"cd-636-update-decisions","reason":"Four calls: 1) Keep the cache. 2) Drop the flag. 3) Pin the image. 4) Split the job."},
    "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}],"no_link":true}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  expect_flagged_build "$home" "$data" cd-636-update-decisions question "a reason with no question anywhere"
  pass "the board reads a question anywhere in the reason and still holds back a reason that asks nothing"
}

# The cd-636 card packed its four calls into one heading question: it is held
# back. The same calls as options under one heading question build, and so
# does a reason that lists numbered calls in its body under that question.
test_build_flags_a_heading_that_packs_several_calls() {
  local home data out
  home=$(make_home heading-calls)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call += [{"key":"cd-636-update-decisions","type":"decision","repo":"cd",
    "title":"cd 636 update decisions",
    "question":"Do you accept all four update recommendations: (1) keep the cache? (2) drop the flag? (3) pin the image? (4) split the job?",
    "context":{"task":"cd-636-update-decisions","reason":"Four update calls are ready."},
    "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}],"no_link":true}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  expect_flagged_build "$home" "$data" cd-636-update-decisions question "a heading with four numbered calls" \
    "heading carries several calls (it asks a numbered list of 4 calls"

  write_valid_payload "$data"
  jq '.captains_call += [{"key":"cd-636-update-decisions","type":"decision","repo":"cd",
    "title":"cd 636 update decisions",
    "question":"Do you keep the cache? Do you drop the flag?",
    "context":{"task":"cd-636-update-decisions","reason":"Two update calls are ready."},
    "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}],"no_link":true}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  expect_flagged_build "$home" "$data" cd-636-update-decisions question "a heading with two questions" \
    "heading carries several calls (it asks 2 questions"

  write_valid_payload "$data"
  jq '.captains_call += [{"key":"cd-636-update-decisions","type":"decision","repo":"cd",
    "title":"cd 636 update decisions",
    "question":"Which update recommendations do you accept (see https://example.com/r?id=636)?",
    "about":"1) Keep the cache. 2) Drop the flag. 3) Pin the image. 4) Split the job.",
    "context":{"task":"cd-636-update-decisions","reason":"Four calls: 1) Keep the cache. 2) Drop the flag. 3) Pin the image. 4) Split the job. Which do you accept?"},
    "options":[{"value":"all","label":"All four"},{"value":"cache","label":"Keep the cache"},
               {"value":"flag","label":"Drop the flag"},{"value":"image","label":"Pin the image"},
               {"value":"job","label":"Split the job"}],"no_link":true}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "one heading question with its calls as options did not build: $out"
  assert_not_contains "$out" "undecided-card: cd-636-update-decisions" "one heading question with its calls as options was held back: $out"
  pass "the board holds back a heading that packs several calls, not one question with its calls as options or body"
}

# The aegis-885 worker line asks its question only in a clause after a long
# lead and a "(a) ... or (b) ...?" run: the payload cut its heading mid-way
# ("...report:…?") and left its background ending "should the captain?". The
# card the real payload builder makes from that line is held back naming both,
# and the watcher bounce check names it too; the same call asked as its own
# sentence first passes.
test_build_flags_a_cut_heading_and_a_dangling_background() {
  local home data line good snapshot card out rc
  home=$(make_home cut-heading)
  data="$home/payload.json"
  line="MR https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/885 has nothing blocking left (14/15 threads resolved, report: /home/rob/repos/firstmate/data/aegis-885-recheck-2/report.md); for the open thread #13, where an imported Paid claim's status history shows Closed from the backdated month while closed_date is its payment date, should the captain (a) accept the caveat and resolve #13, or (b) ask Ali to make the history match by running the close after the backdate step?"
  good='Should the captain accept the caveat on MR https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/885 thread #13? (a) accept the caveat and resolve #13, or (b) ask Ali to make the history match by running the close after the backdate step.'
  # shellcheck disable=SC2016  # jq program text.
  snapshot='{schema:"fm-bearings.v1",prs:"unchecked",
    decisions_open:[{id:"aegis-885-recheck-2",key:"status.aegis-885-recheck-2.mr885-thread13",verb:"needs-decision",
      source:"status",task:"aegis-885-recheck-2",decision_key:"mr885-thread13",mate:null,
      title:"aegis-885-recheck-2",title_full:"aegis-885-recheck-2",reason:$n,reason_full:$n,
      summary:$n,question:$n,owner:"(main)"}],
    in_flight:[],landed:[],recorded_prs:[],contributions:{captain:[]},gates:[],secondmates:[]}'
  card=$(jq -cn --arg n "$line" "$snapshot" \
    | FM_BEARINGS_BOARD_PR_CHECK=0 FM_BEARINGS_BOARD_MR_CHECK=0 "$ROOT/bin/fm-bearings-board-payload.sh" --snapshot - \
    | jq -c '.captains_call[] | select(.key == "status.aegis-885-recheck-2.mr885-thread13")') \
    || fail "the payload builder did not make a card from the aegis-885 line"
  [ -n "$card" ] || fail "the payload builder made no card from the aegis-885 line"
  write_valid_payload "$data"
  jq --argjson c "$card" '.captains_call += [$c]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  expect_flagged_build "$home" "$data" status.aegis-885-recheck-2.mr885-thread13 question \
    "the aegis-885 card with a cut heading" "heading cut short"
  out=$(cat "$home/state/board-cards-to-fix")
  assert_contains "$out" "background ends in a dangling fragment (\"should the captain?\"" \
    "the held-back card does not name its dangling background: $out"

  set +e
  out=$(bash -c '. "$1/bin/fm-bearings-card-check-lib.sh"; fm_bearings_status_decision_problem aegis-885-recheck-2 mr885-thread13 "$2"' _ "$ROOT" "$line")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "the bounce check passed the aegis-885 line (rc=$rc): $out"
  assert_contains "$out" "heading cut short" "the bounce check did not name the cut heading: $out"

  set +e
  out=$(bash -c '. "$1/bin/fm-bearings-card-check-lib.sh"; fm_bearings_status_decision_problem aegis-885-recheck-2 mr885-thread13 "$2"' _ "$ROOT" "$good")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the bounce check held back the call asked as its own sentence (rc=$rc): $out"
  pass "the board holds back a card whose heading was cut and whose background lost its choices"
}

# A card whose reason lists two or more "Option x:" marks but which offers no
# options, or only a default yes/no, is a reason the option reader could not
# read: it is held back naming the marks, even as a worker status card, so the
# next such miss surfaces; once its options are the marked ones it builds.
test_build_flags_a_card_whose_option_marks_were_not_read() {
  local home data reason out
  home=$(make_home unread-option-marks)
  data="$home/payload.json"
  reason='Shall APP-5861 be built as recommended? Option a (recommended): yes, one ticket. Option b: yes, with your changes. Option c: as a, but book every payment.'
  write_valid_payload "$data"
  jq --arg r "$reason" '.captains_call += [{"key":"status.bcr.grill-bcr-r6","type":"decision","repo":null,
    "title":"bcr-dec10-grill","question":"Shall APP-5861 be built as recommended?","from_status":true,
    "allow_freeform":true,"context":{"task":"bcr-dec10-grill","reason":$r},
    "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  expect_flagged_build "$home" "$data" status.bcr.grill-bcr-r6 "options (the reason lists 3 Option marks but the card offers only a default yes/no" \
    "a status card whose Option marks became yes/no"

  write_valid_payload "$data"
  jq --arg r "$reason" '.captains_call += [{"key":"status.aegis.default","type":"decision","repo":null,
    "title":"aegis-release-mrs","question":"Ship today'"'"'s release?","from_status":true,
    "allow_freeform":true,"context":{"task":"aegis-release-mrs","reason":($r | gsub("Option (?<l>[abc])"; "Option \(.l | ascii_upcase)"))},
    "options":[]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  expect_flagged_build "$home" "$data" status.aegis.default "options (the reason lists 3 Option marks but the card offers no options" \
    "a status card whose Option marks became no options"

  write_valid_payload "$data"
  jq --arg r "$reason" '.captains_call += [{"key":"status.bcr.grill-bcr-r6","type":"decision","repo":null,
    "title":"bcr-dec10-grill","question":"Shall APP-5861 be built as recommended?","from_status":true,
    "allow_freeform":true,"context":{"task":"bcr-dec10-grill","reason":$r},
    "options":[{"value":"option-a","label":"Yes, one ticket"},{"value":"option-b","label":"Yes, with your changes"},
               {"value":"option-c","label":"As a, but book every payment"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "a card whose Option marks were read did not build: $out"
  assert_not_contains "$out" "undecided-card: status.bcr.grill-bcr-r6" "a card whose Option marks were read was held back: $out"
  pass "the board holds back a card whose Option marks were not read and builds it once they are"
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

# A card lists each link once. Two spellings of one url across `links` and
# `pr_url` that differ only by a trailing slash or a #fragment, or one url
# repeated in `links`, hold the card back naming that link; a `pr_url` repeated
# exactly in `links`, which the board shows once, does not.
test_build_flags_a_card_listing_a_link_twice() {
  local home data rc out
  home=$(make_home duplicate-links)
  data="$home/payload.json"
  write_valid_payload "$data"
  jq '.captains_call += [
    {"key":"slash-and-fragment","type":"decision","repo":"cd","title":"Apply the merge?",
     "question":"Apply cd-948 now?","options":[{"value":"apply","label":"Apply"},{"value":"wait","label":"Wait"}],
     "pr_url":"https://gitlab.com/example/cd/-/merge_requests/948",
     "links":[{"url":"https://gitlab.com/example/cd/-/merge_requests/948/","label":"MR 948"},
              {"url":"https://gitlab.com/example/cd/-/merge_requests/948#note_1","label":"MR 948 (2)"}]},
    {"key":"repeated-in-links","type":"decision","repo":"cd","title":"Keep the job?",
     "question":"Keep the nightly job?","options":[{"value":"keep","label":"Keep"},{"value":"drop","label":"Drop"}],
     "links":[{"url":"https://example.org/runbook","label":"Runbook"},
              {"url":"https://example.org/runbook","label":"Runbook (2)"}]},
    {"key":"pr-url-echoed","type":"decision","repo":"cd","title":"Ship it?",
     "question":"Ship the image today?","options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}],
     "pr_url":"https://gitlab.com/example/cd/-/merge_requests/950",
     "links":[{"url":"https://gitlab.com/example/cd/-/merge_requests/950","label":"MR 950"},
              {"url":"https://gitlab.com/example/cd/-/merge_requests/951","label":"MR 951"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "cards listing a link twice stopped the whole board: $out"
  assert_contains "$out" "undecided-card: slash-and-fragment: duplicate link (https://gitlab.com/example/cd/-/merge_requests/948 is listed more than once: keep one)" \
    "spellings differing by a trailing slash or fragment were not named as one duplicate link: $out"
  assert_contains "$out" "undecided-card: repeated-in-links: duplicate link (https://example.org/runbook is listed more than once: keep one)" \
    "a url repeated in links was not named: $out"
  assert_not_contains "$out" "pr-url-echoed" "a pr_url echoed exactly in links was flagged: $out"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.cards_to_fix[].key] | sort) == ["repeated-in-links", "slash-and-fragment"]
    and ([.captains_call[] | select(.key == "pr-url-echoed")] | length) == 1
  ' >/dev/null || fail "the board did not hold back exactly the duplicate-link cards: $(extract_payload "$home/.lavish/bearings-board.html" | jq -c '{call: [.captains_call[].key], fix: .cards_to_fix}')"
  pass "build holds back a card listing one link more than once, after normalising trailing slashes and fragments"
}

# The real case: helm-charts !772 merged at 14:41Z and a card asking for its
# review was written at 14:47Z. A card naming a PR/MR the forge reads merged or
# closed is held back; an open one, or one whose read fails, stays. The second
# real case: workload-pruner's next-round hold was held back for its task's
# recorded pr= (an earlier, merged round) that the hold never named, so only
# `links` is judged and a card's `pr_url` alone never names it.
test_build_flags_a_card_naming_a_merged_or_closed_mr() {
  local home data rc out
  home=$(make_home merged-link)
  data="$home/payload.json"
  write_valid_payload "$data"
  printf '{"state":"merged"}\n' > "$home/forge/gitlab-gitlab.com_example_helm-charts-772"
  printf '{"state":"closed"}\n' > "$home/forge/gitlab-gitlab.com_example_helm-charts-773"
  printf '{"state":"opened"}\n' > "$home/forge/gitlab-gitlab.com_example_helm-charts-774"
  jq '.captains_call += [
    {"key":"review-772","type":"decision","repo":"helm-charts","title":"Review !772?",
     "question":"Review helm-charts !772?","options":[{"value":"ok","label":"Approve"},{"value":"no","label":"Reject"}],
     "links":[{"url":"https://gitlab.com/example/helm-charts/-/merge_requests/772#note_9","label":"MR 772"}]},
    {"key":"review-773","type":"decision","repo":"helm-charts","title":"Review !773?",
     "question":"Review helm-charts !773?","options":[{"value":"ok","label":"Approve"},{"value":"no","label":"Reject"}],
     "pr_url":"https://gitlab.com/example/helm-charts/-/merge_requests/774",
     "links":[{"url":"https://gitlab.com/example/helm-charts/-/merge_requests/773","label":"MR 773"}]},
    {"key":"review-774","type":"decision","repo":"helm-charts","title":"Review !774?",
     "question":"Review helm-charts !774?","options":[{"value":"ok","label":"Approve"},{"value":"no","label":"Reject"}],
     "pr_url":"https://gitlab.com/example/helm-charts/-/merge_requests/774"},
    {"key":"review-775","type":"decision","repo":"helm-charts","title":"Review !775?",
     "question":"Review helm-charts !775?","options":[{"value":"ok","label":"Approve"},{"value":"no","label":"Reject"}],
     "pr_url":"https://gitlab.com/example/helm-charts/-/merge_requests/775"},
    {"key":"next-round","type":"decision","repo":"helm-charts","title":"Which bound next?",
     "question":"Measure with the tighter bound?","options":[{"value":"ok","label":"Yes"},{"value":"no","label":"No"}],
     "pr_url":"https://gitlab.com/example/helm-charts/-/merge_requests/772",
     "links":[{"url":"https://example.org/measurements","label":"Measurements"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(FM_BEARINGS_BOARD_PR_TIMEOUT=5 run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "a card naming a merged MR stopped the whole board: $out"
  assert_contains "$out" "undecided-card: review-772: names https://gitlab.com/example/helm-charts/-/merge_requests/772, already merged, and asks to review or merge it" \
    "a card linking a merged MR was not named: $out"
  assert_contains "$out" "undecided-card: review-773: names https://gitlab.com/example/helm-charts/-/merge_requests/773, already closed, and asks to review or merge it" \
    "a card linking a closed MR was not named: $out"
  assert_not_contains "$out" "review-774" "a card linking an open MR was flagged: $out"
  assert_not_contains "$out" "review-775" "a card whose MR read failed was flagged: $out"
  assert_not_contains "$out" "next-round" "a card was flagged for its task's recorded merged pr_url, which the hold never names: $out"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.cards_to_fix[].key] | sort) == ["review-772", "review-773"]
    and ([.captains_call[] | select(.key == "review-774" or .key == "review-775" or .key == "next-round")] | length) == 3
  ' >/dev/null || fail "the board did not hold back exactly the merged and closed cards: $(extract_payload "$home/.lavish/bearings-board.html" | jq -c '{call: [.captains_call[].key], fix: .cards_to_fix}')"
  set +e; out=$(FM_BEARINGS_BOARD_PR_CHECK=0 run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "the build failed with the PR check off: $out"
  assert_not_contains "$out" "already merged" "the PR check ran although it was switched off: $out"
  pass "build holds back a card linking a merged or closed MR and leaves an open or unreadable one, or one only its task's recorded pr_url names"
}

# The real case: runner-image's rollout hold asked whether to roll a merged
# change out to the cluster and linked its merged PR, and the board held it back
# as "already merged", so the captain never saw it. A merged or closed link names
# a card only when the card asks to review or merge that PR/MR; a rollout or
# other post-merge question linking its merged PR reaches the captain.
test_build_shows_a_post_merge_call_linking_its_merged_mr() {
  local home data rc out
  home=$(make_home merged-rollout)
  data="$home/payload.json"
  write_valid_payload "$data"
  printf '{"state":"merged"}\n' > "$home/forge/gitlab-gitlab.com_example_runner-image-86"
  printf '{"state":"merged"}\n' > "$home/forge/gitlab-gitlab.com_example_runner-image-87"
  jq '.captains_call += [
    {"key":"runner-store-gc-rollout","type":"decision","repo":"runner-image",
     "title":"Roll the nightly store-collector window out to the runners cluster",
     "question":"Roll the nightly store-collector window out to the runners cluster, restarting the store daemon at a quiet hour after 22:00 UTC tonight?",
     "about":"Merged PR 86 runs clean-up 01:00-05:00 UTC; the rollout is a hand-applied cluster step.",
     "options":[{"value":"yes-tonight","label":"Yes, roll it out after 22:00 UTC tonight (recommended)"},
                {"value":"no","label":"Not now, keep it merged but unapplied"}],
     "links":[{"url":"https://gitlab.com/example/runner-image/-/merge_requests/86","label":"merged PR"}]},
    {"key":"merge-87","type":"decision","repo":"runner-image","title":"Runner image follow-up",
     "question":"Merge runner-image !87 now?","options":[{"value":"go","label":"Go"},{"value":"wait","label":"Wait"}],
     "links":[{"url":"https://gitlab.com/example/runner-image/-/merge_requests/87","label":"MR 87"}]},
    {"key":"reviewed-86","type":"decision","repo":"runner-image","title":"Have you reviewed runner-image !86?",
     "options":[{"value":"done","label":"Reviewed"},{"value":"not-done","label":"Not yet"}],
     "links":[{"url":"https://gitlab.com/example/runner-image/-/merge_requests/86","label":"MR 86"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(FM_BEARINGS_BOARD_PR_TIMEOUT=5 run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "a post-merge call stopped the whole board: $out"
  assert_not_contains "$out" "runner-store-gc-rollout" "a rollout call linking its merged PR was held back: $out"
  assert_contains "$out" "undecided-card: merge-87: names https://gitlab.com/example/runner-image/-/merge_requests/87, already merged, and asks to review or merge it" \
    "a call asking to merge a merged MR was not held back: $out"
  assert_contains "$out" "undecided-card: reviewed-86: names https://gitlab.com/example/runner-image/-/merge_requests/86, already merged, and asks to review or merge it" \
    "a call asking whether a merged MR was reviewed was not held back: $out"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.cards_to_fix[].key] | sort) == ["merge-87", "reviewed-86"]
    and ([.captains_call[] | select(.key == "runner-store-gc-rollout")] | length) == 1
  ' >/dev/null || fail "the board did not show the rollout call and hold back only the review and merge calls: $(extract_payload "$home/.lavish/bearings-board.html" | jq -c '{call: [.captains_call[].key], fix: .cards_to_fix}')"
  pass "build shows a post-merge call linking its merged MR and holds back a call asking to review or merge a merged MR"
}

# The real case: a profile switch took jq off PATH for a fraction of a second
# about every 20 minutes, and the board build failed. Here jq vanishes after its
# first use in the first attempt - the attempt's shell still holds the old path,
# as it did on the real profile switch - so that attempt fails on a missing
# binary and the one retry, which finds jq again, builds the board.
test_build_retries_once_when_a_binary_vanishes() {
  local home data rc out real
  home=$(make_home vanishing-jq)
  data="$home/payload.json"
  write_valid_payload "$data"
  real=$(command -v jq)
  cat > "$home/fakebin/jq" <<SH
#!/usr/bin/env bash
rm -f -- "\$0"
exec "$real" "\$@"
SH
  chmod +x "$home/fakebin/jq"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ ! -e "$home/fakebin/jq" ] || fail "the vanishing jq was never run"
  [ "$rc" -eq 0 ] || fail "the build did not survive jq vanishing once: $out"
  assert_contains "$out" "fakebin/jq: No such file or directory" "the first attempt did not fail on the missing jq: $out"
  assert_contains "$out" "a binary was missing during the build; retrying once" "the build did not say it was retrying: $out"
  [ -f "$home/.lavish/bearings-board.html" ] || fail "the retried build wrote no board"
  pass "build retries once, after a pause, when a binary vanishes during the first attempt"
}

# An ordinary failure is final at once: a payload that is not JSON is refused
# by one attempt, with no retry.
test_build_does_not_retry_an_ordinary_failure() {
  local home data rc out
  home=$(make_home no-retry)
  data="$home/payload.json"
  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a payload that is not JSON built"
  assert_contains "$out" "board data is not valid JSON" "the refusal did not name the payload: $out"
  assert_not_contains "$out" "retrying once" "an ordinary failure was retried: $out"
  [ "$(printf '%s\n' "$out" | grep -c 'board data is not valid JSON')" -eq 1 ] \
    || fail "an ordinary failure ran more than one attempt: $out"
  pass "build does not retry a failure that is not a missing binary"
}

# A live page about a task links that task's card in place, whether its record
# names the task (fm-board-page.sh open --task) or the card names the page id;
# a Waiting or Charted row about it gains the page in its expandable context.
# A card that links a live page does not also show its raw page:<id> token: the
# token reads "the linked page", or the "<title>" page when the card links more.
test_a_linked_page_token_leaves_the_card_text() {
  local home data dir out id
  home=$(make_home page-token)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null 2>&1 || fail "the first build failed"
  for id in understand-mr821 mr821-diff; do
    dir=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-board-page.sh" dir "$id") \
      || fail "the page folder was not given"
    printf '<html></html>\n' > "$dir/page.html"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_BOARD_PAGE_REFRESH=true \
      "$ROOT/bin/fm-board-page.sh" open "$id" --title "Page $id" >/dev/null \
      || fail "the page $id did not open"
  done
  jq '.captains_call += [
    {"key":"mr821","type":"decision","repo":"aegis","title":"Which held !821 review comments do you want me to post?",
     "about":"Read page:understand-mr821 first, and answer its 8 why-questions in place if you want them checked.",
     "options":[{"value":"a","label":"Post all"},{"value":"b","label":"Post none"}]},
    {"key":"mr821-two","type":"decision","repo":"aegis","title":"Post the !821 comments?",
     "about":"Read page:understand-mr821 and page:mr821-diff first.",
     "options":[{"value":"a","label":"Post all"},{"value":"b","label":"Post none"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "the cards about live pages were refused: $out"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.captains_call[] | select(.key == "mr821") | .about]
       == ["Read the linked page first, and answer its 8 why-questions in place if you want them checked."])
    and ([.captains_call[] | select(.key == "mr821") | .links[].page] == ["understand-mr821"])
    and ([.captains_call[] | select(.key == "mr821-two") | .about]
       == ["Read the \"Page understand-mr821\" page and the \"Page mr821-diff\" page first."])
  ' >/dev/null || fail "a raw page token stayed on a card that links the page: $(extract_payload "$home/.lavish/bearings-board.html" | jq -c '[.captains_call[] | select(.key | startswith("mr821")) | {key, about, links}]')"
  pass "a linked page token leaves the card text"
}

# The understand page a hold's own task status names (page:understand-mr821)
# links the hold card that says "open on the understand page", though the page
# record names no task; another task's status naming it, a card that does not
# speak of that page, and an ended page give no link.
test_a_page_its_task_status_names_links_the_hold_card() {
  local home data dir out id payload
  home=$(make_home page-named-by-status)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null 2>&1 || fail "the first build failed"
  for id in understand-mr821 understand-mr900; do
    dir=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-board-page.sh" dir "$id") \
      || fail "the page folder was not given"
    printf '<html></html>\n' > "$dir/page.html"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_BOARD_PAGE_REFRESH=true \
      "$ROOT/bin/fm-board-page.sh" open "$id" --title "Understand: MR !${id#understand-mr}" >/dev/null \
      || fail "the page $id did not open"
  done
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_BOARD_PAGE_REFRESH=true \
    "$ROOT/bin/fm-board-page.sh" end understand-mr900 >/dev/null 2>&1 || fail "the page understand-mr900 did not end"
  printf 'needs-decision [key=post-821] [at=1795400000]: understand page ready: page:understand-mr821 (8 why-questions)\n' \
    > "$home/state/aegis-821-review.status"
  printf 'needs-decision [key=post-900] [at=1795400000]: understand page ready: page:understand-mr900\n' \
    > "$home/state/aegis-900-review.status"
  printf 'done [at=1795400000]: rebuilt the board; page:understand-mr821 checked\n' > "$home/state/board-keeper.status"
  jq '.captains_call += [
    {"key":"aegis-821-review","type":"decision","repo":"aegis","title":"Which held !821 review comments do you want me to post?",
     "about":"n2 is correct and n3 partly correct; n4 to n11 are open on the understand page. Recommended: post #3, #4 and #6 to #14 and drop #1, #2 and #5.",
     "options":[{"value":"a","label":"Post the recommended set"},{"value":"b","label":"Post none"}]},
    {"key":"board-keeper","type":"decision","repo":"firstmate","title":"Keep the board tidy?",
     "about":"The board was rebuilt.",
     "options":[{"value":"a","label":"Yes"},{"value":"b","label":"No"}]},
    {"key":"aegis-900-review","type":"decision","repo":"aegis","title":"Which held !900 review comments do you want me to post?",
     "about":"They are open on the understand page.",
     "options":[{"value":"a","label":"All"},{"value":"b","label":"None"}]},
    {"key":"aegis-821-other","type":"decision","repo":"aegis","title":"Rebase !821 now?",
     "about":"The branch is behind main; its comments are on the understand page.",
     "options":[{"value":"a","label":"Yes"},{"value":"b","label":"No"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "the build was refused: $out"
  payload=$(extract_payload "$home/.lavish/bearings-board.html")
  links() { jq -c --arg k "$1" '[.captains_call[] | select(.key == $k) | (.links // [])[] | .page // empty]' <<<"$payload"; }
  assert_equals '["understand-mr821"]' "$(links aegis-821-review)" "the hold its task status names the page for links it"
  assert_equals '[]' "$(links board-keeper)" "a card whose task status names the page but whose text does not speak of it"
  assert_equals '[]' "$(links aegis-900-review)" "an ended page is never linked"
  assert_equals '[]' "$(links aegis-821-other)" "a card whose task status does not name the page"
  jq -e '[.. | objects | select(has("named_by"))] | length == 0' <<<"$payload" >/dev/null \
    || fail "the internal named_by field reached the board"
  pass "a page its task status names links the hold card that speaks of it"
}

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

# A card whose text names a live page by its title links that page in place,
# as the real mr887-comments line names "board tab 'Architecture: MR 887
# net-only claims'" for a page recorded with no task.
test_a_card_that_names_a_page_title_links_that_page() {
  local home data dir out
  home=$(make_home page-title-link)
  data="$home/payload.json"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null 2>&1 || fail "the first build failed"
  dir=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-board-page.sh" dir architecture-887) \
    || fail "the page folder was not given"
  printf '<html></html>\n' > "$dir/page.html"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_BOARD_PAGE_REFRESH=true \
    "$ROOT/bin/fm-board-page.sh" open architecture-887 --title "Architecture: MR 887 net-only claims" >/dev/null \
    || fail "the page did not open"
  jq '.captains_call += [
    {"key":"status.aegis-887-review.mr887-comments","type":"decision","repo":"aegis","title":"aegis-887-review: Which held comments should go on MR 887?",
     "about":"Verdict: request changes, small. Report: /home/rob/repos/firstmate/data/aegis-887-review/report.md Architecture page: board tab '"'"'Architecture: MR 887 net-only claims'"'"'.",
     "options":[{"value":"option-a","label":"Post 1, 2, 3, 4, 5 with request changes"},{"value":"option-d","label":"Post none"}],
     "context":{"task":"aegis-887-review"}},
    {"key":"other-arch","type":"decision","repo":"aegis","title":"Architecture review",
     "question":"Approve the architecture?",
     "options":[{"value":"yes","label":"Yes"},{"value":"no","label":"No"}]}]' \
    "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data" 2>&1) || fail "the card naming a page title was refused: $out"
  extract_payload "$home/.lavish/bearings-board.html" | jq -e '
    ([.captains_call[] | select(.key == "status.aegis-887-review.mr887-comments") | .links[]]
       == [{"page":"architecture-887","label":"Architecture: MR 887 net-only claims"}])
    and ([.captains_call[] | select(.key == "other-arch") | .links // [] | .[] | select(has("page"))] == [])
  ' >/dev/null || fail "the card naming the page title did not link it, or a card naming only a word of it did: $(extract_payload "$home/.lavish/bearings-board.html" | jq -c '[.captains_call[] | {key, links}]')"
  pass "a card that names a live page by its title links that page in place"
}

test_path_is_stable_and_home_scoped
test_build_flags_a_card_without_recorded_choices_or_a_link
test_build_flags_a_card_listing_a_link_twice
test_build_flags_a_card_naming_a_merged_or_closed_mr
test_build_shows_a_post_merge_call_linking_its_merged_mr
test_build_retries_once_when_a_binary_vanishes
test_build_does_not_retry_an_ordinary_failure
test_build_flags_a_card_whose_option_marks_were_not_read
test_build_flags_a_card_whose_lettered_choices_were_not_read
test_a_page_about_a_task_links_its_card_and_context_in_place
test_a_linked_page_token_leaves_the_card_text
test_a_page_its_task_status_names_links_the_hold_card
test_a_card_that_names_a_page_title_links_that_page
test_build_flags_a_card_with_no_explicit_decision_and_builds_the_rest
test_build_reads_a_question_anywhere_in_the_reason
test_build_flags_a_heading_that_packs_several_calls
test_build_flags_a_cut_heading_and_a_dangling_background
test_build_accepts_explicit_decisions_and_in_person_actions
test_build_refuses_malformed_payloads_before_touching_the_board
test_a_refusal_names_the_first_failing_item_and_its_fields
test_charted_kind_is_optional_and_accepts_both_values
test_an_underway_row_may_link_its_mr
test_build_lists_live_pages_and_refuses_payload_pages
test_build_links_a_markdown_only_page_to_its_page_md
test_build_flags_a_card_whose_page_missed_its_workers_last_report
test_build_keeps_a_card_whose_page_was_rebuilt_at_its_workers_last_report
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
