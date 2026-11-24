#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-board-payload.sh: the same snapshot always
# yields the same fm-bearings-board.v1 payload, the payload satisfies the board
# validator with no authored copy, and the optional copy overlay can refine a
# card but never change the payload's shape.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GEN="$ROOT/bin/fm-bearings-board-payload.sh"
BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-payload)

# Forge stubs: every PR/MR lookup the payload makes reads a fixture under
# $FORGE_DIR keyed by provider, project and number, and fails when none exists,
# so no test reaches a real forge. A fixture whose content is "hang" sleeps
# past the lookup bound.
FORGE_DIR="$TMP_ROOT/forge-none"
FORGE_BIN="$TMP_ROOT/forgebin"
mkdir -p "$FORGE_DIR" "$FORGE_BIN"
cat > "$FORGE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# The viewer's login and a PR's reviews, for the captain's own approval.
f=''
case "${1-} ${2-}" in
  "api user") f="$FORGE_DIR/github-user" ;;
  "api --paginate")
    f=${4#repos/}; f=${f%/reviews}; f="$FORGE_DIR/github-$(printf '%s' "$f" | sed 's#/pulls/#-#; s#/#-#').reviews" ;;
esac
if [ -n "$f" ]; then [ -f "$f" ] && cat "$f"; exit; fi
owner='' repo='' number=''
for a in "$@"; do
  case "$a" in owner=*) owner=${a#owner=} ;; repo=*) repo=${a#repo=} ;; number=*) number=${a#number=} ;; esac
done
f="$FORGE_DIR/github-$owner-$repo-$number"
[ -f "$f" ] || exit 1
[ "$(cat "$f")" != hang ] || { sleep 30; exit 1; }
cat "$f"
STUB
cat > "$FORGE_BIN/glab" <<'STUB'
#!/usr/bin/env bash
if [ "${1-}" = api ]; then
  case "${2-}" in
    user) f="$FORGE_DIR/gitlab-user" ;;
    projects/*/merge_requests/*/approvals)
      f=${2#projects/}; f=${f%/approvals}
      f="$FORGE_DIR/gitlab-${GITLAB_HOST}_$(printf '%s' "$f" | sed 's#%2F#_#g; s#/merge_requests/#-#').approvals" ;;
    *) exit 1 ;;
  esac
  [ -f "$f" ] && cat "$f"
  exit
fi
number=$3 project=''
while [ "$#" -gt 0 ]; do [ "$1" = -R ] && project=$2; shift; done
f="$FORGE_DIR/gitlab-$(printf '%s' "${project#https://}" | tr '/' '_')-$number"
[ -f "$f" ] || exit 1
[ "$(cat "$f")" != hang ] || { sleep 30; exit 1; }
cat "$f"
STUB
cat > "$FORGE_BIN/tea" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  login) printf '[{"name":"fj","url":"https://forge.example"}]\n'; exit 0 ;;
  api) repo='' path=''
       while [ "$#" -gt 0 ]; do [ "$1" = --repo ] && repo=$2; path=$1; shift; done
       case "$path" in
         /user) f="$FORGE_DIR/forgejo-user" ;;
         */reviews) n=${path%/reviews}; f="$FORGE_DIR/forgejo-$(printf '%s' "$repo" | tr '/' '_')-${n##*/}.reviews" ;;
         *) f="$FORGE_DIR/forgejo-$(printf '%s' "$repo" | tr '/' '_')-${path##*/}" ;;
       esac
       [ -f "$f" ] || exit 1
       cat "$f" ;;
  *) exit 1 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$FORGE_BIN/gh-axi"
chmod +x "$FORGE_BIN/gh" "$FORGE_BIN/glab" "$FORGE_BIN/tea" "$FORGE_BIN/gh-axi"
export FORGE_DIR
PATH="$FORGE_BIN:$PATH"
export PATH

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A snapshot exercising every mapping: a decision with clean title/reason, a
# legacy decision row with only a fused summary, a recorded PR, a done row that
# must not surface as underway, landed rows with and without a PR artifact,
# queued/held/synthetic gates, and both secondmate warning kinds.
write_snapshot() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings.v1",
  "home": "/fixture/home",
  "generated": "2026-11-06T07:34:00Z",
  "prs": "unchecked",
  "decisions_open": [
    {"id": "alpha-fix", "key": "alpha-fix", "verb": "captain-hold",
     "title": "Pick the alpha retry policy", "reason": "two options measured",
     "summary": "Pick the alpha retry policy: two options measured", "owner": "(main)"},
    {"id": "beta/old-row", "key": "old-row", "verb": "captain-hold",
     "summary": "Legacy fused summary", "owner": "beta"}
  ],
  "in_flight": [
    {"id": "t1", "name": "Build the thing", "repo": "alpha", "state": "working", "doing": "writing tests", "kind": "ship"},
    {"id": "t2", "name": "-", "repo": null, "state": "done", "doing": "-", "kind": "ship"},
    {"id": "alpha-fix", "name": "Alpha fix", "repo": "alpha", "state": "parked", "doing": "MR !3: waiting", "kind": "ship",
     "pr_url": "https://gitlab.example.com/acme/alpha/-/merge_requests/3"}
  ],
  "landed": [
    {"id": "l1", "what": "shipped the widget", "artifact": "https://github.com/acme/widgets/pull/7", "owner": "(main)"},
    {"id": "l2", "what": "local landing", "artifact": "-", "owner": "beta"}
  ],
  "recorded_prs": [{"id": "alpha-fix", "url": "https://github.com/acme/alpha/pull/3"}],
  "contributions": {"captain": []},
  "gates": [
    {"id": "plain-queued", "title": "A queued item", "blocked_by": "-", "reason": "-", "owner": "(main)", "filed": "2026-10-30"},
    {"id": "dated-hold", "title": "A dated hold", "blocked_by": "-", "reason": "until 2026-11-14: gate", "owner": "(main)", "filed": "2026-10-31"},
    {"id": "(main-inventory)", "title": "item has no child metadata", "blocked_by": "-", "reason": "main inventory", "owner": "(main)"}
  ],
  "secondmates": [
    {"id": "beta", "state": "no_active_work"},
    {"id": "gamma", "state": "unknown", "reason": "home unreadable"},
    {"id": "delta", "state": "no_active_work"}
  ],
  "secondmate_reconcile": [
    {"id": "delta", "kind": "terminal_in_flight", "ids": ["d-1", "d-2"]},
    {"id": "beta", "kind": null, "ids": []}
  ],
  "omitted": [{"surface": "gates showing 3 of 8", "reveal": "--all-queued"}]
}
EOF
}

# The board validator runs before the template is read, so a missing template
# separates "the payload failed validation" from "validation passed".
validates() {  # <payload>
  local out
  out=$(FM_BEARINGS_BOARD_TEMPLATE="$TMP_ROOT/absent-template.html" FM_HOME="$TMP_ROOT/vhome" \
    "$BOARD" build "$1" 2>&1) || true
  case "$out" in
    *"does not satisfy"*|*"not valid JSON"*) return 1 ;;
    *"template is missing"*) return 0 ;;
    *) printf 'unexpected build output: %s\n' "$out" >&2; return 1 ;;
  esac
}

test_zero_copy_payload_satisfies_the_board_validator() {
  local snap out
  snap="$TMP_ROOT/snap.json"
  write_snapshot "$snap"
  out="$TMP_ROOT/payload.json"
  "$GEN" --snapshot "$snap" > "$out" || fail "the generator failed on a valid snapshot"
  validates "$out" || fail "the zero-copy payload did not satisfy the board validator"
  printf '{"schema":"fm-bearings-board.v1"}\n' > "$TMP_ROOT/bad.json"
  validates "$TMP_ROOT/bad.json" && fail "the validator probe accepted a bad payload, so the check is vacuous"
  pass "a zero-copy payload satisfies the board validator"
}

test_the_same_snapshot_yields_the_same_payload() {
  local snap a b
  snap="$TMP_ROOT/snap.json"
  write_snapshot "$snap"
  a=$("$GEN" --snapshot "$snap") || fail "first run failed"
  b=$("$GEN" --snapshot - < "$snap") || fail "second run failed"
  assert_equals "$a" "$b" "the same snapshot produced two different payloads"
  pass "the same snapshot always yields the same payload"
}

test_rows_map_deterministically_from_the_snapshot() {
  local snap p
  snap="$TMP_ROOT/snap.json"
  write_snapshot "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"

  assert_equals "alpha-fix,old-row" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" "captains_call is one card per open decision"
  assert_equals "Pick the alpha retry policy" "$(jq -r '.captains_call[0].title' <<<"$p")" "the card title comes from the clean title field"
  assert_equals "Two options measured" "$(jq -r '.captains_call[0].question' <<<"$p")" "the card leads with the hold reason as its question"
  assert_equals "Legacy fused summary" "$(jq -r '.captains_call[1].title' <<<"$p")" "a row with no title falls back to its summary"
  assert_equals "https://github.com/acme/alpha/pull/3" "$(jq -r '.captains_call[0].pr_url' <<<"$p")" "the recorded PR is attached to its card"
  assert_equals "alpha" "$(jq -r '.captains_call[0].repo' <<<"$p")" "the card repo comes from the recorded PR"
  assert_equals "true" "$(jq -r '[.captains_call[] | .allow_freeform] | all' <<<"$p")" "every generated card takes a freeform answer"
  assert_equals "t1,alpha-fix" "$(jq -r '[.underway[].id] | join(",")' <<<"$p")" "a done row is not underway"
  assert_equals "Build the thing" "$(jq -r '.underway[0].name' <<<"$p")" "underway keeps the projected name"
  assert_equals "https://gitlab.example.com/acme/alpha/-/merge_requests/3" "$(jq -r '.underway[1].pr_url' <<<"$p")" "an underway row keeps the MR it names"
  assert_equals "false" "$(jq '.underway[0] | has("pr_url")' <<<"$p")" "an underway row with no MR carries no link"
  assert_equals "https://github.com/acme/widgets/pull/7" "$(jq -r '.landed[0].pr_url' <<<"$p")" "a landed PR artifact becomes its link"
  assert_equals "widgets" "$(jq -r '.landed[0].repo' <<<"$p")" "a landed PR artifact supplies the repo"
  assert_equals "null" "$(jq -c '.landed[1].repo' <<<"$p")" "a landed row with no PR has no repo"
  assert_equals "false" "$(jq '.prs_live' <<<"$p")" "unchecked PRs are not live"
  assert_equals "5" "$(jq '.charted_more' <<<"$p")" "charted_more counts the gates the snapshot omitted"
  pass "snapshot rows map to cards the same way every run"
}

test_charted_rows_derive_dispatchable_and_warning_from_structure() {
  local snap p
  snap="$TMP_ROOT/snap.json"
  write_snapshot "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "true" "$(jq '.charted[] | select(.id == "plain-queued") | .dispatchable' <<<"$p")" "a gate with no blocker or hold is dispatchable"
  assert_equals "false" "$(jq '.charted[] | select(.id == "dated-hold") | .dispatchable' <<<"$p")" "a held gate is not dispatchable"
  assert_equals "warning" "$(jq -r '.charted[] | select(.id == "main-inventory") | .kind' <<<"$p")" "a synthetic gate becomes a warning row"
  assert_equals "warning,warning" \
    "$(jq -r '[.charted[] | select(.id | test("^(reconcile|unavailable)-")) | .kind] | join(",")' <<<"$p")" \
    "a mismatched home and an unavailable home each get one warning row"
  assert_equals "false" "$(jq '[.charted[] | select(.kind == "warning") | .dispatchable] | any' <<<"$p")" "no warning row is dispatchable"
  assert_equals "" "$(jq -r '.charted[] | select(.id == "plain-queued") | .reason' <<<"$p")" "a dash reason is blank"
  pass "charted rows derive their kind and dispatchable flag from structure"
}

test_copy_overlay_refines_cards_and_keeps_the_payload_valid() {
  local snap copy p
  snap="$TMP_ROOT/snap.json"
  copy="$TMP_ROOT/copy.json"
  write_snapshot "$snap"
  cat > "$copy" <<'EOF'
{
  "captains_call": {
    "alpha-fix": {"title": "Alpha retry: pick one", "options": [{"value": "fast", "label": "Fast"}], "recommend_value": "fast"},
    "old-row": null
  },
  "captains_call_extra": [
    {"key": "merge-widgets", "type": "merge", "repo": "widgets", "title": "Merge widgets 7",
     "risk": "low", "pr_url": "https://github.com/acme/widgets/pull/7",
     "options": [{"value": "merge", "label": "Merge"}]}
  ],
  "charted": {"plain-queued": {"title": "Queued, reworded"}}
}
EOF
  p=$("$GEN" --snapshot "$snap" --copy "$copy") || fail "the generator refused a valid overlay"
  assert_equals "alpha-fix,merge-widgets" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" "a null overlay drops its card and extra cards append"
  assert_equals "Alpha retry: pick one" "$(jq -r '.captains_call[0].title' <<<"$p")" "the overlay title wins"
  assert_equals "Two options measured" "$(jq -r '.captains_call[0].question' <<<"$p")" "unlisted fields keep the generated value"
  assert_equals "Queued, reworded" "$(jq -r '.charted[] | select(.id == "plain-queued") | .title' <<<"$p")" "the overlay can reword a charted row"
  printf '%s\n' "$p" > "$TMP_ROOT/with-copy.json"
  validates "$TMP_ROOT/with-copy.json" || fail "the payload with a copy overlay did not satisfy the board validator"
  pass "a copy overlay refines cards and keeps the payload valid"
}

