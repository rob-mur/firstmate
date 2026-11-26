#!/usr/bin/env bash
# Behavior tests for bin/fm-unowned-work.sh: the captain's open Draft MRs/PRs
# and paused work that no task, worker or held card moves. glab, curl, the
# captain-calls reader and the crew-state reader are stubs; no test reads a
# live forge. The fixture carries the two design walkthrough cases: MR !126
# (no task at all) and MR !900 (its task is done, the MR is still Draft and no
# card holds it).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-unowned-work)
SCRIPT="$ROOT/bin/fm-unowned-work.sh"
NOW=2000000000
OLD=$(jq -rn --argjson t $((NOW - 7200)) '$t | todateiso8601')
FRESH=$(jq -rn --argjson t $((NOW - 600)) '$t | todateiso8601')
GL=https://gitlab.test/grp
CASE=0

# new_home: a fresh home with stubs; sets H (home) and S (stub directory).
new_home() {
  CASE=$((CASE + 1))
  H="$TMP_ROOT/case$CASE/home"
  S="$TMP_ROOT/case$CASE"
  mkdir -p "$H/state" "$H/data" "$H/config"
  printf 'gitlab\nforgejo forge.test rob rob-bot\nreviewer-owned iac-keycloak\n' > "$H/config/unowned-work"
  printf '{"hosts":{"forge.test":{"token":"secret-token"}}}\n' > "$S/keys.json"
  printf '{"calls":[],"skipped":[]}\n' > "$S/calls.json"
  printf '[]\n' > "$S/forgejo.json"
  : > "$S/nodes"
  : > "$S/states"
  local fb
  fb=$(fm_fakebin "$S")
  cat > "$fb/glab" <<SH
#!/usr/bin/env bash
[ -e "$S/glab-fail" ] && exit 1
printf '%s\n' "\$*" >> "$S/glab-calls"
jq -s '{data: {currentUser: {username: "rob", authoredMergeRequests: {nodes: .}}}}' "$S/nodes"
SH
  cat > "$fb/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$S/curl-calls"
cat "$S/forgejo.json"
SH
  cat > "$S/calls" <<SH
#!/usr/bin/env bash
[ -e "$S/calls-fail" ] && exit 1
cat "$S/calls.json"
SH
  cat > "$S/crew-state" <<SH
#!/usr/bin/env bash
s=\$(awk -v id="\$1" -v h="\$FM_HOME" '\$1 == id && (\$3 == "" || \$3 == h) { print \$2 }' "$S/states" | head -1)
printf 'state: %s · source: stub\n' "\${s:-working}"
SH
  chmod +x "$fb/glab" "$fb/curl" "$S/calls" "$S/crew-state"
  FAKEBIN=$fb
}

# mr <iid> <repo> [branch] [updated] [pipeline] [reviewer] [title]
mr() {
  jq -cn --arg u "$GL/$2/-/merge_requests/$1" --arg iid "$1" --arg b "${3:-fm/x-$1}" \
    --arg t "${4:-$OLD}" --arg p "${5:-}" --arg r "${6:-}" --arg title "${7:-Draft: change $1}" \
    '{webUrl: $u, iid: $iid, title: $title, sourceBranch: $b, updatedAt: $t,
      reviewers: {nodes: (if $r == "" then [] else [{username: $r}] end)},
      headPipeline: (if $p == "" then null else {status: $p} end)}' >> "$S/nodes"
}

state_of() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$S/states"; }

run() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$H" FM_UNOWNED_NOW=${RUN_NOW:-$NOW} \
    FM_UNOWNED_FORGEJO_KEYS="$S/keys.json" FM_UNOWNED_CALLS_CMD="$S/calls" \
    FM_UNOWNED_CREW_STATE_CMD="$S/crew-state" "$SCRIPT" "$@"
}

reasons() { run | jq -r '.findings[] | "\(.ref) \(.reason)"'; }

test_mr_126_with_no_task_is_a_finding() {
  new_home
  mr 126 aegis fm/a-126 "$OLD" FAILED
  local out
  out=$(run)
  assert_equals 1 "$(jq '.findings | length' <<<"$out")" "one finding"
  assert_equals "$GL/aegis/-/merge_requests/126+red Draft, no task, no worker and no card" \
    "$(jq -r '.findings[0].key' <<<"$out")" "key is URL plus reason"
  assert_equals "draft aegis !126 $GL/aegis/-/merge_requests/126 $NOW" \
    "$(jq -r '.findings[0] | "\(.kind) \(.repo) \(.ref) \(.url) \(.since)"' <<<"$out")" "finding fields"
  assert_equals "$NOW null 0" "$(jq -r '"\(.checked_at) \(.read_failed_at) \(.failed_sweeps)"' <<<"$out")" "sweep fields"
  assert_equals 1 "$(wc -l < "$S/glab-calls" | tr -d ' ')" "one GitLab call per sweep"
  assert_equals "$out" "$(cat "$H/state/unowned-work.json")" "JSON written to state"
  pass "MR 126 with no task, worker or card is a finding"
}