test_copy_overlay_cannot_change_the_payload_shape() {
  local snap copy out rc
  snap="$TMP_ROOT/snap.json"
  copy="$TMP_ROOT/bad-copy.json"
  write_snapshot "$snap"

  printf '{"captains_call":{"alpha-fix":{"sneaky":"x"}}}\n' > "$copy"
  set +e; out=$("$GEN" --snapshot "$snap" --copy "$copy" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an overlay with an unknown field was accepted"
  assert_contains "$out" "unknown field" "the unknown-field refusal did not say why: $out"

  printf '{"extras":{}}\n' > "$copy"
  set +e; out=$("$GEN" --snapshot "$snap" --copy "$copy" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an overlay with an unknown section was accepted"
  assert_contains "$out" "unknown section" "the unknown-section refusal did not say why: $out"

  printf '{"captains_call":{"alpha-fix":{"options":[{"value":"reconcile","label":"R"}]}}}\n' > "$copy"
  set +e; out=$("$GEN" --snapshot "$snap" --copy "$copy" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an overlay authoring the reconcile option was accepted"
  assert_contains "$out" "reconcile" "the reconcile refusal did not name the value: $out"

  printf '{"schema":"other"}\n' > "$TMP_ROOT/not-a-snapshot.json"
  set +e; out=$("$GEN" --snapshot "$TMP_ROOT/not-a-snapshot.json" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-snapshot input was accepted"
  pass "a copy overlay cannot add fields, sections, or the reconcile option"
}

# A captain-waiting item firstmate never held: a contribution awaiting merge
# approval has no hold, so the snapshot carries it only in contributions.captain.
test_an_unheld_captain_contribution_becomes_a_link_card() {
  local snap p out
  snap="$TMP_ROOT/snap-unheld.json"
  write_snapshot "$TMP_ROOT/snap.json"
  jq '.contributions.captain = [
        {task: "alpha-fix", url: "https://github.com/acme/alpha/pull/3", kind: "pr",
         reason: "checks green; merge approval needed", hold: "alpha-fix"},
        {task: "gamma-ship", url: "https://github.com/acme/gamma/pull/12", kind: "pr",
         reason: "checks green; merge approval needed"},
        {task: "same-pr", url: "https://github.com/acme/alpha/pull/3", kind: "pr",
         reason: "checks green; merge approval needed"}]' "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "alpha-fix,old-row,contribution.gamma-ship" \
    "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" \
    "an unheld captain contribution is carded once, and a held or duplicate one adds nothing"
  out=$(jq -c '.captains_call[2] | {type, repo, title, pr_url, about}' <<<"$p")
  assert_equals '{"type":"decision","repo":"gamma","title":"gamma #12","pr_url":"https://github.com/acme/gamma/pull/12","about":"checks green; merge approval needed"}' \
    "$out" "the link card did not carry the contribution's page"
  printf '%s\n' "$p" > "$TMP_ROOT/unheld.json"
  validates "$TMP_ROOT/unheld.json" || fail "a payload with an unheld contribution card did not satisfy the board validator"
  pass "a captain contribution with no hold becomes a link card the validator accepts"
}

# The build refuses a card that does not state its decision. The generator's
# own cards - a pending contribution and a ready review page - must always pass,
# while an authored hold whose reason is not a question is still refused.
# lavish-axi is a stub that fails, so the build stops after the check and
# never reaches a real Lavish server.
build_checks() {  # <payload>
  local home="$TMP_ROOT/build-home" stub="$TMP_ROOT/no-lavish"
  mkdir -p "$home/state" "$home/data" "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/lavish-axi"
  chmod +x "$stub/lavish-axi"
  PATH="$stub:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" "$BOARD" build --no-reopen "$1" 2>&1 || true
}

# The payload the last build_checks published for the board page.
built_data() {
  local js
  js=$(cat "$TMP_ROOT/build-home/.lavish/bearings-board.data.js") || fail "the build published no board data"
  js=${js#window.FM_BEARINGS_BOARD_DATA = }
  printf '%s\n' "${js%;}"
}

test_the_generators_own_cards_pass_the_build_decision_check() {
  local snap p out
  snap="$TMP_ROOT/snap-own-cards.json"
  write_snapshot "$TMP_ROOT/snap.json"
  jq '.decisions_open = [
        {id: "rv", key: "review.rv", verb: "review-ready", source: "review-page", task: "rv",
         title: "Understand request",
         reason: "report ready; understand board live at http://dev-1.tailf848b0.ts.net:4387/session/5e96b7b8f3b4f9db",
         owner: "(main)"}]
      | .contributions.captain = [
        {task: "gamma-ship", url: "https://github.com/acme/gamma/pull/12", kind: "pr",
         reason: "checks green; merge approval needed"}]' "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "review.rv,contribution.gamma-ship" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" \
    "the snapshot did not produce the review and contribution cards"
  printf '%s\n' "$p" > "$TMP_ROOT/own-cards.json"
  out=$(build_checks "$TMP_ROOT/own-cards.json")
  assert_not_contains "$out" "undecided-card" "the build refused a card the generator made itself: $out"
  assert_contains "$out" "board: " "the build did not get past the decision check: $out"

  # An authored hold whose reason is a statement is still refused by key.
  "$GEN" --snapshot "$TMP_ROOT/snap.json" > "$TMP_ROOT/authored.json" || fail "the generator failed"
  out=$(build_checks "$TMP_ROOT/authored.json")
  assert_contains "$out" "undecided-card: alpha-fix: missing question" \
    "an authored hold with no question was not refused: $out"
  pass "a pending contribution and a review page build cleanly, and an authored non-question hold is still refused"
}

# A hold that recorded its choices and links (fm-captain-hold.sh hold --option
# and --link) shows exactly those on its card, a page:<id> link as a board page,
# and every board item carries the context it expands to show in place.
test_a_hold_with_recorded_options_and_links_puts_them_on_its_card() {
  local snap p out
  snap="$TMP_ROOT/snap-recorded.json"
  write_snapshot "$TMP_ROOT/snap.json"
  jq '.decisions_open = [
        {id: "cd-grill", key: "cd-grill", verb: "captain-hold", owner: "(main)",
         title_full: "Pick the CD grill outcome",
         reason_full: "Which grill outcome do we keep? (1) keep both (2) drop the second",
         choices: {options: [{value: "keep", label: "Keep both"}, {value: "drop", label: "Drop the second"}],
                   links: [{target: "page:cd-697-698-grill", label: "Grill page"},
                           {target: "https://github.com/acme/alpha/pull/9", label: ""}],
                   free_text: false, no_link: false},
         answers: [{at: "2026-11-10T09:00:00Z", mode: "captain", text: "keep it parked until Friday"}],
         notes: ["Grill ran on both MRs."],
         report_path: "data/cd-grill/report.md"},
        {id: "wait-x", key: "wait-x", verb: "captain-hold", owner: "(main)",
         title_full: "Relock uv", reason_full: "captain parked: wait for the upstream release",
         answers: [{at: "2026-11-01T08:00:00Z", mode: "captain", text: "park it until upstream ships"}],
         notes: ["Relock after uv 0.9."]}]
      | .gates = [{id: "plain-queued", title: "A queued item", blocked_by: "-", reason: "-", owner: "(main)",
                   filed: "2026-10-30", title_full: "A queued item in full", reason_full: null,
                   answers: [], notes: ["Start after the audit."], report_path: null}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals '[{"label":"Keep both","value":"keep"},{"label":"Drop the second","value":"drop"}]' \
    "$(jq -cS '[.captains_call[] | select(.key == "cd-grill") | .options[]]' <<<"$p")" \
    "the card did not offer the recorded options as its choices"
  assert_equals '[{"label":"Grill page","page":"cd-697-698-grill"},{"label":"PR 9","url":"https://github.com/acme/alpha/pull/9"}]' \
    "$(jq -cS '[.captains_call[] | select(.key == "cd-grill") | .links[]]' <<<"$p")" \
    "the card did not carry the recorded links with the page link first"
  assert_equals '{"answers":[{"at":"2026-11-10T09:00:00Z","mode":"captain","text":"keep it parked until Friday"}],"notes":["Grill ran on both MRs."],"reason":"Which grill outcome do we keep? (1) keep both (2) drop the second","report":"data/cd-grill/report.md","task":"cd-grill"}' \
    "$(jq -cS '.captains_call[] | select(.key == "cd-grill") | .context' <<<"$p")" \
    "the card did not carry its context"
  assert_equals '{"answers":[{"at":"2026-11-01T08:00:00Z","mode":"captain","text":"park it until upstream ships"}],"notes":["Relock after uv 0.9."],"reason":"captain parked: wait for the upstream release","task":"wait-x"}' \
    "$(jq -cS '.waiting[] | select(.key == "wait-x") | .context' <<<"$p")" \
    "the waiting row did not carry its context"
  assert_equals '{"notes":["Start after the audit."],"task":"plain-queued"}' \
    "$(jq -cS '.charted[] | select(.id == "plain-queued") | .context' <<<"$p")" \
    "the charted row did not carry its context"
  printf '%s\n' "$p" > "$TMP_ROOT/recorded.json"
  validates "$TMP_ROOT/recorded.json" || fail "a payload with recorded options, page links and context did not validate"
  out=$(build_checks "$TMP_ROOT/recorded.json")
  assert_not_contains "$out" "undecided-card" "the build refused a card with recorded options and links: $out"
  pass "a hold's recorded options and links are its card's choices and links, and every item carries its context"
}

# A hold whose recorded options carry no label shows words, never raw values:
# the reason's own inline "(a, recommended) ... (b) ... (c) ... <url>" options
# label them in place, recommendation included, and a bare review-gate value
# reads as plain words.
test_a_hold_with_bare_recorded_options_shows_words_not_raw_values() {
  local snap p
  snap="$TMP_ROOT/snap-bare.json"
  write_snapshot "$TMP_ROOT/snap.json"
  jq '.decisions_open = [
        {id: "cd-915-stable-lag", key: "cd-915-stable-lag", verb: "captain-hold", owner: "cd",
         title_full: "#915: report when releasable is ahead of stable",
         reason_full: "Where should the stable-lag report run, and what should it be called? (a, recommended) An advisory step at the end of every green main run, named cd-stable-lag, with record .ci/advisory/stable-lag.json: adopters get it at their next pin bump with no new file, forge call or secret. (b) A new daily scheduled workflow that goes red while commits wait: more visible, but adopters must add a new file. (c) A built-in that keeps one forge issue open while commits wait: most visible, but needs a forge write token. https://forgejo.example/rob/continuous-delivery/issues/915",
         choices: {options: [{value: "aa", label: "aa"}, {value: "ba", label: "ba"}, {value: "ca", label: "ca"}],
                   links: [{target: "https://forgejo.example/rob/continuous-delivery/issues/915", label: ""}],
                   free_text: false, no_link: false}},
        {id: "cd-896-gpu-task", key: "cd-896-gpu-task", verb: "captain-hold", owner: "cd",
         title_full: "#896: pipeline path runs a task on a GPU runner",
         reason_full: "Will you clear the bot'"'"'s request-changes review 671 on PR 924? It is green at 9662296 (7 of 7 checks). Recommended: dismiss review 671 after reading the diff; I then merge it.",
         choices: {options: [{value: "cleared-merge", label: "cleared-merge"}, {value: "changes-needed", label: "changes-needed"}],
                   links: [{target: "https://forgejo.example/rob/continuous-delivery/pulls/924", label: ""}],
                   free_text: false, no_link: false}},
        {id: "cd-920-coverage-names", key: "cd-920-coverage-names", verb: "captain-hold", owner: "cd",
         title_full: "#920: coverage scripts named scripts.<language>.<tool>",
         reason_full: "Will you clear the acknowledgement review 667 on PR 923? It is green at 828ab11 (7 of 7 checks). Recommended: dismiss review 667 after reading the diff; I then merge it.",
         choices: {options: [{value: "cleared-merge"}, {value: "changes-needed", label: ""}, {value: "keep-open", label: "keep-open"}],
                   links: [{target: "https://forgejo.example/rob/continuous-delivery/pulls/923", label: ""}],
                   free_text: false, no_link: false}}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals '[{"label":"An advisory step at the end of every green main run, named cd-stable-lag, with record .ci/advisory/stable-lag.json: adopters get it at their next pin bump with no new file, forge call or secret","value":"aa"},{"label":"A new daily scheduled workflow that goes red while commits wait: more visible, but adopters must add a new file","value":"ba"},{"label":"A built-in that keeps one forge issue open while commits wait: most visible, but needs a forge write token","value":"ca"}]' \
    "$(jq -cS '[.captains_call[] | select(.key == "cd-915-stable-lag") | .options[]]' <<<"$p")" \
    "bare recorded options did not take the reason's inline (a, recommended) option text"
  assert_equals "aa" "$(jq -r '.captains_call[] | select(.key == "cd-915-stable-lag") | .recommend_value' <<<"$p")" \
    "the option the reason marks recommended is not the card's recommendation"
  assert_equals "Where should the stable-lag report run, and what should it be called?" \
    "$(jq -r '.captains_call[] | select(.key == "cd-915-stable-lag") | .question' <<<"$p")" \
    "the card question is not the sentence before the options"
  assert_equals "https://forgejo.example/rob/continuous-delivery/issues/915" \
    "$(jq -r '[.captains_call[] | select(.key == "cd-915-stable-lag") | .links[].url] | join(",")' <<<"$p")" \
    "the reason's URL is not the card's one link"
  assert_equals "Cleared to merge|Changes requested" \
    "$(jq -r '.captains_call[] | select(.key == "cd-896-gpu-task") | [.options[].label] | join("|")' <<<"$p")" \
    "bare review-gate values were shown as raw labels"
  assert_equals "cleared-merge,changes-needed" \
    "$(jq -r '.captains_call[] | select(.key == "cd-896-gpu-task") | [.options[].value] | join(",")' <<<"$p")" \
    "the recorded values did not stay the answer values"
  assert_equals "Cleared to merge|Changes requested|Keep open" \
    "$(jq -r '.captains_call[] | select(.key == "cd-920-coverage-names") | [.options[].label] | join("|")' <<<"$p")" \
    "a missing, empty or value-only label did not read as plain words"
  printf '%s\n' "$p" > "$TMP_ROOT/bare.json"
  validates "$TMP_ROOT/bare.json" || fail "a payload with bare recorded options did not validate"
  pass "a hold's bare recorded options show the reason's own option words or plain words, never raw values"
}

# A hold whose recorded options are the reason's own letters with slug values
# ("a) reads - explanation ... (recommended); b) paths - ...") keeps each
# option's explanation and its trailing recommendation, and a question with a
# lead-in clause ("when X, should Y?") keeps its subject.
test_a_hold_with_lettered_slug_options_keeps_explanations_and_lead_in() {
  local snap p url h1 h4
  snap="$TMP_ROOT/snap-lettered-slugs.json"
  url="https://forgejo.example/rob/continuous-delivery/issues/987#issuecomment-35848"
  h1="Path filter (design section 4, H1): what should adopters call the option that lists the files a stage depends on? a) reads - names it as a claim the pipeline checks against what the stage actually opened (recommended); b) paths - matches GitHub on.push.paths but invites trigger semantics and negation; c) changedPaths; d) runsWhenChanged. Design: $url"
  h4="Path filter (design section 4, H4): when a filtered stage is seen reading a tracked file outside its filter, should the run go red or only warn? a) red from day one - relaxing later breaks nobody, tightening later breaks adopters (recommended); b) advisory warning first, red later. Design: $url"
  write_snapshot "$TMP_ROOT/snap.json"
  jq --arg h1 "$h1" --arg h4 "$h4" --arg url "$url" '.decisions_open = [
        {id: "cd-987-h1-option-name", key: "cd-987-h1-option-name", verb: "captain-hold", owner: "cd",
         title_full: "#987 H1: path filter option name", reason_full: $h1,
         choices: {options: [{value: "a", label: "reads"}, {value: "b", label: "paths"},
                             {value: "c", label: "changedPaths"}, {value: "d", label: "runsWhenChanged"}],
                   links: [{target: $url, label: "design report"}], free_text: false, no_link: false}},
        {id: "cd-987-h4-red-or-warn", key: "cd-987-h4-red-or-warn", verb: "captain-hold", owner: "cd",
         title_full: "#987 H4: red or warn", reason_full: $h4,
         choices: {options: [{value: "a", label: "red"}, {value: "b", label: "advisory"}],
                   links: [{target: $url, label: "design report"}], free_text: false, no_link: false}}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  printf '%s\n' "$p" > "$TMP_ROOT/lettered-slugs.json"
  validates "$TMP_ROOT/lettered-slugs.json" || fail "a payload with lettered slug options did not validate"
  assert_equals '[{"label":"Reads - names it as a claim the pipeline checks against what the stage actually opened","value":"a"},{"label":"Paths - matches GitHub on.push.paths but invites trigger semantics and negation","value":"b"},{"label":"changedPaths","value":"c"},{"label":"runsWhenChanged","value":"d"}]' \
    "$(jq -cS '[.captains_call[] | select(.key == "cd-987-h1-option-name") | .options[]]' <<<"$p")" \
    "a lettered slug option lost its explanation"
  assert_equals "a" "$(jq -r '.captains_call[] | select(.key == "cd-987-h1-option-name") | .recommend_value' <<<"$p")" \
    "an option's trailing (recommended) did not become the card's recommendation"
  assert_equals "Red from day one - relaxing later breaks nobody, tightening later breaks adopters|Advisory warning first, red later" \
    "$(jq -r '.captains_call[] | select(.key == "cd-987-h4-red-or-warn") | [.options[].label] | join("|")' <<<"$p")" \
    "a lettered slug option lost its explanation"
  assert_equals "a" "$(jq -r '.captains_call[] | select(.key == "cd-987-h4-red-or-warn") | .recommend_value' <<<"$p")" \
    "an option's trailing (recommended) did not become the card's recommendation"
  assert_equals "Path filter (design section 4, H4): when a filtered stage is seen reading a tracked file outside its filter, should the run go red or only warn?" \
    "$(jq -r '.captains_call[] | select(.key == "cd-987-h4-red-or-warn") | .question' <<<"$p")" \
    "a question with a lead-in clause lost its subject"
  pass "a hold's lettered slug options keep their explanations and a lead-in question keeps its subject"
}

# A hold whose reason lists its choices inline ("Options: a) ... b) ...") and
# whose recorded options are other values would print its options twice, so the
# build names it for its owner to re-post; a hold whose recorded options are the
# reason's own letters, or whose prose holds a single stray "a)", is not named.
test_a_hold_listing_its_options_in_the_reason_as_well_is_named() {
  local snap p out url
  snap="$TMP_ROOT/snap-twice.json"
  url="https://forgejo.example/rob/nixos/issues/12"
  write_snapshot "$TMP_ROOT/snap.json"
  jq --arg url "$url" '.decisions_open = [
        {id: "dns-encrypt-rollout", key: "dns-encrypt-rollout", verb: "captain-hold", owner: "nixos",
         title_full: "Encrypted DNS rollout",
         reason_full: "How should encrypted DNS roll out? Today the NixOS machines leak plaintext DNS to the router. Options: a) recommended: fix NixOS, Quad9 everywhere. b) NixOS fix, keep dnscrypt pool. c) Tailscale Override for the tailnet. d) change nothing.",
         choices: {options: [{value: "quad9", label: "Fix NixOS, Quad9 everywhere"}, {value: "pool", label: "NixOS fix, keep dnscrypt pool"},
                             {value: "tailscale", label: "Tailscale Override for the tailnet"}, {value: "nothing", label: "Change nothing"}],
                   links: [{target: $url, label: "issue"}], free_text: false, no_link: false}},
        {id: "lettered", key: "lettered", verb: "captain-hold", owner: "nixos",
         title_full: "Red or warn",
         reason_full: "Should the run go red or only warn? a) red from day one (recommended); b) advisory warning first.",
         choices: {options: [{value: "a", label: "red"}, {value: "b", label: "advisory"}],
                   links: [{target: $url, label: "issue"}], free_text: false, no_link: false}},
        {id: "stray", key: "stray", verb: "captain-hold", owner: "nixos",
         title_full: "Keep the pool",
         reason_full: "Should we keep the dnscrypt pool? Step a) of the plan already landed, so only the pool remains.",
         choices: {options: [{value: "keep", label: "Keep it"}, {value: "drop", label: "Drop it"}],
                   links: [{target: $url, label: "issue"}], free_text: false, no_link: false}}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  printf '%s\n' "$p" > "$TMP_ROOT/twice.json"
  validates "$TMP_ROOT/twice.json" || fail "a payload with options in its reason did not validate"
  out=$(build_checks "$TMP_ROOT/twice.json")
  assert_contains "$out" "undecided-card: dns-encrypt-rollout: options given twice" \
    "the build did not name a card whose reason lists its options as well: $out"
  assert_not_contains "$out" "undecided-card: lettered" "the build named a card whose reason's letters are its options: $out"
  assert_not_contains "$out" "undecided-card: stray" "the build named a card with a single stray a) in its prose: $out"
  pass "a hold listing its options in the reason as well as on the card is named for its owner to re-post"
}

# A question that opens with a verbless asking word ("What next for X, where Y
# names?") keeps its lead-in, so a comma-led "where ..." clause before the
# "?" is neither taken as the question nor cut away.
test_a_question_that_opens_what_next_keeps_its_comma_led_clause() {
  local snap p url reason
  snap="$TMP_ROOT/snap-comma-lead-in.json"
  url="https://forgejo.example/rob/fos-rulings-research/issues/4"
  reason="What next for the FOS rulings steer experiments after the forced-choice run, where each steer's list of conclusions seems to act as a burden of proof on the side it names? Recommend a: ..."
  write_snapshot "$TMP_ROOT/snap.json"
  jq --arg r "$reason" --arg url "$url" '.decisions_open = [
        {id: "fos-rulings-research.captain-hold-fos-after-fourth-experiment-1",
         key: "fos-rulings-research.captain-hold-fos-after-fourth-experiment-1",
         verb: "captain-hold", owner: "fos-rulings-research",
         title_full: "FOS rulings: after the fourth experiment", reason_full: $r,
         choices: {options: [], links: [{target: $url, label: "experiment report"}],
                   free_text: true, no_link: false}}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  printf '%s\n' "$p" > "$TMP_ROOT/comma-lead-in.json"
  validates "$TMP_ROOT/comma-lead-in.json" || fail "a payload with a comma-led question clause did not validate"
  assert_equals "What next for the FOS rulings steer experiments after the forced-choice run, where each steer's list of conclusions seems to act as a burden of proof on the side it names?" \
    "$(jq -r '.captains_call[] | select(.key == "fos-rulings-research.captain-hold-fos-after-fourth-experiment-1") | .question' <<<"$p")" \
    "a \"What next\" question lost its lead-in or its comma-led clause"
  pass "a question that opens \"What next\" keeps its lead-in and its comma-led clause"
}

# A hold with no recorded options, or with no link, is refused by key naming
# what to add; a declared free-text question with --no-link builds.
test_a_hold_without_recorded_options_or_a_link_is_refused_naming_what_to_add() {
  local snap p out
  snap="$TMP_ROOT/snap-unrecorded.json"
  write_snapshot "$TMP_ROOT/snap.json"
  jq '.decisions_open = [
        {id: "alpha-fix", key: "alpha-fix", verb: "captain-hold", owner: "(main)",
         title: "Pick the alpha retry policy", reason: "Which retry policy? (1) fast (2) slow"},
        {id: "no-link", key: "no-link", verb: "captain-hold", owner: "(main)",
         title: "Pick a name", reason: "Which name do we use?",
         choices: {options: [{value: "a", label: "Name A"}, {value: "b", label: "Name B"}], links: [],
                   free_text: false, no_link: false}},
        {id: "opted-out", key: "opted-out", verb: "captain-hold", owner: "(main)",
         title: "Say what you remember", reason: "What did we agree about the relock?",
         choices: {options: [], links: [], free_text: true, no_link: true}}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  printf '%s\n' "$p" > "$TMP_ROOT/unrecorded.json"
  validates "$TMP_ROOT/unrecorded.json" || fail "the payload did not satisfy the validator"
  out=$(build_checks "$TMP_ROOT/unrecorded.json")
  assert_contains "$out" "undecided-card: alpha-fix: missing options" \
    "a hold with no recorded options was not refused: $out"
  assert_not_contains "$out" "undecided-card: alpha-fix: missing link" \
    "a hold whose task recorded a PR was refused for a link: $out"
  assert_contains "$out" "undecided-card: no-link: missing link" \
    "a hold with no link was not refused: $out"
  assert_not_contains "$out" "undecided-card: no-link: missing options" \
    "a hold with recorded options was refused for options: $out"
  assert_not_contains "$out" "undecided-card: opted-out" \
    "a declared free-text question with no link was refused: $out"
  p=$(built_data)
  assert_equals "opted-out" "$(jq -r '[.captains_call[].key | select(. == "alpha-fix" or . == "no-link" or . == "opted-out")] | join(",")' <<<"$p")" \
    "a card that needs fixing reached Captain's Call"
  assert_equals "alpha-fix,no-link" "$(jq -r '[.cards_to_fix[].key] | join(",")' <<<"$p")" \
    "the cards that need fixing were not listed to fix"
  assert_equals "alpha-fix:missing options" "$(jq -r '.cards_to_fix[0] | "\(.task):\(.problem | split(" (")[0])"' <<<"$p")" \
    "a card to fix did not name its task and problem"
  pass "a hold missing recorded options or a link is held back from Captain's Call to fix, and the explicit opt-outs build"
}

test_cards_carry_links_and_a_non_held_credential_card_survives() {
  local snap copy p
  snap="$TMP_ROOT/snap.json"
  copy="$TMP_ROOT/links-copy.json"
  write_snapshot "$snap"
  cat > "$copy" <<'EOF'
{
  "captains_call": {
    "alpha-fix": {"links": [{"url": "http://dev-1.tailf848b0.ts.net:4387/session/abc", "label": "Review page"}]}
  },
  "captains_call_extra": [
    {"key": "registry-login", "type": "credential", "repo": null, "title": "Log in to the package registry",
     "options": [{"value": "done", "label": "Done"}], "close": "done",
     "links": [{"url": "https://registry.example.test/login"}]},
    {"key": "mr-review", "type": "decision", "repo": "alpha", "title": "Review the alpha MR",
     "options": [], "allow_freeform": true,
     "links": [{"url": "https://gitlab.example.test/acme/alpha/-/merge_requests/4", "label": "MR 4"}]}
  ]
}
EOF
  p=$("$GEN" --snapshot "$snap" --copy "$copy") || fail "the generator refused cards with links"
  assert_equals "alpha-fix,old-row,registry-login,mr-review" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" \
    "a card whose key is not a held task id was dropped"
  assert_equals "Review page" "$(jq -r '.captains_call[0].links[0].label' <<<"$p")" "an overlay attaches links to a generated card"
  assert_equals "https://registry.example.test/login" "$(jq -r '.captains_call[2].links[0].url' <<<"$p")" "a credential card keeps its link"
  printf '%s\n' "$p" > "$TMP_ROOT/links.json"
  validates "$TMP_ROOT/links.json" || fail "cards with links did not satisfy the board validator"
  pass "every card type carries links and a non-held credential card survives the generator and validator"
}

test_the_validator_accepts_https_and_the_tailnet_origin_and_refuses_other_http() {
  local snap p url
  snap="$TMP_ROOT/snap.json"
  write_snapshot "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  for url in https://example.test/page \
             http://dev-1.tailf848b0.ts.net:4387 \
             'http://dev-1.tailf848b0.ts.net:4387/session/abc?x=1#frag'; do
    jq --arg u "$url" '.captains_call[0].links = [{url: $u}]' <<<"$p" > "$TMP_ROOT/link-ok.json"
    validates "$TMP_ROOT/link-ok.json" || fail "the validator refused an allowed link: $url"
  done
  for url in http://example.test/page \
             http://dev-1.tailf848b0.ts.net:4388/x \
             http://dev-1.tailf848b0.ts.net/x \
             http://dev-1.tailf848b0.ts.net:4387.evil.test/x \
             http://dev-1.tailf848b0.ts.net:4387@evil.test/x \
             http://dev-1xtailf848b0.ts.net:4387/x \
             'javascript:alert(1)' \
             'https://example.test/has space'; do
    jq --arg u "$url" '.captains_call[0].links = [{url: $u}]' <<<"$p" > "$TMP_ROOT/link-bad.json"
    validates "$TMP_ROOT/link-bad.json" && fail "the validator accepted a link it must refuse: $url"
  done
  jq '.captains_call[0].links = []' <<<"$p" > "$TMP_ROOT/link-empty.json"
  validates "$TMP_ROOT/link-empty.json" || fail "the validator refused an empty links list"
  jq '.captains_call[0].links = [{url: "https://example.test/x", extra: 1}]' <<<"$p" > "$TMP_ROOT/link-field.json"
  validates "$TMP_ROOT/link-field.json" && fail "the validator accepted a link with an unknown field"
  jq '.captains_call[0].links = "https://example.test/x"' <<<"$p" > "$TMP_ROOT/link-str.json"
  validates "$TMP_ROOT/link-str.json" && fail "the validator accepted links that is not an array"
  pass "the validator accepts https and the tailnet origin only, refusing every other http link"
}

test_the_captains_priority_orders_cards_and_tasks_and_is_recorded_durably() {
  local snap="$TMP_ROOT/prio-snap.json" data="$TMP_ROOT/prio-data" out ctx="$TMP_ROOT/prio-ctx.json"
  local PRIO="$ROOT/bin/fm-board-priority.sh"
  write_snapshot "$snap"
  mkdir -p "$data"
  out=$("$GEN" --snapshot "$snap")
  [ "$(jq -c '[.captains_call[0].key, .underway[0].id]' <<<"$out")" = '["alpha-fix","t1"]' ] \
    || fail "the default order changed without a priority: $out"
  FM_DATA_OVERRIDE="$data" "$PRIO" set old-row alpha-fix old-row t1 || fail "set refused a valid ranking"
  [ "$(FM_DATA_OVERRIDE="$data" "$PRIO" show | paste -sd, -)" = "old-row,alpha-fix,t1" ] || fail "the ranking was not stored in order without duplicates"
  [ "$(FM_DATA_OVERRIDE="$data" "$PRIO" rank alpha-fix)" = 2 ] || fail "rank did not report the stored position"
  [ "$(FM_DATA_OVERRIDE="$data" "$PRIO" rank nope)" = - ] || fail "rank did not report an unranked id"
  out=$(FM_DATA_OVERRIDE="$data" "$GEN" --snapshot "$snap")
  [ "$(jq -r '.captains_call[0].key' <<<"$out")" = old-row ] || fail "the payload did not honor the stored priority for cards: $out"
  [ "$(jq -r '.underway[0].id' <<<"$out")" = alpha-fix ] || fail "the payload did not rank the underway tasks by priority"
  FM_DATA_OVERRIDE="$data" "$PRIO" set t1 || fail "set refused one id"
  out=$(FM_DATA_OVERRIDE="$data" "$GEN" --snapshot "$snap")
  [ "$(jq -r '.underway[0].id' <<<"$out")" = t1 ] || fail "ranked task did not lead underway"
  [ "$(jq -r '.captains_call[0].key' <<<"$out")" = alpha-fix ] || fail "unranked cards lost their snapshot order"
  printf '{"schema":"fm-bearings-priority.v1","keys":["alpha-fix","t1"],"order":[]}' > "$ctx"
  FM_DATA_OVERRIDE="$data" "$PRIO" set --from-ctx "$ctx" || fail "the board's priority context was refused"
  [ "$(FM_DATA_OVERRIDE="$data" "$PRIO" show | paste -sd, -)" = "alpha-fix,t1" ] || fail "--from-ctx did not record the board's ranking"
  printf '{"schema":"other","keys":["x"]}' > "$ctx"
  FM_DATA_OVERRIDE="$data" "$PRIO" set --from-ctx "$ctx" 2>/dev/null && fail "a foreign context was accepted"
  FM_DATA_OVERRIDE="$data" "$PRIO" set 'bad id' 2>/dev/null && fail "an invalid id was accepted"
  [ "$(FM_DATA_OVERRIDE="$data" "$PRIO" show | paste -sd, -)" = "alpha-fix,t1" ] || fail "a refused set changed the stored ranking"
  pass "the stored priority orders the payload's cards and tasks and records the board's ranking"
}

# A board priority names only the decisions on the board and the tasks under
# way. Recording one must keep every other stored rank - a queued task, or the
# decisions themselves when a send carries only tasks - in its own place.
test_a_partial_board_priority_keeps_the_ranks_it_does_not_name() {
  local data="$TMP_ROOT/prio-merge-data" ctx="$TMP_ROOT/prio-merge-ctx.json" PRIO="$ROOT/bin/fm-board-priority.sh"
  mkdir -p "$data"
  FM_DATA_OVERRIDE="$data" "$PRIO" set d1 queued-a d2 t1 d3 queued-b || fail "set refused a valid ranking"
  printf '{"schema":"fm-bearings-priority.v1","keys":["d3","d1","d2","t1"],"order":["d3","d1","d2"]}' > "$ctx"
  FM_DATA_OVERRIDE="$data" "$PRIO" set --from-ctx "$ctx" || fail "the board's priority context was refused"
  assert_equals "d3,queued-a,d1,t1,d2,queued-b" "$(FM_DATA_OVERRIDE="$data" "$PRIO" show | paste -sd, -)" \
    "a board priority dropped or moved the queued tasks it does not name"
  printf '{"schema":"fm-bearings-priority.v1","keys":["t1"],"order":[]}' > "$ctx"
  FM_DATA_OVERRIDE="$data" "$PRIO" set --from-ctx "$ctx" || fail "a tasks-only priority context was refused"
  assert_equals "d3,queued-a,d1,t1,d2,queued-b" "$(FM_DATA_OVERRIDE="$data" "$PRIO" show | paste -sd, -)" \
    "a priority carrying only tasks under way dropped the stored decision ranking"
  printf '{"schema":"fm-bearings-priority.v1","keys":["new-call","d2","d3","t1"],"order":["new-call","d2","d3"]}' > "$ctx"
  FM_DATA_OVERRIDE="$data" "$PRIO" set --from-ctx "$ctx" || fail "a priority with a new decision was refused"
  assert_equals "new-call,d2,queued-a,d1,t1,d3,queued-b" "$(FM_DATA_OVERRIDE="$data" "$PRIO" show | paste -sd, -)" \
    "a new decision did not take its place in the board's order, or a stored rank was lost"
  pass "a board priority keeps every stored rank it does not name in its place"
}

# fm-board-priority.sh promises a decision the ranking does not name sorts after
# every ranked one, so a newly raised card is never dealt first.
test_an_unranked_decision_card_is_dealt_after_every_ranked_card() {
  local snap="$TMP_ROOT/prio-unranked.json" data="$TMP_ROOT/prio-unranked-data" out PRIO="$ROOT/bin/fm-board-priority.sh"
  write_snapshot "$TMP_ROOT/prio-unranked-base.json"
  jq '.decisions_open = [{id: "fresh-call", key: "fresh-call", verb: "captain-hold", title: "Fresh call",
        reason: "Repad the GPU nodes?", owner: "(main)"}] + .decisions_open
      | .decisions_open += [{id: "q3", key: "q3", verb: "captain-hold", title: "Still open",
        reason: "Choose the public name?", owner: "(main)"}]' \
    "$TMP_ROOT/prio-unranked-base.json" > "$snap"
  mkdir -p "$data"
  FM_DATA_OVERRIDE="$data" "$PRIO" set q3 t1 old-row alpha-fix >/dev/null || fail "set failed"
  out=$(FM_DATA_OVERRIDE="$data" "$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "q3,old-row,alpha-fix,fresh-call" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$out")" \
    "an unranked decision was not dealt after every ranked one"
  pass "an unranked decision card is dealt after every ranked card"
}

test_the_priority_digest_is_bounded_and_silent_when_unset() {
  local data="$TMP_ROOT/digest-data" out ids PRIO="$ROOT/bin/fm-board-priority.sh"
  mkdir -p "$data"
  out=$(FM_DATA_OVERRIDE="$data" "$PRIO" digest) || fail "digest failed with no ranking"
  [ -z "$out" ] || fail "digest printed with no ranking: $out"
  FM_DATA_OVERRIDE="$data" "$PRIO" set t2 t1 || fail "set refused ids"
  out=$(FM_DATA_OVERRIDE="$data" "$PRIO" digest)
  case "$out" in "CAPTAIN PRIORITY"*) ;; *) fail "digest has no heading: $out" ;; esac
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = "  1. t2" ] || fail "digest did not lead with the top rank: $out"
  ids=$(seq -f 'task%g' 1 15)
  # shellcheck disable=SC2086
  FM_DATA_OVERRIDE="$data" "$PRIO" set $ids || fail "set refused many ids"
  out=$(FM_DATA_OVERRIDE="$data" "$PRIO" digest)
  printf '%s\n' "$out" | grep -q '(3 more ranked' || fail "digest did not bound a long ranking: $out"
  pass "the priority digest is bounded and silent when unset"
}

# A captain hold whose time gate has passed is back on the captain: it is a
# Captain's Call card again (never dropped, never waiting, never charted), and
# when its reason does not ask, the card asks whether it is still waiting so
# the build still shows it. A hold dated in the future stays charted.
test_a_lapsed_time_gate_returns_the_hold_to_captains_call() {
  local snap p out
  write_snapshot "$TMP_ROOT/snap.json"
  snap="$TMP_ROOT/lapsed.json"
  jq '.decisions_open = [
        {id: "lapsed-wait", key: "lapsed-wait", verb: "captain-hold", title: "Restore staging",
         reason: "Waiting on devops to grant restore access; then restore the snapshot",
         hold_until: "2020-01-01", hold_bucket: "live", owner: "(main)"},
        {id: "lapsed-ask", key: "lapsed-ask", verb: "captain-hold", title: "Pick rollout",
         reason: "Which rollout should we use?",
         hold_until: "2020-01-01", hold_bucket: "live", owner: "(main)",
         choices: {options: [{value: "a", label: "Canary"}, {value: "b", label: "Big bang"}],
                   links: [], free_text: false, no_link: true}},
        {id: "mate/lapsed-mate", key: "lapsed-mate", verb: "captain-hold", title: "Mate wait",
         reason: "parked until devops replies", hold_until: "2020-01-01", owner: "mate"},
        {id: "later", key: "later", verb: "captain-hold", title: "Later",
         reason: "Waiting on devops", hold_until: "2999-01-01", hold_bucket: "dated", owner: "(main)"}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "lapsed-wait,lapsed-ask,lapsed-mate" "$(jq -r '[.captains_call[] | select(.key | startswith("lapsed")) | .key] | join(",")' <<<"$p")" \
    "a hold whose time gate passed is a Captain's Call card"
  assert_equals "later" "$(jq -r '[.waiting[].key] | join(",")' <<<"$p")" "a lapsed hold is not waiting"
  assert_equals "" "$(jq -r '[.charted[] | select(.id | startswith("lapsed") or startswith("mate-lapsed")) | .id] | join(",")' <<<"$p")" \
    "a lapsed hold is not charted"
  assert_equals "later|until 2999-01-01: Waiting on devops" "$(jq -r '.waiting[] | select(.key == "later") | "\(.key)|\(.reason)"' <<<"$p")" \
    "a hold dated in the future is still a waiting row with its date"
  assert_contains "$(jq -r '.captains_call[] | select(.key == "lapsed-wait") | .question' <<<"$p")" "2020-01-01" \
    "a lapsed card that does not ask names its passed date in its question"
  assert_equals "Which rollout should we use?|a,b" "$(jq -r '.captains_call[] | select(.key == "lapsed-ask") | "\(.question)|\([.options[].value] | join(","))"' <<<"$p")" \
    "a lapsed hold that asks keeps its own question and recorded choices"
  printf '%s\n' "$p" > "$TMP_ROOT/lapsed-payload.json"
  validates "$TMP_ROOT/lapsed-payload.json" || fail "a payload with lapsed hold cards did not satisfy the board validator"
  out=$(build_checks "$TMP_ROOT/lapsed-payload.json")
  assert_not_contains "$out" "undecided-card: lapsed" "the build refused a lapsed hold card: $out"
  pass "a hold whose time gate passed returns to Captain's Call and a future one waits with its date"
}

test_a_wait_or_park_hold_moves_to_the_waiting_group_and_questions_lead_cards() {
  local snap="$TMP_ROOT/wait-snap.json" p
  write_snapshot "$TMP_ROOT/snap.json"
  jq '.decisions_open += [
        {id: "w1", key: "w1", verb: "captain-hold", title: "Forge ops", reason: "Parked for the weekend; resume Monday", owner: "(main)"},
        {id: "w2", key: "w2", verb: "captain-hold", title: "Release", reason: "hold until the captain re-runs forge ops", owner: "(main)"},
        {id: "w3", key: "w3", verb: "captain-hold", title: "Dated", reason: "needs a call", hold_until: "2026-12-01", owner: "(main)"},
        {id: "q1", key: "q1", verb: "captain-hold", title: "Resume?", reason: "Should we resume the migration until Monday or cancel it?", owner: "(main)"},
        {id: "q2", key: "q2", verb: "captain-hold", title: "Pick a name", reason: "Choose the public name", owner: "(main)"}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "w1,w2,w3" "$(jq -r '[.waiting[].key] | join(",")' <<<"$p")" "waits, parks and future-dated holds go to the waiting group"
  assert_equals "until 2026-12-01: needs a call" "$(jq -r '.waiting[] | select(.key == "w3") | .reason' <<<"$p")" "a hold dated in the future waits with its date"
  assert_equals "alpha-fix,old-row,q1,q2" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" "a reason with a question mark, or no wait wording, stays a decision card"
  assert_equals "Parked for the weekend; resume Monday" "$(jq -r '.waiting[0].reason' <<<"$p")" "a waiting row carries its hold reason"
  assert_equals "Forge ops" "$(jq -r '.waiting[0].title' <<<"$p")" "a waiting row carries its task title"
  assert_equals "Choose the public name" "$(jq -r '.captains_call[3].question' <<<"$p")" "a decision card leads with its hold reason as the question"
  assert_equals "false" "$(jq -r '[.captains_call[] | has("about")] | any' <<<"$p")" "the reason is not repeated as about text"
  printf '%s\n' "$p" > "$TMP_ROOT/wait.json"
  validates "$TMP_ROOT/wait.json" || fail "a payload with a waiting group did not satisfy the board validator"
  jq '.waiting[0].title = ""' "$TMP_ROOT/wait.json" > "$TMP_ROOT/wait-bad.json"
  validates "$TMP_ROOT/wait-bad.json" && fail "the validator accepted a waiting row with no title"
  pass "a wait or park hold is shown as waiting and each decision card leads with its question"
}

test_a_released_hold_is_not_a_decision_card() {
  local snap="$TMP_ROOT/released.json" p
  jq '.decisions_open = [
        {id: "r1", key: "r1", verb: "captain-hold", title: "Past date", reason: "Pick the rollout", hold_until: "2020-01-01", owner: "(main)"},
        {id: "r2", key: "r2", verb: "captain-hold", title: "Unheld", reason: "Pick the owner", held: "no", owner: "(main)"},
        {id: "r3", key: "r3", verb: "captain-hold", title: "Unheld flag", reason: "Pick the date", held: false, owner: "(main)"},
        {id: "r4", key: "r4", verb: "captain-hold", title: "Future date", reason: "Pick the plan", hold_until: "2999-01-01", owner: "(main)"},
        {id: "r5", key: "r5", verb: "captain-hold", title: "Active", reason: "Pick the name", held: "yes", owner: "(main)"}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "r1,r5" "$(jq -r '[.captains_call[] | select(.key | test("^r[0-9]$")) | .key] | join(",")' <<<"$p")" "an active hold and a lapsed dated hold stay decision cards"
  assert_equals "r4|until 2999-01-01: Pick the plan" "$(jq -r '.waiting[] | select(.key | test("^r[0-9]$")) | "\(.key)|\(.reason)"' <<<"$p")" "a hold dated in the future waits with its date, never a card"
  assert_equals "" "$(jq -r '[.charted[] | select(.id == "r4") | .id] | join(",")' <<<"$p")" "a hold dated in the future is not charted"
  assert_equals "0" "$(jq -r '[.. | objects | select(.key? == "r2" or .key? == "r3")] | length' <<<"$p")" "a released hold appears nowhere on the board"
  pass "a released hold does not render as a decision card"
}

test_every_question_card_gets_real_default_choices() {
  local snap="$TMP_ROOT/choices.json" copy="$TMP_ROOT/choices-copy.json" p
  write_snapshot "$TMP_ROOT/choices-base.json"
  jq '.decisions_open = [
        {id: "n1", key: "n1", verb: "captain-hold", title: "Two calls", reason: "two calls left: (1) build the separated text dataset as its own PR? (2) actionlint", owner: "(main)"},
        {id: "y1", key: "y1", verb: "captain-hold", title: "Ship it", reason: "Should we ship the migration this week?", owner: "(main)"},
        {id: "o1", key: "o1", verb: "captain-hold", title: "Pick one", reason: "Retain the old workflow or migrate to the new runner?", owner: "(main)"},
        {id: "g1", key: "g1", verb: "captain-hold", title: "Release plan", reason: "Choose the public release name", owner: "(main)"},
        {id: "a1", key: "a1", verb: "captain-hold", title: "Authored", reason: "Should we ship?", owner: "(main)"}]' \
    "$TMP_ROOT/choices-base.json" > "$snap"
  printf '{"captains_call":{"a1":{"options":[{"value":"fast","label":"Fast"}],"recommend_value":"fast"}}}\n' > "$copy"
  p=$("$GEN" --snapshot "$snap" --copy "$copy") || fail "the generator failed"
  assert_equals "option-1,option-2" "$(jq -r '.captains_call[] | select(.key == "n1") | [.options[].value] | join(",")' <<<"$p")" "numbered sub-questions become their own choices"
  assert_equals "Build the separated text dataset as its own PR" "$(jq -r '.captains_call[] | select(.key == "n1") | .options[0].label' <<<"$p")" "a numbered choice is labelled with its own text"
  assert_equals "actionlint" "$(jq -r '.captains_call[] | select(.key == "n1") | .options[1].label' <<<"$p")" "the last numbered choice keeps its text"
  assert_equals "yes,no" "$(jq -r '.captains_call[] | select(.key == "y1") | [.options[].value] | join(",")' <<<"$p")" "a yes/no question gets yes and no"
  assert_equals "option-1,option-2" "$(jq -r '.captains_call[] | select(.key == "o1") | [.options[].value] | join(",")' <<<"$p")" "an either-or question splits into its alternatives"
  assert_equals "Retain the old workflow" "$(jq -r '.captains_call[] | select(.key == "o1") | .options[0].label' <<<"$p")" "an alternative is labelled with its own words"
  assert_equals "approve,decline" "$(jq -r '.captains_call[] | select(.key == "g1") | [.options[].value] | join(",")' <<<"$p")" "an unrecognizable question still gets approve and decline"
  assert_equals "fast" "$(jq -r '.captains_call[] | select(.key == "a1") | [.options[].value] | join(",")' <<<"$p")" "authored copy options replace the derived choices"
  assert_equals "true" "$(jq -r '[.captains_call[] | select(.key | IN("n1","y1","o1","g1","a1")) | (.options | length) > 0 and .allow_freeform] | all' <<<"$p")" "every card has choices and keeps the freeform box"
  assert_equals "false" "$(jq -r '[.captains_call[].options[]?.value] | any(. == "reconcile")' <<<"$p")" "reconcile is never generated"
  printf '%s\n' "$p" > "$TMP_ROOT/choices-payload.json"
  validates "$TMP_ROOT/choices-payload.json" || fail "a payload with derived choices did not satisfy the board validator"
  pass "every question card gets real default choices and authored options still win"
}

test_a_task_status_question_becomes_a_card_and_a_wait_a_waiting_row() {
  local snap="$TMP_ROOT/status.json" p
  write_snapshot "$TMP_ROOT/status-base.json"
  jq '.decisions_open += [
        {id: "slack-scout", key: "status.slack-scout.blocked.default", verb: "blocked", source: "status", task: "slack-scout", decision_key: "default", owner: "(main)",
         title_full: "slack-scout", reason_full: "Slack MCP tools are missing", question: "Slack MCP tools are missing", summary: "Slack MCP tools are missing"},
        {id: "mate/fos-rulings", key: "status.mate.fos-rulings.default", verb: "needs-decision", source: "status", task: "fos-rulings", decision_key: "default", owner: "mate",
         title_full: "fos-rulings", reason_full: "two calls left: (1) build the dataset as its own PR? (2) actionlint", summary: "two calls left"},
        {id: "mate/parked", key: "status.mate.parked.default", verb: "needs-decision", source: "status", task: "parked", decision_key: "default", owner: "mate",
         title_full: "parked", reason_full: "waiting for the upstream release", summary: "waiting for the upstream release"}]' \
    "$TMP_ROOT/status-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "Slack MCP tools are missing" "$(jq -r '.captains_call[] | select(.key == "status.slack-scout.blocked.default") | .question // .about // .title' <<<"$p")" "a blocked task opens as a card with its blocker text"
  assert_equals "true" "$(jq -r '.captains_call[] | select(.key == "status.slack-scout.blocked.default") | (.options | length) > 0' <<<"$p")" "a blocked task card offers answer choices"
  assert_equals "option-1,option-2" "$(jq -r '.captains_call[] | select(.key == "status.mate.fos-rulings.default") | [.options[].value] | join(",")' <<<"$p")" "a secondmate status question is a card with real choices"
  assert_equals "status.mate.parked.default" "$(jq -r '[.waiting[] | select(.key | startswith("status."))] | map(.key) | join(",")' <<<"$p")" "a status wait goes to the waiting group"
  pass "task and secondmate status questions reach the board as cards or waiting rows"
}

# A keyless blocked line that names what it waits on is a dependency wait, not
# a captain call: it lands in Waiting with that dependency in its reason, never
# in Captain's Call and never nowhere. A keyed blocked line, or a keyless one
# that names no dependency, stays a card.
test_a_keyless_blocked_line_naming_a_dependency_waits_instead_of_a_card() {
  local snap="$TMP_ROOT/dep-wait.json" p k
  fresh_homes dep-wait
  write_snapshot "$TMP_ROOT/dep-wait-base.json"
  jq '.decisions_open = [
        {id: "workload-pruner", key: "status.workload-pruner.default", verb: "blocked", source: "status", task: "workload-pruner", decision_key: "default", mate: null, owner: "workload-pruner",
         title_full: "workload-pruner", reason_full: "corr=6666af660f0353c1 R1-I1 GPU measurement depends on continuous-delivery #896 (no pipeline path runs a task on a GPU runner): https://forgejo.example/rob/continuous-delivery/issues/896. Parked until #896 lands.", summary: "depends on cd #896"},
        {id: "babysit", key: "status.babysit.default", verb: "blocked", source: "status", task: "babysit", decision_key: "default", mate: null, owner: "(main)",
         title_full: "babysit", reason_full: "MR 870 push is blocked: the pre-push hook gets 401. 876 waits on 870. Loop continues.", summary: "MR 870 push blocked"},
        {id: "keyed", key: "status.keyed.wp-x", verb: "blocked", source: "status", task: "keyed", decision_key: "wp-x", mate: null, owner: "(main)",
         title_full: "keyed", reason_full: "this depends on cd #896; route it to the cd second mate", summary: "keyed"},
        {id: "disk", key: "status.disk.default", verb: "blocked", source: "status", task: "disk", decision_key: "default", mate: null, owner: "(main)",
         title_full: "disk", reason_full: "disk still full, needs space freed", summary: "disk full"}]' \
    "$TMP_ROOT/dep-wait-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  for k in status.workload-pruner.default status.babysit.default; do
    assert_equals "0" "$(jq --arg k "$k" '[.captains_call[] | select(.key == $k)] | length' <<<"$p")" "a keyless dependency wait $k became a Captain's Call card"
    assert_equals "1" "$(jq --arg k "$k" '[.waiting[] | select(.key == $k)] | length' <<<"$p")" "a keyless dependency wait $k is not in Waiting"
  done
  jq -e '.waiting[] | select(.key == "status.workload-pruner.default") | .reason | contains("depends on continuous-delivery #896")' <<<"$p" >/dev/null \
    || fail "the waiting row does not show what it waits on: $p"
  jq -e '.waiting[] | select(.key == "status.babysit.default") | .reason | contains("876 waits on 870")' <<<"$p" >/dev/null \
    || fail "the babysit waiting row does not show what it waits on: $p"
  for k in status.keyed.wp-x status.disk.default; do
    assert_equals "1" "$(jq --arg k "$k" '[.captains_call[] | select(.key == $k)] | length' <<<"$p")" "blocked line $k should stay a card"
    assert_equals "0" "$(jq --arg k "$k" '[.waiting[] | select(.key == $k)] | length' <<<"$p")" "blocked line $k should not wait"
  done
  printf '%s\n' "$p" > "$TMP_ROOT/dep-wait-payload.json"
  validates "$TMP_ROOT/dep-wait-payload.json" || fail "a payload with dependency waits did not satisfy the board validator"
  pass "a keyless blocked line that names a dependency waits with it, and keyed or dependency-free blocked lines stay cards"
}

test_urls_in_a_question_become_card_links() {
  local snap="$TMP_ROOT/urls.json" p
  write_snapshot "$TMP_ROOT/urls-base.json"
  jq '.decisions_open = [
        {id: "u1", key: "u1", verb: "captain-hold", title: "Review", reason: "Should we merge https://github.com/acme/app/pull/7, or wait? <b>x</b> http://insecure.example/x", owner: "(main)"}]' \
    "$TMP_ROOT/urls-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "https://github.com/acme/app/pull/7" "$(jq -r '.captains_call[0].links | map(.url) | join(",")' <<<"$p")" "an https URL in the question is lifted into the card links, without trailing punctuation"
  printf '%s\n' "$p" > "$TMP_ROOT/urls-payload.json"
  validates "$TMP_ROOT/urls-payload.json" || fail "a payload with lifted links did not satisfy the board validator"
  pass "URLs in a question become clickable card links and plain http is not lifted"
}

test_a_tailnet_review_page_link_and_a_review_card_get_choices() {
  local snap="$TMP_ROOT/review.json" p
  write_snapshot "$TMP_ROOT/review-base.json"
  jq '.decisions_open = [
        {id: "rv", key: "review.rv", verb: "review-ready", source: "review-page", title: "Understand request", reason: "report ready; understand board live at http://dev-1.tailf848b0.ts.net:4387/session/5e96b7b8f3b4f9db. ask devops first", owner: "(main)"},
        {id: "q", key: "q", verb: "needs-decision", source: "status", title: "Round", reason: "Round on http://dev-1.tailf848b0.ts.net:4387/session/988b504d3271c0ea - (1) run it now (2) pick models; also http://evil.example/x", owner: "mate"}]' \
    "$TMP_ROOT/review-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "reviewed,later" "$(jq -r '.captains_call[] | select(.key == "review.rv") | .options | map(.value) | join(",")' <<<"$p")" "a review-ready card offers reviewed and later"
  assert_equals "http://dev-1.tailf848b0.ts.net:4387/session/5e96b7b8f3b4f9db" "$(jq -r '.captains_call[] | select(.key == "review.rv") | .links[0].url' <<<"$p")" "the tailnet review page is lifted into the links"
  assert_equals "http://dev-1.tailf848b0.ts.net:4387/session/988b504d3271c0ea" "$(jq -r '.captains_call[] | select(.key == "q") | .links | map(.url) | join(",")' <<<"$p")" "only the tailnet origin is lifted among http URLs"
  printf '%s\n' "$p" > "$TMP_ROOT/review-payload.json"
  validates "$TMP_ROOT/review-payload.json" || fail "a payload with a tailnet link did not satisfy the board validator"
  pass "a ready review page is a card with reviewed/later choices and a clickable tailnet link"
}

# Every regression below runs the generator against its own fresh FM_HOME and
# parent home, so nothing reads or writes a real firstmate home.
fresh_homes() {  # <name>
  FM_HOME=$(mktemp -d "$TMP_ROOT/$1-home.XXXXXX"); export FM_HOME
  FM_PARENT_HOME=$(mktemp -d "$TMP_ROOT/$1-parent.XXXXXX"); export FM_PARENT_HOME
}

test_a_secondmate_status_question_is_titled_from_its_decision_not_its_home() {
  local snap="$TMP_ROOT/st-title.json" p
  fresh_homes st-title
  write_snapshot "$TMP_ROOT/st-title-base.json"
  jq '.decisions_open = [
        {id: "fm-patches", key: "status.fm-patches.retire-slot", task: "fm-patches", decision_key: "retire-slot", source: "status", verb: "needs-decision", title: "fm-patches", reason: "corr=ab12 (1) land now (2) drop it", owner: "fm-patches", mate: "fm-patches"},
        {id: "fm-patches/retire-slot", key: "retire-slot", verb: "captain-hold", title: "Retire slot residue", reason: "until 2026-12-01: parked", owner: "fm-patches"},
        {id: "fos", key: "status.fos.default", task: "fos", decision_key: "default", source: "status", verb: "needs-decision", title: "fos", reason: "PR 13 updated per the picks at https://github.com/acme/fos/pull/13; two calls left. (1) Build it (2) skip", owner: "fos", mate: "fos"},
        {id: "fos2", key: "status.fos.arm", task: "fos", decision_key: "arm", source: "status", verb: "needs-decision", title: "fos", reason: "Run the minimal arm now?", owner: "fos", mate: "fos"}]' \
    "$TMP_ROOT/st-title-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "fm-patches: Retire slot residue" "$(jq -r '[.captains_call[], .waiting[]] | map(select(.key == "status.fm-patches.retire-slot")) | .[0].title' <<<"$p")" "a status key that names a task takes that task title"
  assert_equals "fos: PR 13 updated per the picks; two calls left" "$(jq -r '.captains_call[] | select(.key == "status.fos.default") | .title' <<<"$p")" "a default-key status question takes its first sentence, without the URL"
  assert_equals "fos: Run the minimal arm now?" "$(jq -r '.captains_call[] | select(.key == "status.fos.arm") | .title' <<<"$p")" "an unknown task key falls back to the question text"
  assert_equals "0" "$(jq '[.captains_call[], .waiting[]] | map(select(.title == "fos" or .title == "fm-patches")) | length' <<<"$p")" "no card is titled with only the home name"
  printf '%s\n' "$p" > "$TMP_ROOT/st-title-payload.json"
  validates "$TMP_ROOT/st-title-payload.json" || fail "a payload with derived status titles did not satisfy the board validator"
  pass "a secondmate status question is titled from its task or question, never the bare home name"
}

# A secondmate status line made only of numbered items - here a relay request
# to firstmate and a scout note - asks the captain nothing of its own: an
# asking sentence inside one of its items is a choice, never its title, so the
# card has no question and the build lists it to fix instead of Captain's Call.
test_a_status_question_whose_only_asking_sentence_is_inside_an_option_is_listed_to_fix() {
  local snap="$TMP_ROOT/relay-items.json" p out
  fresh_homes relay-items
  write_snapshot "$TMP_ROOT/relay-items-base.json"
  jq '.decisions_open = [
        {id: "cd", key: "status.cd.cd-web-bucket-home", task: "cd", decision_key: "cd-web-bucket-home", source: "status", verb: "needs-decision", title: "cd",
         reason: "(1) Please relay to the runner-image second mate, I have no channel to it: '"'"'The captain wants ONE private GCS bucket for the web home builds. Should its Terraform live in runner-image'"'"'s infra or in continuous-delivery'"'"'s infra/? Reason for your answer please.'"'"' Worker cd-965-c4-diagram holds the infra part until the answer comes back. (2) pin-bump: scout cd-pinbump-red dispatched. Already known: the pin bump turned the runner image CI red.",
         owner: "cd", mate: "cd"}]' \
    "$TMP_ROOT/relay-items-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "null" "$(jq -c '.captains_call[] | select(.key == "status.cd.cd-web-bucket-home") | .question' <<<"$p")" \
    "the numbered items stood in for a question"
  assert_not_contains "$(jq -r '.captains_call[] | select(.key == "status.cd.cd-web-bucket-home") | .title' <<<"$p")" "Terraform" \
    "an asking sentence inside an option titled the card"
  printf '%s\n' "$p" > "$TMP_ROOT/relay-items-payload.json"
  out=$(build_checks "$TMP_ROOT/relay-items-payload.json")
  assert_contains "$out" "undecided-card: status.cd.cd-web-bucket-home: missing question" \
    "a status card with no question was not refused: $out"
  p=$(built_data)
  assert_equals "0" "$(jq '[.captains_call[] | select(.key == "status.cd.cd-web-bucket-home")] | length' <<<"$p")" \
    "a status card with no question reached Captain's Call"
  assert_equals "missing question" "$(jq -r '.cards_to_fix[] | select(.key == "status.cd.cd-web-bucket-home") | .problem | split(" (")[0]' <<<"$p")" \
    "a status card with no question was not listed to fix for its missing question"
  pass "a status line whose only asking sentence is inside a numbered item is listed to fix, not put on Captain's Call"
}

test_a_status_question_and_its_same_home_hold_render_one_card_with_every_choice() {
  local snap="$TMP_ROOT/twin.json" p
  fresh_homes twin
  write_snapshot "$TMP_ROOT/twin-base.json"
  jq '.decisions_open = [
        {id: "mate/slot", key: "slot", verb: "captain-hold", title: "Retire slot residue", reason: "Should I land the slot fix?", owner: "mate"},
        {id: "mate", key: "status.mate.slot", task: "mate", decision_key: "slot", source: "status", verb: "needs-decision", title: "mate", reason: "corr=9f (1) land now (2) wait for the dedupe fix (3) drop it", owner: "mate", mate: "mate"},
        {id: "other", key: "status.other.slot", task: "other", decision_key: "slot", source: "status", verb: "needs-decision", title: "other", reason: "Ship the other slot fix?", owner: "other", mate: "other"},
        {id: "mate2", key: "status.mate.upstream", task: "mate", decision_key: "upstream", source: "status", verb: "needs-decision", title: "mate", reason: "Open the upstream PRs now?", owner: "mate", mate: "mate"}]' \
    "$TMP_ROOT/twin-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "0" "$(jq '[.captains_call[], .waiting[]] | map(select(.key == "status.mate.slot")) | length' <<<"$p")" "the status twin does not render its own card or waiting row"
  assert_equals "1" "$(jq '[.captains_call[] | select(.key == "slot" and (.title | test("Retire")))] | length' <<<"$p")" "the hold renders exactly one card"
  assert_equals "Yes,No,Land now,Wait for the dedupe fix,Drop it" "$(jq -r '.captains_call[] | select(.key == "slot" and (.title | test("Retire"))) | .options | map(.label) | join(",")' <<<"$p")" "the card keeps every choice from both the hold and its status twin"
  jq -e '.captains_call[] | select(.key == "slot" and (.title | test("Retire"))) | [.question, (.about // ""), (.options[].label)] | join(" ") | test("Land now") and test("Should I land")' <<<"$p" >/dev/null || fail "the card keeps the text of both questions, an option list as its choices"
  assert_equals "1" "$(jq '[.captains_call[] | select(.key == "status.other.slot")] | length' <<<"$p")" "a status question with the same key in another home stays its own card"
  assert_equals "1" "$(jq '[.captains_call[] | select(.key == "status.mate.upstream")] | length' <<<"$p")" "a status question with no hold twin stays its own card"
  printf '%s\n' "$p" > "$TMP_ROOT/twin-payload.json"
  validates "$TMP_ROOT/twin-payload.json" || fail "a payload with a merged twin card did not satisfy the board validator"
  pass "one question renders one card that keeps the richer text and loses no choice"
}

# A worker that raised a captain hold and then posted an unkeyed needs-decision
# announcing it (cd's #930 identity call, "...; card cd-930-identity") gets one
# card: the unkeyed line naming the held task is dropped, the hold card stays.
test_an_unkeyed_status_line_naming_a_held_card_does_not_make_a_second_card() {
  local snap="$TMP_ROOT/names-hold.json" p line
  line="#930 follow-on from the captain's Secret Manager answer: every cloud runner job of every repo runs as one shared Google account, so which identity may read the image-push key? (a, recommended) per-job Forgejo OIDC admitted only for continuous-delivery and runner-image, desktop needs no stored credential for it; (b) the shared runner account plus a desktop credential, which lets every adopter read the key. Security-sensitive new trust path, so raised; card cd-930-identity. https://forgejo.clarob.uk/rob/continuous-delivery/issues/930#issuecomment-34897"
  fresh_homes names-hold
  write_snapshot "$TMP_ROOT/names-hold-base.json"
  jq --arg line "$line" '.decisions_open = [
        {id: "cd/cd-930-identity", key: "cd-930-identity", verb: "captain-hold", title: "Image-push key identity", reason: "Which identity should be allowed to read the new image-push key?", owner: "cd"},
        {id: "cd", key: "status.cd.default", task: "cd", decision_key: "default", source: "status", verb: "needs-decision", title: "cd", reason: $line, reason_full: $line, owner: "cd", mate: "cd"},
        {id: "cd2", key: "status.cd2.default", task: "cd2", decision_key: "default", source: "status", verb: "needs-decision", title: "cd2", reason: "Rotate the cd-930-identity-old key now or keep it?", owner: "cd", mate: "cd"},
        {id: "other", key: "status.other.default", task: "other", decision_key: "default", source: "status", verb: "needs-decision", title: "other", reason: "Ship card cd-930-identity in this home too?", owner: "other", mate: "other"}]' \
    "$TMP_ROOT/names-hold-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "0" "$(jq '[.captains_call[], .waiting[]] | map(select(.key == "status.cd.default")) | length' <<<"$p")" "the unkeyed line naming the held card renders no card or waiting row"
  assert_equals "1" "$(jq '[.captains_call[] | select(.key == "cd-930-identity")] | length' <<<"$p")" "the held card stays"
  assert_equals "1" "$(jq '[.captains_call[] | select(.key == "status.cd2.default")] | length' <<<"$p")" "a line naming only a longer id is not folded"
  assert_equals "1" "$(jq '[.captains_call[] | select(.key == "status.other.default")] | length' <<<"$p")" "a line in another home naming the id is not folded"
  printf '%s\n' "$p" > "$TMP_ROOT/names-hold-payload.json"
  validates "$TMP_ROOT/names-hold-payload.json" || fail "a payload with a dropped announcing line did not satisfy the board validator"
  pass "an unkeyed status line naming a held card is dropped and the held card stays"
}

test_a_keyed_worker_question_on_a_held_task_does_not_make_a_second_card() {
  local snap="$TMP_ROOT/held-task.json" p
  fresh_homes held-task
  write_snapshot "$TMP_ROOT/held-task-base.json"
  jq '.decisions_open = [
        {id: "aegis-821-review", key: "aegis-821-review", verb: "captain-hold", title: "Pick which MR 821 review comments to post", reason: "Which held review comments on MR 821 should be posted?", owner: "(main)"},
        {id: "aegis-821-review", key: "status.aegis-821-review.mr821-comment-pick", task: "aegis-821-review", decision_key: "mr821-comment-pick", source: "status", verb: "needs-decision", title: "aegis-821-review", reason: "Which of the held comments on MR 821 do you want posted?", owner: "(main)"},
        {id: "aegis-821-plain", key: "status.aegis-821-review.default", task: "aegis-821-review", decision_key: "default", source: "status", verb: "needs-decision", title: "aegis-821-review", reason: "Rebase the review branch onto main now?", owner: "(main)"},
        {id: "aegis-822", key: "status.aegis-822.pick", task: "aegis-822", decision_key: "pick", source: "status", verb: "needs-decision", title: "aegis-822", reason: "Post the MR 822 comments now?", owner: "(main)"},
        {id: "cd/aegis-821-review", key: "status.aegis-821-review.other-home", task: "aegis-821-review", decision_key: "other-home", source: "status", verb: "needs-decision", title: "aegis-821-review", reason: "Close the cd issue for MR 821?", owner: "cd", mate: "cd"}]' \
    "$TMP_ROOT/held-task-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "0" "$(jq '[.captains_call[], .waiting[]] | map(select(.key == "status.aegis-821-review.mr821-comment-pick")) | length' <<<"$p")" "the keyed worker question on the held task renders no card or waiting row"
  assert_equals "1" "$(jq '[.captains_call[] | select(.key == "aegis-821-review")] | length' <<<"$p")" "the hold card stays the one card"
  assert_equals "1" "$(jq '[.captains_call[] | select(.key == "status.aegis-821-review.default")] | length' <<<"$p")" "an unkeyed line on the held task is not folded by its task"
  assert_equals "1" "$(jq '[.captains_call[] | select(.key == "status.aegis-822.pick")] | length' <<<"$p")" "a keyed question on another task stays a card"
  assert_equals "1" "$(jq '[.captains_call[] | select(.key == "status.aegis-821-review.other-home")] | length' <<<"$p")" "a keyed question in another home stays a card"
  printf '%s\n' "$p" > "$TMP_ROOT/held-task-payload.json"
  validates "$TMP_ROOT/held-task-payload.json" || fail "a payload with a folded worker key did not satisfy the board validator"
  pass "a keyed worker question on a captain-held task is folded into the hold card"
}

test_a_past_tense_worker_option_keeps_its_verb() {
  local snap="$TMP_ROOT/past-tense.json" p
  fresh_homes past-tense
  write_snapshot "$TMP_ROOT/past-tense-base.json"
  jq '.decisions_open = [
        {id: "gcloud", key: "status.gcloud.login", task: "gcloud", decision_key: "login", source: "status", verb: "needs-decision", title: "gcloud", reason: "gcloud credentials expired for MR 902. Options: I ran gcloud auth login, carry on / I took a new token from the vault / I need more time / I post it later", owner: "(main)"}]' \
    "$TMP_ROOT/past-tense-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "The worker ran gcloud auth login, carry on|The worker took a new token from the vault|The worker needs more time|The worker posts it later" \
    "$(jq -r '.captains_call[] | select(.key == "status.gcloud.login") | [.options[].label] | join("|")' <<<"$p")" "a past-tense verb stays as it is and a present one takes its s"
  printf '%s\n' "$p" > "$TMP_ROOT/past-tense-payload.json"
  validates "$TMP_ROOT/past-tense-payload.json" || fail "a payload with past-tense options did not satisfy the board validator"
  # A regular -ed verb after "(a) recommended: I" stays past tense, never "removeds".
  jq '.decisions_open = [
        {id: "prek", key: "status.prek.prek-shim", task: "prek", decision_key: "prek-shim", source: "status", verb: "needs-decision", title: "prek", reason: "Will you clear the stale prek hook copies so I can commit the 13 fixes for MR 900? The shared hooks dir holds pre-commit.legacy, commit-msg.legacy and pre-push.legacy, so the commit fails. (a) recommended: I removed the three .legacy files there (or ran prek install -f for pre-commit, commit-msg and pre-push), carry on; (b) you may remove those three .legacy files yourself, then carry on; (c) wait", owner: "(main)"}]' \
    "$TMP_ROOT/past-tense-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "a|The worker removed the three .legacy files there (or ran prek install -f for pre-commit, commit-msg and pre-push), carry on" \
    "$(jq -r '.captains_call[] | select(.key == "status.prek.prek-shim") | "\(.recommend_value)|\(.options[0].label)"' <<<"$p")" \
    "a regular past-tense verb keeps its form and the recommended option stays the recommendation"
  assert_not_contains "$p" "removeds" "a past-tense verb took a present-tense s"
  pass "a past-tense worker option keeps its verb"
}

# A question whose lettered marks follow their options ("... yourself (a,
# recommended) or have this lane post it as a draft note (b)?") offers those
# options with the recommendation kept, never only the reconcile choice.
test_options_marked_after_their_text_are_the_card_choices() {
  local snap="$TMP_ROOT/trailing-marks.json" p card
  fresh_homes trailing-marks
  write_snapshot "$TMP_ROOT/trailing-marks-base.json"
  jq '.decisions_open = [
        {id: "pinocchio-125-understand", key: "status.pinocchio-125-understand.mr125-review", task: "pinocchio-125-understand", decision_key: "mr125-review", source: "status", verb: "needs-decision", title: "pinocchio-125-understand",
         reason: "Will you review https://gitlab.descartesunderwriting.com/descartes-underwriting/app/pinocchio/-/merge_requests/125 then https://gitlab.descartesunderwriting.com/descartes-underwriting/app/pinocchio/-/merge_requests/126, and post the set -eo pipefail comment drafted in data/pinocchio-125-understand/report.md yourself (a, recommended) or have this lane post it as a draft note (b)? Page: page:understand-mr125. Report: data/pinocchio-125-understand/report.md", owner: "(main)"},
        {id: "rel", key: "status.rel.pick", task: "rel", decision_key: "pick", source: "status", verb: "needs-decision", title: "rel",
         reason: "Which release should ship: cut it today (a), wait for the fix (b, recommended), or skip it (c)?", owner: "(main)"},
        {id: "ref", key: "status.ref.pick", task: "ref", decision_key: "pick", source: "status", verb: "needs-decision", title: "ref",
         reason: "It was fixed in step (a) or step (b). Ship it now?", owner: "(main)"}]' \
    "$TMP_ROOT/trailing-marks-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  card() { jq -c --arg k "$1" '.captains_call[] | select(.key == $k)' <<<"$p"; }
  card=$(card status.pinocchio-125-understand.mr125-review)
  assert_equals "a|b" "$(jq -r '[.options[].value | select(. != "reconcile")] | join("|")' <<<"$card")" \
    "an option marked after its text was not a card choice"
  assert_equals "Post the set -eo pipefail comment drafted in data/pinocchio-125-understand/report.md yourself|Have this lane post it as a draft note" \
    "$(jq -r '[.options[] | select(.value != "reconcile") | .label] | join("|")' <<<"$card")" "the options do not read as their own text"
  assert_equals "a" "$(jq -r .recommend_value <<<"$card")" "the (a, recommended) option is not the recommendation"
  assert_contains "$(jq -r .question <<<"$card")" "?" "the card heading does not ask"
  card=$(card status.rel.pick)
  assert_equals "a:Cut it today|b:Wait for the fix|c:Skip it" \
    "$(jq -r '[.options[] | select(.value != "reconcile") | "\(.value):\(.label)"] | join("|")' <<<"$card")" "an a/b/c run marked after its text was not the choices"
  assert_equals "b" "$(jq -r .recommend_value <<<"$card")" "a later recommended mark is not the recommendation"
  assert_equals "" "$(card status.ref.pick | jq -r '[.options[].value | select(. != "reconcile")] | sort | join(",")')" \
    "marks that only refer back became options"
  printf '%s\n' "$p" > "$TMP_ROOT/trailing-marks-payload.json"
  validates "$TMP_ROOT/trailing-marks-payload.json" || fail "a payload with options marked after their text did not validate"
  pass "options marked after their text are the card choices, with the recommendation kept"
}

# A last option followed by " \u2014 " and the links the question cites ends
# at the dash, so the link list never joins its label.
test_a_last_option_ends_at_a_dash_before_links() {
  local snap="$TMP_ROOT/dash-links.json" p card reason
  fresh_homes dash-links
  write_snapshot "$TMP_ROOT/dash-links-base.json"
  reason="Will you review MR 125 then MR 126, and who posts the set -eo pipefail comment drafted in data/pinocchio-125-understand/report.md? a) the captain posts it (recommended) b) this lane posts it as a draft note $(printf '\u2014') MR 125: https://gitlab.descartesunderwriting.com/descartes-underwriting/app/pinocchio/-/merge_requests/125 MR 126: https://gitlab.descartesunderwriting.com/descartes-underwriting/app/pinocchio/-/merge_requests/126 page: page:understand-mr125 report: data/pinocchio-125-understand/report.md"
  jq --arg r "$reason" '.decisions_open = [
        {id: "pinocchio-125-understand", key: "status.pinocchio-125-understand.mr125-review", task: "pinocchio-125-understand", decision_key: "mr125-review", source: "status", verb: "needs-decision", title: "pinocchio-125-understand",
         reason: $r, owner: "(main)"}]' \
    "$TMP_ROOT/dash-links-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  card=$(jq -c '.captains_call[] | select(.key == "status.pinocchio-125-understand.mr125-review")' <<<"$p")
  assert_equals "a:The captain posts it|b:This lane posts it as a draft note" \
    "$(jq -r '[.options[] | select(.value != "reconcile") | "\(.value):\(.label)"] | join("|")' <<<"$card")" \
    "the link list after the dash joined the last option"
  assert_equals "a" "$(jq -r .recommend_value <<<"$card")" "the recommended option is not the recommendation"
  printf '%s\n' "$p" > "$TMP_ROOT/dash-links-payload.json"
  validates "$TMP_ROOT/dash-links-payload.json" || fail "a payload whose last option ends at a dash did not validate"
  pass "a last option ends at a dash that links follow"
}

test_a_recorded_option_marked_recommended_is_the_card_recommendation() {
  local snap="$TMP_ROOT/rec-label.json" p
  fresh_homes rec-label
  write_snapshot "$TMP_ROOT/rec-label-base.json"
  jq '.decisions_open = [
        {id: "cd/cd-962-merge-2", key: "cd-962-merge-2", verb: "captain-hold", owner: "cd", title: "Merge fos-rulings-research PR 29",
         reason: "Both review comments on PR 29 are answered and all 10 checks are green. Merge PR 29?",
         choices: {options: [{value: "a", label: "Merge it (recommended)"}, {value: "b", label: "Leave it for you to review first"}], free_text: true}},
        {id: "plain", key: "plain", verb: "captain-hold", owner: "(main)", title: "Plain pick", reason: "Which one?",
         choices: {options: [{value: "x", label: "Take x"}, {value: "y", label: "Take y"}]}},
        {id: "pref", key: "pref", verb: "captain-hold", owner: "(main)", title: "Preferred pick", reason: "Which one?",
         choices: {options: [{value: "x", label: "Take x"}, {value: "y", label: "Take y (Preferred)."}]}}]' \
    "$TMP_ROOT/rec-label-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  card() { jq -c --arg k "$1" '.captains_call[] | select(.key == $k)' <<<"$p"; }
  assert_equals "a" "$(card cd-962-merge-2 | jq -r .recommend_value)" "a recorded label ending in (recommended) is the recommendation"
  assert_equals "Merge it|Leave it for you to review first" "$(card cd-962-merge-2 | jq -r '[.options[].label] | join("|")')" "the marker leaves the label"
  assert_equals "null" "$(card plain | jq -r .recommend_value)" "no marker, no recommendation"
  assert_equals "y" "$(card pref | jq -r .recommend_value)" "a (preferred) marker in any case marks its option"
  printf '%s\n' "$p" > "$TMP_ROOT/rec-label-payload.json"
  validates "$TMP_ROOT/rec-label-payload.json" || fail "a payload with a recommended recorded option did not satisfy the board validator"
  pass "a recorded hold option marked (recommended) is the card recommendation"
}

test_an_a_recommended_hold_with_recorded_labels_is_the_recommendation() {
  local snap="$TMP_ROOT/a-rec-held.json" p
  fresh_homes a-rec-held
  write_snapshot "$TMP_ROOT/a-rec-held-base.json"
  # The cd-965-ack-981 hold as its second mate recorded it: the reason carries
  # "(a, recommended) ..." and the recorded option a keeps "(recommended)".
  jq '.decisions_open = [
        {id: "cd/cd-965-ack-981", key: "cd-965-ack-981", verb: "captain-hold", owner: "cd",
         title: "Acknowledge PR 981 (infra plan guard admits IAP settings, #965)",
         reason_full: "You dismissed review 710 on PR 981 at 15:06; shall I merge PR 981 and then PR 982? (a, recommended) Merge PR 981, then PR 982. (b) Leave both open. https://forgejo.example/rob/continuous-delivery/pulls/981 https://forgejo.example/rob/continuous-delivery/pulls/982",
         choices: {options: [{value: "a", label: "Merge PR 981, then PR 982 (recommended)"}, {value: "b", label: "Leave both open"}], free_text: true}}]' \
    "$TMP_ROOT/a-rec-held-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "a" "$(jq -r '.captains_call[] | select(.key == "cd-965-ack-981") | .recommend_value' <<<"$p")" \
    "an (a, recommended) hold did not mark option a as the recommendation"
  assert_equals "Merge PR 981, then PR 982|Leave both open" \
    "$(jq -r '.captains_call[] | select(.key == "cd-965-ack-981") | [.options[].label] | join("|")' <<<"$p")" \
    "the (recommended) marker stayed in the label"
  printf '%s\n' "$p" > "$TMP_ROOT/a-rec-held-payload.json"
  validates "$TMP_ROOT/a-rec-held-payload.json" || fail "an (a, recommended) hold payload did not satisfy the board validator"
  pass "an (a, recommended) hold with recorded labels marks option a"
}

test_a_hold_the_captain_parked_waits_even_when_its_reason_asks_a_question() {
  local snap="$TMP_ROOT/parked.json" p
  fresh_homes parked
  write_snapshot "$TMP_ROOT/parked-base.json"
  jq '.decisions_open = [
        {id: "relock", key: "relock", verb: "captain-hold", title: "Aegis relock", reason: "Parked by the captain on 2026-11-10 to focus on the release. Start the relock MR? Do it before the registry switch.", owner: "(main)"},
        {id: "ask", key: "ask", verb: "captain-hold", title: "Plain question", reason: "Start the relock MR before the registry switch?", owner: "(main)"},
        {id: "worker-parked", key: "worker-parked", verb: "captain-hold", title: "Worker parked", reason: "Worker parked the branch; should the captain review it now?", owner: "(main)"}]' \
    "$TMP_ROOT/parked-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "relock" "$(jq -r '.waiting | map(.key) | join(",")' <<<"$p")" "a hold the captain parked is a waiting row"
  assert_equals "ask,worker-parked" "$(jq -r '.captains_call | map(.key) | sort | join(",")' <<<"$p")" "a question with no captain park stays a card"
  printf '%s\n' "$p" > "$TMP_ROOT/parked-payload.json"
  validates "$TMP_ROOT/parked-payload.json" || fail "a payload with a parked hold did not satisfy the board validator"
  pass "a captain-parked hold waits while an open question remains a card"
}