test_mr_900_task_done_still_draft_is_a_finding() {
  new_home
  mr 900 bearings fm/b-900 "$OLD" SUCCESS
  printf 'project=/repos/bearings\nbranch=fm/other\npr=%s\n' "$GL/bearings/-/merge_requests/900" > "$H/state/t900.meta"
  state_of t900 "done"
  assert_equals "!900 green Draft, task t900 done, no card" "$(reasons)" "done task finding"
  pass "MR 900 whose task is done and has no card is a finding"
}

test_each_owner_rule_owns_a_working_draft() {
  new_home
  mr 1 r1; mr 2 r2; mr 3 r3; mr 4 r4 fm/own-4; mr 5 r5
  printf 'pr=%s\n' "$GL/r1/-/merge_requests/1" > "$H/state/a.meta"
  printf 'pr=\npr_extra=https://x.test/y %s\n' "$GL/r2/-/merge_requests/2" > "$H/state/b.meta"
  : > "$H/state/c.meta"
  printf 'working [at=1]: opened %s.\n' "$GL/r3/-/merge_requests/3" > "$H/state/c.status"
  printf 'project=/repos/r4/\nbranch=fm/own-4\n' > "$H/state/d.meta"
  printf '## Queued\n- [ ] e - fix (repo: r5) (kind: ship)\n  MR: %s\n' "$GL/r5/-/merge_requests/5" > "$H/data/backlog.md"
  assert_equals "" "$(reasons)" "every Draft is owned"
  # An owning task that is paused on something else, not the captain, still moves it.
  state_of a paused
  printf 'paused [at=1]: waiting on CI for %s\n' "$GL/r1/-/merge_requests/1" > "$H/state/a.status"
  assert_equals "" "$(reasons)" "paused on CI is owned"
  printf 'paused [at=2]: waiting on the captain to approve\n' >> "$H/state/a.status"
  assert_equals "!1 Draft, task a paused on you, no card" "$(reasons)" "paused on captain is a finding"
  pass "meta pr, pr_extra, status link, branch plus project and backlog row each own a Draft"
}

test_owner_in_a_secondmate_home() {
  new_home
  local M="$S/mate"
  mkdir -p "$M/state" "$M/data"
  printf -- '- mate1 - a mate (home: %s; scope: x; projects: ; added 2026-01-01)\n' "$M" > "$H/data/secondmates.md"
  : > "$H/state/mate1.meta"
  printf 'working [at=1]: on %s\n' "$GL/r/-/merge_requests/7" > "$H/state/mate1.status"
  mr 7 r
  printf 'pr=%s\n' "$GL/r/-/merge_requests/7" > "$M/state/m7.meta"
  assert_equals "" "$(reasons)" "mate task owns it"
  state_of m7 "done" "$M"
  assert_equals "!7 Draft, task m7 done, no card" "$(reasons)" "mate task state read from its home"
  rm "$M/state/m7.meta"
  assert_equals "!7 Draft, no task, no worker and no card" "$(reasons)" "the mate itself is not an owner"
  pass "a task in a local secondmate home owns a Draft; the mate's own record does not"
}

test_false_positive_rows() {
  new_home
  mr 10 r10 fm/a "$OLD" "" alice                # waits on another reviewer
  mr 11 iac-keycloak fm/b                        # reviewer-owned repo
  mr 12 r12; mr 13 r13; mr 14 r14 fm/c "$FRESH"  # held card, deferred card, in grace
  mr 15 r15 fm/d "$OLD" "" rob                   # captain is the only reviewer
  mr 16 r16
  printf '{"calls":[{"task":"h","links":[{"url":"%s."}]}],"skipped":[{"task":"k","question":"see %s)"}]}\n' \
    "$GL/r12/-/merge_requests/12" "$GL/r13/-/merge_requests/13" > "$S/calls.json"
  printf 'pr=%s\n' "$GL/r16/-/merge_requests/16" > "$H/state/babysit-mrs-1.meta"
  state_of babysit-mrs-1 "done"
  assert_equals $'!15 Draft, no task, no worker and no card\n!16 Draft, no task, no worker and no card' \
    "$(reasons | sort)" "only the captain-reviewed and babysit Drafts remain"
  pass "other reviewer, reviewer-owned repo, held or deferred card and grace are not findings; a babysit sweep never owns"
}