test_a_card_heading_is_one_short_asking_sentence_without_correlation_ids() {
  local snap="$TMP_ROOT/heading.json" p long
  long="PR 13 answer recorded and the worker told to update PR 13: drop what forge-ops already set up, choose the commit-stage lints and checks, and ask with a recommendation for each real choice; no merge. PR 14 adds the simplest-prompt option; its own tests pass."
  write_snapshot "$TMP_ROOT/heading-base.json"
  jq --arg long "$long" '.decisions_open += [
        {id: "mate/fos", key: "status.mate.fos.default", verb: "needs-decision", source: "status", task: "fos", decision_key: "default", owner: "mate",
         reason_full: ("corr=ab12cd34 corr=ef56 " + $long + " Question: wait or merge now? (a) wait for PR 13 (b) merge PR 14 now"), summary: "x",
         twins: [{reason_full: "corr=0a1b2c captain hold fos: Should pdm ship a module, or only document it in the README?"}]},
        {id: "hold-long", key: "hold-long", verb: "captain-hold", title: "Decide the rollout", owner: "(main)",
         reason_full: ($long + " " + $long + " Should the rollout start on Monday?")},
        {id: "mate/w", key: "status.mate.w.default", verb: "needs-decision", source: "status", task: "w", decision_key: "default", owner: "mate",
         reason_full: "corr=deadbeef waiting for the upstream release", summary: "waiting"}]' \
    "$TMP_ROOT/heading-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "0" "$(jq '[.. | strings | select(test("corr="))] | length' <<<"$p")" "no correlation token reaches any card or waiting row"
  assert_equals "mate: wait or merge now?" "$(jq -r '.captains_call[] | select(.key == "status.mate.fos.default") | .title' <<<"$p")" "a status card is titled by its asking sentence"
  assert_equals "true" "$(jq -r '.captains_call[] | select(.key == "status.mate.fos.default") | (.about | contains("PR 14 adds the simplest-prompt option") and contains("only document it in the README"))' <<<"$p")" "the full text of the question and its folded twin stays in the body"
  assert_equals "a,b,option-1,option-2" "$(jq -r '.captains_call[] | select(.key == "status.mate.fos.default") | [.options[].value] | join(",")' <<<"$p")" "the card keeps the lettered choices and the twin choices"
  assert_equals "Should the rollout start on Monday?" "$(jq -r '.captains_call[] | select(.key == "hold-long") | .question' <<<"$p")" "a long hold reason gets its asking sentence as the heading"
  assert_equals "true" "$(jq -r '.captains_call[] | select(.key == "hold-long") | (.question | length) <= 120 and (.about | length) > 400' <<<"$p")" "the heading stays short while the body keeps the full reason"
  assert_equals "waiting for the upstream release" "$(jq -r '.waiting[] | select(.key == "status.mate.w.default") | .reason' <<<"$p")" "a waiting row reads without its correlation token"
  printf '%s\n' "$p" > "$TMP_ROOT/heading-payload.json"
  validates "$TMP_ROOT/heading-payload.json" || fail "a payload with short headings did not satisfy the board validator"
  pass "a card heading is one short asking sentence and the full text is the body"
}

# A long asking sentence, its "?" past the heading's length after a long
# parenthetical, still heads its card as a question, so the build does not
# refuse it as a card that asks nothing. The text is the cd mate's real line.
test_a_long_asking_sentence_still_heads_its_card_as_a_question() {
  local snap="$TMP_ROOT/long-ask.json" p out reason
  reason="Review continuous-delivery PR 894 (#697 vulnerability scan: ci:non-functional-requirements scans what CD ships for known vulnerabilities), now that it is complete? It changes pipeline paths, so the acknowledgement-gate review 638 (raised on an older head) still blocks it. PR 894: the scan, with every review, QA and break finding fixed; head 4315087; all 7 checks green; https://forgejo.clarob.uk/rob/continuous-delivery/pulls/894. When you are satisfied, dismiss or approve on Forgejo yourself, and the cd mate merges once the block clears (after a rebase if main has moved). The scan runs only on main, so the first main pipeline after the merge shows it working."
  write_snapshot "$TMP_ROOT/long-ask-base.json"
  jq --arg r "$reason" '.decisions_open = [
        {id: "cd/cd-review-894", key: "status.cd.cd-review-894", verb: "needs-decision", source: "status",
         task: "cd", decision_key: "cd-review-894", owner: "cd", title: "cd", reason_full: $r, summary: "x"}]' \
    "$TMP_ROOT/long-ask-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "true" "$(jq -r '.captains_call[] | select(.key == "status.cd.cd-review-894")
      | (.question | endswith("?")) and (.question | length) <= 120 and (.question | startswith("Review continuous-delivery PR 894"))' <<<"$p")" \
    "a long asking sentence did not head its card as a short question"
  assert_equals "true" "$(jq -r '.captains_call[] | select(.key == "status.cd.cd-review-894") | .title | endswith("?")' <<<"$p")" \
    "a status card titled by a long asking sentence does not read as a question"
  printf '%s\n' "$p" > "$TMP_ROOT/long-ask-payload.json"
  out=$(build_checks "$TMP_ROOT/long-ask-payload.json")
  assert_not_contains "$out" "undecided-card" "the build refused a card whose long asking sentence asks: $out"
  pass "a long asking sentence still heads its card as a question and the build accepts it"
}

# A status question whose lead sentence states the subject and whose "?"
# sits only in its numbered calls does not ask in the card's own question,
# so the build flags that card rather than letting a "?" from its options or
# body pass for one. The text is the workload-pruner mate's real line.
test_a_card_whose_question_does_not_ask_is_flagged_even_when_its_options_ask() {
  local snap="$TMP_ROOT/calls-ask.json" p out reason
  reason="Research agent ticket #37, two calls the priors do not cover. 1) Which model runs the research agent? Recommend Fable, the strongest; agent time is cheap next to GPU time. 2) Where do ideas and their outcomes (refused and failed included) live? Recommend the existing lab notebook next to the run directories (scratch/runs/NOTES.md) as the one record, one entry per round, each idea with its status, so no idea is proposed twice without new evidence. Details: https://forgejo.clarob.uk/rob/workload-pruner/issues/37#issuecomment-33470"
  write_snapshot "$TMP_ROOT/calls-ask-base.json"
  jq --arg r "$reason" '.decisions_open = [
        {id: "workload-pruner/wp-37-grill", key: "status.workload-pruner.wp-37-grill", verb: "needs-decision",
         source: "status", task: "workload-pruner", decision_key: "wp-37-grill", owner: "workload-pruner",
         title: "workload-pruner", reason_full: $r, summary: "x"}]' \
    "$TMP_ROOT/calls-ask-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  printf '%s\n' "$p" > "$TMP_ROOT/calls-ask-payload.json"
  out=$(build_checks "$TMP_ROOT/calls-ask-payload.json")
  assert_contains "$out" "undecided-card: status.workload-pruner.wp-37-grill: missing question" \
    "the build let through a card whose question does not ask: $(jq -c '.captains_call[] | select(.key == "status.workload-pruner.wp-37-grill") | {title, question, decide}' <<<"$p") $out"
  pass "a card whose question does not ask is flagged even when its options ask"
}

test_default_choices_match_the_question_asked() {
  local snap="$TMP_ROOT/fit.json" p
  write_snapshot "$TMP_ROOT/fit-base.json"
  jq '.decisions_open = [
        {id: "alt", key: "alt", verb: "captain-hold", title: "Module", owner: "(main)", reason: "Issue 70 design is written up. Should pdm ship a home-manager module, or only document it in the README?"},
        {id: "yn", key: "yn", verb: "captain-hold", title: "Merge", owner: "(main)", reason: "PR 13 is green and reviewed. Should I merge it?"},
        {id: "open", key: "open", verb: "captain-hold", title: "Name", owner: "(main)", reason: "The flag needs a name before release. Which name do you want for it?"},
        {id: "ab", key: "ab", verb: "captain-hold", title: "Order", owner: "(main)", reason: "Two PRs touch the same file. Question: which lands first? (a) PR 13 first (b) PR 14 first"},
        {id: "plan", key: "plan", verb: "captain-hold", title: "Plan", owner: "(main)", reason: "Plan for the migration is ready for sign-off."},
        {id: "cd-872-874-dismiss", key: "cd-872-874-dismiss", verb: "captain-hold", title: "Dismiss stale reviews", owner: "(main)", reason: "Dismiss review 623 on PR 872 https://gitlab.example.com/grp/proj/-/merge_requests/872 and review 624 on PR 874 https://gitlab.example.com/grp/proj/-/merge_requests/874; the gate posted them before the fix landed."},
        {id: "relogin", key: "relogin", verb: "captain-hold", title: "Codex login", owner: "(main)", reason: "The codex credential expired. Captain to log in again with codex login."},
        {id: "rerun", key: "rerun", verb: "captain-hold", title: "Flaky CI", owner: "(main)", reason: "CI hit a runner timeout on PR 13. Please re-run the failed job."},
        {id: "go", key: "go", verb: "captain-hold", title: "Release", owner: "(main)", reason: "Release 2.4 is staged; approve the publish to the registry."}]' \
    "$TMP_ROOT/fit-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  opts() { jq -r --arg k "$1" '.captains_call[] | select(.key == $k) | [.options[].label] | join("|")' <<<"$p"; }
  assert_equals "Should pdm ship a home-manager module|Only document it in the README" "$(opts alt)" "an either-or question led by should offers its two alternatives, not yes and no"
  assert_equals "Yes|No" "$(opts yn)" "a plain should question offers yes and no"
  assert_equals "" "$(opts open)" "an open question offers no choices and takes a free-text answer"
  assert_equals "true" "$(jq -r '.captains_call[] | select(.key == "open") | .allow_freeform' <<<"$p")" "the open question card keeps its free-text box"
  assert_equals "PR 13 first|PR 14 first" "$(opts ab)" "lettered sub-questions become one choice each"
  assert_equals "Approve / go ahead|Decline" "$(opts plan)" "a sign-off request with no question offers approve and decline"
  assert_equals "Done|Not done (say why)" "$(opts cd-872-874-dismiss)" "a request to dismiss reviews offers done and not done, not approve"
  assert_equals "done,not-done" "$(jq -r '.captains_call[] | select(.key == "cd-872-874-dismiss") | [.options[].value] | join(",")' <<<"$p")" "the action card answers record done or not-done, never approve"
  assert_equals "Say why in the answer box|true" "$(jq -r '.captains_call[] | select(.key == "cd-872-874-dismiss") | "\(.options[1].hint)|\(.allow_freeform)"' <<<"$p")" "not done asks for the reason and the card keeps its answer box"
  assert_equals "false" "$(jq -r '.captains_call[] | select(.key == "cd-872-874-dismiss") | has("close")' <<<"$p")" "an action card declares no close mode, so done is never a release"
  assert_equals "Done|Not done (say why)" "$(opts relogin)" "a request that the captain log in offers done and not done"
  assert_equals "Done|Not done (say why)" "$(opts rerun)" "a request to re-run a job offers done and not done"
  assert_equals "Approve / go ahead|Decline" "$(opts go)" "an approval request keeps approve and decline"
  printf '%s\n' "$p" > "$TMP_ROOT/fit-payload.json"
  validates "$TMP_ROOT/fit-payload.json" || fail "a payload with fitted choices did not satisfy the board validator"
  pass "default choices match the question the card asks"
}

test_action_card_answers_reach_the_intake_as_the_captains_report() {
  local result="$TMP_ROOT/action-answers.result" out
  # What the board queues when the captain picks Done, or Not done with a reason.
  cat > "$result" <<'EOF'
session:
  file: /board.html
  status: feedback
prompts[2]{uid,prompt,selector,tag,text}:
  "1","Captain's Call answer - Dismiss stale reviews: done\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"cd-872-874-dismiss\",\n  \"selection\": \"done\",\n  \"note\": \"\"\n}","form",choice,"Dismiss stale reviews -> done"
  "2","Captain's Call answer - Codex login: not-done - no access from here\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"relogin\",\n  \"selection\": \"not-done\",\n  \"note\": \"no access from here\"\n}","form",choice,"Codex login -> not-done - no access from here"
EOF
  out=$("$ROOT/bin/fm-procevent-lavish.sh" answers "$result") || fail "the board answers could not be read"
  assert_equals "$(printf 'cd-872-874-dismiss\tdone\tDismiss stale reviews -> done\nrelogin\tnot-done - no access from here\tCodex login -> not-done - no access from here')" "$out" \
    "done and not done reach the keyed-answer intake as the captain's words, the reason kept, and no release mode"
  pass "an action card's done or not-done answer reaches the intake as the captain's report, never a release"
}

test_a_card_whose_pr_merged_or_closed_leaves_the_board() {
  local snap="$TMP_ROOT/live-pr.json" fd="$TMP_ROOT/forge-live" p
  fresh_homes live-pr
  mkdir -p "$fd"
  printf 'state=MERGED\nmerged=true\n' > "$fd/github-acme-alpha-3"
  printf '{"state":"closed"}\n' > "$fd/gitlab-gitlab.example.com_grp_sub_proj-801"
  printf '{"state":"closed","merged":true,"head":{"sha":"0a1b2c"}}\n' > "$fd/forgejo-own_rep-5"
  printf 'state=OPEN\nmerged=false\n' > "$fd/github-acme-open-9"
  printf 'hang\n' > "$fd/github-acme-slow-4"
  printf 'state=CLOSED\nmerged=false\n' > "$fd/github-acme-ext-11"
  write_snapshot "$TMP_ROOT/live-pr-base.json"
  jq '.decisions_open += [
        {id: "gl", key: "gl", verb: "captain-hold", title: "GitLab MR", reason: "Merge https://gitlab.example.com/grp/sub/proj/-/merge_requests/801 once the reviewers sign off?", owner: "(main)"},
        {id: "fj", key: "fj", verb: "captain-hold", title: "Forgejo PR", reason: "Approve https://forge.example/own/rep/pulls/5 for release?", owner: "(main)"},
        {id: "op", key: "op", verb: "captain-hold", title: "Open PR", reason: "Merge https://github.com/acme/open/pull/9 now?", owner: "(main)"},
        {id: "slow", key: "slow", verb: "captain-hold", title: "Slow forge", reason: "Merge https://github.com/acme/slow/pull/4 now?", owner: "(main)"},
        {id: "lk", key: "lk", verb: "captain-hold", title: "Lookup fails", reason: "Merge https://github.com/acme/none/pull/2 now?", owner: "(main)"}]
      | .contributions.captain = [
        {task: "ext", url: "https://github.com/acme/ext/pull/11", kind: "pr", reason: "checks green; merge approval needed"}]' \
    "$TMP_ROOT/live-pr-base.json" > "$snap"
  p=$(FORGE_DIR="$fd" FM_BEARINGS_BOARD_PR_TIMEOUT=1 "$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "alpha-fix,old-row,op,slow,lk" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" \
    "a merge ask whose PR or MR merged or closed leaves, and an open, slow or unreadable one or a non-merge question stays"
  p=$(FORGE_DIR="$fd" FM_BEARINGS_BOARD_PR_CHECK=0 "$GEN" --snapshot "$snap") || fail "the generator failed with the check off"
  assert_equals "alpha-fix,old-row,gl,fj,op,slow,lk,contribution.ext" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" \
    "with the live check off every card stays"
  pass "the board drops cards whose PR or MR merged or closed and keeps a card when the lookup fails"
}

# A merged PR settles a question only when the question was whether to merge
# it. A hold or status question asked after the merge (apply the plan, delete
# old jobs) stays, even when every PR it links or inherits merged.
test_a_question_after_a_merge_stays_and_a_stale_merge_ask_leaves() {
  local snap="$TMP_ROOT/post-merge.json" fd="$TMP_ROOT/forge-post-merge" p
  fresh_homes post-merge
  mkdir -p "$fd"
  for n in 13 18 19 65 68; do printf 'state=MERGED\nmerged=true\n' > "$fd/github-acme-run-$n"; done
  write_snapshot "$TMP_ROOT/post-merge-base.json"
  jq '.decisions_open = [
        {id: "apply-plan", key: "apply-plan", verb: "captain-hold", title: "Approve the pinned plan", owner: "(main)",
         reason: "Should the worker apply the lock-fix plan? PR 68 is merged but not yet applied to the cluster.",
         pr_url: "https://github.com/acme/run/pull/68",
         choices: {options: [{value: "a", label: "Apply the pinned plan"}, {value: "c", label: "Do not apply yet"}],
                   links: [{target: "https://github.com/acme/run/pull/68", label: "PR 68"}], free_text: true, no_link: false}},
        {id: "old-jobs", key: "old-jobs", verb: "captain-hold", title: "Bulk-delete old runner Jobs", owner: "(main)",
         reason: "About 850 old Jobs predate the new dispatcher. Delete them in bulk? (a) yes, delete them (b) no, leave them.",
         pr_url: "https://github.com/acme/run/pull/65",
         choices: {options: [{value: "a", label: "Yes, delete them"}, {value: "b", label: "No, leave them"}],
                   links: [], free_text: true, no_link: true}},
        {id: "runner/plan", key: "status.runner.plan", verb: "needs-decision", source: "status", task: "runner", decision_key: "plan", owner: "(main)",
         title: "runner", reason: "Pinned plan changes only the ConfigMap, exactly the PR 68 diff. Apply exactly the saved pinned plan?",
         pr_url: "https://github.com/acme/run/pull/68"},
        {id: "merge-run", key: "merge-run", verb: "captain-hold", title: "Merge the runner PRs", owner: "(main)",
         reason: "Merge these green PRs in order: first PR 19 https://github.com/acme/run/pull/19, then PR 18 https://github.com/acme/run/pull/18?",
         choices: {options: [{value: "both", label: "Merge 19 and 18"}, {value: "none", label: "Merge none for now"}],
                   links: [], free_text: false, no_link: false}},
        {id: "order-run", key: "order-run", verb: "captain-hold", title: "Runner PR order", owner: "(main)",
         reason: "Two runner PRs are green. Which order?", pr_url: "https://github.com/acme/run/pull/13",
         choices: {options: [{value: "a", label: "Merge 13 first"}, {value: "b", label: "Merge 18 first"}],
                   links: [], free_text: false, no_link: false}},
        {id: "runner/merge", key: "status.runner.merge", verb: "needs-decision", source: "status", task: "runner", decision_key: "merge", owner: "(main)",
         title: "runner", reason: "checks green; merge https://github.com/acme/run/pull/65 now?"}]' \
    "$TMP_ROOT/post-merge-base.json" > "$snap"
  p=$(FORGE_DIR="$fd" "$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "apply-plan,old-jobs,status.runner.plan" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" \
    "a question asked after its PR merged left the board, or a stale merge ask stayed"
  assert_equals "Apply the pinned plan|Do not apply yet" \
    "$(jq -r '.captains_call[] | select(.key == "apply-plan") | [.options[].label] | join("|")' <<<"$p")" \
    "a post-merge hold lost its recorded choices"
  printf '%s\n' "$p" > "$TMP_ROOT/post-merge-payload.json"
  validates "$TMP_ROOT/post-merge-payload.json" || fail "a payload with post-merge questions did not satisfy the board validator"
  pass "a question asked after a merge stays on the board, and only a merge ask whose PRs all merged leaves"
}

test_announcements_and_time_gates_are_not_calls_and_a_real_question_stays() {
  local snap="$TMP_ROOT/announce.json" p
  fresh_homes announce
  write_snapshot "$TMP_ROOT/announce-base.json"
  jq '.decisions_open = [
        {id: "rp", key: "status.rp.default", verb: "needs-decision", source: "status", task: "rp", decision_key: "default", owner: "(main)",
         title_full: "rp", reason_full: "review page live: http://dev-1.tailf848b0.ts.net:4387/session/5e96b7b8f3b4f9db", summary: "review page live"},
        {id: "up", key: "status.up.default", verb: "needs-decision", source: "status", task: "up", decision_key: "default", owner: "(main)",
         title_full: "up", reason_full: "understand page live: http://dev-1.tailf848b0.ts.net:4387/session/988b504d3271c0ea", summary: "understand page live"},
        {id: "pr", key: "status.pr.default", verb: "needs-decision", source: "status", task: "pr", decision_key: "default", owner: "(main)",
         title_full: "pr", reason_full: "PR ready: https://github.com/acme/app/pull/77", summary: "PR ready"},
        {id: "tg", key: "tg", verb: "captain-hold", title: "Trial rerun", reason: "not before 2026-12-01; rerun the trial with the new data", owner: "(main)"},
        {id: "bk", key: "bk", verb: "captain-hold", title: "Blocked", reason: "needs the registry switch first", hold_bucket: "blocked", owner: "(main)"},
        {id: "pdm", key: "status.pdm-systemd.default", verb: "needs-decision", source: "status", task: "pdm-systemd", decision_key: "default", owner: "(main)",
         title_full: "pdm-systemd", reason_full: "Two ways to order the units: (1) the dotfiles wait for the mount (2) the mount unit pulls in the dotfiles", summary: "Two ways"},
        {id: "rt", key: "status.rt.default", verb: "needs-decision", source: "status", task: "rt", decision_key: "default", owner: "(main)",
         title_full: "rt", reason_full: "Which retry policy should ship: fixed or exponential?", summary: "Which retry policy"}]' \
    "$TMP_ROOT/announce-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "status.pdm-systemd.default,status.rt.default" "$(jq -r '[.captains_call[].key] | sort | join(",")' <<<"$p")" \
    "only a real question is a card, including one whose options mention waiting"
  assert_equals "bk,tg" "$(jq -r '[.waiting[].key] | sort | join(",")' <<<"$p")" "a time gate and a blocked hold wait"
  assert_equals "0" "$(jq '[.. | objects | select(.key? == "status.rp.default" or .key? == "status.up.default" or .key? == "status.pr.default")] | length' <<<"$p")" \
    "an announcement with no card for its work appears nowhere"
  printf '%s\n' "$p" > "$TMP_ROOT/announce-payload.json"
  validates "$TMP_ROOT/announce-payload.json" || fail "a payload with announcements dropped did not satisfy the board validator"
  pass "announcements and time gates are not calls and a real question stays a card"
}

test_page_live_lines_fold_their_links_into_the_mr_card() {
  local snap="$TMP_ROOT/fold.json" p
  fresh_homes fold
  write_snapshot "$TMP_ROOT/fold-base.json"
  jq '.decisions_open += [
        {id: "mr-fix", key: "mr-fix", verb: "captain-hold", title: "Review the retry MR", reason: "Approve https://gitlab.example.com/grp/proj/-/merge_requests/801 once the bot comments are read", owner: "(main)"},
        {id: "mr-fix", key: "status.mr-fix.understand", verb: "needs-decision", source: "status", task: "mr-fix", decision_key: "understand", owner: "(main)",
         title_full: "mr-fix", reason_full: "understand page live: http://dev-1.tailf848b0.ts.net:4387/session/aaaa1111", summary: "understand page live"},
        {id: "mr-fix", key: "status.mr-fix.review", verb: "needs-decision", source: "status", task: "mr-fix", decision_key: "review", owner: "(main)",
         title_full: "mr-fix", reason_full: "review page live: http://dev-1.tailf848b0.ts.net:4387/session/bbbb2222", summary: "review page live"},
        {id: "ship-x", key: "status.ship-x.ready", verb: "needs-decision", source: "status", task: "ship-x", decision_key: "ready", owner: "(main)",
         title_full: "ship-x", reason_full: "PR ready: https://github.com/acme/alpha/pull/3", summary: "PR ready"}]' \
    "$TMP_ROOT/fold-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "alpha-fix,mr-fix,old-row" "$(jq -r '[.captains_call[].key] | sort | join(",")' <<<"$p")" "each MR keeps one card and a page-live line adds none"
  assert_equals "0" "$(jq '.waiting | length' <<<"$p")" "a folded page-live line is not a waiting row"
  assert_equals "http://dev-1.tailf848b0.ts.net:4387/session/aaaa1111,http://dev-1.tailf848b0.ts.net:4387/session/bbbb2222,https://gitlab.example.com/grp/proj/-/merge_requests/801" \
    "$(jq -r '.captains_call[] | select(.key == "mr-fix") | .links | map(.url) | join(",")' <<<"$p")" "the MR card carries the understand page, the review page and the MR"
  assert_equals "Understand page,Review page" \
    "$(jq -r '.captains_call[] | select(.key == "mr-fix") | .links[:2] | map(.label) | join(",")' <<<"$p")" "each page link is labelled by its line"
  assert_equals "https://github.com/acme/alpha/pull/3" "$(jq -r '.captains_call[] | select(.key == "alpha-fix") | .links | map(.url) | join(",")' <<<"$p")" \
    "a PR-ready line folds into the card for the same PR"
  printf '%s\n' "$p" > "$TMP_ROOT/fold-payload.json"
  validates "$TMP_ROOT/fold-payload.json" || fail "a payload with folded page links did not satisfy the board validator"
  pass "page-live lines fold their links into the matching MR card"
}

test_a_secondmate_dated_hold_waits_with_its_date() {
  local snap="$TMP_ROOT/sm-dated.json" p
  fresh_homes sm-dated
  write_snapshot "$TMP_ROOT/sm-dated-base.json"
  jq '.decisions_open = [
        {id: "home7/explore-trial-measure", key: "explore-trial-measure", verb: "captain-hold", title: "Explore trial measure", reason: "Pick the trial metric", hold_until: "2999-11-14", hold_bucket: "dated", owner: "home7"},
        {id: "bucket-only", key: "bucket-only", verb: "captain-hold", title: "Bucket only", reason: "Pick the window", hold_bucket: "dated", owner: "(main)"},
        {id: "home7/live", key: "live", verb: "captain-hold", title: "Live call", reason: "Pick the dataset", hold_bucket: "live", owner: "home7"}]' \
    "$TMP_ROOT/sm-dated-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "live" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" "only the live hold is a card"
  assert_equals "home7: Explore trial measure|until 2999-11-14: Pick the trial metric" \
    "$(jq -r '.waiting[] | select(.key == "home7-explore-trial-measure") | "\(.title)|\(.reason)"' <<<"$p")" \
    "a secondmate hold deferred to a later date waits with its date"
  assert_equals "1" "$(jq '[.waiting[] | select(.key == "bucket-only")] | length' <<<"$p")" "a hold the fleet dated waits"
  assert_equals "0" "$(jq '[.charted[] | select(.id == "bucket-only" or .id == "home7-explore-trial-measure")] | length' <<<"$p")" "a dated hold is not charted"
  printf '%s\n' "$p" > "$TMP_ROOT/sm-dated-payload.json"
  validates "$TMP_ROOT/sm-dated-payload.json" || fail "a payload with dated waiting holds did not satisfy the board validator"
  pass "a dated hold from any home waits with its date"
}

# Every open held or in-flight task in a second mate home names what it waits
# on: a held gate is a waiting row (with its date while that is in the future,
# or its outside party from its reason), a second mate's in-flight child is
# under way, and a row whose PR or MR merged leaves Under way.
test_every_held_or_in_flight_secondmate_task_has_a_row() {
  local snap="$TMP_ROOT/sm-cover.json" p
  fresh_homes sm-cover
  write_snapshot "$TMP_ROOT/sm-cover-base.json"
  jq '.decisions_open = []
      | .gates += [
          {id: "pinocchio-litellm-mr", title: "LiteLLM MR", blocked_by: "-", reason: "blocked on DevOps: new service for agent access in CI", hold_kind: "external", owner: "intake", filed: "2026-11-20"},
          {id: "gke-cp-ip-close", title: "Close the GKE control plane IP", blocked_by: "-", reason: "Soak gate before closing", hold_kind: "until", hold_until: "2999-11-26", owner: "runner-image", filed: "2026-11-20"},
          {id: "lapsed-park", title: "Lapsed park", blocked_by: "-", reason: "Soak ended", hold_kind: "external", hold_until: "2020-01-01", owner: "runner-image", filed: "2026-11-20"},
          {id: "lapsed-date", title: "Lapsed date", blocked_by: "-", reason: "-", hold_until: "2020-01-01", owner: "runner-image", filed: "2026-11-20"}]
      | .in_flight += [
          {id: "fos-rulings-research/fos-insurer-facts", name: "Insurer facts", repo: "fos", state: "done", doing: "-", kind: "ship"},
          {id: "workload-pruner/wp-r1-i1-why", name: "R1-I1 why", repo: "wp", state: "working", doing: "reading", kind: "scout"},
          {id: "intake/pinocchio-litellm-mr", name: "LiteLLM MR", repo: "pinocchio", state: "parked", doing: "-", kind: "ship"},
          {id: "cd-962-main-acceptance", name: "Main acceptance", repo: "cd", state: "parked", doing: "-", kind: "ship", pr_url: "https://github.com/acme/widgets/pull/7"},
          {id: "cd/cd-merged-child", name: "Merged child", repo: "cd", state: "parked", doing: "-", kind: "ship", pr_url: "https://github.com/acme/widgets/pull/7"},
          {id: "cd/cd-open-child", name: "Open child", repo: "cd", state: "parked", doing: "-", kind: "ship", pr_url: "https://github.com/acme/widgets/pull/8"},
          {id: "cd/cd-working-child", name: "Working child", repo: "cd", state: "working", doing: "fixing", kind: "ship", pr_url: "https://github.com/acme/widgets/pull/7"}]' \
    "$TMP_ROOT/sm-cover-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "intake: LiteLLM MR|blocked on DevOps: new service for agent access in CI|pinocchio" \
    "$(jq -r '.waiting[] | select(.key == "intake-pinocchio-litellm-mr") | "\(.title)|\(.reason)|\(.repo)"' <<<"$p")" \
    "an external hold waits naming its outside party"
  assert_equals "until 2999-11-26: Soak gate before closing" \
    "$(jq -r '.waiting[] | select(.key == "runner-image-gke-cp-ip-close") | .reason' <<<"$p")" \
    "a future-dated hold waits with its date"
  assert_equals "Soak ended" "$(jq -r '.waiting[] | select(.key == "runner-image-lapsed-park") | .reason' <<<"$p")" \
    "a hold whose date passed waits without a stale date"
  assert_equals "0" "$(jq '[.charted[] | select(.id | test("litellm|gke-cp|lapsed-park"))] | length' <<<"$p")" "a held gate is not charted"
  assert_equals "Lapsed date" "$(jq -r '.charted[] | select(.id == "lapsed-date") | .title' <<<"$p")" \
    "a gate whose only hold was a date now past is charted work again"
  local ids
  ids=$(jq -r '[.underway[].id] | join(",")' <<<"$p")
  assert_contains "$ids" "fos-rulings-research/fos-insurer-facts" "a second mate child that is done stays under way until its home cleans it up"
  assert_contains "$ids" "workload-pruner/wp-r1-i1-why" "a second mate in-flight child is under way"
  assert_contains "$ids" "cd/cd-open-child" "a row whose PR is still open stays under way"
  assert_contains "$ids" "cd/cd-working-child" "a working row stays under way even when its PR merged"
  assert_not_contains "$ids" "intake/pinocchio-litellm-mr" "a row its held gate already shows as waiting leaves Under way"
  assert_not_contains "$ids" "cd-962-main-acceptance" "a main row whose PR merged leaves Under way"
  assert_not_contains "$ids" "cd/cd-merged-child" "a second mate row whose PR merged leaves Under way"
  assert_not_contains "$ids" "t2" "a main row that is done is not under way"
  printf '%s\n' "$p" > "$TMP_ROOT/sm-cover-payload.json"
  validates "$TMP_ROOT/sm-cover-payload.json" || fail "a payload with held-gate waiting rows did not satisfy the board validator"
  pass "every held or in-flight second mate task has a row naming its wait"
}

test_a_round_a_newer_round_superseded_leaves_the_board() {
  local snap="$TMP_ROOT/rounds.json" p
  fresh_homes rounds
  write_snapshot "$TMP_ROOT/rounds-base.json"
  jq '.decisions_open = [
        {id: "sweep-r2", key: "sweep-r2", verb: "captain-hold", title: "Sweep round 2", reason: "Pick the sweep grid", owner: "(main)"},
        {id: "sweep", key: "sweep", verb: "captain-hold", title: "Sweep", reason: "Pick the first sweep grid", owner: "(main)"},
        {id: "home7/tune-v1", key: "tune-v1", verb: "captain-hold", title: "Tune v1", reason: "Pick the learning rate", owner: "home7"},
        {id: "fix-issue-41", key: "fix-issue-41", verb: "captain-hold", title: "Issue 41", reason: "Pick the fix", owner: "(main)"},
        {id: "probe-v1", key: "probe-v1", verb: "captain-hold", title: "Main probe", reason: "Pick the probe set", owner: "(main)"}]
      | .in_flight += [
        {id: "sweep-r3", name: "Sweep round 3", repo: "alpha", state: "working", doing: "-", kind: "ship"},
        {id: "home7/tune-v2", name: "Tune v2", repo: "alpha", state: "working", doing: "-", kind: "ship"},
        {id: "fix-issue-42", name: "Issue 42", repo: "alpha", state: "working", doing: "-", kind: "ship"},
        {id: "home7/probe-v2", name: "Probe v2", repo: "alpha", state: "working", doing: "-", kind: "ship"}]' \
    "$TMP_ROOT/rounds-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "fix-issue-41,probe-v1" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" \
    "a round a newer round of the same work superseded leaves, in its own home only"
  pass "a superseded round leaves the board"
}

test_a_numbered_option_question_stays_a_card_when_an_option_says_until() {
  local snap="$TMP_ROOT/opt-until.json" p
  fresh_homes opt-until
  write_snapshot "$TMP_ROOT/opt-until-base.json"
  jq '.decisions_open = [
        {id: "mr-872", key: "mr-872", verb: "captain-hold", title: "MR 872 review", reason: "Bot comments on https://gitlab.example.com/grp/proj/-/merge_requests/872 are in: (1) Post nothing until I finish both pages (2) post the blocking finding now", owner: "(main)"},
        {id: "mr-874", key: "mr-874", verb: "captain-hold", title: "MR 874 review", reason: "Until the pages are done: (1) wait for the understand page (2) post the bot findings now", owner: "(main)"},
        {id: "hold", key: "hold", verb: "captain-hold", title: "Plain wait", reason: "until the upstream release lands", owner: "(main)"}]' \
    "$TMP_ROOT/opt-until-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "mr-872,mr-874" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" "a reason with numbered options is a question card"
  assert_equals "hold" "$(jq -r '[.waiting[].key] | join(",")' <<<"$p")" "a plain until reason still waits"
  pass "an until or wait inside an option never turns a numbered-option question into a wait"
}

test_card_links_are_labelled_by_what_they_point_at() {
  local snap="$TMP_ROOT/labels.json" p
  fresh_homes labels
  write_snapshot "$TMP_ROOT/labels-base.json"
  jq '.decisions_open = [
        {id: "mr-872", key: "mr-872", verb: "captain-hold", title: "MR 872 review", reason: "Bot comments on https://gitlab.example.com/grp/proj/-/merge_requests/872 are in; understand page at http://dev-1.tailf848b0.ts.net:4387/session/aaaa1111, review page at http://dev-1.tailf848b0.ts.net:4387/session/bbbb2222. Post the blocking finding now?", owner: "(main)"},
        {id: "pr-837", key: "pr-837", verb: "captain-hold", title: "PR 837", reason: "Merge https://github.com/acme/app/pull/837 after https://github.com/acme/app/issues/12 closes?", owner: "(main)"}]' \
    "$TMP_ROOT/labels-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "MR 872,Understand page,Review page" "$(jq -r '.captains_call[] | select(.key == "mr-872") | .links | map(.label) | join(",")' <<<"$p")" \
    "MR and Lavish page links are labelled by what they are"
  assert_equals "PR 837,Issue 12" "$(jq -r '.captains_call[] | select(.key == "pr-837") | .links | map(.label) | join(",")' <<<"$p")" "PR and issue links are labelled by number"
  assert_equals "Bot comments on MR 872 are in; understand page at Understand page, review page at Review page." \
    "$(jq -r '.captains_call[] | select(.key == "mr-872") | .about' <<<"$p")" "the card text names each link instead of repeating its URL"
  assert_equals "0" "$(jq '[.captains_call[] | (.question // ""), (.about // "") | select(test("https?://"))] | length' <<<"$p")" "no question or about text repeats a raw URL"
  printf '%s\n' "$p" > "$TMP_ROOT/labels-payload.json"
  validates "$TMP_ROOT/labels-payload.json" || fail "a payload with labelled links did not satisfy the board validator"
  pass "card links are labelled by what they point at and question text shows the labels"
}

# The decisions the captain annotated on the board: each card offers the
# decision's own options in full and in captain terms, and a decision answered
# on its Lavish page shows only the link to that page.
test_annotated_decisions_offer_their_own_full_options_in_captain_terms() {
  local snap="$TMP_ROOT/annotated.json" p
  fresh_homes annotated
  write_snapshot "$TMP_ROOT/annotated-base.json"
  jq '.decisions_open = [
    {id: "ci-onboard", key: "ci-onboard", verb: "captain-hold", owner: "(main)", title: "Onboard to the CI pipeline with lint and test checks",
     reason: "Merge PR 13: (1) Add the CD_PIPELINE_TOKEN secret, then merge once all checks pass (recommended) (2) Merge now and skip the one failing check. https://github.com/acme/research/pull/13"},
    {id: "ready-signal", key: "ready-signal", verb: "captain-hold", owner: "(main)", title: "Should the tool tell systemd when the mount is ready?",
     reason: "Keep the optional systemd ready signal (PR 89)? 1) Keep it. 2) Drop it: close PR 89 and #68; if anything needs it, dotfiles wait for the folder to mount. Recommendation: 2, since the mount never needs systemd."},
    {id: "cd/gate-part2", key: "status.cd.gate-part2", verb: "needs-decision", source: "status", task: "gate-part2", decision_key: "default", owner: "cd",
     reason: "#835 second half - a gate stop already posted never clears, even after a later push removes nothing. Changing it is a published-contract choice: A) leave it; PR 837 stops new false stops, and the stale ones get one manual dismissal each (recommended). B) the gate dismisses its own stop when a later run finds nothing; every adopter then needs review-dismiss rights and the earlier ruling reverses. C) a later run posts APPROVE to clear it; that makes the gate an approver, against the gate judging nothing. Detail: /fixture/part2-decision.md"},
    {id: "cd/gate-merge", key: "status.cd.gate-merge", verb: "needs-decision", source: "status", task: "gate-merge", decision_key: "default", owner: "cd", title: "#835 fix is two PRs",
     reason: "#835 fix is two PRs. 1) Spec PR https://github.com/acme/cd/pull/836 (regression scenario) is green; it carries the gate review 576, so it needs your dismissal and your merge word. 2) Fix PR https://github.com/acme/cd/pull/837 (gate measures removals from the merge base) is red on acceptance only until 836 lands; then it rebases and goes green for your merge word."},
    {id: "research/round5", key: "status.research.round5", verb: "needs-decision", source: "status", task: "round5", decision_key: "default", owner: "research",
     reason: "Grilling round 5 (research plan without the pipeline) is on one Lavish page: http://dev-1.tailf848b0.ts.net:4387/session/988b504d3271c0ea - 7 questions, each with options and a recommendation: (1) run the baseline now (rec: yes); (2) scored candidates (rec: two smaller models); (3) techniques (rec: add one combined arm). PR 13 stays parked."},
    {id: "research/exp1", key: "status.research.exp1", verb: "needs-decision", source: "status", task: "exp1", decision_key: "default", owner: "research",
     reason: "experiment 1 plan revised per the note: the page now shows the exact current prompt and a proposed simplest prompt with no aids. Decision: use it as written (recommended) / name the Act / change wording. No calls made. Page http://dev-1.tailf848b0.ts.net:4387/session/53e6c4bcfdcacae4. PR 13 stays parked."},
    {id: "review-mr872", key: "status.review-mr872.post-question", verb: "needs-decision", source: "status", task: "review-mr872", decision_key: "post-question", owner: "(main)", title: "Review page for MR 872",
     reason: "a product question for MR 872 is held unposted with a draft in the review report. Options: firstmate posts it / I post it if authorized / keep held. https://gitlab.example.com/grp/app/-/merge_requests/872"}]' "$TMP_ROOT/annotated-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  card() { jq -c --arg k "$1" '.captains_call[] | select(.key == $k)' <<<"$p"; }
  opts() { card "$1" | jq -r '[.options[].label] | join("|")'; }
  assert_equals "Merge PR 13" "$(card ci-onboard | jq -r .question)" "a numbered list heading comes from the sentence that introduces it"
  assert_equals "Add the CD_PIPELINE_TOKEN secret, then merge once all checks pass|Merge now and skip the one failing check" "$(opts ci-onboard)" "numbered options are the choices, not approve and decline"
  assert_equals "option-1" "$(card ci-onboard | jq -r .recommend_value)" "a trailing (recommended) marks its option as the recommendation"
  assert_equals "Keep it|Drop it: close PR 89 and #68; if anything needs it, dotfiles wait for the folder to mount" "$(opts ready-signal)" "a long option is kept in full"
  assert_equals "Recommendation: 2, since the mount never needs systemd." "$(card ready-signal | jq -r .about)" "the body does not repeat the heading or the options"
  assert_equals "3" "$(card status.cd.gate-part2 | jq '.options | length')" "the third lettered option is not lost"
  assert_equals "A later run posts APPROVE to clear it; that makes the gate an approver, against the gate judging nothing" "$(card status.cd.gate-part2 | jq -r '.options[2].label')" "the third option keeps its full text"
  assert_equals "option-1,option-2" "$(card status.cd.gate-merge | jq -r '[.options[].value] | join(",")')" "numbered options after a plain sentence are the choices"
  assert_equals "Post it for me|The worker posts it if authorized|Keep held" "$(opts status.review-mr872.post-question)" "worker-perspective options are put in captain terms"
  assert_equals "A product question for MR 872 is held unposted with a draft in the review report" "$(card status.review-mr872.post-question | jq -r .question)" "the heading starts with a capital letter"
  assert_equals "0" "$(jq '[.captains_call[] | .options[].value | select(. == "approve" or . == "decline")] | length' <<<"$p")" "no decision with its own options offers approve or decline"
  for k in status.research.round5 status.research.exp1; do
    assert_equals '{"options":[],"allow_freeform":false,"about":null,"question":null,"links":["Lavish page"]}' \
      "$(card "$k" | jq -c '{options, allow_freeform, about, question, links: [.links[].label]}')" "a page-backed decision shows only the page link"
  done
  assert_equals "research: Grilling round 5 (research plan without the pipeline)" "$(card status.research.round5 | jq -r .title)" "a page-backed card is titled by what its page is about"
  assert_equals "research: experiment 1 plan revised per the note" "$(card status.research.exp1 | jq -r .title)" "a page-backed card is titled by what its page is about"
  printf '%s\n' "$p" > "$TMP_ROOT/annotated-payload.json"
  validates "$TMP_ROOT/annotated-payload.json" || fail "a payload with the annotated decisions did not satisfy the board validator"
  pass "annotated decisions offer their own full options in captain terms, and page-backed ones only the page link"
}

# The body drops a reason's option list because the options are the card's
# choices, so it also drops the words that only introduced that list.
test_the_body_drops_the_words_that_introduced_its_options() {
  local snap="$TMP_ROOT/intro.json" p
  fresh_homes intro
  write_snapshot "$TMP_ROOT/intro-base.json"
  jq '.decisions_open = [
    {id: "intake-picks", key: "intake-picks", verb: "captain-hold", owner: "(main)", title: "Pick which intake candidates to start",
     reason: "Start the three ready tickets now? They are APP-1 and APP-2. Options are (a) all three, (b) only some, named in a note, (c) none for now. The other tickets wait for open MRs."},
    {id: "colon-intro", key: "colon-intro", verb: "captain-hold", owner: "(main)", title: "Pick a rollout",
     reason: "Roll the fix out today? The canary is green. Options: (1) all hosts, (2) one region first. The pager is quiet."}]' \
    "$TMP_ROOT/intro-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  card() { jq -c --arg k "$1" '.captains_call[] | select(.key == $k)' <<<"$p"; }
  assert_equals "All three|Only some, named in a note|None for now" "$(card intake-picks | jq -r '[.options[].label] | join("|")')" "the lettered options are the choices"
  assert_equals "They are APP-1 and APP-2. The other tickets wait for open MRs." "$(card intake-picks | jq -r .about)" "the body kept the words that introduced the options it dropped"
  card colon-intro | jq -e '.about | test("Options") | not' >/dev/null \
    || fail "the body kept a colon heading that introduced the options it dropped: $(card colon-intro | jq -r .about)"
  pass "the body drops the words that introduced the options it leaves to the card's choices"
}

# A decision the snapshot marks handed (the answer or the work went to a worker,
# or the captain marked the card out of date) is no longer the captain's call:
# it waits, saying who has it, until the worker raises a fresh question.
test_a_handed_decision_waits_with_who_has_it_instead_of_a_card() {
  local snap="$TMP_ROOT/handed.json" p
  write_snapshot "$TMP_ROOT/handed-base.json"
  jq '.decisions_open += [
        {id: "h1", key: "h1", verb: "captain-hold", title: "Post the comments", reason: "Post the review comments?", owner: "(main)",
         handed_at: "2026-11-13T09:30:00Z", handed_via: "steer", handed_task: "review-page-mr872", raised_at: "2026-11-13T09:00:00Z"},
        {id: "h2", key: "h2", verb: "captain-hold", title: "Round five", reason: "Approve round five?", owner: "(main)",
         handed_at: "2026-11-13T10:15:00Z", handed_via: "reconcile", handed_task: "firstmate", raised_at: "2026-11-13T09:00:00Z"},
        {id: "mate/q", key: "status.mate.q.pick", verb: "needs-decision", source: "status", task: "q", decision_key: "pick", owner: "mate",
         title_full: "q", reason_full: "Pick option one or two?", summary: "Pick option one or two?",
         handed_at: "2026-11-13T11:00:00Z", handed_via: "steer", handed_task: "q", raised_at: "2026-11-13T10:00:00Z"},
        {id: "q3", key: "q3", verb: "captain-hold", title: "Still open", reason: "Choose the public name?", owner: "(main)"}]' \
    "$TMP_ROOT/handed-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "0" "$(jq '[.captains_call[] | select(.key == "h1" or .key == "h2" or .key == "status.mate.q.pick")] | length' <<<"$p")" \
    "a handed decision is not a Captain's Call card"
  assert_equals "1" "$(jq '[.captains_call[] | select(.key == "q3")] | length' <<<"$p")" "an unhanded decision stays a card"
  assert_equals "With review-page-mr872 since 2026-11-13 09:30 UTC; it raises a fresh question when it needs the captain" \
    "$(jq -r '.waiting[] | select(.key == "h1") | .reason' <<<"$p")" "a decision handed by a steer waits on the worker that has it"
  assert_equals "true" "$(jq -r '.waiting[] | select(.key == "h2") | .reason | startswith("Marked out of date on the board at 2026-11-13 10:15 UTC")' <<<"$p")" \
    "a decision marked out of date on the board waits for firstmate to check it"
  assert_equals "1" "$(jq '[.waiting[] | select(.key == "status.mate.q.pick")] | length' <<<"$p")" "a handed status question waits too"
  printf '%s\n' "$p" > "$TMP_ROOT/handed-payload.json"
  validates "$TMP_ROOT/handed-payload.json" || fail "a payload with handed rows did not satisfy the board validator"
  pass "a handed decision waits, saying who has it, instead of showing as a card"
}

# The captain's stored priority only orders cards: an id it ranks first that has
# no open decision (answered, closed, or handed) never comes back as a card.
test_a_priority_never_brings_back_a_closed_or_handed_decision() {
  local snap="$TMP_ROOT/prio-closed.json" p
  local PRIO="$ROOT/bin/fm-board-priority.sh"
  write_snapshot "$TMP_ROOT/prio-closed-base.json"
  jq '.decisions_open += [
        {id: "h1", key: "h1", verb: "captain-hold", title: "Handed", reason: "Post the comments?", owner: "(main)",
         handed_at: "2026-11-13T09:30:00Z", handed_via: "steer", handed_task: "t1", raised_at: "2026-11-13T09:00:00Z"},
        {id: "q3", key: "q3", verb: "captain-hold", title: "Still open", reason: "Choose the public name?", owner: "(main)"}]' \
    "$TMP_ROOT/prio-closed-base.json" > "$snap"
  mkdir -p "$TMP_ROOT/prio-closed-data"
  FM_DATA_OVERRIDE="$TMP_ROOT/prio-closed-data" "$PRIO" set gone-call h1 q3 >/dev/null || fail "set failed"
  p=$(FM_DATA_OVERRIDE="$TMP_ROOT/prio-closed-data" "$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "0" "$(jq '[.captains_call[] | select(.key == "gone-call" or .key == "h1")] | length' <<<"$p")" \
    "a priority entry with no open decision created a card"
  assert_equals "0" "$(jq '[.waiting[]?, .charted[]? | select((.key // .id) == "gone-call")] | length' <<<"$p")" \
    "a priority entry with no open decision created a row"
  assert_equals "q3" "$(jq -r '[.captains_call[] | select(.key | test("^(q3|h1|gone-call)$")) | .key] | join(",")' <<<"$p")" \
    "only the open decision is a card"
  pass "the stored priority never brings back a closed or handed decision"
}


test_a_review_card_the_captain_approved_leaves_and_any_other_stays() {
  local snap="$TMP_ROOT/approved.json" fd="$TMP_ROOT/forge-approved" p
  fresh_homes approved
  mkdir -p "$fd"
  printf 'captain\n' > "$fd/github-user"
  printf '{"username":"captain"}\n' > "$fd/gitlab-user"
  printf '{"login":"captain"}\n' > "$fd/forgejo-user"
  # An MR the captain approved, behind a review-page card and a review-ready card.
  printf '{"state":"opened"}\n' > "$fd/gitlab-gitlab.example.com_grp_proj-874"
  printf '{"approved_by":[{"user":{"username":"captain"}}]}\n' > "$fd/gitlab-gitlab.example.com_grp_proj-874.approvals"
  printf 'state=OPEN\nmerged=false\n' > "$fd/github-acme-app-21"
  printf '[[{"user":{"login":"captain"},"state":"APPROVED"}]]\n' > "$fd/github-acme-app-21.reviews"
  # The captain approved, then asked for changes: the review is still owed.
  printf 'state=OPEN\nmerged=false\n' > "$fd/github-acme-app-22"
  printf '[[{"user":{"login":"captain"},"state":"APPROVED"},{"user":{"login":"captain"},"state":"CHANGES_REQUESTED"}]]\n' \
    > "$fd/github-acme-app-22.reviews"
  # Someone else approved; the captain's dismissed approval does not count.
  printf '{"state":"open","merged":false,"head":{"sha":"0a1b2c"}}\n' > "$fd/forgejo-own_rep-6"
  printf '[{"user":{"login":"bot"},"state":"APPROVED"},{"user":{"login":"captain"},"state":"APPROVED","dismissed":true}]\n' \
    > "$fd/forgejo-own_rep-6.reviews"
  # The captain approved, but the card asks whether to merge, not for a review.
  printf 'state=OPEN\nmerged=false\n' > "$fd/github-acme-app-23"
  printf '[[{"user":{"login":"captain"},"state":"APPROVED"}]]\n' > "$fd/github-acme-app-23.reviews"
  write_snapshot "$TMP_ROOT/approved-base.json"
  jq '.decisions_open = [
        {id: "mr874", key: "review.mr874", verb: "review-ready", source: "review-page", task: "mr874", title: "MR 874 review page",
         reason: "review page for https://gitlab.example.com/grp/proj/-/merge_requests/874", owner: "(main)"},
        {id: "rr21", key: "rr21", verb: "captain-hold", title: "Review PR 21",
         reason: "Please review the PR https://github.com/acme/app/pull/21 and re-review the PR once the bot answers", owner: "(main)"},
        {id: "rr22", key: "rr22", verb: "captain-hold", title: "Review PR 22",
         reason: "Please review the PR https://github.com/acme/app/pull/22 and re-review the PR after fixes", owner: "(main)"},
        {id: "rr6", key: "review.rr6", verb: "review-ready", source: "review-page", task: "rr6", title: "PR 6 review page",
         reason: "review page for https://forge.example/own/rep/pulls/6", owner: "(main)"},
        {id: "mg23", key: "mg23", verb: "captain-hold", title: "Merge PR 23",
         reason: "Merge https://github.com/acme/app/pull/23 now?", owner: "(main)"}]' \
    "$TMP_ROOT/approved-base.json" > "$snap"
  p=$(FORGE_DIR="$fd" "$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "mg23,review.rr6,rr22" "$(jq -r '[.captains_call[].key] | sort | join(",")' <<<"$p")" \
    "a review the captain approved leaves; a withdrawn, dismissed or merge-question approval keeps its card"
  printf '%s\n' "$p" > "$TMP_ROOT/approved-payload.json"
  validates "$TMP_ROOT/approved-payload.json" || fail "a payload without approved reviews did not satisfy the board validator"
  pass "a review card the captain already approved never asks again, and every other card stays"
}

test_a_freeze_or_a_hold_that_says_it_is_no_decision_waits_instead_of_asking() {
  local snap="$TMP_ROOT/freeze.json" p
  fresh_homes freeze
  write_snapshot "$TMP_ROOT/freeze-base.json"
  jq '.decisions_open = [
        {id: "cd/fz1", key: "fz1", verb: "captain-hold", title: "Freeze arm runs", reason: "Freeze: no new arm runs while the forge migrates", owner: "cd"},
        {id: "cd/fz2", key: "fz2", verb: "captain-hold", title: "Frozen pipeline", reason: "Frozen until the release ships.", owner: "cd"},
        {id: "cd/fz3", key: "fz3", verb: "captain-hold", title: "Keep the cache", reason: "Held so the sweep skips it; not a captain decision. Should it ever be rerun?", owner: "cd"},
        {id: "cd/real", key: "real", verb: "captain-hold", title: "Unfreeze now", reason: "Should the arm runs unfreeze now that the forge is back?", owner: "cd"}]' \
    "$TMP_ROOT/freeze-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "real" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" "only the real question is a card"
  assert_equals "fz1,fz2,fz3" "$(jq -r '[.waiting[].key] | sort | join(",")' <<<"$p")" \
    "a freeze and a hold that says it is no decision show as waits"
  pass "a freeze or a hold that says it is not a decision waits instead of asking"
}

test_a_card_carries_the_pr_link_its_snapshot_row_recorded() {
  local snap="$TMP_ROOT/prurl.json" p
  fresh_homes prurl
  write_snapshot "$TMP_ROOT/prurl-base.json"
  jq '.decisions_open = [
        {id: "pdm/pdm-91", key: "pdm-91", verb: "captain-hold", title: "Merge PR 91", reason: "Merge PR 91 now?",
         pr_url: "https://github.com/acme/pdm/pull/91", owner: "pdm"},
        {id: "pdm/bad", key: "bad", verb: "captain-hold", title: "Bad link", reason: "Ship it now?",
         pr_url: "http://evil.example/pull/1", owner: "pdm"}]' \
    "$TMP_ROOT/prurl-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "https://github.com/acme/pdm/pull/91" "$(jq -r '.captains_call[] | select(.key == "pdm-91") | .pr_url' <<<"$p")" \
    "a card takes the PR link its row recorded"
  assert_equals "null" "$(jq -r '.captains_call[] | select(.key == "bad") | .pr_url' <<<"$p")" "a non-https link is not a PR link"
  printf '%s\n' "$p" > "$TMP_ROOT/prurl-payload.json"
  validates "$TMP_ROOT/prurl-payload.json" || fail "a payload with a recorded PR link did not satisfy the board validator"
  pass "a card carries the PR link its snapshot row recorded"
}

test_a_card_shows_every_option_its_text_refers_to_or_says_it_does_not_list_them() {
  local snap="$TMP_ROOT/refs.json" p
  fresh_homes refs
  write_snapshot "$TMP_ROOT/refs-base.json"
  jq '.decisions_open = [
    {id: "cd/cd", key: "status.cd.gate-merge", verb: "needs-decision", source: "status", task: "cd", decision_key: "gate-merge", owner: "cd",
     reason_full: "Update: spec PR 836 is rebased on main and green: https://github.com/acme/cd/pull/836. Fix PR 837 is green except spec-reach: https://github.com/acme/cd/pull/837. I need the merge word: merge 836 now, then rebase 837 and merge it once green? Still open from before: A/B/C for stale gate stops (recommend A).",
     reason_earlier: [
       "#835 fix is two PRs. 1) Spec PR https://github.com/acme/cd/pull/836 is green. 2) Fix PR https://github.com/acme/cd/pull/837 is red until 836 lands.",
       "#835 needs two answers. 1) Merge word: merge 836, then 837 once green. 2) A stop the gate already posted never clears by itself. Options: A) keep the design; 837 prevents new false stops, and the one stale stop needs a single dismissal. B) the gate dismisses its own stop when a later run finds nothing; every adopter then needs review-dismiss rights. C) a later run posts an approval to clear it, which makes the gate an approver. I recommend A. Answer with merge 835 and A, B or C."]},
    {id: "cd/cd", key: "status.cd.gate-lost", verb: "needs-decision", source: "status", task: "cd", decision_key: "gate-lost", owner: "cd",
     reason_full: "Spec PR 836 is green. Merge it now? Still open from before: A/B/C for stale gate stops (recommend A)."},
    {id: "cd/cd", key: "status.cd.gate-same", verb: "needs-decision", source: "status", task: "cd", decision_key: "gate-same", owner: "cd",
     reason_full: "Stale gate stops never clear. 1) Merge word for 836. 2) Stale stops. Options: A) keep the design. B) the gate dismisses its own stop. C) a later run approves. Answer with A, B or C."}]' "$TMP_ROOT/refs-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  card() { jq -c --arg k "$1" '.captains_call[] | select(.key == $k)' <<<"$p"; }
  assert_equals "a,b,c" "$(card status.cd.gate-merge | jq -r '[.options[].value] | join(",")')" \
    "the options A, B and C named only in an earlier line of the same decision are on the card"
  assert_equals "A) Keep the design; 837 prevents new false stops, and the one stale stop needs a single dismissal" \
    "$(card status.cd.gate-merge | jq -r '.options[] | select(.value == "a") | .label')" "a taken-over option keeps its mark and its full text"
  assert_equals "from an earlier message on this question" \
    "$(card status.cd.gate-merge | jq -r '.options[] | select(.value == "c") | .hint')" "a taken-over option says it came from an earlier message"
  assert_equals "null" "$(card status.cd.gate-merge | jq -c .malformed)" "a card whose options were recovered is not marked"
  assert_equals "This question refers to options A, B and C, which it does not list; answer in your own words." \
    "$(card status.cd.gate-lost | jq -r .malformed)" "a card that refers to options no line lists says so"
  assert_equals "true" "$(card status.cd.gate-lost | jq '.allow_freeform')" "a marked card still takes a free-text answer"
  assert_equals "0" "$(card status.cd.gate-lost | jq '[.options[].value | select(test("^[a-c]$"))] | length')" \
    "a marked card offers no buttons for the options it cannot show"
  assert_equals "a,b,c" "$(card status.cd.gate-same | jq -r '[.options[].value | select(test("^[a-c]$"))] | join(",")')" \
    "lettered options in the same line beside a numbered list are on the card"
  assert_equals "null" "$(card status.cd.gate-same | jq -c '[.options[] | select(.hint)] | first')" "options from the current line need no hint"
  printf '%s\n' "$p" > "$TMP_ROOT/refs-payload.json"
  validates "$TMP_ROOT/refs-payload.json" || fail "a payload with a marked card did not satisfy the board validator"
  pass "a card shows every option its text refers to, or says it does not list them"
}

# A worker's keyed grill question that lists its options as "rec A = ...;
# B = ...; C = ..." gets a button per option, the "rec" option as the
# recommendation, the question as its heading, and a free-text answer, and the
# build accepts it. The text is the BCR grill worker's real line.
test_a_rec_letter_equals_option_line_gets_buttons_and_a_free_text_answer() {
  local snap="$TMP_ROOT/rec-eq.json" p card out line reason
  line='needs-decision [key=grill-bcr-r1] [at=1794917099]: Q1 what does BCR ship on 10 Dec? rec A = dry-run beta, no writes anywhere, on in prod behind Beta (~6 tickets: flag+upload/parse [APP-5860 rewritten, dummy page dropped], match+notice dry run, outcome CSV, money rows, policy prompt, link prompt); B = A + Confirm in dev/stg (one-way doors, stretch); C = skeleton only. Facts: APP-5860 not built, all 12 Submitted/untagged, no release::2026-12-10 tag, prototype predates spec by 1 day. Assumed A1-A9 from priors. Full round: /home/rob/repos/firstmate/data/bcr-dec10-grill/round-1.md'
  reason=${line#*: }
  fresh_homes rec-eq
  write_snapshot "$TMP_ROOT/rec-eq-base.json"
  jq --arg r "$reason" '.decisions_open = [
        {id: "bcr-dec10-grill", key: "status.bcr-dec10-grill.grill-bcr-r1", verb: "needs-decision", source: "status",
         task: "bcr-dec10-grill", decision_key: "grill-bcr-r1", owner: "bcr-dec10-grill", reason: $r}]' \
    "$TMP_ROOT/rec-eq-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  card=$(jq -c '.captains_call[] | select(.key == "status.bcr-dec10-grill.grill-bcr-r1")' <<<"$p")
  assert_equals "a|b|c" "$(jq -r '[.options[].value] | join("|")' <<<"$card")" \
    "the options A, B and C written as A = ... are the card's buttons: $card"
  assert_equals "Dry-run beta, no writes anywhere, on in prod behind Beta (~6 tickets: flag+upload/parse [APP-5860 rewritten, dummy page dropped], match+notice dry run, outcome CSV, money rows, policy prompt, link prompt)|A + Confirm in dev/stg (one-way doors, stretch)|Skeleton only" \
    "$(jq -r '[.options[].label] | join("|")' <<<"$card")" "each option keeps its full text without the rec mark"
  assert_equals "a" "$(jq -r '.recommend_value // "none"' <<<"$card")" "the option marked rec is the recommendation"
  assert_equals "bcr-dec10-grill: Q1 what does BCR ship on 10 Dec?" "$(jq -r .title <<<"$card")" "the question heads the card"
  assert_equals "true" "$(jq -r .allow_freeform <<<"$card")" "the card takes a free-text answer"
  jq -e '.about | test("Facts: APP-5860 not built") and (test(" = ") | not)' <<<"$card" >/dev/null \
    || fail "the card body is not the text around the options: $card"
  printf '%s\n' "$p" > "$TMP_ROOT/rec-eq-payload.json"
  validates "$TMP_ROOT/rec-eq-payload.json" || fail "the payload did not satisfy the board validator"
  out=$(build_checks "$TMP_ROOT/rec-eq-payload.json")
  assert_not_contains "$out" "undecided-card" "the build flagged the card: $out"
  pass "a rec A = ...; B = ... option line gets buttons, its recommendation and a free-text answer"
}