test_card_by_task_covers_done_owner() {
  new_home
  mr 20 r
  printf 'pr=%s\n' "$GL/r/-/merge_requests/20" > "$H/state/t20.meta"
  state_of t20 "done"
  printf '{"calls":[{"task":"t20","links":[]}],"skipped":[]}\n' > "$S/calls.json"
  assert_equals "" "$(reasons)" "a card on the owning task covers it"
  pass "a held card on the owning task covers its Draft"
}

test_grace_is_30_minutes() {
  new_home
  mr 30 r fm/g "$(jq -rn --argjson t $((NOW - 1799)) '$t | todateiso8601')"
  mr 31 r fm/h "$(jq -rn --argjson t $((NOW - 1800)) '$t | todateiso8601')"
  mr 32 r fm/i "$(jq -rn --argjson t $((NOW - 1700 + 3600)) '$t | strftime("%Y-%m-%dT%H:%M:%S.123+01:00")')"
  assert_equals "!31 Draft, no task, no worker and no card" "$(reasons)" "only the Draft past 30 minutes"
  pass "a Draft updated under 30 minutes ago waits a sweep"
}

test_cap_of_5_without_prototypes() {
  new_home
  local i
  for i in 41 42 43 44 45; do mr "$i" r "fm/$i" "$FRESH"; done
  mr 46 r prototype/x "$FRESH"
  mr 47 r fm/47 "$FRESH" "" "" "Draft: prototype of the board"
  mr 48 r fm/48 "$FRESH" "" alice
  assert_equals "" "$(reasons)" "5 Drafts plus prototypes and a reviewed Draft are under the cap"
  mr 49 r fm/49 "$FRESH"
  local out
  out=$(run)
  assert_equals "cap cap+Drafts over cap 5" "$(jq -r '.findings[] | "\(.kind) \(.key)"' <<<"$out")" "cap finding"
  assert_equals "6 Drafts open, cap 5: r !41, r !42, r !43, r !44, r !45, r !49" \
    "$(jq -r '.findings[0].reason' <<<"$out")" "cap lists the counted Drafts"
  printf 'cap 6\n' >> "$H/config/unowned-work"
  assert_equals "" "$(reasons)" "configured cap"
  pass "more than 5 Drafts is one finding; prototypes and reviewed Drafts are not counted"
}

test_prototype_draft_is_named() {
  new_home
  mr 50 r prototype/demo
  assert_equals "!50 prototype Draft, no task, no worker and no card" "$(reasons)" "prototype named"
  pass "an unowned prototype Draft is still a finding"
}

test_forgejo_drafts() {
  new_home
  jq -n --arg t "$OLD" '[
    {number: 3, html_url: "https://forge.test/rob/cd/pulls/3", updated_at: $t, title: "x",
     user: {login: "rob-bot"}, repository: {name: "cd"}, pull_request: {draft: true}},
    {number: 4, html_url: "https://forge.test/rob/cd/pulls/4", updated_at: $t, title: "x",
     user: {login: "rob"}, repository: {name: "cd"}, pull_request: {draft: false}},
    {number: 5, html_url: "https://forge.test/eve/cd/pulls/5", updated_at: $t, title: "x",
     user: {login: "eve"}, repository: {name: "cd"}, pull_request: {draft: true}}]' > "$S/forgejo.json"
  local out
  out=$(run)
  assert_equals "cd #3 https://forge.test/rob/cd/pulls/3" \
    "$(jq -r '.findings[] | "\(.repo) \(.ref) \(.url)"' <<<"$out")" "only the captain's Draft PR"
  assert_equals 1 "$(wc -l < "$S/curl-calls" | tr -d ' ')" "one Forgejo search per sweep"
  assert_contains "$(cat "$S/curl-calls")" "repos/issues/search?type=pulls&state=open" "issues search"
  assert_not_contains "$(cat "$S/curl-calls")" "secret-token" "token kept off argv"
  pass "Forgejo Draft PRs by the configured logins are read with one search"
}

test_no_config_reads_no_forge() {
  new_home
  rm "$H/config/unowned-work"
  mr 60 r
  assert_equals "" "$(reasons)" "no Draft findings"
  [ ! -e "$S/glab-calls" ] && [ ! -e "$S/curl-calls" ] || fail "a forge was read without config"
  pass "with no config/unowned-work no forge is read"
}