# A worker's keyed decision that numbers its options "(1, recommended) ...;
# (2) ...; (3) ..." gets a button per option and the recommended one as the
# recommendation, as the lettered form does, and its asking sentence, not the
# "Options:" that introduces the list, is the question. The text is a ralph
# worker's real line.
test_a_numbered_recommended_option_line_gets_buttons() {
  local snap="$TMP_ROOT/num-rec.json" p card out line reason
  line='needs-decision [at=1794925270] [key=app-5750-mr883-undraft]: Should Draft MR https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/883 (APP-5750, test-only fix so test_concurrent_requests_no_cross_contamination can fail; head 98c2eee5, pipeline 544413 green, 0 unresolved threads, not behind main, no approvals) be marked ready for another human reviewer? Options: (1, recommended) you read the one-file diff, then I mark it ready - every ralph round is clean (review clean, QA 6/6 pass, break clean with all binder mutants killed), so only your look is left before it goes to a reviewer; (2) mark it ready now without your read; (3) keep it Draft and say what to change.'
  reason=${line#*]: }
  fresh_homes num-rec
  write_snapshot "$TMP_ROOT/num-rec-base.json"
  jq --arg r "$reason" '.decisions_open = [
        {id: "app-5750-ralph", key: "status.app-5750-ralph.app-5750-mr883-undraft", verb: "needs-decision", source: "status",
         task: "app-5750-ralph", decision_key: "app-5750-mr883-undraft", owner: "app-5750-ralph", reason: $r}]' \
    "$TMP_ROOT/num-rec-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  card=$(jq -c '.captains_call[] | select(.key == "status.app-5750-ralph.app-5750-mr883-undraft")' <<<"$p")
  assert_equals "option-1|option-2|option-3" "$(jq -r '[.options[].value] | join("|")' <<<"$card")" \
    "the numbered options are the card's buttons: $card"
  assert_equals "Mark it ready now without your read|Keep it Draft and say what to change" \
    "$(jq -r '[.options[1:][].label] | join("|")' <<<"$card")" "each option keeps its text without its number"
  assert_equals "option-1" "$(jq -r '.recommend_value // "none"' <<<"$card")" "the option marked recommended is the recommendation"
  jq -e '.question | test("^Should Draft MR .*[?]$")' <<<"$card" >/dev/null \
    || fail "the asking sentence before \"Options:\" is not the card question: $card"
  printf '%s\n' "$p" > "$TMP_ROOT/num-rec-payload.json"
  validates "$TMP_ROOT/num-rec-payload.json" || fail "the payload did not satisfy the board validator"
  out=$(build_checks "$TMP_ROOT/num-rec-payload.json")
  assert_not_contains "$out" "undecided-card" "the build flagged the card: $out"
  pass "a numbered (1, recommended) option line gets buttons and its recommendation"
}

# An abbreviation such as "e.g." or "i.e." never ends a sentence, so a
# question that holds one is the card heading whole and the body keeps the
# text around it. The text is the pdm secondmate's real captain-hold line.
test_an_abbreviation_never_ends_the_card_question() {
  local snap="$TMP_ROOT/abbrev.json" p card line reason
  line="needs-decision [key=captain-hold-pdm-99-version-2]: captain hold pdm-99-version: Where should pdm --version get the release semver (e.g. 1.2.0) for 'proton-drive-mount 1.2.0 (4f84552 2026-11-15)'? Designs: https://forgejo.clarob.uk/rob/proton-drive-mount/issues/99#issuecomment-34788 . (a, recommended) each release ships ... (d) no semver: print only commit and date."
  reason=${line#*]: }
  fresh_homes abbrev
  write_snapshot "$TMP_ROOT/abbrev-base.json"
  jq --arg r "$reason" --arg i "${reason/e.g./i.e.}" '.decisions_open = [
        {id: "pdm", key: "status.pdm.captain-hold-pdm-99-version-2", verb: "needs-decision", source: "status",
         task: "pdm", decision_key: "captain-hold-pdm-99-version-2", owner: "pdm", title: "pdm --version semver", reason: $r},
        {id: "pdm", key: "status.pdm.captain-hold-pdm-99-version-ie", verb: "needs-decision", source: "status",
         task: "pdm", decision_key: "captain-hold-pdm-99-version-ie", owner: "pdm", title: "pdm --version semver", reason: $i}]' \
    "$TMP_ROOT/abbrev-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  card=$(jq -c '.captains_call[] | select(.key == "status.pdm.captain-hold-pdm-99-version-2")' <<<"$p")
  assert_equals "Where should pdm --version get the release semver (e.g. 1.2.0) for 'proton-drive-mount 1.2.0 (4f84552 2026-11-15)'?" \
    "$(jq -r .question <<<"$card")" "e.g. does not end the card question: $card"
  jq -e '.about // "" | test("[(]e[.]g[.] Designs") | not' <<<"$card" >/dev/null \
    || fail "the card body is cut at e.g.: $card"
  card=$(jq -c '.captains_call[] | select(.key == "status.pdm.captain-hold-pdm-99-version-ie")' <<<"$p")
  assert_equals "Where should pdm --version get the release semver (i.e. 1.2.0) for 'proton-drive-mount 1.2.0 (4f84552 2026-11-15)'?" \
    "$(jq -r .question <<<"$card")" "i.e. does not end the card question: $card"
  printf '%s\n' "$p" > "$TMP_ROOT/abbrev-payload.json"
  validates "$TMP_ROOT/abbrev-payload.json" || fail "the payload did not satisfy the board validator"
  pass "an abbreviation such as e.g. or i.e. never ends the card question"
}

# A sentence a worker addresses to firstmate ("Firstmate: ...", "Firstmate, ...")
# is not for the captain: the card drops it from its question and body, and it
# never sticks to the last option. A sentence that only mentions firstmate stays.
# Each option the reason marks "(a, recommended)" stays the card recommendation.
# The reasons are the real lines from the aegis-879 review, the runner FUSE
# apply, and the ForgeArm design hold.
test_a_sentence_addressed_to_firstmate_never_reaches_the_card() {
  local snap="$TMP_ROOT/addressee.json" p card mr fuse arm mention
  mr='Review of https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/879 is done and nothing is posted (verdict: request changes, small; low danger, seed-only, prod never mounts the seed router; one blocker: the default 10-claim seed shows 8 of 16 status pairs, and the description claims code for claims 2-4 that the branch lacks). Which held comments do you want posted, numbered in data/aegis-879-review/report.md? (a, recommended) Post 1, 2, 3, 4, 6 with request changes (b) Post 1-4 and 6-10 (adds the test gaps) (c) Post all 12 (d) Post none. Firstmate: the inventory is this one call, please register it and attest completion.'
  fuse='May the two FUSE cluster changes be applied live now, before the FUSE PR opens? (a, recommended) the worker plans again and applies only if the plans are unchanged: infra/shared = 1 in-place change, adding node-pool label clusterautoscaler-nodetemplate-resources.squat.ai/fuse=10 with no node-pool replacement; infra/cluster = 1 add, the FUSE device-plugin DaemonSet (about 50m CPU and 20Mi). After that it opens the PR, and that PR'"'"'s FUSE job, started with the pool at zero, is the scale-from-zero check. (b) open the PR first and apply later: its FUSE job cannot be scheduled and blocks all cluster dispatch for up to 1 h. (c) apply only the DaemonSet now and hold the node label: FUSE jobs then run only while another job keeps a node up. No new spend in any option. Branch: https://forgejo.clarob.uk/rob/runner-image/src/branch/fm/runner-fuse-ship (via-helper)'
  arm='captain hold cd-forge-arm-lab: Which ForgeArm acceptance design should we build first? (a, recommended) a test that starts a throwaway Forgejo, runs the real arm on new, existing and already-armed repo shapes, and compares the result with a reviewed golden per shape, plus cheap static checks of the seeded files against the pipeline they call; about 60 s, so you review a diff instead of re-running the arm. (b) the static checks alone now, then decide after measuring what they miss. (c) shapes and goldens on today'"'"'s fake forge only, with no new infrastructure. (d) the full stack with a runner, on main only, with the highest upkeep. https://forgejo.clarob.uk/rob/continuous-delivery/issues/932'
  mention='Should the sweep keep the old logs? Firstmate already archived them last week. (a) keep them (b) drop them. Firstmate, the sweep is idle until this is answered.'
  fresh_homes addressee
  write_snapshot "$TMP_ROOT/addressee-base.json"
  jq --arg mr "$mr" --arg fuse "$fuse" --arg arm "$arm" --arg mention "$mention" '.decisions_open = [
        {id: "aegis-879-review", key: "status.aegis-879-review.mr879-comments", verb: "needs-decision", source: "status",
         task: "aegis-879-review", decision_key: "mr879-comments", owner: "(main)", reason: $mr},
        {id: "runner-fuse", key: "status.runner-fuse.runner-fuse-apply", verb: "needs-decision", source: "status",
         task: "runner-fuse", decision_key: "runner-fuse-apply", owner: "(main)", reason: $fuse},
        {id: "cd-forge-arm", key: "status.cd-forge-arm.captain-hold-cd-forge-arm-lab-1", verb: "needs-decision", source: "status",
         task: "cd-forge-arm", decision_key: "captain-hold-cd-forge-arm-lab-1", owner: "(main)", reason: $arm},
        {id: "sweep", key: "status.sweep.logs", verb: "needs-decision", source: "status",
         task: "sweep", decision_key: "logs", owner: "(main)", reason: $mention}]' \
    "$TMP_ROOT/addressee-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  card=$(jq -c '.captains_call[] | select(.key == "status.aegis-879-review.mr879-comments")' <<<"$p")
  jq -e '[.title, .question, .about, .context.reason, (.options[].label)] | map(. // "") | any(test("Firstmate|attest completion")) | not' <<<"$card" >/dev/null \
    || fail "the card shows the sentence addressed to firstmate: $card"
  jq -e '(.about // "") | test("branch lacks[)][.]$")' <<<"$card" >/dev/null \
    || fail "the card body lost the text before the sentence addressed to firstmate: $card"
  jq -e '[.options[] | .label] == ["Post 1, 2, 3, 4, 6 with request changes", "Post 1-4 and 6-10 (adds the test gaps)", "Post all 12", "Post none"]' <<<"$card" >/dev/null \
    || fail "the MR 879 card did not keep its four options intact: $card"
  for key in status.aegis-879-review.mr879-comments status.runner-fuse.runner-fuse-apply status.cd-forge-arm.captain-hold-cd-forge-arm-lab-1; do
    assert_equals "a" "$(jq -r --arg k "$key" '.captains_call[] | select(.key == $k) | .recommend_value' <<<"$p")" \
      "the (a, recommended) option is the recommendation of $key"
  done
  card=$(jq -c '.captains_call[] | select(.key == "status.sweep.logs")' <<<"$p")
  jq -e '(.about // "") | test("Firstmate already archived them last week[.]")' <<<"$card" >/dev/null \
    || fail "a sentence that only mentions firstmate was dropped: $card"
  jq -e '[.question, .about, (.options[].label)] | map(. // "") | any(test("Firstmate, the sweep")) | not' <<<"$card" >/dev/null \
    || fail "the card shows the sentence addressed to firstmate with a comma: $card"
  printf '%s\n' "$p" > "$TMP_ROOT/addressee-payload.json"
  validates "$TMP_ROOT/addressee-payload.json" || fail "the payload did not satisfy the board validator"
  pass "a sentence addressed to firstmate never reaches the card, and (a, recommended) stays the recommendation"
}

# A URL written right before its "?" with a space between ("on <url> ?") reads
# as its link label with the "?" against it ("on PR 135?"), never "PR 135 ?".
# The reason is the real line from the pdm registry namespace hold.
test_a_link_label_right_before_a_question_mark_keeps_no_space() {
  local snap="$TMP_ROOT/label-qmark.json" p card line reason
  line="needs-decision [key=captain-hold-pdm-registry-ns-1] [at=1795093479]: captain hold pdm-registry-ns: Will you read and dismiss the acknowledgement review on https://forgejo.clarob.uk/rob/proton-drive-mount/pulls/135 ? It changes only devenv.nix: build records move to the shared registry prefix with namespace proton-drive-mount, as continuous-delivery #810 requires. CI is green and published to the shared registry. Once you dismiss it, I merge."
  reason=${line#*]: }
  fresh_homes label-qmark
  write_snapshot "$TMP_ROOT/label-qmark-base.json"
  jq --arg r "$reason" '.decisions_open = [
        {id: "pdm", key: "status.pdm.captain-hold-pdm-registry-ns-1", verb: "needs-decision", source: "status",
         task: "pdm", decision_key: "captain-hold-pdm-registry-ns-1", owner: "pdm", reason: $r}]' \
    "$TMP_ROOT/label-qmark-base.json" > "$snap"
  p=$(FM_BEARINGS_BOARD_PR_CHECK=0 "$GEN" --snapshot "$snap") || fail "the generator failed"
  card=$(jq -c '.captains_call[] | select(.key == "status.pdm.captain-hold-pdm-registry-ns-1")' <<<"$p")
  jq -e '[.title, .question, .about] | map(. // "") | any(test(" [?]")) | not' <<<"$card" >/dev/null \
    || fail "the card keeps a space before its question mark: $card"
  jq -e '[.title, .question, .about] | map(. // "") | any(contains("review on PR 135?"))' <<<"$card" >/dev/null \
    || fail "the card does not ask about PR 135 with the question mark against its label: $card"
  printf '%s\n' "$p" > "$TMP_ROOT/label-qmark-payload.json"
  validates "$TMP_ROOT/label-qmark-payload.json" || fail "the payload did not satisfy the board validator"
  pass "a link label right before a question mark keeps no space before it"
}

# The real status lines of these tests, each the reason after its "[at=...]: ".
MR879_LINE="needs-decision [key=mr879-comments] [at=1795093937]: Blocker withdrawn: the seed reaches all 16 status pairs (60 claims at seed 42; the preview https://aegis-879.dev.descartesunderwriting.fr/ runs head 2ce8982c), so the verdict is now approve with comments. Which comments should go on https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/879? (a) recommended: 1,2,3,4 with Approve; (b) 1,2,3,4 plus test gaps 6-9; (c) another list of numbers; (d) none. Report: /home/rob/repos/firstmate/data/aegis-879-review/report.md"
DEPLOY_LINE="needs-decision [at=1795094034] [key=deploy-actions-busy]: Forgejo Actions never went idle in the 1 h wait (12:13-13:13Z; new continuous-delivery runs kept starting, 1-5 running and 1-9 waiting each minute; now 1 running ci:acceptance from run 10250 and 1 waiting ci:deploy; the upload queue is 0), so how should I deploy 0237139 (PR https://github.com/rob-mur/immich-config/pull/133)? (a) recommended: deploy at the first minute no job is running, leaving waiting jobs to start after the reboot, and if that does not happen within 30 min deploy anyway; (b) deploy now and accept that the reboot kills the running ci:acceptance job; (c) wait up to 1 more hour for a minute with no running or waiting job."
PDM_LINE="needs-decision [key=captain-hold-pdm-registry-ns-1] [at=1795093479]: captain hold pdm-registry-ns: Will you read and dismiss the acknowledgement review on https://forgejo.clarob.uk/rob/proton-drive-mount/pulls/135 ? It changes only devenv.nix: build records move to the shared registry prefix with namespace proton-drive-mount, as continuous-delivery #810 requires. CI is green and published to the shared registry. Once you dismiss it, I merge."

# real_line_card <name> <task> <line>: the card the payload makes from one real
# status line of <task>, after the payload validated.
# A lettered question answers as its letters: the card's choice values are
# a, b, c, d as the question names them, never the parser's option-a.
MR900_LINE="needs-decision [at=1795442310]: Review of https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/900 is done and nothing is posted (summary: /home/rob/repos/firstmate/data/APP-5999-bcr-flags/review-900-summary.md; 16 held, no crash or data defect, design good, verdict COMMENT). Which held comments should I post as one COMMENT review? (a) recommended: the 13 unique ones, #1-7, #9-13 and #15, dropping duplicates #8, #14 and #16; (b) all 16 as held; (c) only the review-me three, #1-3; (d) none, and instead fix them on the branch myself"
MR891_LINE="needs-decision [at=1795430298] [key=mr891-comments]: After reading page:understand-mr891 (live on the board, built on the current MR head 6342f52d, with your three earlier answers kept), which of my 37 held review comments should I post on MR 891, where the recommended 9 cover its five small runtime defects plus wrong guard ticket markers, silently dropped status inputs, a missing default-date test and stale guard-ticket steps? (a, recommended) Post the recommended 9: 3, 4, 7, 8, 9, 10, 11, 22, 36. (b) Post none. (c) Post all 37 held comments. https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/891"
GCLOUD_LINE="needs-decision [key=gcloud-login] [at=1795444442]: Will you renew the gcloud login so I can commit the Slopstrap fix to MR https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/902? (a, recommended) I ran gcloud auth login and gcloud auth application-default login, carry on; (b) commit with --no-verify; (c) wait."

test_lettered_options_answer_as_their_letters() {
  local card
  card=$(real_line_card letters-mr900 APP-5999-bcr-flags "${MR900_LINE/\]: /] [key=default]: }")
  assert_equals "a|b|c|d|a" "$(jq -r '[.options[].value, .recommend_value] | join("|")' <<<"$card")" "MR 900: letter values and recommendation"
  assert_equals "All 16 as held" "$(jq -r '.options[] | select(.value == "b") | .label' <<<"$card")" "MR 900: a letter keeps its label"
  card=$(real_line_card letters-mr891 aegis-891-review "$MR891_LINE")
  assert_equals "a|b|c|a" "$(jq -r '[.options[].value, .recommend_value] | join("|")' <<<"$card")" "MR 891: letter values and recommendation"
  assert_equals "Post the recommended 9: 3, 4, 7, 8, 9, 10, 11, 22, 36" "$(jq -r '.options[] | select(.value == "a") | .label' <<<"$card")" "MR 891: a letter keeps its label"
  card=$(real_line_card letters-gcloud aegis-slopstrap-demo "$GCLOUD_LINE")
  assert_equals "a|b|c|a" "$(jq -r '[.options[].value, .recommend_value] | join("|")' <<<"$card")" "gcloud login: (a, recommended) answers as a"
  pass "lettered options answer as their letters, never option-a"
}

real_line_card() {
  local name=$1 task=$2 line=$3 key reason p
  key=$(sed -n 's/.*\[key=\([^]]*\)\].*/\1/p' <<<"$line")
  reason=${line#*]: }
  fresh_homes "$name"
  write_snapshot "$TMP_ROOT/$name-base.json"
  jq --arg r "$reason" --arg t "$task" --arg k "$key" '.decisions_open = [
        {id: $t, key: ("status." + $t + "." + $k), verb: "needs-decision", source: "status",
         task: $t, decision_key: $k, owner: $t, reason: $r}]' \
    "$TMP_ROOT/$name-base.json" > "$TMP_ROOT/$name.json"
  p=$(FM_BEARINGS_BOARD_PR_CHECK=0 "$GEN" --snapshot "$TMP_ROOT/$name.json") || fail "the generator failed on $name"
  printf '%s\n' "$p" > "$TMP_ROOT/$name-payload.json"
  validates "$TMP_ROOT/$name-payload.json" || fail "the $name payload did not satisfy the board validator"
  jq -c '.captains_call[0]' <<<"$p"
}

# A link written after its own kind word ("PR <url>") shows that word once.
test_a_link_label_never_doubles_its_kind_word() {
  local card
  card=$(real_line_card label-deploy immich-runner-dns-bump "$DEPLOY_LINE")
  jq -e '[.title, .question, .about] | map(. // "") | any(contains("PR PR")) | not' <<<"$card" >/dev/null \
    || fail "a kind word before a link was doubled: $card"
  jq -e '.about | contains("deploy 0237139 (PR 133)?")' <<<"$card" >/dev/null \
    || fail "the about does not name the link as (PR 133)?: $card"
  card=$(real_line_card label-pdm pdm "$PDM_LINE")
  jq -e '[.title, .question, .about] | map(. // "") | any(test(" on [?]")) | not' <<<"$card" >/dev/null \
    || fail "the card dropped the link before its question mark: $card"
  assert_equals "Will you read and dismiss the acknowledgement review on PR 135?" "$(jq -r .question <<<"$card")" \
    "the question keeps the link label before its question mark"
  pass "a link label never doubles its kind word"
}

# The real keyless cd-992 line of the cd home ("... How to proceed? (a) ...").
# As a status card its title names the task and the asking sentence, so the
# question lives in the title and the card carries no second one. As a mate
# hold whose title does not ask, the same text gives the card its question.
CD992_LINE="needs-decision [at=1795527005]: PR https://forgejo.clarob.uk/rob/continuous-delivery/pulls/993 fails ci:acceptance spec reach (unreached cd-builtins/src/spec_reach.rs:272, the refusal text line; no frozen scenario drives the no SF: record refusal, and a new scenario must land in its own spec MR first). How to proceed? (a) I raise a separate spec-only PR adding a frozen scenario that runs cd-spec-reach on a coverage report missing a file's SF: record, then rebase #993 on it after it merges; (b) hold #993 and leave the scenario to the captain; (c) close #993."

test_a_how_to_proceed_question_is_in_the_title_or_the_question() {
  local card reason p
  card=$(real_line_card how-cd992 cd-992-spec-reach-allow-list-hint "${CD992_LINE/\]: /] [key=default]: }")
  assert_equals "cd-992-spec-reach-allow-list-hint: How to proceed?" "$(jq -r .title <<<"$card")" "status card: the title asks"
  assert_equals "null" "$(jq -r .question <<<"$card")" "status card: no second question beside the title"
  assert_equals "a|b|c" "$(jq -r '[.options[].value] | join("|")' <<<"$card")" "status card: the lettered options"
  reason=${CD992_LINE#*]: }
  fresh_homes how-cd992-hold
  write_snapshot "$TMP_ROOT/how-cd992-hold-base.json"
  jq --arg r "$reason" '.decisions_open = [
        {id: "cd-992-spec-reach-allow-list-hint", key: "cd.captain-hold.cd-992-spec-reach-allow-list-hint",
         verb: "captain-hold", title: "Spec reach allow-list hint", owner: "cd", reason: $r}]' \
    "$TMP_ROOT/how-cd992-hold-base.json" > "$TMP_ROOT/how-cd992-hold.json"
  p=$(FM_BEARINGS_BOARD_PR_CHECK=0 "$GEN" --snapshot "$TMP_ROOT/how-cd992-hold.json") || fail "the generator failed on the cd-992 hold"
  card=$(jq -c '.captains_call[0]' <<<"$p")
  assert_equals "How to proceed?" "$(jq -r '.question // "undefined"' <<<"$card")" "mate hold: the card asks its question"
  jq -e '.about | startswith("PR 993 fails ci:acceptance spec reach") and (contains("How to proceed?") | not)' <<<"$card" >/dev/null \
    || fail "mate hold: the about does not hold only the context before the question: $card"
  assert_equals "a|b|c" "$(jq -r '[.options[].value] | join("|")' <<<"$card")" "mate hold: the lettered options"
  pass "a How to proceed? question is in the title or the question, never neither"
}

# A long asking sentence that ends in a clause which asks ("..., so how should I
# deploy X?") is headed by that clause, whole, not by its truncated start.
test_a_long_asking_sentence_is_headed_by_the_clause_that_asks() {
  local card
  card=$(real_line_card ask-deploy immich-runner-dns-bump "$DEPLOY_LINE")
  assert_equals "immich-runner-dns-bump: How should I deploy 0237139 (PR 133)?" "$(jq -r .title <<<"$card")" \
    "the title is the clause that asks"
  jq -e '(.question // null) == null or .question == "How should I deploy 0237139 (PR 133)?"' <<<"$card" >/dev/null \
    || fail "the question is not the clause that asks: $card"
  jq -e '.about | startswith("Forgejo Actions never went idle")' <<<"$card" >/dev/null \
    || fail "the about lost the context before the asking clause: $card"
  card=$(real_line_card ask-mr879 aegis-879-review "$MR879_LINE")
  assert_equals "Which comments should go on MR 879?" "$(jq -r .question <<<"$card")" \
    "a question that is not the first sentence is still the heading"
  pass "a long asking sentence is headed by the clause that asks"
}

# "(a) recommended: ..." marks option a as the recommendation exactly as
# "(a, recommended)" does, and the label drops "recommended:".
test_an_a_recommended_colon_option_is_the_recommendation() {
  local card
  card=$(real_line_card rec-mr879 aegis-879-review "$MR879_LINE")
  assert_equals "a" "$(jq -r .recommend_value <<<"$card")" "(a) recommended: is the recommendation"
  assert_equals "1,2,3,4 with Approve|1,2,3,4 plus test gaps 6-9|Another list of numbers|none" \
    "$(jq -r '[.options[] | select(.value | test("^[a-z]$")) | .label] | join("|")' <<<"$card")" \
    "the labels carry no recommended:"
  card=$(real_line_card rec-deploy immich-runner-dns-bump "$DEPLOY_LINE")
  assert_equals "a" "$(jq -r .recommend_value <<<"$card")" "(a) recommended: is the recommendation"
  jq -e '[.options[].label] | (.[0] | startswith("Deploy at the first minute")) and (map(test("recommended"; "i")) | any | not)' \
    <<<"$card" >/dev/null || fail "an option label kept recommended:: $card"
  pass "an (a) recommended: option is the recommendation"
}

# The real mr887-comments and mr888-comments lines: a note to firstmate or a
# report and page pointer after the last option, an "(a, recommended)" or a
# trailing "(recommended)" mark, a local path in a parenthesis before "?",
# and a report path the card carries.
MR887_LINE=$(cat <<'EOF_LINE'
needs-decision [key=mr887-comments] [at=1795095263]: Which held comments should go on MR 887 (verdict: request changes, small; the fix works but the call sites are untested and the automatic 100 is stored like a user override; numbered in /home/rob/repos/firstmate/data/aegis-887-review/report.md)? (a, recommended) Post 1, 2, 3, 4, 5 with request changes (b) Post 1-5 plus 6 (pre-existing advisory) and 7 (human checks) (c) Post all 9 (d) Post none. https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/887 Firstmate: the inventory is this one call, please register it and attest completion.
EOF_LINE
)
MR887_POINTERS_LINE=$(cat <<'EOF_LINE'
needs-decision [key=mr887-comments] [at=1795095537]: Which held comments should go on MR 887? Verdict: request changes, small. The fix works, but the recommended comments ask for tests on the two call sites, fix the stored 100 that a null, a policy change or a cleared override gets wrong, and drop the MCP server from the doc. (a, recommended) Post 1, 2, 3, 4, 5 with request changes (b) Post 1-7, adding the pre-existing advisory and the human-checks note (c) Post all 9 (d) Post none. https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/887 Report: /home/rob/repos/firstmate/data/aegis-887-review/report.md Architecture page: board tab 'Architecture: MR 887 net-only claims'.
EOF_LINE
)
MR888_LINE=$(cat <<'EOF_LINE'
needs-decision [at=1795094938] [key=mr888-comments]: Which held review comments should go on MR 888 (verdict: request changes, small; numbered comments in /home/rob/repos/firstmate/data/aegis-888-review/report.md)? a) post 1, 2, 3 as a request-changes review (recommended) b) post 1, 2, 3 and the pre-existing advisory 5 c) post all six d) post none https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/888
EOF_LINE
)
MR888_POINTERS_LINE=$(cat <<'EOF_LINE'
needs-decision [at=1795095539] [key=mr888-comments]: Which review comments should go on MR 888? Verdict: request changes, small; the fix is right but the new word "entry" is a glossary term to avoid, the doc row's advice only fits a payment, and the wording check belongs in its own test. (a, recommended) post comments 1, 2 and 3 as a request-changes review (b) post 1, 2, 3 and the advisory 5 about the existing 0.00 EUR deficit display (c) post all six comments (d) post nothing https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/888 — report: /home/rob/repos/firstmate/data/aegis-888-review/report.md; architecture page: board tab "Architecture: MR 888 reserve-floor wording"
EOF_LINE
)

# Nothing after the last option's own words reaches that option: not a note to
# firstmate after the link, and not the report or page pointer after it.
test_the_last_option_ends_at_its_own_words() {
  local card
  card=$(real_line_card last-887 aegis-887-review "$MR887_LINE")
  assert_equals "Post none" "$(jq -r '.options[] | select(.value == "d") | .label' <<<"$card")" "887: option d"
  jq -e '[.title, .question, .about, .context.reason, (.options[].label)] | map(. // "") | any(test("Firstmate[:,]")) | not' \
    <<<"$card" >/dev/null || fail "a note to firstmate after a link reached the card: $card"
  card=$(real_line_card last-887p aegis-887-review "$MR887_POINTERS_LINE")
  assert_equals "Post none" "$(jq -r '.options[] | select(.value == "d") | .label' <<<"$card")" "887 pointers: option d"
  card=$(real_line_card last-888p aegis-888-review "$MR888_POINTERS_LINE")
  assert_equals "Post nothing" "$(jq -r '.options[] | select(.value == "d") | .label' <<<"$card")" "888 pointers: option d"
  pass "the last option ends at its own words"
}

# "(a, recommended) ..." and "a) ... (recommended)" both mark option a, and
# the label keeps no "(recommended)".
test_both_recommended_marks_reach_the_card() {
  local card name line
  for name in 887 888; do
    if [ "$name" = 887 ]; then line=$MR887_LINE; else line=$MR888_LINE; fi
    card=$(real_line_card "rec2-$name" "aegis-$name-review" "$line")
    assert_equals "a" "$(jq -r .recommend_value <<<"$card")" "$name: option a is the recommendation"
    jq -e '[.options[].label] | map(test("recommended"; "i")) | any | not' <<<"$card" >/dev/null \
      || fail "$name: an option label kept the recommended mark: $card"
  done
  pass "both recommended marks reach the card"
}

# A question that ends in a long parenthesis before "?" is never cut inside
# it: the parenthesis is dropped whole and stays in the about.
test_a_parenthesis_before_the_question_mark_is_never_cut() {
  local card name line title
  for name in 887 888; do
    if [ "$name" = 887 ]; then
      line=$MR887_LINE title="aegis-887-review: Which held comments should go on MR 887?"
    else
      line=$MR888_LINE title="aegis-888-review: Which held review comments should go on MR 888?"
    fi
    card=$(real_line_card "paren-$name" "aegis-$name-review" "$line")
    assert_equals "$title" "$(jq -r .title <<<"$card")" "$name: the title keeps the asking words whole"
    jq -e '[.title, .question] | map(. // "") | any(test("[(][^)]*$")) | not' <<<"$card" >/dev/null \
      || fail "$name: the title or question ends inside an open parenthesis: $card"
    jq -e '.about | test("report[.]md[)][?]")' <<<"$card" >/dev/null \
      || fail "$name: the about lost the whole parenthesis: $card"
  done
  pass "a parenthesis before the question mark is never cut"
}

# A local report path the reason names is the card's report.
test_a_report_path_in_the_text_is_the_card_report() {
  local card
  card=$(real_line_card report-887 aegis-887-review "$MR887_LINE")
  assert_equals "/home/rob/repos/firstmate/data/aegis-887-review/report.md" "$(jq -r .context.report <<<"$card")" "887: report"
  card=$(real_line_card report-888p aegis-888-review "$MR888_POINTERS_LINE")
  assert_equals "/home/rob/repos/firstmate/data/aegis-888-review/report.md" "$(jq -r .context.report <<<"$card")" "888 pointers: report"
  pass "a report path in the text is the card report"
}

# The real status lines of the continuous-delivery and BCR cards below.
CD942_LINE="needs-decision [key=captain-hold-cd-942-identity-scope-1] [at=1795100000]: captain hold cd-942-identity-scope: Should service accounts, keys, Workload Identity and IAM grants stay a human apply, with all other infra applied by each repo's own pipeline? Per issue 942 (https://forgejo.clarob.uk/rob/continuous-delivery/issues/942), each repo gets a deployer bound to its own main branch, its own state prefix, and grants limited to its own resources; those limits hold only if the deployer cannot change IAM, since a deployer that can grant roles can grant itself anything. (a, recommended) yes: identity stays a rare human apply, everything else goes through CI. (b) no: each pipeline also applies its own identity with conditioned IAM admin; simpler, but a merged change can widen that repo's power. https://forgejo.clarob.uk/rob/continuous-delivery/issues/942#issuecomment-34957"
CD932_LINE="needs-decision [key=captain-hold-cd-932-forge-arm-lab-1] [at=1795100000]: captain hold cd-932-forge-arm-lab: Merge PRs 938 and 939 now that the ForgeArm lab passed locally (16 of 16 shapes, 128 s) and in CI on both runner sizes? PR 938 (https://forgejo.clarob.uk/rob/continuous-delivery/pulls/938) adds the local Forgejo to the dev shell; PR 939 (https://forgejo.clarob.uk/rob/continuous-delivery/pulls/939) adds the lab for issue 932 and rebases onto 938 before merge. (a, recommended) merge both, 938 first. (b) hold them. Local run evidence: https://forgejo.clarob.uk/rob/continuous-delivery/issues/932#issuecomment-34954"
BCR_WRITES_LINE="needs-decision [key=grill-bcr-writes] [at=1795100000]: When should the BCR import's Confirm start writing data in dev and staging (prod stays read only)? (a, recommended) Right after the payments ticket, because before it a notice's reserve ignores the file's payments and would be booked too high. (b) Right after the first real file check, booking notices only. (c) Last, after every kind of line is built. https://youtrack.prd.descartesunderwriting.fr/issue/APP-5861"
BCR_MONEY_LINE="needs-decision [key=grill-bcr-money] [at=1795100000]: The BCR file gives amounts in our share but Aegis books 100% amounts, so how should a file amount become a booking? (a, recommended) Compare in our share, book the amount divided by our share, and show both in the preview; our share in Aegis can then be one cent off the file. (b) Ask the claims team first, which holds up the first real file check. https://youtrack.prd.descartesunderwriting.fr/issue/APP-5837"
BCR_RETEST_LINE="needs-decision [key=grill-bcr-retest] [at=1795100000]: Once a BCR month is confirmed in staging it is locked, so how do testers try the same month again? (a, recommended) They do not; they test a new month or use a fresh preview environment, with nothing to build. (b) Add a \"Forget this import\" action in dev and staging, about half a day, but a second Confirm would then book the same amounts twice. (c) Build undo before testing starts. https://youtrack.prd.descartesunderwriting.fr/issue/APP-5871"

# A decision that links only Forgejo issues and pulls/<n> still names its repo.
test_a_forgejo_card_takes_its_repo_from_its_links() {
  local card
  card=$(real_line_card repo-942 cd "$CD942_LINE")
  assert_equals "continuous-delivery" "$(jq -r .repo <<<"$card")" "942: repo from its Forgejo issue link"
  card=$(real_line_card repo-932 cd "$CD932_LINE")
  assert_equals "continuous-delivery" "$(jq -r .repo <<<"$card")" "932: repo from its Forgejo pulls link"
  pass "a forgejo card takes its repo from its links"
}

# "issue 942 (<url>)" and "PR 938 (<url>)" already name the link, so the about
# shows no "(Issue 942)" or "(PR 938)" after them.
test_a_link_the_text_already_names_shows_no_label_in_parentheses() {
  local card
  card=$(real_line_card named-942 cd "$CD942_LINE")
  jq -e '.about | contains("Per issue 942, each repo gets a deployer") and (contains("(Issue 942)") | not)' <<<"$card" >/dev/null \
    || fail "942: the about doubles the issue label: $(jq -r .about <<<"$card")"
  card=$(real_line_card named-932 cd "$CD932_LINE")
  jq -e '.about | contains("PR 938 adds the local Forgejo") and contains("PR 939 adds the lab")
         and (test("[(](PR|Issue) [0-9]+[)]") | not)' <<<"$card" >/dev/null \
    || fail "932: the about doubles a PR label: $(jq -r .about <<<"$card")"
  pass "a link the text already names shows no label in parentheses"
}

# A link to a comment reads as a comment on its issue, never as the bare issue.
test_a_comment_link_reads_as_a_comment() {
  local card
  card=$(real_line_card comment-942 cd "$CD942_LINE")
  assert_equals "Issue 942|Comment on issue 942" "$(jq -r '[.links[].label] | join("|")' <<<"$card")" "942: link labels"
  card=$(real_line_card comment-932 cd "$CD932_LINE")
  jq -e '.about | endswith("Local run evidence: Comment on issue 932")' <<<"$card" >/dev/null \
    || fail "932: the comment link reads as the bare issue: $(jq -r .about <<<"$card")"
  assert_equals "Comment on issue 932" "$(jq -r '.links[] | select(.url | endswith("#issuecomment-34954")) | .label' <<<"$card")" "932: comment link label"
  pass "a comment link reads as a comment"
}

# An asking sentence too long for the heading is cut at a clause boundary,
# never mid-clause; the about keeps the sentence whole.
test_a_too_long_asking_sentence_is_cut_at_a_clause_boundary() {
  local card
  card=$(real_line_card cut-942 cd "$CD942_LINE")
  assert_equals "Should service accounts, keys, Workload Identity and IAM grants stay a human apply?" "$(jq -r .question <<<"$card")" "942: question"
  jq -e '.about | contains("with all other infra applied by each repo'"'"'s own pipeline?")' <<<"$card" >/dev/null \
    || fail "942: the about lost the clause the heading cut: $(jq -r .about <<<"$card")"
  pass "a too long asking sentence is cut at a clause boundary"
}

FOS29_LINE="needs-decision [key=merge-pr-29] [at=1795100000]: Shall I merge fos-rulings-research PR 29 (https://github.com/rob-mur/fos-rulings-research/pull/29), which makes its main run judge the same 27 tests the nightly eval judges (all 8 checks green)? (a, recommended) merge it. (b) hold it."

# A trailing ", which ..." relative clause qualifies the clause before it, so a
# heading cut keeps that main clause and never asks the relative clause.
test_a_trailing_which_clause_is_never_the_question() {
  local card
  card=$(real_line_card which-29 fos-merge-pr-29 "$FOS29_LINE")
  assert_equals "fos-merge-pr-29: Shall I merge fos-rulings-research PR 29?" "$(jq -r .title <<<"$card")" "29: title"
  assert_equals "null" "$(jq -r .question <<<"$card")" "29: no second question beside the title"
  jq -e '.about | contains("PR 29, which makes its main run judge")' <<<"$card" >/dev/null \
    || fail "29: the about lost the relative clause the heading cut: $(jq -r .about <<<"$card")"
  pass "a trailing which clause is never the question"
}

# A reason that opens with its question asks that sentence, even when a later
# lead-in ending in ":" introduces an inline numbered list, so the hold is a
# card and is not held back to fix.
test_a_leading_question_beats_a_later_list_lead_in() {
  local snap p out
  snap="$TMP_ROOT/snap-lead-question.json"
  write_snapshot "$TMP_ROOT/snap.json"
  jq '.decisions_open = [
        {id: "c4-diagrams", key: "c4-diagrams", verb: "captain-hold", owner: "(main)",
         title: "C4 diagrams for each repo",
         reason: "Which tool should draw each repo\u0027s C4 diagram? Two ways to add sign-in: 1) Structurizr DSL checked into each repo, rendered in CI 2) Mermaid C4 blocks in each README, rendered by the forge.",
         choices: {options: [{value: "structurizr", label: "Structurizr DSL"}, {value: "mermaid", label: "Mermaid C4"}],
                   links: [{target: "https://github.com/acme/docs/issues/4", label: "Issue 4"}],
                   free_text: false, no_link: false}}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  printf '%s\n' "$p" > "$TMP_ROOT/lead-question.json"
  validates "$TMP_ROOT/lead-question.json" || fail "the payload did not satisfy the validator"
  assert_equals "Which tool should draw each repo's C4 diagram?" \
    "$(jq -r '.captains_call[] | select(.key == "c4-diagrams") | .question' <<<"$p")" \
    "the card did not ask its leading question"
  out=$(build_checks "$TMP_ROOT/lead-question.json")
  assert_not_contains "$out" "undecided-card: c4-diagrams" "the hold was refused: $out"
  p=$(built_data)
  assert_equals "c4-diagrams" "$(jq -r '[.captains_call[].key | select(. == "c4-diagrams")] | join(",")' <<<"$p")" \
    "the hold did not reach Captain's Call"
  assert_equals "" "$(jq -r '[.cards_to_fix[]?.key] | join(",")' <<<"$p")" \
    "the hold was sent to cards_to_fix"
  pass "a leading question beats a later list lead-in"
}

CD965_LINE="needs-decision [key=default] [at=1795432859]: Pages service is up behind IAP (https://pages-413301784905.europe-west1.run.app/_probe-965/) but answers 502 until IAP has an OAuth client, which only the console can create (no org; Google shut the IAP OAuth API). Who does the one-time ~3-min console step? (a, recommended) the captain, following the 4 steps in data/cd-965-c4-diagram/iap-serving-report.md, then opens the probe; (b) I drive the captain's running Chrome via chrome-devtools-axi auto-connect (needs remote debugging enabled at chrome://inspect/#remote-debugging); (c) drop IAP and choose another serving path. New guard PR https://forgejo.clarob.uk/rob/continuous-delivery/pulls/977 must merge before https://forgejo.clarob.uk/rob/continuous-delivery/pulls/967; https://forgejo.clarob.uk/rob/continuous-delivery/pulls/971 and https://forgejo.clarob.uk/rob/continuous-delivery/pulls/972 CI green; https://forgejo.clarob.uk/rob/continuous-delivery/pulls/973 updated, held."

# A secondmate child's question that follows a context sentence titles its
# card, so the card reaches Captain's Call and is not held back to fix.
test_a_secondmate_question_after_its_context_is_asked() {
  local snap="$TMP_ROOT/cd965.json" p out reason
  fresh_homes cd965
  reason=${CD965_LINE#*]: }
  write_snapshot "$TMP_ROOT/cd965-base.json"
  jq --arg r "$reason" '.decisions_open = [
        {id: "cd/cd-965-c4-diagram", key: "status.cd.cd-965-c4-diagram.default", verb: "needs-decision",
         source: "status", task: "cd-965-c4-diagram", decision_key: "default", mate: "cd",
         title: "cd-965-c4-diagram", title_full: "cd-965-c4-diagram", reason: $r[:80], reason_full: $r,
         question: $r, owner: "cd"}]' \
    "$TMP_ROOT/cd965-base.json" > "$snap"
  p=$(FM_BEARINGS_BOARD_PR_CHECK=0 "$GEN" --snapshot "$snap") || fail "the generator failed"
  printf '%s\n' "$p" > "$TMP_ROOT/cd965-payload.json"
  validates "$TMP_ROOT/cd965-payload.json" || fail "the payload did not satisfy the validator"
  assert_equals "cd: Who does the one-time ~3-min console step?" "$(jq -r '.captains_call[0].title' <<<"$p")" \
    "the card was not titled from its asking sentence"
  out=$(build_checks "$TMP_ROOT/cd965-payload.json")
  assert_not_contains "$out" "undecided-card: status.cd.cd-965-c4-diagram.default" "the question was refused: $out"
  p=$(built_data)
  assert_equals "status.cd.cd-965-c4-diagram.default" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" \
    "the question did not reach Captain's Call"
  pass "a secondmate question after its context is asked"
}

# A reason whose asking sentence follows a context sentence asks that sentence,
# even when a later lead-in ending in ":" introduces an inline numbered list.
test_a_later_question_beats_a_later_list_lead_in() {
  local snap="$TMP_ROOT/snap-later-question.json" p out
  write_snapshot "$TMP_ROOT/snap.json"
  jq '.decisions_open = [
        {id: "iap-console", key: "iap-console", verb: "captain-hold", owner: "(main)",
         title: "IAP console step for the pages service",
         reason: "The pages service answers 502 until IAP has an OAuth client, which only the console can create. Who does the one-time ~3-min console step? Two ways to do it: 1) the captain, following the 4 steps in the report 2) the worker drives the captain\u0027s running Chrome.",
         choices: {options: [{value: "captain", label: "The captain"}, {value: "worker", label: "The worker"}],
                   links: [{target: "https://forgejo.clarob.uk/rob/continuous-delivery/pulls/967", label: "PR 967"}],
                   free_text: false, no_link: false}}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  printf '%s\n' "$p" > "$TMP_ROOT/later-question.json"
  validates "$TMP_ROOT/later-question.json" || fail "the payload did not satisfy the validator"
  assert_equals "Who does the one-time ~3-min console step?" \
    "$(jq -r '.captains_call[] | select(.key == "iap-console") | .question' <<<"$p")" \
    "the card asked its list lead-in, not its question"
  out=$(build_checks "$TMP_ROOT/later-question.json")
  assert_not_contains "$out" "undecided-card: iap-console" "the hold was refused: $out"
  pass "a later question beats a later list lead-in"
}

# The wp-results-persist hold, re-held twice: its card shows only the current
# hold's options, and PR 78, linked by its hold and named in its reason, once
# under the hold's label.
test_a_re_held_card_shows_its_current_options_and_each_link_once() {
  local snap="$TMP_ROOT/snap-re-held.json" p pr=https://forgejo.clarob.uk/rob/workload-pruner/pulls/78
  write_snapshot "$TMP_ROOT/snap.json"
  jq --arg pr "$pr" '.decisions_open = [
        {id: "wp-results-persist", key: "wp-results-persist", verb: "captain-hold", owner: "(main)",
         title: "Save stage results outside the runner cache",
         reason: ("May a project admin apply infra/identity in PR 78 (" + $pr + ") once, so that CI can create the results bucket? The CI login does not exist yet, and a CI job must not set up its own access."),
         choices: {options: [{value: "a", label: "Yes: an admin applies infra/identity once; CI then creates the bucket on the next main run"},
                             {value: "b", label: "No project-wide create: an admin creates the bucket once in infra/identity too"}],
                   links: [{target: $pr, label: "PR 78 (infra/README.md explains both roots)"},
                           {target: $pr, label: "PR 78 (infra/README.md has the apply steps)"}],
                   free_text: true, no_link: false}}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  printf '%s\n' "$p" > "$TMP_ROOT/re-held.json"
  validates "$TMP_ROOT/re-held.json" || fail "the payload did not satisfy the validator"
  assert_equals "a,b" \
    "$(jq -r '.captains_call[] | select(.key == "wp-results-persist") | [.options[].value] | join(",")' <<<"$p")" \
    "the card shows only the current hold's options"
  assert_equals "1|PR 78 (infra/README.md explains both roots)" \
    "$(jq -r --arg pr "$pr" '.captains_call[] | select(.key == "wp-results-persist") | [.links[] | select(.url == $pr)] | "\(length)|\(.[0].label)"' <<<"$p")" \
    "the card links PR 78 once, under its first label"
  pass "a re-held card shows its current options and each link once"
}

# The cd-965-iap-console hold as first written: numbered steps that each start
# with a console URL, then a redirect URI whose path holds a <CLIENT_ID>
# placeholder, then the card links.
IAP_HOLD_REASON="Will you finish the Google sign-in setup in the Cloud Run console? Google's Cloud Run docs put these settings in the service's Security tab, not an IAP Applications tab. Auto Generate makes the OAuth client for you, so you need no redirect URI or origins. Corrected steps. 1) https://console.cloud.google.com/auth/branding?project=ai-ci-pipeline: Get started, audience External, Create (skip if done). 2) https://console.cloud.google.com/auth/audience?project=ai-ci-pipeline: add rmurphyswimmer@gmail.com as a test user. 3) https://console.cloud.google.com/run/detail/europe-west1/pages/security?project=ai-ci-pipeline: IAP section, Edit policy, Configure in IAP, Custom OAuth, Auto Generate Credentials, Save. Leave the principals there as they are. 4) Open the probe page in a private window. It should show an account chooser, then the page. If you already made a client by hand: it must be a Web application with no JavaScript origins and one redirect URI, https://iap.googleapis.com/v1/oauth/clientIds/<CLIENT_ID>:handleRedirect (added after it is created). Then enter its ID and secret in Configure in IAP instead of Auto Generate. https://pages-413301784905.europe-west1.run.app/_probe-965/ https://forgejo.clarob.uk/rob/continuous-delivery/pulls/967"

# iap_hold_card: the card the payload makes from that hold, after it validated.
iap_hold_card() {
  local p
  write_snapshot "$TMP_ROOT/snap.json"
  jq --arg r "$IAP_HOLD_REASON" '.decisions_open = [
        {id: "cd-965-iap-console", key: "cd-965-iap-console", verb: "captain-hold", owner: "(main)",
         title: "IAP OAuth client console step for the pages service (#965)", reason: $r,
         choices: {options: [{value: "a", label: "I will finish in the console with Auto Generate (recommended)"},
                             {value: "b", label: "I make the client by hand and OpenTofu attaches it to IAP"}],
                   links: [], free_text: true, no_link: false}}]' \
    "$TMP_ROOT/snap.json" > "$TMP_ROOT/snap-iap.json"
  p=$(FM_BEARINGS_BOARD_PR_CHECK=0 "$GEN" --snapshot "$TMP_ROOT/snap-iap.json") || fail "the generator failed"
  printf '%s\n' "$p" > "$TMP_ROOT/iap.json"
  validates "$TMP_ROOT/iap.json" || fail "the payload did not satisfy the validator"
  jq -c '.captains_call[] | select(.key == "cd-965-iap-console")' <<<"$p"
}

# Steps that each start with a URL are prose, so they stay in the about; only
# the run of links after the last sentence leaves it.
test_steps_that_start_with_a_url_stay_in_the_about() {
  local card step
  card=$(iap_hold_card)
  for step in "1) " "Get started, audience External" "2) " "add rmurphyswimmer@gmail.com as a test user" \
              "3) " "Auto Generate Credentials, Save" "4) Open the probe page"; do
    jq -e --arg s "$step" '(.about // "") | contains($s)' <<<"$card" >/dev/null \
      || fail "the about lost the step text '$step': $card"
  done
  jq -e '(.about // "") | contains("_probe-965") or contains("pulls/967") | not' <<<"$card" >/dev/null \
    || fail "the about kept the trailing links: $card"
  jq -e '[.links[].url] | index("https://forgejo.clarob.uk/rob/continuous-delivery/pulls/967") != null' <<<"$card" >/dev/null \
    || fail "the trailing PR link is not a card link: $card"
  pass "steps that start with a url stay in the about"
}

# A URL holding a <PLACEHOLDER> is an address to type, not a link: the text
# keeps it whole and the card never links the part before the placeholder.
test_a_url_with_a_placeholder_stays_whole_and_is_never_a_link() {
  local card uri=https://iap.googleapis.com/v1/oauth/clientIds/
  card=$(iap_hold_card)
  jq -e --arg u "$uri<CLIENT_ID>:handleRedirect" '(.about // "") | contains($u)' <<<"$card" >/dev/null \
    || fail "the about did not keep the redirect URI whole: $card"
  jq -e --arg u "$uri" '[.links[].url | select(startswith($u))] | length == 0' <<<"$card" >/dev/null \
    || fail "the card linked the placeholder URI's prefix: $card"
  pass "a url with a placeholder stays whole and is never a link"
}

# A hold question that names its release by a full URL in parentheses: the URL
# is a card link, so the question drops it and its parentheses whole.
test_a_url_in_a_hold_question_leaves_it_cleanly() {
  local p q rel=https://forgejo.clarob.uk/rob/proton-drive-mount/releases/tag/v1.1.1
  write_snapshot "$TMP_ROOT/snap.json"
  jq --arg rel "$rel" '.decisions_open = [
        {id: "pdm-deploy-v111", key: "pdm-deploy-v111", verb: "captain-hold", owner: "(main)",
         title: "Deploy proton-drive-mount v1.1.1 to the Immich storage host",
         reason: ("Deploy proton-drive-mount v1.1.1 (" + $rel + ") to the Immich storage host?"),
         choices: {options: [{value: "a", label: "deploy in a quiet window and check reads and writes after (recommended)"},
                             {value: "b", label: "wait"}, {value: "c", label: "do not deploy"}],
                   links: [], free_text: true, no_link: false}}]' \
    "$TMP_ROOT/snap.json" > "$TMP_ROOT/snap-pdm.json"
  p=$(FM_BEARINGS_BOARD_PR_CHECK=0 "$GEN" --snapshot "$TMP_ROOT/snap-pdm.json") || fail "the generator failed"
  printf '%s\n' "$p" > "$TMP_ROOT/pdm.json"
  validates "$TMP_ROOT/pdm.json" || fail "the payload did not satisfy the validator"
  q=$(jq -r '.captains_call[] | select(.key == "pdm-deploy-v111") | .question // .title' <<<"$p")
  assert_equals "Deploy proton-drive-mount v1.1.1 to the Immich storage host?" "$q" "the question drops the URL cleanly"
  jq -e --arg u "$rel" '[.captains_call[] | select(.key == "pdm-deploy-v111") | .links[].url] | index($u) != null' <<<"$p" >/dev/null \
    || fail "the release is not a card link: $p"
  pass "a url in a hold question leaves it cleanly"
}

# A YouTrack link that ends a reason after its options is a card link labelled
# by its issue id, never about text.
test_a_reason_ending_on_a_youtrack_link_keeps_it_as_a_link() {
  local card name line id
  for name in writes:APP-5861 money:APP-5837 retest:APP-5871; do
    id=${name#*:} name=${name%%:*}
    case $name in writes) line=$BCR_WRITES_LINE ;; money) line=$BCR_MONEY_LINE ;; retest) line=$BCR_RETEST_LINE ;; esac
    card=$(real_line_card "bcr-$name" bcr-dec10-grill "$line")
    jq -e --arg id "$id" '(.about // "") | contains($id) | not' <<<"$card" >/dev/null \
      || fail "bcr $name: the about kept its trailing link: $card"
    assert_equals "$id" "$(jq -r '.links[0].label' <<<"$card")" "bcr $name: link label"
    jq -e '.question | endswith("?")' <<<"$card" >/dev/null || fail "bcr $name: the card lost its question: $card"
  done
  pass "a reason ending on a youtrack link keeps it as a link"
}

# The bcr-ticket-texts line: one "(a, recommended)" mark, then "b = " and "c = "
# marks, then 13 YouTrack links and four file paths after its last sentence.
BCR_TEXTS_LINE="needs-decision [key=bcr-ticket-texts] [at=1795103927]: Can I post these BCR ticket changes to YouTrack? The change creates two tickets, rewrites APP-5861 to APP-5871, renames APP-5868 and moves the links from APP-5860 to the new Confirm ticket. (a, recommended) post all as written. b = post with edits you write on the page. c = hold. https://youtrack.prd.descartesunderwriting.fr/issue/APP-5860 https://youtrack.prd.descartesunderwriting.fr/issue/APP-5861 https://youtrack.prd.descartesunderwriting.fr/issue/APP-5862 https://youtrack.prd.descartesunderwriting.fr/issue/APP-5863 https://youtrack.prd.descartesunderwriting.fr/issue/APP-5864 https://youtrack.prd.descartesunderwriting.fr/issue/APP-5865 https://youtrack.prd.descartesunderwriting.fr/issue/APP-5866 https://youtrack.prd.descartesunderwriting.fr/issue/APP-5867 https://youtrack.prd.descartesunderwriting.fr/issue/APP-5868 https://youtrack.prd.descartesunderwriting.fr/issue/APP-5869 https://youtrack.prd.descartesunderwriting.fr/issue/APP-5870 https://youtrack.prd.descartesunderwriting.fr/issue/APP-5871 https://youtrack.prd.descartesunderwriting.fr/issue/APP-6000 /home/rob/repos/firstmate/data/bcr-dec10-grill/youtrack-changes.md (Round 5) /home/rob/repos/firstmate/data/bcr-dec10-grill/texts/V1.md /home/rob/repos/firstmate/data/bcr-dec10-grill/texts/V2.md /home/rob/repos/firstmate/data/bcr-dec10-grill/texts/old-tickets.diff"

# Lowercase "b = " options after a parenthesised "(a, recommended)" one are the
# card choices, and the trailing links and paths go to the card links, web
# links labelled by issue id first and file paths by file name last.
test_equals_options_and_trailing_links_and_paths_leave_the_about() {
  local card
  card=$(real_line_card bcr-texts bcr-dec10-grill "$BCR_TEXTS_LINE")
  assert_equals "a|b|c" "$(jq -r '[.options[].value] | join("|")' <<<"$card")" "texts: option values"
  assert_equals "Post all as written|Post with edits you write on the page|hold" \
    "$(jq -r '[.options[].label] | join("|")' <<<"$card")" "texts: option labels"
  assert_equals "a" "$(jq -r .recommend_value <<<"$card")" "texts: recommendation"
  assert_equals "Can I post these BCR ticket changes to YouTrack? The change creates two tickets, rewrites APP-5861 to APP-5871, renames APP-5868 and moves the links from APP-5860 to the new Confirm ticket." \
    "$(jq -r '[.question, .about] | map(. // "") | map(select(length > 0)) | join(" ")' <<<"$card")" "texts: about"
  assert_equals "APP-5860 APP-5861 APP-5862 APP-5863 APP-5864 APP-5865 APP-5866 APP-5867 APP-5868 APP-5869 APP-5870 APP-5871 APP-6000" \
    "$(jq -r '[.links[] | select(has("url")) | .label] | join(" ")' <<<"$card")" "texts: web links"
  assert_equals "youtrack-changes.md (Round 5)|V1.md|V2.md|old-tickets.diff" \
    "$(jq -r '[.links[] | select(has("path")) | .label] | join("|")' <<<"$card")" "texts: path links"
  jq -e '(.links | map(has("path"))) as $p | $p[13:] | all' <<<"$card" >/dev/null \
    || fail "texts: a path link came before a web link: $card"
  assert_equals "/home/rob/repos/firstmate/data/bcr-dec10-grill/texts/old-tickets.diff" \
    "$(jq -r '.links[-1].path' <<<"$card")" "texts: last path"
  pass "equals options and trailing links and paths leave the about"
}

# The cd-930-members-key-2 line: an apply guard sentence follows a shell command
# whose quoted argument ends on a sentence end.
CD930_LINE=$(cat <<'EOF'
needs-decision [key=captain-hold-cd-930-members-key-2] [at=1795107988]: captain hold cd-930-members-key: Will you merge PR 945 (https://forgejo.clarob.uk/rob/continuous-delivery/pulls/945) and then run its infrastructure apply? It is green (7 of 7 checks) at 10127ad and is part 3 of issue 930 (https://forgejo.clarob.uk/rob/continuous-delivery/issues/930): it removes the shared registry key's write access to the container-members image registry, now that the image pushes use the new push-only key. It changes access rights, so it is your call. Nothing applies on merge. Run from devenv shell on main: cd infra && tofu init -backend-config="bucket=ai-ci-pipeline-tofu-state" && tofu apply -var="project_id=ai-ci-pipeline". The plan must read 0 to add, 0 to change, 1 to destroy (the container-members writer grant); anything else is drift, so stop and tell me. (a, recommended) yes, merge and apply; I then close issue 930. (b) hold it for now. https://forgejo.clarob.uk/rob/continuous-delivery/pulls/945
EOF
)

# An about keeps a quoted shell command whole and never drops the guard sentence
# after it, on a worker's status line and on a secondmate's hold alike; a
# sentence end inside a quoted argument or a code span is no cut point either.
test_an_apply_guard_after_a_quoted_shell_command_stays_in_the_about() {
  local card snap p cmd guard
  cmd='cd infra && tofu init -backend-config="bucket=ai-ci-pipeline-tofu-state" && tofu apply -var="project_id=ai-ci-pipeline".'
  guard='The plan must read 0 to add, 0 to change, 1 to destroy (the container-members writer grant); anything else is drift, so stop and tell me.'
  card=$(real_line_card cd930-status cd-930-members-key "$CD930_LINE")
  jq -e --arg c "$cmd" --arg g "$guard" '.about | contains($c) and contains($g)' <<<"$card" >/dev/null \
    || fail "status: the about lost the apply command or its guard: $card"
  assert_equals "a|b|a" "$(jq -r '[.options[].value, .recommend_value] | join("|")' <<<"$card")" "status: options"
  fresh_homes cd930-hold
  write_snapshot "$TMP_ROOT/cd930-hold-base.json"
  snap="$TMP_ROOT/cd930-hold.json"
  jq --arg r "${CD930_LINE#*captain hold cd-930-members-key: }" '.decisions_open = [
        {id: "cd/cd-930-members-key", key: "cd-930-members-key", verb: "captain-hold", owner: "cd",
         title_full: "#930: second container-members credential via forge-ops, then cut container-members writer off the shared key; human tofu apply after merge",
         reason_full: $r,
         choices: {options: [{label: "a", value: "a"}, {label: "b", value: "b"}],
                   links: [{label: "PR 945", target: "https://forgejo.clarob.uk/rob/continuous-delivery/pulls/945"},
                           {label: "issue 930", target: "https://forgejo.clarob.uk/rob/continuous-delivery/issues/930"}],
                   free_text: false, no_link: false}}]' "$TMP_ROOT/cd930-hold-base.json" > "$snap"
  p=$(FM_BEARINGS_BOARD_PR_CHECK=0 "$GEN" --snapshot "$snap") || fail "the generator failed on the cd-930 hold"
  card=$(jq -c '.captains_call[] | select(.key == "cd-930-members-key")' <<<"$p")
  jq -e --arg c "$cmd" --arg g "$guard" '.about | contains($c) and contains($g)' <<<"$card" >/dev/null \
    || fail "hold: the about lost the apply command or its guard: $card"
  assert_equals "a|b|a" "$(jq -r '[.options[].value, .recommend_value] | join("|")' <<<"$card")" "hold: options"
  # shellcheck disable=SC2016 # The backticks are a code span in the text, not a command.
  card=$(real_line_card quoted-cut apply-x 'needs-decision [key=apply] [at=1795107988]: Will you run `tofu apply -var="note=one. two"` on main? The plan must read 0 to add, 0 to change, 1 to destroy; anything else is drift, so stop and tell me.')
  jq -e '(.title | endswith("Will you run `tofu apply -var=\"note=one. two\"` on main?"))
         and (.about | contains("`tofu apply -var=\"note=one. two\"`"))
         and (.about | endswith("anything else is drift, so stop and tell me."))' <<<"$card" >/dev/null \
    || fail "quoted: a sentence end inside a code span was a cut point: $card"
  pass "an apply guard after a quoted shell command stays in the about"
}

# The aegis-821-review line: "Option a is my recommendation: ... Option b: ..."
# marks, a prose sentence after the last option, and a raw page:<id> token.
MR821_LINE='needs-decision [at=1795104252] [key=default]: Which held !821 review comments do you want me to post? Read page:understand-mr821 first, and answer its 8 why-questions in place if you want them checked. Option a is my recommendation: post a Comment with #3, #4 and #6 to #14, and drop #1, #2 and #5. Option b: post all 14. Option c: post the numbers you list. Option d: post none. I post nothing until you answer. https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/821'