test_paused_work_on_the_captain() {
  new_home
  printf 'project=/repos/bearings\n' > "$H/state/p1.meta"
  printf 'working [at=1]: go\npaused [at=2]: needs the captain'"'"'s word on https://x.test/doc.\n' > "$H/state/p1.status"
  state_of p1 paused
  printf 'project=/repos/q\n' > "$H/state/p2.meta"
  printf 'paused [at=2]: waiting on CI; no captain call needed\n' > "$H/state/p2.status"
  state_of p2 paused
  printf 'project=/repos/q\n' > "$H/state/p3.meta"
  printf 'paused [at=2]: waiting on the captain\n' > "$H/state/p3.status"
  state_of p3 working
  local out
  out=$(run)
  assert_equals "paused bearings p1 https://x.test/doc p1+paused on you, no card" \
    "$(jq -r '.findings[] | "\(.kind) \(.repo) \(.ref) \(.url) \(.key)"' <<<"$out")" "paused finding"
  printf '{"calls":[],"skipped":[{"task":"other","question":"see https://x.test/doc"}]}\n' > "$S/calls.json"
  assert_equals "" "$(reasons)" "a card naming its link covers it"
  printf '{"calls":[{"task":"p1"}],"skipped":[]}\n' > "$S/calls.json"
  assert_equals "" "$(reasons)" "a card on the task covers it"
  pass "work paused on the captain with no card is a finding; other pauses are not"
}

test_check_prints_each_key_once_and_keeps_since() {
  new_home
  mr 126 aegis
  local out
  out=$(run --check)
  assert_equals "unowned-work: aegis !126: Draft, no task, no worker and no card  $GL/aegis/-/merge_requests/126" \
    "$out" "first check announces"
  out=$(RUN_NOW=$((NOW + 300)) run --check)
  assert_equals "" "$out" "second check is silent"
  assert_equals "$NOW $((NOW + 300))" "$(jq -r '"\(.findings[0].since) \(.checked_at)"' "$H/state/unowned-work.json")" "since kept"
  : > "$S/nodes"
  run --check >/dev/null
  mr 126 aegis
  assert_contains "$(run --check)" "aegis !126" "a key that left and came back is announced again"
  pass "--check prints each new key once and since survives sweeps"
}

test_failed_read() {
  new_home
  mr 126 aegis
  run >/dev/null
  local before
  before=$(jq -c .findings "$H/state/unowned-work.json")
  touch "$S/glab-fail"
  local t1=$((NOW + 300)) out
  out=$(RUN_NOW=$t1 run --check)
  assert_equals "" "$out" "first failure is silent"
  assert_equals "$NOW $t1 1 $before" \
    "$(jq -c -r '"\(.checked_at) \(.read_failed_at) \(.failed_sweeps) \(.findings | tojson)"' "$H/state/unowned-work.json")" \
    "failure keeps findings and checked_at"
  assert_equals "" "$(RUN_NOW=$((t1 + 300)) run --check)" "second failure is silent"
  rm "$S/glab-fail"
  touch "$S/calls-fail"
  out=$(RUN_NOW=$((t1 + 600)) run --check)
  assert_equals "unowned-work: forge unreadable since $(date -u -d "@$t1" +%H:%MZ 2>/dev/null || date -u -r "$t1" +%H:%MZ)" \
    "$out" "third failure in a row announces once"
  assert_equals "" "$(RUN_NOW=$((t1 + 900)) run --check)" "fourth failure is silent"
  assert_equals 4 "$(jq .failed_sweeps "$H/state/unowned-work.json")" "failures counted"
  rm "$S/calls-fail"
  RUN_NOW=$((t1 + 1200)) run --check >/dev/null
  assert_equals "null 0 $((t1 + 1200))" \
    "$(jq -r '"\(.read_failed_at) \(.failed_sweeps) \(.checked_at)"' "$H/state/unowned-work.json")" "success resets"
  printf 'oops' > "$S/forgejo.json"
  RUN_NOW=$((t1 + 1500)) run >/dev/null
  assert_equals 1 "$(jq .failed_sweeps "$H/state/unowned-work.json")" "an unparseable forge answer is a failed read"
  pass "a failed forge or card read keeps the last findings and announces on the third failure"
}

test_print_check_and_usage() {
  local out code
  out=$("$SCRIPT" --print-check)
  assert_equals 3 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "three lines"
  assert_contains "$out" "fm-unowned-work.sh --check" "runs the check mode"
  "$SCRIPT" --bogus >/dev/null 2>&1; code=$?
  expect_code 2 "$code" "unknown option"
  assert_contains "$("$SCRIPT" --help)" "Usage: fm-unowned-work.sh" "help"
  pass "--print-check prints the 3-line check; unknown options exit 2"
}

fm_test_run \
  test_mr_126_with_no_task_is_a_finding \
  test_mr_900_task_done_still_draft_is_a_finding \
  test_each_owner_rule_owns_a_working_draft \
  test_owner_in_a_secondmate_home \
  test_false_positive_rows \
  test_card_by_task_covers_done_owner \
  test_grace_is_30_minutes \
  test_cap_of_5_without_prototypes \
  test_prototype_draft_is_named \
  test_forgejo_drafts \
  test_no_config_reads_no_forge \
  test_paused_work_on_the_captain \
  test_check_prints_each_key_once_and_keeps_since \
  test_failed_read \
  test_print_check_and_usage