# "Option x:" and "Option x is my recommendation:" marks, any case, are the
# card options with the recommended one, and the prose after the last option
# stays in the about.
test_option_x_colon_marks_are_the_card_options() {
  local card
  card=$(real_line_card mr821 aegis-821-review "$MR821_LINE")
  assert_equals "a|b|c|d" "$(jq -r '[.options[].value] | join("|")' <<<"$card")" "821: option values"
  assert_equals "Post a Comment with #3, #4 and #6 to #14, and drop #1, #2 and #5|Post all 14|Post the numbers you list|Post none" \
    "$(jq -r '[.options[].label] | join("|")' <<<"$card")" "821: option labels"
  assert_equals "a" "$(jq -r '.recommend_value // "none"' <<<"$card")" "821: recommendation"
  jq -e '(.about | endswith("in place if you want them checked. I post nothing until you answer.")) and (.about | test("Option [a-d]") | not)' <<<"$card" >/dev/null \
    || fail "821: the about lost its last sentence or kept an option: $card"
  card=$(real_line_card mr821-caps aegis-821-review "$(sed 's/Option a is my recommendation:/OPTION A IS MY RECOMMENDATION:/; s/Option b:/option B:/' <<<"$MR821_LINE")")
  assert_equals "a|b|c|d|a" "$(jq -r '[.options[].value, .recommend_value] | join("|")' <<<"$card")" "821: any case"
  pass "option x colon marks are the card options"
}

# The bcr-dec10-grill grill-bcr-r6 line ("Option a (recommended): ...") and the
# aegis-release-mrs line ("Option A (recommended): ..."): a parenthesised
# recommendation between the mark and its colon.
BCR_R6_LINE='needs-decision [key=grill-bcr-r6] [at=1795169168]: Shall APP-5861 be built with the recommended answer (a) to all five questions on page bcr-5861? Option a (recommended): yes, one ticket of about 3 days; a payment a handler already booked by hand is not booked again; a payment line with Code opération avis 50 goes to manual review. Option b: yes, with the changes you choose per question on page bcr-5861. Option c: as a, but book every payment, even ones a handler already booked by hand. Assumptions A1-A9 are in the round file; object by number. https://youtrack.prd.descartesunderwriting.fr/issue/APP-5861 /home/rob/repos/firstmate/data/bcr-dec10-grill/round-6.md'
AEGIS_REL_LINE='needs-decision [key=default] [at=1795169167]: Ship today'"'"'s release as 2.64.0 (on staging since 08:41 UTC today; holds !870, !876 and 9 tagged tickets) without the unready tickets? Option A (recommended): after the staging UAT go-ahead, promote 2.64.0 to prod; move the claim-status set (APP-5485/5486/5487, epic MR !895 is a draft 16 behind main) to a later release tag; !878 and !898 change nothing in prod, so they can merge today without a new staging round. Option B: merge !878 and !898 first, cut a new version and redo staging and UAT today (no prod gain). Option C: hold today'"'"'s release for the claim-status set (not achievable today). Report: /home/rob/repos/firstmate/data/aegis-release-mrs/report.md MRs: https://gitlab.descartesunderwriting.com/descartes-underwriting/app/aegis/-/merge_requests/878'

# "Option a (recommended):" and "Option A (recommended):" marks, and the
# "(preferred)" and "(my recommendation)" spellings in any case, are the card
# options with the parenthesised one recommended.
test_option_x_parenthesised_recommendation_marks_are_the_card_options() {
  local card
  card=$(real_line_card bcr-r6 bcr-dec10-grill "$BCR_R6_LINE")
  assert_equals "a|b|c|a" "$(jq -r '[.options[].value, .recommend_value] | join("|")' <<<"$card")" "bcr r6: options and recommendation"
  jq -e '(.options[0].label | contains("one ticket of about 3 days")) and (.options[1].label | contains("the changes you choose per question"))
         and (.options[2].label == "As a, but book every payment, even ones a handler already booked by hand")
         and (.question == "Shall APP-5861 be built with the recommended answer (a) to all five questions on page bcr-5861?")' <<<"$card" >/dev/null \
    || fail "bcr r6: the labels or the question are not the reason's: $card"
  card=$(real_line_card aegis-rel aegis-release-mrs "$AEGIS_REL_LINE")
  assert_equals "a|b|c|a" "$(jq -r '[.options[].value, .recommend_value] | join("|")' <<<"$card")" "aegis release: options and recommendation"
  assert_equals "Merge !878 and !898 first, cut a new version and redo staging and UAT today (no prod gain)|Hold today's release for the claim-status set (not achievable today)" \
    "$(jq -r '[.options[1:][].label] | join("|")' <<<"$card")" "aegis release: option labels"
  jq -e '.options[0].label | startswith("After the staging UAT go-ahead, promote 2.64.0 to prod;")' <<<"$card" >/dev/null \
    || fail "aegis release: the recommended label lost its text or kept its mark: $card"
  card=$(real_line_card aegis-rel-pref aegis-release-mrs "$(sed 's/Option A (recommended):/Option A:/; s/Option B:/option b (PREFERRED):/' <<<"$AEGIS_REL_LINE")")
  assert_equals "a|b|c|b" "$(jq -r '[.options[].value, .recommend_value] | join("|")' <<<"$card")" "aegis release: (preferred)"
  card=$(real_line_card aegis-rel-mine aegis-release-mrs "$(sed 's/Option A (recommended):/Option A:/; s/Option C:/Option C (My Recommendation):/' <<<"$AEGIS_REL_LINE")")
  assert_equals "a|b|c|c" "$(jq -r '[.options[].value, .recommend_value] | join("|")' <<<"$card")" "aegis release: (my recommendation)"
  pass "option x parenthesised recommendation marks are the card options"
}

# The APP-4132-tests-unit-rename mr898-gate line: inline "a=..., b=..., c=...?"
# options after the question.
MR898_LINE='needs-decision [key=mr898-gate] [at=1795422660]: The gate found no gaps in the test rename - how shall MR 898 proceed? a=mark ready and merge under the single-reviewer route (re-run the gate once ready to get the official AUTO_APPROVE first), b=fix the gaps first (none found; the only arguable hunk is app/pyrightconfig.json, which is not a test file), c=leave it as Draft?'

# Inline "a=label, b=label, c=label?" marks are the card options; key=, at= and
# a URL query string are never read as options.
test_inline_letter_equals_options_are_the_card_options() {
  local card
  card=$(real_line_card mr898 APP-4132-tests-unit-rename "$MR898_LINE")
  assert_equals "a|b|c" "$(jq -r '[.options[].value] | join("|")' <<<"$card")" "898: option values"
  assert_equals "Mark ready and merge under the single-reviewer route (re-run the gate once ready to get the official AUTO_APPROVE first)|Fix the gaps first (none found; the only arguable hunk is app/pyrightconfig.json, which is not a test file)|Leave it as Draft" \
    "$(jq -r '[.options[].label] | join("|")' <<<"$card")" "898: option labels"
  card=$(real_line_card eq-tokens eq-tokens 'needs-decision [key=eq-tokens] [at=1795422660]: The gate stopped with key=mr898 at=08:31Z; the log is at https://ci.example.com/job?x=1&y=2 and a=1 b=2 is set, so what next?')
  assert_equals "" "$(jq -r '[.options[].value] | join("|")' <<<"$card")" "key=/at=/query tokens: no options"
  pass "inline letter equals options are the card options"
}

test_inline_bare_letter_options_are_the_card_options() {
  local card
  card=$(real_line_card aegis-848-recheck aegis-848-recheck 'needs-decision [key=default] [at=1795422660]: On aegis MR 848 (https://gitlab.example/app/aegis/-/merge_requests/848), the author fixed your comment-length and test-gap threads but has not replied to or changed anything for your same-tab early-navigation QA gap or your description-rewrite request, so should I a) draft follow-up replies on those two threads (plus the give-up behaviour question) for your approval before anything is posted, b) build the understand page anyway, or c) leave the MR as it is?')
  assert_equals "a|b|c" "$(jq -r '[.options[].value] | join("|")' <<<"$card")" "848: option values"
  assert_equals "Draft follow-up replies on those two threads (plus the give-up behaviour question) for your approval before anything is posted|Build the understand page anyway|Leave the MR as it is" \
    "$(jq -r '[.options[].label] | join("|")' <<<"$card")" "848: option labels"
  jq -e '(.question | test("[a-c]\\) ") | not) and (.question | endswith("?"))' <<<"$card" >/dev/null \
    || fail "848: the question holds its options or does not ask: $(jq -r .question <<<"$card")"
  jq -e '(.about | test("so should I[?]$")) and (.about | test("[a-c]\\) ") | not)' <<<"$card" >/dev/null \
    || fail "848: the about holds its options or does not end in the question: $(jq -r .about <<<"$card")"
  pass "inline bare a), b), c) options are the card options and leave the question"
}

# A secondmate decision is answered from its card: options the reason marks
# recommended are the card recommendation, a "Captain call:" label is not the
# heading, and a decision answered on a page the board may not show carries what
# the card says without that page.
test_a_secondmate_decision_is_answerable_from_its_card() {
  local snap="$TMP_ROOT/mate-calls.json" copy="$TMP_ROOT/mate-calls-copy.json" p
  fresh_homes mate-calls
  write_snapshot "$TMP_ROOT/mate-calls-base.json"
  jq '.decisions_open = [
    {id: "pruner/diag", key: "status.pruner.diag", verb: "needs-decision", source: "status", task: "diag", decision_key: "default", owner: "pruner",
     reason: "forge diagnosis done (report: data/diag/report.md). Root cause: the seed push is refused. Captain call: main on armed repos only lets the pipeline push, so the re-run must either (a, recommended) push the seed with the pipeline token, which is never the admin token, or (b) open a PR and do one admin merge past the red check. PR 40 stays open."},
    {id: "pruner/tiers", key: "status.pruner.tiers", verb: "needs-decision", source: "status", task: "tiers", decision_key: "tiers", owner: "pruner",
     reason: "grilling round ready on one Lavish page: http://dev-1.tailf848b0.ts.net:4387/session/041adba9a930a7a9 - 15 questions, each with options and a pre-selected recommendation. No GPU used."},
    {id: "pruner/viewer", key: "status.pruner.viewer", verb: "needs-decision", source: "status", task: "viewer", decision_key: "viewer", owner: "pruner",
     reason: "the run-viewer prototype is ready for round-1 feedback on its review page http://dev-1.tailf848b0.ts.net:4387/session/08e66097e7ba349c. Feedback on the page goes straight to the prototype worker."},
    {id: "pruner/calls", key: "status.pruner.calls", verb: "needs-decision", source: "status", task: "calls", decision_key: "calls", owner: "pruner",
     title: "pruner: all seven baseline-run choices are now on one…",
     reason: "all seven baseline-run choices are now on one page: http://dev-1.tailf848b0.ts.net:4387/session/0c1b2a3d4e5f6a7b (answer on the page). 1-4 unchanged."}]' "$TMP_ROOT/mate-calls-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  card() { jq -c --arg k "$1" '.captains_call[] | select(.key == $k)' <<<"$p"; }
  assert_equals "Main on armed repos only lets the pipeline push, so the re-run must either" "$(card status.pruner.diag | jq -r .question)" "a decision label is not part of the heading"
  assert_equals "a|b" "$(card status.pruner.diag | jq -r '[.options[].value] | join("|")')" "the lettered options are the choices"
  card status.pruner.diag | jq -e '.about | test("PR 40 stays open") and (test("Captain call") | not)' >/dev/null \
    || fail "the about kept the decision label of the sentence the heading took: $(card status.pruner.diag | jq -r .about)"
  assert_equals "a" "$(card status.pruner.diag | jq -r .recommend_value)" "the option marked recommended is the recommendation"
  assert_equals "Push the seed with the pipeline token, which is never the admin token" "$(card status.pruner.diag | jq -r '.options[0].label')" "the recommendation note is not part of the option label"
  for k in status.pruner.tiers status.pruner.viewer status.pruner.calls; do
    assert_equals '{"options":[],"allow_freeform":false,"question":null}' "$(card "$k" | jq -c '{options, allow_freeform, question}')" "a page-backed decision shows only its page link"
    assert_equals 'true|answer in your own words (say later to defer)' "$(card "$k" | jq -r '.off_board | "\(.allow_freeform)|\(.freeform_hint)"')" "a page-backed decision can still be answered in words off its page"
    card "$k" | jq -e '.off_board | (.question | length > 0) and (.malformed | test("Lavish page"))' >/dev/null \
      || fail "a page-backed decision does not carry its question and why its choices are missing: $(card "$k")"
  done
  assert_equals "pruner: grilling round ready" "$(card status.pruner.tiers | jq -r .title)" "a page-backed card is titled by what its page is about"
  assert_equals "pruner: the run-viewer prototype is ready" "$(card status.pruner.viewer | jq -r .title)" "a page-backed card is titled by what its page is about"
  assert_equals "pruner: all seven baseline-run choices" "$(card status.pruner.calls | jq -r .title)" "a title cut short before its page phrase is still titled by what the page is about"
  printf '%s\n' "$p" > "$TMP_ROOT/mate-calls-payload.json"
  validates "$TMP_ROOT/mate-calls-payload.json" || fail "a payload with off-board fields did not satisfy the board validator"
  printf '{"captains_call":{"status.pruner.tiers":{"question":"Which test tiers run?","options":[{"value":"all","label":"All"},{"value":"fast","label":"Fast only"}]},"status.pruner.diag":{"options":[{"value":"seed","label":"Seed it"}]}}}\n' > "$copy"
  p=$("$GEN" --snapshot "$snap" --copy "$copy") || fail "the generator failed with a copy overlay"
  assert_equals '{"allow_freeform":true,"freeform_hint":"answer in your own words (say later to defer)"}' \
    "$(card status.pruner.tiers | jq -c '.off_board | del(.about)')" "an authored question and options leave the off-board fields"
  assert_equals "null" "$(card status.pruner.diag | jq -r '.recommend_value // null')" "a recommendation the authored options lack is dropped"
  printf '%s\n' "$p" > "$TMP_ROOT/mate-calls-copy-payload.json"
  validates "$TMP_ROOT/mate-calls-copy-payload.json" || fail "an overlaid payload with off-board fields did not satisfy the board validator"
  pass "a secondmate decision is answerable from its card, and a page-backed one off its page"
}

# The captain's open GitLab MRs that no task covers reach the board as
# information rows - URL and one state line - never as decision cards. A
# snapshot without them adds no section. An MR that waits on its author keeps
# that wait in its state line and never becomes a card or a waiting row.
test_open_mrs_no_task_covers_become_information_rows() {
  local base snap out
  base="$TMP_ROOT/mrs-base.json"; write_snapshot "$base"
  snap="$TMP_ROOT/mrs-snap.json"
  jq '.open_mrs = [
        {key:"mr-42-880", repo:"aegis", title:"Bump the dependencies",
         url:"https://gitlab.example.com/grp/app/aegis/-/merge_requests/880",
         state:"mergeable, CI passing, 0 approvals, threads resolved, last activity 2026-07-11",
         updated:"2026-07-11T08:30:00Z"},
        {key:"mr-42-846", repo:"aegis", title:"Teammate pricing change",
         url:"https://gitlab.example.com/grp/app/aegis/-/merge_requests/846",
         state:"waiting on boyd.ebsworthy (you requested changes), threads open, CI passing, 0 approvals, last activity 2026-07-11",
         updated:"2026-07-11T08:00:00Z"}]
      | .mrs = "checked (gitlab.example.com, 2 open MR(s) no task covers)"' "$base" > "$snap"
  out="$TMP_ROOT/mrs-payload.json"
  "$GEN" --snapshot "$snap" > "$out" || fail "the generator failed on a snapshot with open MRs"
  jq -e '
    .open_mrs == [{key:"mr-42-880", repo:"aegis", title:"Bump the dependencies",
                   url:"https://gitlab.example.com/grp/app/aegis/-/merge_requests/880",
                   state:"mergeable, CI passing, 0 approvals, threads resolved, last activity 2026-07-11"},
                  {key:"mr-42-846", repo:"aegis", title:"Teammate pricing change",
                   url:"https://gitlab.example.com/grp/app/aegis/-/merge_requests/846",
                   state:"waiting on boyd.ebsworthy (you requested changes), threads open, CI passing, 0 approvals, last activity 2026-07-11"}]
    and ([.captains_call[] | select((.pr_url // "") | test("merge_requests/(880|846)"))] | length) == 0
    and ([.waiting[]? | tostring | select(test("merge_requests/846|aegis!846"))] | length) == 0
  ' "$out" >/dev/null || fail "an uncovered MR must be an information row, not a card: $(cat "$out")"
  validates "$out" || fail "a payload with open MRs must satisfy the board validator"
  "$GEN" --snapshot "$base" | jq -e 'has("open_mrs") | not' >/dev/null \
    || fail "a snapshot without open MRs must add no open_mrs section"
  jq '.open_mrs[0].url = "http://gitlab.example.com/x"' "$out" > "$TMP_ROOT/mrs-bad-url.json"
  validates "$TMP_ROOT/mrs-bad-url.json" && fail "an open MR row without an https URL must be refused"
  jq '.open_mrs[0].state = ""' "$out" > "$TMP_ROOT/mrs-bad-state.json"
  validates "$TMP_ROOT/mrs-bad-state.json" && fail "an open MR row without a state line must be refused"
  jq '.open_mrs[0].question = "Merge?"' "$out" > "$TMP_ROOT/mrs-bad-key.json"
  validates "$TMP_ROOT/mrs-bad-key.json" && fail "an open MR row must not carry decision-card fields"
  jq '.open_mrs = {}' "$out" > "$TMP_ROOT/mrs-bad-shape.json"
  validates "$TMP_ROOT/mrs-bad-shape.json" && fail "open_mrs must be an array"
  pass "uncovered open MRs are validated information rows with their URL and state"
}

# The cd secondmate holds cd-732-calls and cd-forge-arm-login-access, each
# ending in an "Evidence: <path>" line under its mate home's data directory: one
# names a calls.md, the other a report.md.
CD732_REASON=$(printf '%s\n%s' 'CD self-hosting (#732): which answer for calls 10 and 11? Pick one option per call (recommended 10a 11a), or type a line like "10a 11a".' \
  'Evidence: /home/rob/.treehouse/firstmate-8a8811/6/firstmate/data/cd-732-cd-runs-own-callees/calls.md')
FORGE_ARM_REASON=$(printf '%s\n%s' "Firstmate's tea login is a rob token limited to the repos chosen when it was made on 2026-11-03, so it cannot see bearings-board, forge-ops or firstmate-settings, and Forgejo has no way for forge-arm to extend it. How should tea reach new repos? For A, at the link: new token for rob, repository access All, scopes write:repository, write:issue, read:user; replace the tea login (tea login delete forgejo.clarob.uk, then tea login add --name forgejo.clarob.uk --url https://forgejo.clarob.uk --token <new>); delete the old token." \
  'Evidence: /home/rob/.treehouse/firstmate-8a8811/6/firstmate/data/cd-forge-arm-login-access/report.md')

# The two cd holds as the snapshot shows them, owned by the cd home.
cd_mate_hold_payload() {
  local snap="$TMP_ROOT/cd-mate-holds.json"
  write_snapshot "$TMP_ROOT/cd-mate-holds-base.json"
  jq --arg r1 "$CD732_REASON" --arg r2 "$FORGE_ARM_REASON" '.decisions_open = [
      {id: "cd/cd-732-calls", key: "cd-732-calls", verb: "captain-hold", owner: "cd",
       title_full: "#732 S9: CD-only release jobs and credentials (calls 10-11)", reason_full: $r1,
       choices: {options: [], links: [{target: "https://forgejo.clarob.uk/rob/continuous-delivery/issues/732", label: ""}],
                 free_text: true, no_link: false}},
      {id: "cd/cd-forge-arm-login-access", key: "cd-forge-arm-login-access", verb: "captain-hold", owner: "cd",
       title_full: "forge-arm grants the firstmate login access to an armed repo", reason_full: $r2,
       choices: {options: [{value: "a", label: "A: you make one unrestricted rob token once and swap it into tea; no code change (recommended)"},
                           {value: "b", label: "B: tea uses a rob-bot token, which forge-arm already adds to every armed repo; check merging as rob-bot first"},
                           {value: "c", label: "C: keep a restricted token and remake it for every new repo"}],
                 links: [{target: "https://forgejo.clarob.uk/user/settings/applications", label: "Forgejo access tokens"}],
                 free_text: true, no_link: false}}]' \
    "$TMP_ROOT/cd-mate-holds-base.json" > "$snap"
  "$GEN" --snapshot "$snap"
}

# An "Evidence: <path>" tail links the file it names, whatever its name, and
# leaves the about.
test_an_evidence_path_in_a_mate_hold_is_a_card_link() {
  local p
  p=$(cd_mate_hold_payload) || fail "the generator failed"
  assert_equals "/home/rob/.treehouse/firstmate-8a8811/6/firstmate/data/cd-732-cd-runs-own-callees/calls.md" \
    "$(jq -r '.captains_call[] | select(.key == "cd-732-calls") | [.links[] | .path // empty] | join("|")' <<<"$p")" \
    "the calls.md Evidence path is not a link on its card"
  assert_equals "/home/rob/.treehouse/firstmate-8a8811/6/firstmate/data/cd-forge-arm-login-access/report.md" \
    "$(jq -r '.captains_call[] | select(.key == "cd-forge-arm-login-access") | [.links[] | .path // empty] | join("|")' <<<"$p")" \
    "the report.md Evidence path is not a link on its card"
  assert_equals "Issue 732|calls.md" \
    "$(jq -r '.captains_call[] | select(.key == "cd-732-calls") | [.links[].label] | join("|")' <<<"$p")" \
    "the calls.md card does not keep its issue link first"
  assert_equals "" \
    "$(jq -r '[.captains_call[] | ((.question // "") + (.about // "")) | select(test("Evidence:"))] | join("|")' <<<"$p")" \
    "an Evidence: tail stayed in the card text"
  printf '%s\n' "$p" > "$TMP_ROOT/cd-mate-holds-payload.json"
  validates "$TMP_ROOT/cd-mate-holds-payload.json" || fail "the payload with Evidence path links did not validate"
  pass "an Evidence: path in a mate hold links its file, calls.md and report.md alike"
}

# A recorded label that opens with its own option letter ("A: ...") shows
# without it, so the card does not write the letter twice.
test_an_uppercase_letter_tag_leaves_a_recorded_label() {
  local p
  p=$(cd_mate_hold_payload) || fail "the generator failed"
  assert_equals "a=you make one unrestricted rob token once and swap it into tea; no code change|b=tea uses a rob-bot token, which forge-arm already adds to every armed repo; check merging as rob-bot first|c=keep a restricted token and remake it for every new repo" \
    "$(jq -r '.captains_call[] | select(.key == "cd-forge-arm-login-access") | [.options[] | "\(.value)=\(.label)"] | join("|")' <<<"$p")" \
    "an A:/B:/C: tag stayed on a recorded label"
  assert_equals "a" \
    "$(jq -r '.captains_call[] | select(.key == "cd-forge-arm-login-access") | .recommend_value' <<<"$p")" \
    "the recommended option lost its mark"
  pass "an uppercase tag of its own letter leaves a recorded label"
}

# A URL given to a command in the hold text ("tea login add --url
# https://forgejo.clarob.uk") is an argument, not a link, and stays as written;
# the same goes for a URL in a code span.
test_a_url_given_to_a_command_is_never_a_card_link() {
  local p snap
  p=$(cd_mate_hold_payload) || fail "the generator failed"
  assert_equals "Forgejo access tokens|report.md" \
    "$(jq -r '.captains_call[] | select(.key == "cd-forge-arm-login-access") | [.links[].label] | join("|")' <<<"$p")" \
    "a URL given to the tea command became a card link"
  jq -e '.captains_call[] | select(.key == "cd-forge-arm-login-access")
         | ((.question // "") + " " + (.about // "")) | contains("--url https://forgejo.clarob.uk --token")' <<<"$p" >/dev/null \
    || fail "the tea command lost its URL argument: $p"
  snap="$TMP_ROOT/code-span-url.json"
  write_snapshot "$TMP_ROOT/code-span-url-base.json"
  jq '.decisions_open = [{id: "span", key: "span", verb: "captain-hold", owner: "(main)", title_full: "Pick a host",
        reason_full: "Should I run `curl https://example.org/health` before the switch, as PR https://github.com/acme/alpha/pull/9 asks?",
        choices: {options: [], links: [], free_text: true, no_link: false}}]' \
    "$TMP_ROOT/code-span-url-base.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "https://github.com/acme/alpha/pull/9" \
    "$(jq -r '.captains_call[] | select(.key == "span") | [.links[].url] | join("|")' <<<"$p")" \
    "a URL in a code span became a card link, or the PR link was lost"
  pass "a URL given to a command or written in a code span is never a card link"
}

fm_test_run \
  test_zero_copy_payload_satisfies_the_board_validator \
  test_open_mrs_no_task_covers_become_information_rows \
  test_the_same_snapshot_yields_the_same_payload \
  test_rows_map_deterministically_from_the_snapshot \
  test_charted_rows_derive_dispatchable_and_warning_from_structure \
  test_copy_overlay_refines_cards_and_keeps_the_payload_valid \
  test_copy_overlay_cannot_change_the_payload_shape \
  test_an_unheld_captain_contribution_becomes_a_link_card \
  test_the_generators_own_cards_pass_the_build_decision_check \
  test_a_hold_with_recorded_options_and_links_puts_them_on_its_card \
  test_a_hold_with_bare_recorded_options_shows_words_not_raw_values \
  test_a_hold_with_lettered_slug_options_keeps_explanations_and_lead_in \
  test_a_hold_listing_its_options_in_the_reason_as_well_is_named \
  test_a_question_that_opens_what_next_keeps_its_comma_led_clause \
  test_a_hold_without_recorded_options_or_a_link_is_refused_naming_what_to_add \
  test_cards_carry_links_and_a_non_held_credential_card_survives \
  test_the_validator_accepts_https_and_the_tailnet_origin_and_refuses_other_http \
  test_the_captains_priority_orders_cards_and_tasks_and_is_recorded_durably \
  test_the_priority_digest_is_bounded_and_silent_when_unset \
  test_a_wait_or_park_hold_moves_to_the_waiting_group_and_questions_lead_cards \
  test_a_released_hold_is_not_a_decision_card \
  test_a_lapsed_time_gate_returns_the_hold_to_captains_call \
  test_every_question_card_gets_real_default_choices \
  test_a_task_status_question_becomes_a_card_and_a_wait_a_waiting_row \
  test_a_keyless_blocked_line_naming_a_dependency_waits_instead_of_a_card \
  test_urls_in_a_question_become_card_links \
  test_a_tailnet_review_page_link_and_a_review_card_get_choices \
  test_a_secondmate_status_question_is_titled_from_its_decision_not_its_home \
  test_a_status_question_whose_only_asking_sentence_is_inside_an_option_is_listed_to_fix \
  test_a_status_question_and_its_same_home_hold_render_one_card_with_every_choice \
  test_an_unkeyed_status_line_naming_a_held_card_does_not_make_a_second_card \
  test_a_keyed_worker_question_on_a_held_task_does_not_make_a_second_card \
  test_a_past_tense_worker_option_keeps_its_verb \
  test_options_marked_after_their_text_are_the_card_choices \
  test_a_last_option_ends_at_a_dash_before_links \
  test_a_recorded_option_marked_recommended_is_the_card_recommendation \
  test_an_a_recommended_hold_with_recorded_labels_is_the_recommendation \
  test_a_hold_the_captain_parked_waits_even_when_its_reason_asks_a_question \
  test_a_card_heading_is_one_short_asking_sentence_without_correlation_ids \
  test_a_long_asking_sentence_still_heads_its_card_as_a_question \
  test_a_card_whose_question_does_not_ask_is_flagged_even_when_its_options_ask \
  test_default_choices_match_the_question_asked \
  test_action_card_answers_reach_the_intake_as_the_captains_report \
  test_a_card_whose_pr_merged_or_closed_leaves_the_board \
  test_a_question_after_a_merge_stays_and_a_stale_merge_ask_leaves \
  test_announcements_and_time_gates_are_not_calls_and_a_real_question_stays \
  test_page_live_lines_fold_their_links_into_the_mr_card \
  test_a_secondmate_dated_hold_waits_with_its_date \
  test_every_held_or_in_flight_secondmate_task_has_a_row \
  test_a_round_a_newer_round_superseded_leaves_the_board \
  test_a_numbered_option_question_stays_a_card_when_an_option_says_until \
  test_card_links_are_labelled_by_what_they_point_at \
  test_annotated_decisions_offer_their_own_full_options_in_captain_terms \
  test_the_body_drops_the_words_that_introduced_its_options \
  test_a_handed_decision_waits_with_who_has_it_instead_of_a_card \
  test_a_priority_never_brings_back_a_closed_or_handed_decision \
  test_a_partial_board_priority_keeps_the_ranks_it_does_not_name \
  test_an_unranked_decision_card_is_dealt_after_every_ranked_card \
  test_a_review_card_the_captain_approved_leaves_and_any_other_stays \
  test_a_freeze_or_a_hold_that_says_it_is_no_decision_waits_instead_of_asking \
  test_a_card_carries_the_pr_link_its_snapshot_row_recorded \
  test_a_card_shows_every_option_its_text_refers_to_or_says_it_does_not_list_them \
  test_a_secondmate_decision_is_answerable_from_its_card \
  test_a_rec_letter_equals_option_line_gets_buttons_and_a_free_text_answer \
  test_a_numbered_recommended_option_line_gets_buttons \
  test_an_abbreviation_never_ends_the_card_question \
  test_a_sentence_addressed_to_firstmate_never_reaches_the_card \
  test_a_link_label_right_before_a_question_mark_keeps_no_space \
  test_a_link_label_never_doubles_its_kind_word \
  test_a_long_asking_sentence_is_headed_by_the_clause_that_asks \
  test_a_how_to_proceed_question_is_in_the_title_or_the_question \
  test_an_a_recommended_colon_option_is_the_recommendation \
  test_the_last_option_ends_at_its_own_words \
  test_both_recommended_marks_reach_the_card \
  test_a_parenthesis_before_the_question_mark_is_never_cut \
  test_a_report_path_in_the_text_is_the_card_report \
  test_a_forgejo_card_takes_its_repo_from_its_links \
  test_a_link_the_text_already_names_shows_no_label_in_parentheses \
  test_a_comment_link_reads_as_a_comment \
  test_a_too_long_asking_sentence_is_cut_at_a_clause_boundary \
  test_a_trailing_which_clause_is_never_the_question \
  test_a_leading_question_beats_a_later_list_lead_in \
  test_a_later_question_beats_a_later_list_lead_in \
  test_a_secondmate_question_after_its_context_is_asked \
  test_a_re_held_card_shows_its_current_options_and_each_link_once \
  test_steps_that_start_with_a_url_stay_in_the_about \
  test_a_url_with_a_placeholder_stays_whole_and_is_never_a_link \
  test_a_url_in_a_hold_question_leaves_it_cleanly \
  test_a_reason_ending_on_a_youtrack_link_keeps_it_as_a_link \
  test_equals_options_and_trailing_links_and_paths_leave_the_about \
  test_an_apply_guard_after_a_quoted_shell_command_stays_in_the_about \
  test_option_x_colon_marks_are_the_card_options \
  test_option_x_parenthesised_recommendation_marks_are_the_card_options \
  test_inline_letter_equals_options_are_the_card_options \
  test_inline_bare_letter_options_are_the_card_options \
  test_lettered_options_answer_as_their_letters \
  test_an_evidence_path_in_a_mate_hold_is_a_card_link \
  test_an_uppercase_letter_tag_leaves_a_recorded_label \
  test_a_url_given_to_a_command_is_never_a_card_link
