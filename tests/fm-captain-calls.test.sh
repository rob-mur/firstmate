#!/usr/bin/env bash
# Behavior tests for bin/fm-captain-calls.sh: every open captain call of a home
# comes from one model - main-backlog captain holds plus open needs-decision
# keys in each registered secondmate's parent status log. A call leaves the
# model only on an explicit act: the captain's answer or release, a deferral
# date, or the mate resolving that exact key. Each call is a decision or not
# (a merge ask or review hand-off is not). A settled non-decision - its linked
# PRs/MRs all finished, or the captain already answered it - leaves the calls for
# the to_close list with its evidence; a decision stays a call.
# The fixture mirrors the nine calls the live board misfiled on 2026-11-18:
# main holds fos-merge-19-18-13 and aegis-880-comments, and secondmate keys
# cd-870-version-file, captain-hold-cd-810-infra-home-1,
# captain-hold-cd-882-name-1, captain-hold-cd-882-mr-run-1,
# captain-hold-cd-915-stable-lag-1, captain-hold-gke-cp-lockdown-rollout-1 and
# captain-hold-runner-fuse-rollout-1. It also holds a question from one of main's
# own workers, like bcr-dec10-grill's grill-bcr-r4 (APP-3655) that the model
# missed, and checks that a work-project call is shown at any time of day.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-captain-calls)
TASKS_AXI_BIN=$(command -v tasks-axi)
CALLS="$ROOT/bin/fm-captain-calls.sh"

ANSWER_AT=2026-07-14T12:00:00Z
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
ANSWER_EPOCH=$(fm_utc_iso_to_epoch "$ANSWER_AT")
BEFORE=$((ANSWER_EPOCH - 3600))
LATER=$((ANSWER_EPOCH + 3600))

FOS=https://forgejo.example/rob/fos-rulings-research/pulls
AEGIS_MR=https://gitlab.example/app/aegis/-/merge_requests/880
CD_PR=https://forgejo.example/rob/continuous-delivery/pulls/885
CD_MERGE_PR=https://forgejo.example/rob/continuous-delivery/pulls/940

in_home() {  # <home> <command args...>
  local home=$1
  shift
  REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$@"
}

hold() {  # <home> <task-id> <hold args...>
  local home=$1 id=$2
  shift 2
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id" "$@" >/dev/null \
    || fail "could not hold $id"
}

answer() {  # <home> <task-id> [--release]
  local home=$1 id=$2
  shift 2
  printf 'Done with it.\n' > "$home/decision-$id.txt"
  FM_CAPTAIN_HOLD_NOW=$ANSWER_AT in_home "$home" "$ROOT/bin/fm-captain-hold.sh" \
    answer "$id" --decision-file "$home/decision-$id.txt" "$@" >/dev/null \
    || fail "could not answer $id"
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

# The shared fixture: built once, read by most tests.
FIXTURE=
fixture() {
  local home
  [ -z "$FIXTURE" ] || { printf '%s\n' "$FIXTURE"; return 0; }
  home=$(make_home shared)

  # Main holds.
  hold "$home" fos-merge-19-18-13 --title "Merge fos-rulings-research PRs 19, 18 and 13" \
    --repo fos-rulings-research \
    --reason "Merge these green fos-rulings-research PRs in order: PR 19 $FOS/19, then PR 18 $FOS/18, then PR 13 $FOS/13?" \
    --option "all-three=Merge 19, 18 and 13" --option "none=Merge none for now" \
    --link "$FOS/19 PR 19" --link "$FOS/18 PR 18" --link "$FOS/13 PR 13"
  hold "$home" aegis-880-held --title "Pick which held MR 880 review comments to post" --repo aegis \
    --reason "Which held review comments on MR 880 ($AEGIS_MR) should be posted?" --free-text
  hold "$home" aegis-880-comments --title "Pick which held MR 880 review comments to post" --repo aegis \
    --reason "Which held review comments on MR 880 ($AEGIS_MR) should be posted?" --free-text
  answer "$home" aegis-880-comments
  hold "$home" released-call --title "A call the captain let go" --reason "Keep this?" --free-text
  answer "$home" released-call --release
  hold "$home" deferred-call --title "Revisit later" --reason "Revisit the pricing?" --until 2099-01-01
  hold "$home" plain-call --title "A plain question" --reason "Ship the plain thing?" \
    --option "yes=Yes" --option "no=No"
  # A captain answer to the secondmate key cd-911-answered (the hold id is the key).
  hold "$home" cd-911-answered --title "Answered from the board" --reason "Pick one?" \
    --origin cd --free-text
  answer "$home" cd-911-answered
  # A captain answer to the secondmate key cd-912-merge, a merge ask.
  hold "$home" cd-912-merge --title "Merge from the board" --reason "Merge PR 912?" \
    --origin cd --free-text
  answer "$home" cd-912-merge

  # Secondmate registry: two local mates, one remote mate, one with no status log.
  {
    printf -- '- cd - continuous delivery (home: %s/cd-home; scope: cd work; projects: cd; added 2026-11-01)\n' "$home"
    printf -- '- runner-image - runner images (home: %s/ri-home; scope: runner work; projects: ri; added 2026-11-01)\n' "$home"
    printf -- '- far - remote work (host: far.example; root: /srv/fm; home: /srv/fm/far; scope: far work; projects: far; added 2026-11-01)\n'
    printf -- '- quiet - no log yet (home: %s/quiet-home; scope: quiet work; projects: q; added 2026-11-01)\n' "$home"
  } > "$home/data/secondmates.md"

  # cd's parent status log, shaped like main's real state/cd.status.
  cat > "$home/state/cd.status" <<EOF
needs-decision [key=cd-870-version-file] [at=$BEFORE]: Where should a release write the version, (a) cd-pipeline/version or (b) VERSION? PR $CD_PR
needs-decision [key=cd-870-release-mr] [at=$BEFORE]: Run the release MR job?
resolved [key=cd-870-release-mr] [at=$LATER]: covered by cd-870-version-file
needs-decision [key=captain-hold-cd-810-infra-home-1] [at=$BEFORE]: captain hold cd-810-infra-home: Do you accept the six recommendations for issue 810?
needs-decision [key=cd-810-infra-home] [at=$BEFORE]: duplicate card for cd-810-infra-home
resolved [key=cd-810-infra-home] [at=$LATER]: duplicate of captain-hold-cd-810-infra-home-1; keep the captain hold only
needs-decision [key=captain-hold-cd-882-name-1] [at=$BEFORE]: captain hold cd-882-name: What should the new coverage script be called?
needs-decision [key=captain-hold-cd-882-mr-run-1] [at=$BEFORE]: captain hold cd-882-mr-run: When an adopter turns on the coverage run, should it replace the plain scenario run in the merge request?
resolved [key=cd-882-decisions] [at=$LATER]: replaced by two captain cards, cd-882-name and cd-882-mr-run
reply [corr=8ec61280a4835c50] [at=$LATER]: re-held. cd-882-name and cd-882-mr-run both wait on the captain
needs-decision [key=captain-hold-cd-915-stable-lag-1] [at=$BEFORE]: captain hold cd-915-stable-lag: How far may stable lag behind main?
needs-decision [key=captain-hold-cd-930-done-1] [at=$BEFORE]: captain hold cd-930-done: Settled by the mate itself?
resolved [key=captain-hold-cd-930-done-1] [at=$LATER]: the captain answered in chat; closing this exact key
needs-decision [key=cd-911-answered] [at=$BEFORE]: Pick one?
needs-decision [key=cd-912-merge] [at=$BEFORE]: Merge PR 912?
needs-decision [key=cd-940-merge] [at=$BEFORE]: PR $CD_MERGE_PR is green. Merge it?
needs-decision [key=captain-hold-cd-950-later-1] [at=$BEFORE]: captain hold cd-950-later: Revisit the stable branch later?
EOF

  # cd's own backlog defers its cd-950-later hold to a future date.
  mkdir -p "$home/cd-home/data"
  printf '## Queued\n\n- [ ] cd-950-later - Revisit the stable branch (hold: revisit later) (hold-kind: captain) (hold-until: 2099-01-01)\n\n## Done\n' \
    > "$home/cd-home/data/backlog.md"

  # runner-image's parent status log: a duplicate plain key resolved by the mate.
  cat > "$home/state/runner-image.status" <<EOF
needs-decision [key=captain-hold-gke-cp-lockdown-rollout-1] [at=$BEFORE]: captain hold gke-cp-lockdown-rollout: Roll out the control-plane lockdown?
needs-decision [key=captain-hold-gke-cp-lockdown-rollout-1] [at=$LATER]: captain hold gke-cp-lockdown-rollout: Reach the control plane only over Tailscale?
needs-decision [corr=e5939cd6ca5294b6] [at=$LATER]: [key=gke-cp-lockdown-rollout] Tailscale-only rework done.
needs-decision [key=captain-hold-runner-fuse-rollout-1] [at=$LATER]: captain hold runner-fuse-rollout: How should runner job pods get FUSE?
needs-decision [corr=6e7f621d04e20555] [at=$LATER]: [key=runner-fuse-rollout] FUSE for runner jobs needs more than /dev/fuse.
resolved [corr=1b2a95cd9375d31e] [at=$LATER]: [key=gke-cp-lockdown-rollout] Duplicate of the captain card for the same task; one question, one card.
resolved [corr=6e7f621d04e20555] [at=$LATER]: [key=runner-fuse-rollout] Duplicate of the captain card runner-fuse-rollout.
EOF

  # Main's own workers: a live task (it has a .meta record) with an open
  # question on a YouTrack issue, a live personal task, and a finished task
  # whose log stays behind with no record.
  cat > "$home/state/bcr-grill.status" <<EOF
needs-decision [key=bcr-close-5860] [at=$BEFORE]: May I close APP-5860?
resolved [key=bcr-close-5860] [at=$LATER]: APP-5860 closed
needs-decision [key=grill-bcr-r4] [at=$LATER]: Should the engine get its own tickets, since no subtask of APP-3655 owns it?
paused [key=grill-bcr-r4] [at=$LATER]: waiting for the captain's answer
EOF
  : > "$home/state/bcr-grill.meta"
  printf 'needs-decision [key=name-pick] [at=%s]: Which name for the mount helper?\n' "$LATER" \
    > "$home/state/home-task.status"
  : > "$home/state/home-task.meta"
  printf 'needs-decision [key=old-ask] [at=%s]: An old question?\n' "$BEFORE" > "$home/state/old-task.status"

  # A remote mate's status reaches the same parent log.
  printf 'needs-decision [key=captain-hold-far-plan-1] [at=%s]: captain hold far-plan: Which plan?\n' \
    "$BEFORE" > "$home/state/far.status"

  # Housekeeping steers from main that name the calls: they hand nothing off.
  mkdir -p "$home/state/cd.inbox" "$home/state/runner-image.inbox"
  printf 'Close the duplicate card for captain-hold-cd-810-infra-home-1; keep the captain hold only.\n' \
    > "$home/state/cd.inbox/352.msg"
  printf 'Close the old duplicate keys cd-882-name and cd-882-mr-run. Re-raise cd-915-stable-lag. Resolve cd-870-release-mr as covered by cd-870-version-file.\n' \
    > "$home/state/cd.inbox/363.msg"
  printf 'Duplicate-card cleanup for captain-hold-gke-cp-lockdown-rollout-1: keep the captain hold.\n' \
    > "$home/state/runner-image.inbox/009.msg"

  # Recorded PR/MR states used instead of live lookups.
  printf '%s\tmerged\n%s\tmerged\n%s\tmerged\n%s\topen\n%s\tclosed\n' \
    "$FOS/19" "$FOS/18" "$FOS/13" "$CD_PR" "$CD_MERGE_PR" > "$home/prs-fos-merged.tsv"
  printf '%s\tmerged\n%s\topen\n%s\tmerged\n%s\topen\n' "$FOS/19" "$FOS/18" "$FOS/13" "$CD_PR" \
    > "$home/prs-fos-one-open.tsv"
  printf '%s\tmerged\n' "$AEGIS_MR" > "$home/prs-aegis-merged.tsv"
  FIXTURE=$home
  printf '%s\n' "$home"
}

run_calls() {  # <home> <pr-states-file or "off">  -> JSON on stdout
  local home=$1 prs=$2
  if [ "$prs" = off ]; then
    FM_CAPTAIN_CALLS_PR_CHECK=0 in_home "$home" "$CALLS"
  else
    FM_CAPTAIN_CALLS_PR_STATES="$prs" in_home "$home" "$CALLS"
  fi
}

where() {  # <json> <key>  -> calls, to_close, skipped or absent
  printf '%s\n' "$1" | jq -r --arg k "$2" '
    if any(.calls[]; .key == $k) then "calls"
    elif any(.to_close[]; .key == $k) then "to_close"
    elif any(.skipped[]; .key == $k) then "skipped"
    else "absent" end'
}

expect_where() {  # <json> <key> <want> <message>
  local got
  got=$(where "$1" "$2")
  [ "$got" = "$3" ] || fail "$4: $2 is in $got, expected $3"
}

FIXTURE=$(fixture)

test_settled_merge_ask_goes_to_close_not_calls() {
  local out card
  out=$(run_calls "$FIXTURE" "$FIXTURE/prs-fos-merged.tsv") || fail "fm-captain-calls failed"
  expect_where "$out" fos-merge-19-18-13 to_close "a held merge ask whose PRs all merged"
  card=$(printf '%s\n' "$out" | jq -c '.to_close[] | select(.key == "fos-merge-19-18-13")')
  assert_equals false "$(printf '%s\n' "$card" | jq '.decision')" "a merge ask is not a decision"
  assert_equals "every linked PR/MR merged or closed" "$(printf '%s\n' "$card" | jq -r '.evidence.settled_by')" \
    "the evidence says what settled it"
  assert_equals "$FOS/13 merged,$FOS/18 merged,$FOS/19 merged" \
    "$(printf '%s\n' "$card" | jq -r '[.evidence.prs[] | "\(.url) \(.state)"] | join(",")')" \
    "the evidence lists every linked PR with its state"
  assert_contains "$(printf '%s\n' "$card" | jq -r '.evidence.text')" "$FOS/19 merged" "the evidence text names the URL"
  assert_contains "$(printf '%s\n' "$card" | jq -r '.close_with')" \
    "bin/fm-captain-hold.sh reconcile close fos-merge-19-18-13 --evidence-file" "it says how main closes it"
  assert_equals "all-three,none" "$(printf '%s\n' "$card" | jq -r '[.options[].value] | join(",")')" \
    "the entry keeps the hold's options"
  assert_equals "PR 13,PR 18,PR 19" "$(printf '%s\n' "$card" | jq -r '[.links[].label] | join(",")')" \
    "the entry keeps the hold's labelled links once each"
  pass "fos-merge-19-18-13: a settled merge ask is in to_close with its evidence, not in calls"
}

test_settled_secondmate_merge_ask_goes_to_close() {
  local out
  out=$(run_calls "$FIXTURE" "$FIXTURE/prs-fos-merged.tsv") || fail "fm-captain-calls failed"
  expect_where "$out" cd.cd-940-merge to_close "a mate's merge ask whose PR closed"
  assert_equals "ask cd to resolve [key=cd-940-merge] with evidence.text" \
    "$(printf '%s\n' "$out" | jq -r '.to_close[] | select(.key == "cd.cd-940-merge") | .close_with')" \
    "a mate's key closes through the mate"
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  expect_where "$out" cd.cd-940-merge calls "a mate's merge ask with PR lookups off"
  pass "a mate's settled merge ask is in to_close; unsettled it stays a call"
}

test_answered_non_decision_goes_to_close() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  expect_where "$out" cd.cd-912-merge to_close "a merge ask the captain answered"
  assert_equals "answered by the captain in cd-912-merge" \
    "$(printf '%s\n' "$out" | jq -r '.to_close[] | select(.key == "cd.cd-912-merge") | .evidence.settled_by')" \
    "the evidence names the answer"
  pass "a non-decision the captain already answered is in to_close, not skipped or calls"
}

test_held_merge_ask_with_an_open_pr_stays_a_call() {
  local out
  out=$(run_calls "$FIXTURE" "$FIXTURE/prs-fos-one-open.tsv") || fail "fm-captain-calls failed"
  expect_where "$out" fos-merge-19-18-13 calls "a held merge ask with one PR still open"
  pass "a held merge ask with any PR still open stays a call"
}

test_open_decision_stays_a_call_after_its_mr_merges() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  expect_where "$out" aegis-880-held calls "a held question naming a merge_requests URL"
  assert_equals true "$(printf '%s\n' "$out" | jq '.calls[] | select(.key == "aegis-880-held") | .decision')" \
    "a merge_requests URL does not make a merge ask"
  out=$(run_calls "$FIXTURE" "$FIXTURE/prs-aegis-merged.tsv") || fail "fm-captain-calls failed"
  expect_where "$out" aegis-880-held calls "an open decision whose linked MR merged"
  pass "aegis-880 (held): an open decision stays a call, even after its MR merges"
}

test_merge_request_noun_is_not_a_merge_ask() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  assert_equals true "$(printf '%s\n' "$out" | jq '.calls[] | select(.key == "cd.captain-hold-cd-882-mr-run-1") | .decision')" \
    "a question about what runs in the merge request is a decision"
  pass "cd-882-mr-run: the noun 'merge request' does not make a merge ask"
}

test_answered_hold_is_dropped() {
  local out
  out=$(run_calls "$FIXTURE" "$FIXTURE/prs-aegis-merged.tsv") || fail "fm-captain-calls failed"
  expect_where "$out" aegis-880-comments absent "a hold the captain answered"
  pass "aegis-880-comments (answered): an answered hold is not a call"
}

test_released_hold_is_dropped() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  expect_where "$out" released-call absent "a hold the captain released"
  pass "a released hold is not a call"
}

test_deferred_hold_is_skipped_until_its_date() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  expect_where "$out" deferred-call skipped "a hold deferred to a future date"
  assert_contains "$(printf '%s\n' "$out" | jq -r '.skipped[] | select(.key == "deferred-call") | .why')" \
    "deferred until 2099-01-01" "the skip names the date"
  pass "a hold deferred to a future date is skipped with its date"
}

test_deferred_secondmate_hold_is_skipped_until_its_date() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  expect_where "$out" cd.captain-hold-cd-950-later-1 skipped "a secondmate hold deferred to a future date"
  assert_equals "cd|cd-950-later|deferred until 2099-01-01" \
    "$(printf '%s\n' "$out" | jq -r '.skipped[] | select(.key == "cd.captain-hold-cd-950-later-1") | "\(.home)|\(.task)|\(.why)"')" \
    "the skip names the mate, task and date"
  pass "a secondmate hold deferred in the mate's backlog is skipped with its date"
}

test_plain_hold_is_a_call_with_its_options() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  expect_where "$out" plain-call calls "a plain held question"
  assert_equals true "$(printf '%s\n' "$out" | jq '.calls[] | select(.key == "plain-call") | .decision')" \
    "a plain question is a decision"
  assert_equals "main-hold|Ship the plain thing?|yes=Yes,no=No" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "plain-call") | "\(.source)|\(.question)|\([.options[] | "\(.value)=\(.label)"] | join(","))"')" \
    "the call carries its source, decoded question and options"
  pass "a plain held question is a call with its question and options"
}

# A task re-held after released holds keeps every earlier hold's option and
# link lines in its backlog body, as wp-results-persist did on 2026-11-23: its
# card showed the earlier holds' options after the current ones and PR 78 twice.
test_a_re_held_task_shows_only_its_current_options() {
  local home out pr=https://forgejo.example/rob/workload-pruner/pulls/78
  home=$(make_home re-held)
  hold "$home" wp-results-persist --title "Save stage results outside the runner cache" \
    --reason "How should the GPU measurement job log in to the new private results bucket?" \
    --option "a=New workload-identity pool that admits only main runs; no stored key (recommended)" \
    --option "b=Dedicated service-account key in a new forge secret" \
    --option "c=Give the existing registry writer access to the bucket" \
    --link "https://forgejo.example/rob/workload-pruner/issues/77 Storage survey and options"
  answer "$home" wp-results-persist --release
  hold "$home" wp-results-persist \
    --reason "Will you apply the new results bucket before I merge PR 78?" \
    --option "a=Applied it; merge PR 78 when its checks pass" \
    --option "b=Merge PR 78 when its checks pass; I will apply it later" \
    --link "$pr PR 78 (infra/README.md has the apply steps)"
  answer "$home" wp-results-persist --release
  hold "$home" wp-results-persist \
    --reason "May a project admin apply infra/identity in PR 78 once, so that CI can create the results bucket?" \
    --option "a=Yes: an admin applies infra/identity once; CI then creates the bucket" \
    --option "b=No project-wide create: an admin creates the bucket once in infra/identity too" \
    --free-text --link "$pr PR 78 (infra/README.md explains both roots)"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  expect_where "$out" wp-results-persist calls "a re-held question"
  assert_equals "a,b" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "wp-results-persist") | [.options[].value] | join(",")')" \
    "the call carries only the current hold's options"
  assert_equals "No project-wide create: an admin creates the bucket once in infra/identity too" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "wp-results-persist") | .options[1].label')" \
    "the options are the current hold's, not an earlier hold's"
  assert_equals "$pr|PR 78 (infra/README.md explains both roots)" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "wp-results-persist") | .links[] | "\(.url)|\(.label)"')" \
    "the call links PR 78 once, with the current hold's label, and no earlier hold's link"
  pass "a re-held task shows only its current hold's options and links"
}

test_a_worker_key_on_a_held_task_is_not_a_second_call() {
  local home out
  home=$(make_home held-task)
  hold "$home" aegis-821-review --title "Pick which MR 821 review comments to post" --repo aegis \
    --reason "Which held review comments on MR 821 should be posted?" --free-text
  printf 'needs-decision [key=mr821-comment-pick] [at=%s]: Which of the held MR 821 comments should be posted?\n' "$LATER" \
    > "$home/state/aegis-821-review.status"
  : > "$home/state/aegis-821-review.meta"
  printf 'needs-decision [key=mr822-pick] [at=%s]: Post the MR 822 comments now?\n' "$LATER" \
    > "$home/state/aegis-822-review.status"
  : > "$home/state/aegis-822-review.meta"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  expect_where "$out" aegis-821-review calls "the captain hold"
  expect_where "$out" aegis-821-review.mr821-comment-pick skipped "a worker key on the held task"
  assert_contains "$(printf '%s\n' "$out" | jq -r '.skipped[] | select(.key == "aegis-821-review.mr821-comment-pick") | .why')" \
    "is held for the captain" "the skip names the hold"
  expect_where "$out" aegis-822-review.mr822-pick calls "a worker key on a task with no hold"
  assert_equals "1" "$(printf '%s\n' "$out" | jq '[.calls[] | select(.task == "aegis-821-review")] | length')" \
    "the held task asks one call"
  pass "a worker key on a captain-held task is skipped, so the hold is the one call"
}

test_inline_lettered_options_leave_the_question() {
  local home out card mr=https://gitlab.example/app/aegis/-/merge_requests/848
  home=$(make_home inline-letters)
  printf 'needs-decision [key=default] [at=%s]: On aegis MR 848 (%s), the author fixed your comment-length and test-gap threads but has not replied to or changed anything for your same-tab early-navigation QA gap or your description-rewrite request, so should I a) draft follow-up replies on those two threads (plus the give-up behaviour question) for your approval before anything is posted, b) build the understand page anyway, or c) leave the MR as it is?\n' \
    "$LATER" "$mr" > "$home/state/aegis-848-recheck.status"
  : > "$home/state/aegis-848-recheck.meta"
  printf 'needs-decision [key=stray] [at=%s]: Should I keep note a) as it is?\n' "$LATER" > "$home/state/stray-task.status"
  : > "$home/state/stray-task.meta"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  card=$(printf '%s\n' "$out" | jq -c '.calls[] | select(.key == "aegis-848-recheck.default")')
  [ -n "$card" ] || fail "the 848 worker question is not a call"
  assert_equals "On aegis MR 848 ($mr), the author fixed your comment-length and test-gap threads but has not replied to or changed anything for your same-tab early-navigation QA gap or your description-rewrite request, so should I?" \
    "$(printf '%s\n' "$card" | jq -r '.question')" "the question is its lead up to the options, ending in ?"
  assert_equals "a|Draft follow-up replies on those two threads (plus the give-up behaviour question) for your approval before anything is posted,b|Build the understand page anyway,c|Leave the MR as it is" \
    "$(printf '%s\n' "$card" | jq -r '[.options[] | "\(.value)|\(.label)"] | join(",")')" \
    "the inline a), b), c) are the call's options"
  assert_equals "Should I keep note a) as it is?|0" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "stray-task.stray") | "\(.question)|\(.options | length)"')" \
    "a lone a) in a sentence is not an option list"
  pass "a question's inline a), b), c) become its options and leave the question"
}

# A second mate with one registered local home, for the mate call tests below.
make_mate_home() {  # <name>
  local home
  home=$(make_home "$1")
  printf -- '- mm - mate work (home: %s/mm-home; scope: mate work; projects: m; added 2026-11-01)\n' "$home" \
    > "$home/data/secondmates.md"
  mkdir -p "$home/mm-home/data"
  printf '## Queued\n\n## Done\n' > "$home/mm-home/data/backlog.md"
  printf '%s\n' "$home"
}

test_mate_inline_recommended_option_is_the_recommend() {
  local home out
  home=$(make_mate_home mate-inline-recommend)
  printf 'needs-decision [key=captain-hold-t1-1] [at=%s]: captain hold t1: Pick a) one (recommended) b) two?\n' \
    "$LATER" > "$home/state/mm.status"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  assert_equals "a|a=one,b=two" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "mm.captain-hold-t1-1") | "\(.recommend)|\([.options[] | "\(.value)=\(.label)"] | join(","))"')" \
    "the option marked (recommended) is the recommend and the marker leaves its label"
  pass "a mate question's inline (recommended) option is its recommend"
}

test_mate_keyless_line_does_not_shadow_a_keyed_call() {
  local home out
  home=$(make_mate_home mate-keyless)
  {
    printf 'needs-decision [key=captain-hold-t1-1] [at=%s]: captain hold t1: Pick a) one b) two?\n' "$BEFORE"
    printf 'needs-decision [at=%s]: captain hold t1: Pick a) one b) two?\n' "$LATER"
  } > "$home/state/mm.status"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  expect_where "$out" mm.captain-hold-t1-1 calls "the keyed mate call"
  expect_where "$out" mm.default skipped "a keyless repeat of the keyed mate call"

  home=$(make_mate_home mate-keyless-own)
  {
    printf 'needs-decision [key=captain-hold-t1-1] [at=%s]: captain hold t1: Pick a) one b) two?\n' "$BEFORE"
    printf 'needs-decision [at=%s]: Should the mate rotate its runner token?\n' "$LATER"
  } > "$home/state/mm.status"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  expect_where "$out" mm.captain-hold-t1-1 calls "the keyed mate call"
  expect_where "$out" mm.default calls "a keyless mate call of its own"
  pass "a keyless mate line never drops the mate's keyed call, and an own keyless call stays"
}

where_firstmate() {  # <json> <key>  -> the corr of a with_firstmate[] entry, or "absent"
  printf '%s\n' "$1" | jq -r --arg k "$2" '([.with_firstmate[]? | select(.key == $k) | .corr][0]) // "absent"'
}

# The runner-image mate replied to a marked request from main with a keyless
# "needs-decision [corr=419fc60d0fbfec7c]" line and held its task with a reason
# that waits on main's answer to that request. The board showed both as cards
# for the captain; both are firstmate's.
RI_CORR=419fc60d0fbfec7c
test_mate_corr_reply_is_with_firstmate_not_a_call() {
  local home out
  home=$(make_mate_home mate-corr-reply)
  printf 'needs-decision [corr=%s] [at=%s]: Store collector cold-store fallback scoped, nothing changed on the cluster. Recommend option A. Details and options: /srv/mm/data/gc/report.md (via-helper)\n' \
    "$RI_CORR" "$LATER" > "$home/state/mm.status"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  expect_where "$out" mm.default absent "a mate reply to a marked request from main"
  assert_equals "$RI_CORR" "$(where_firstmate "$out" mm.default)" "the reply is with firstmate, with its corr"

  # The bare token and the older note-head shape are replies too.
  printf 'needs-decision corr=%s [at=%s]: Which window?\nneeds-decision [key=gc-window] [at=%s]: corr=%s Which window, again?\n' \
    "$RI_CORR" "$LATER" "$LATER" "$RI_CORR" > "$home/state/mm.status"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  expect_where "$out" mm.default absent "a bare corr reply"
  expect_where "$out" mm.gc-window absent "a note-head corr reply"
  assert_equals "$RI_CORR,$RI_CORR" \
    "$(where_firstmate "$out" mm.default),$(where_firstmate "$out" mm.gc-window)" "both replies are with firstmate"
  pass "a mate needs-decision that answers a marked request (corr) is with firstmate, not a captain call"
}

test_mate_hold_waiting_on_main_is_with_firstmate() {
  local home out reason
  reason="Waiting for the main firstmate to approve option A and its live rollout (corr=$RI_CORR)"
  # A local mate: its backlog row holds the full reason.
  home=$(make_mate_home mate-hold-on-main)
  printf 'needs-decision [key=captain-hold-gc-quiet-1] [at=%s]: captain hold gc-quiet: %s\n' \
    "$LATER" "$reason" > "$home/state/mm.status"
  printf '## Queued\n\n- [ ] gc-quiet - Collect at a quiet hour (hold: %s) (hold-kind: captain)\n\n## Done\n' \
    "$reason" > "$home/mm-home/data/backlog.md"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  expect_where "$out" mm.captain-hold-gc-quiet-1 absent "a mate hold waiting on main"
  assert_equals "$RI_CORR" "$(where_firstmate "$out" mm.captain-hold-gc-quiet-1)" "the hold is with firstmate"
  assert_equals "gc-quiet" \
    "$(printf '%s\n' "$out" | jq -r '.with_firstmate[] | select(.key == "mm.captain-hold-gc-quiet-1") | .task')" \
    "the entry names the held task"

  # With no backlog row (a remote mate, or the row gone), the status line says it.
  printf '## Queued\n\n## Done\n' > "$home/mm-home/data/backlog.md"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  expect_where "$out" mm.captain-hold-gc-quiet-1 absent "a mate hold waiting on main, status line only"
  assert_equals "$RI_CORR" "$(where_firstmate "$out" mm.captain-hold-gc-quiet-1)" "the status-only hold is with firstmate"
  pass "a mate captain hold whose reason carries a corr token is with firstmate, not a captain call"
}

test_mate_captain_decisions_without_corr_stay_calls() {
  local home out
  home=$(make_mate_home mate-real-calls)
  {
    printf 'needs-decision [at=%s]: Should the mate rotate its runner token?\n' "$LATER"
    printf 'needs-decision [key=captain-hold-gc-pick-1] [at=%s]: captain hold gc-pick: Collect at 03:00 or 05:00?\n' "$LATER"
    printf 'needs-decision [key=cache-size] [at=%s]: Grow the cache, as corr=%s asked, or keep it?\n' "$LATER" "$RI_CORR"
  } > "$home/state/mm.status"
  printf '## Queued\n\n- [ ] gc-pick - Pick the hour (hold: Collect at 03:00 or 05:00?) (hold-kind: captain)\n\n## Done\n' \
    > "$home/mm-home/data/backlog.md"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  expect_where "$out" mm.default calls "a keyless mate question with no corr"
  expect_where "$out" mm.captain-hold-gc-pick-1 calls "a mate hold for the captain"
  expect_where "$out" mm.cache-size calls "a corr named in the question prose"
  assert_equals 0 "$(printf '%s\n' "$out" | jq '.with_firstmate | length')" "nothing is with firstmate"
  pass "mate needs-decision lines and holds with no corr reply marker stay captain calls"
}

test_mate_backlog_hold_options_are_the_call_options() {
  local home out
  home=$(make_mate_home mate-backlog-options)
  printf 'needs-decision [key=captain-hold-t2-1] [at=%s]: captain hold t2: Which way?\n' \
    "$LATER" > "$home/state/mm.status"
  printf '## Queued\n\n- [ ] t2 - Way (hold: which way) (hold-kind: captain)\n  Captain hold option: x=Go left (recommended)\n  Captain hold option: y=Go right\n\n## Done\n' \
    > "$home/mm-home/data/backlog.md"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  assert_equals "x|x=Go left,y=Go right" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "mm.captain-hold-t2-1") | "\(.recommend)|\([.options[] | "\(.value)=\(.label)"] | join(","))"')" \
    "the mate backlog's hold options are the call's options, with its recommend"
  pass "a mate backlog's Captain hold option lines are the call's options"
}

# The pdm-oss-open-source-call card showed "(a, recommended) Go: ...", "(b) Go,
# but ..." and "(c) Not now": each recorded label kept its letter tag.
test_mate_backlog_option_letter_tags_leave_the_labels() {
  local home out
  home=$(make_mate_home mate-backlog-letter-tags)
  printf 'needs-decision [key=captain-hold-t3-1] [at=%s]: captain hold t3: Open-source it?\n' \
    "$LATER" > "$home/state/mm.status"
  printf '## Queued\n\n- [ ] t3 - Open source (hold: open-source it) (hold-kind: captain)\n  Captain hold option: a=(a, recommended) Go: publish it now\n  Captain hold option: b=(b) Go, but after the audit\n  Captain hold option: c=(c) Not now\n\n## Done\n' \
    > "$home/mm-home/data/backlog.md"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  assert_equals "a|a=Go: publish it now,b=Go, but after the audit,c=Not now" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "mm.captain-hold-t3-1") | "\(.recommend)|\([.options[] | "\(.value)=\(.label)"] | join(","))"')" \
    "a leading (x) or (x, recommended) tag leaves each label, and the recommended one is the recommend"
  pass "a recorded option's leading letter tag leaves its label and keeps its recommendation"
}

# The cd-987-path-filter-calls card stopped mid-word at '"{src,envs}/**" are
# rej': the parent channel cuts a hold note to its bound with no marker, and the
# card took its question from that line. The row in the mate's backlog holds
# the full reason, so the card shows all five calls and the answer to the
# captain's enforcement question. The row names the design doc in each of its
# three paragraphs, and the reason links it too: the card links it once. With
# no row to read, a line as long as the bound is a call cut short.
CD987_DESIGN=https://forgejo.clarob.uk/rob/continuous-delivery/issues/987#issuecomment-35848
cd987_reason() {
  cat <<'CD987'
Path filter design (#987, design section 4): which answer do you choose for each of the five calls below? Answer with one line like "1a 2a 3a 4a 5a". Each example uses workload-pruner, whose slow GPU stage (non-functional-requirements, NFR) should skip on a docs-only push to main.
1. Option name for the files a stage depends on. Recommended: 1a.
 1a reads: in devenv.nix you write cd-pipeline.verbs.non-functional-requirements.reads = [ "src/**" "envs/**" "Cargo.lock" ]; a push that changes only README.md skips NFR; a push that changes src/main.rs runs it, and the run fails if NFR opened a file outside that list.
 1b paths: the same list, written ...non-functional-requirements.paths = [ ... ]; same behaviour, but people read it as a GitHub-style trigger and expect !negation to work.
 1c changedPaths: ...non-functional-requirements.changedPaths = [ ... ]; same behaviour, name describes the push, not the stage.
 1d runsWhenChanged: ...non-functional-requirements.runsWhenChanged = [ ... ]; same behaviour, reads as a rule rather than a list of files.
2. Glob syntax inside that list. Recommended: 2a.
 2a strict glob.rs: "src/**" and "envs/*.py" work; "!docs/**" and "{src,envs}/**" are rejected when devenv builds, so you write two entries instead.
 2b git pathspec: ":(glob)src/**" and ":(exclude)docs/**" work; every entry carries git's prefix syntax.
 2c GitHub/minimatch: "src/**", "!src/docs/**" and "{src,envs}/**" all work; once adopters use ! and braces we cannot remove them.
3. What the forge shows for NFR on a docs-only push. Recommended: 3a.
 3a forge skipped: the commit shows NFR as grey skipped; end-of-run prints "non-functional-requirements: skipped by path filter, base <sha>, 0 of 3 changed files matched" and stays green; a skip for any other reason (failed upstream) turns end-of-run red.
 3b no-op success: NFR shows a green tick although it judged nothing; release notes cannot tell it apart from a real pass.
 3c run and fail: NFR shows red on every docs-only push, so the filter is useless.
 3d extra status: NFR shows skipped plus a separate ci:nfr-skipped status; needs the pipeline to write to the forge, which #47 forbids today.
4. NFR opens a file the list leaves out, e.g. scripts/voxtype-request.sh when reads has only src/** and envs/**. Recommended: 4a.
 4a fail: that run goes red and names scripts/voxtype-request.sh; you add it to reads and push again. workload-pruner would go red on its first filtered run until it adds scripts/voxtype-request.sh, host/** and results/NOTES.md.
 4b warn first: that run stays green with a warning in the log; a later release turns the warning red, which breaks adopters who ignored it.
5. Input name in the shared main workflow (generated for you; you only see it if you read the workflow). Recommended: 5a.
 5a <job>-reads: the generated caller passes non-functional-requirements-reads: '["src/**","envs/**"]', next to the existing non-functional-requirements-runs-on.
 5b one JSON input: the caller passes path-filters: '{"non-functional-requirements":["src/**","envs/**"]}' covering every job.
Your question: how is "the run fails if NFR opened a file outside that list" enforced?
 What observes the files: on every run of NFR that is not skipped, the pipeline's own NFR job starts a file-open tracer (inotify IN_OPEN watching the whole checkout, recursively) before the stage command runs, and stops it after. The adopter writes nothing for this.
 Where the check runs: in that same NFR job on the GPU runner, as a step after the stage command. It keeps only files git tracks (git ls-files), drops .git/, .ci/ and .devenv/, then checks each one against the reads list plus the pipeline's fixed always-run set (devenv.nix and the pipeline's own files).
 What the failure looks like: the NFR job goes red with a line like "non-functional-requirements read scripts/voxtype-request.sh, which is not in cd-pipeline.verbs.non-functional-requirements.reads; add it or a glob that covers it". The run never marks the commit releasable. If the tracer cannot start or drops events (inotify queue overflow), the job also goes red; it never passes unchecked.
 Why a skip is safe: any change to the reads list changes devenv.nix, so that push always runs NFR under the tracer. After that, NFR can only start reading a new file because a file it already reads changed, and that change is in the list, so that run is traced too.
 Limits: reads that are not file opens inside the checkout (network, GPU driver, files outside the repo) are not seen; a scheduled unfiltered run and a manual run button cover those. Before building, a test run on the GPU host must confirm inotify sees reads through the sandbox bind mount (measurement M5). If it does not, the tracer becomes fanotify or strace; the check and the failure stay the same.
Design: https://forgejo.clarob.uk/rob/continuous-delivery/issues/987#issuecomment-35848
CD987
}

test_mate_long_hold_shows_its_full_text() {
  local home out card reason line
  # shellcheck source=bin/fm-hold-reason-lib.sh
  . "$ROOT/bin/fm-hold-reason-lib.sh"
  # shellcheck source=bin/fm-parent-channel-lib.sh
  . "$ROOT/bin/fm-parent-channel-lib.sh"
  reason=$(cd987_reason)
  line="needs-decision [key=captain-hold-cd-987-path-filter-calls-1] [at=$LATER]: captain hold cd-987-path-filter-calls: $(fm_parent_channel_clean_note "$reason")"
  case "$line" in *'"{src,envs}/**" are rej') ;; *) fail "the fixture line is not cut where the live line was" ;; esac

  home=$(make_mate_home mate-long-hold)
  printf '%s\n' "$line" > "$home/state/mm.status"
  {
    printf '## Queued\n\n'
    printf -- '- [ ] cd-987-path-filter-calls - #987 path filter design: five calls (repo: continuous-delivery) (kind: captain) (hold: %s) (hold-kind: captain)\n' \
      "$(fm_hold_reason_encode "$reason")"
    printf '  Captain hold set: 2026-11-24T13:03:31Z\n  Captain hold free text: yes\n  Captain hold link: %s design doc\n\n' "$CD987_DESIGN"
    printf '  Captain hold free text: yes\n  Captain hold link: %s design doc\n\n' "$CD987_DESIGN"
    printf '  Captain hold origin: cd-987-path-filter-design\n  Captain hold free text: yes\n  Captain hold link: %s design doc\n\n' "$CD987_DESIGN"
    printf '## Done\n'
  } > "$home/mm-home/data/backlog.md"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  card=$(printf '%s\n' "$out" | jq -c '.calls[] | select(.key == "mm.captain-hold-cd-987-path-filter-calls-1")')
  [ -n "$card" ] || fail "the cd-987 hold is not a call"
  assert_equals "$reason" "$(printf '%s\n' "$card" | jq -r '.question')" "the question is the row's full hold reason"
  assert_contains "$(printf '%s\n' "$card" | jq -r '.question')" ' 5b one JSON input: ' "call 5 is on the card"
  assert_contains "$(printf '%s\n' "$card" | jq -r '.question')" ' What observes the files: ' "the enforcement answer is on the card"
  assert_equals "$CD987_DESIGN|design doc" \
    "$(printf '%s\n' "$card" | jq -r '[.links[] | "\(.url)|\(.label)"] | join(",")')" \
    "the design doc is linked once, with its label"
  assert_equals false "$(printf '%s\n' "$card" | jq -r '.cut_short')" "a call read from its row is not cut short"

  home=$(make_mate_home mate-long-hold-no-row)
  {
    printf '%s\n' "$line"
    printf 'needs-decision [key=captain-hold-t5-1] [at=%s]: captain hold t5: Ship it?\n' "$LATER"
  } > "$home/state/mm.status"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  assert_equals true \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "mm.captain-hold-cd-987-path-filter-calls-1") | .cut_short')" \
    "a call known only from a line as long as the channel bound is cut short, and stays a call"
  assert_equals false \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "mm.captain-hold-t5-1") | .cut_short')" \
    "a short line is not cut short"
  pass "a mate hold card shows its full hold text and design link once; a cut line alone is cut short"
}

# The real cd-987-stage-calls holds of the cd secondmate home: first held at
# 13:33:15Z, re-held at 13:34:14Z with the question first. Each ends in an
# "Evidence: data/<task>/report.md" tail (a new line before it in the row), so
# each version of the call has that report, and the tail is never question text.
CD987_STAGE_EVIDENCE=data/cd-987-skippable-stages/report.md
CD987_STAGE_FIRST='Path filter for #987, four more calls: 6 which stages may skip (only NFR on main passes the analysis), 7 the format of the reads input in the generated workflow, 8 ship now on Forgejo 16 despite a known queue-stall report, 9 add nightly and manual unfiltered runs. Answer with one line like "6a 7a 8a 9a" (recommended all a). Options and the skip analysis for every pipeline part are in the report.'
CD987_STAGE_REHELD='Path filter (#987): which answer do you choose for each of calls 6 to 9? Answer with one line like "6a 7a 8a 9a" (recommended all a). 6 which stages may skip (only NFR on main passes the analysis), 7 the format of the reads input in the generated workflow, 8 ship now on Forgejo 16 despite a reported queue stall, 9 add nightly and manual unfiltered runs. Options and the skip analysis are in the report.'

test_mate_hold_evidence_tail_is_always_its_report() {
  local home out reason
  # shellcheck source=bin/fm-hold-reason-lib.sh
  . "$ROOT/bin/fm-hold-reason-lib.sh"
  home=$(make_mate_home mate-stage-first)
  printf 'needs-decision [key=captain-hold-cd-987-stage-calls-1] [at=%s]: captain hold cd-987-stage-calls: %s Evidence: %s\n' \
    "$LATER" "$CD987_STAGE_FIRST" "$CD987_STAGE_EVIDENCE" > "$home/state/mm.status"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  assert_equals "$CD987_STAGE_EVIDENCE|$CD987_STAGE_FIRST" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "mm.captain-hold-cd-987-stage-calls-1") | "\(.report)|\(.question)"')" \
    "the first hold, known from its line, has the report and no Evidence: text"

  home=$(make_mate_home mate-stage-reheld)
  reason=$(printf '%s\nEvidence: %s' "$CD987_STAGE_REHELD" "$CD987_STAGE_EVIDENCE")
  printf 'needs-decision [key=captain-hold-cd-987-stage-calls-1] [at=%s]: captain hold cd-987-stage-calls: %s Evidence: %s\n' \
    "$LATER" "$CD987_STAGE_REHELD" "$CD987_STAGE_EVIDENCE" > "$home/state/mm.status"
  {
    printf '## Queued\n\n'
    printf -- '- [ ] cd-987-stage-calls - #987 path filter: four more calls (answer like 6a 7a 8a 9a) (repo: continuous-delivery) (kind: captain) (hold: %s) (hold-kind: captain)\n' \
      "$(fm_hold_reason_encode "$reason")"
    printf '  Captain hold set: 2026-11-24T13:34:14Z\n  Captain hold origin: cd-987-skippable-stages\n  Captain hold free text: yes\n  Captain hold link: %s design doc\n\n' "$CD987_DESIGN"
    printf '## Done\n'
  } > "$home/mm-home/data/backlog.md"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  assert_equals "$CD987_STAGE_EVIDENCE|$CD987_STAGE_REHELD" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "mm.captain-hold-cd-987-stage-calls-1") | "\(.report)|\(.question)"')" \
    "the re-held call, read from its row, has the report and no Evidence: text"
  pass "a mate hold's Evidence: data/<task>/report.md tail is its report in every version"
}

# The pdm-oss-history-name card lost the instruction after its options and the
# "Evidence: <path>" tail that names its report.
test_mate_inline_options_keep_trailing_prose_and_evidence_report() {
  local home out card report=/home/m/data/pdm-oss-history-name/report.md
  home=$(make_mate_home mate-inline-tail)
  printf 'needs-decision [key=captain-hold-t4-1] [at=%s]: captain hold t4: Which name should the history page use? a) Chronicle b) Ledger c) Another name. Write the new name with your letter, with no Proton in it. Evidence: %s\n' \
    "$LATER" "$report" > "$home/state/mm.status"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  card=$(printf '%s\n' "$out" | jq -c '.calls[] | select(.key == "mm.captain-hold-t4-1")')
  [ -n "$card" ] || fail "the history-name question is not a call"
  assert_equals "Which name should the history page use? Write the new name with your letter, with no Proton in it." \
    "$(printf '%s\n' "$card" | jq -r '.question')" "the prose after the options stays on the question"
  assert_equals "a=Chronicle,b=Ledger,c=Another name" \
    "$(printf '%s\n' "$card" | jq -r '[.options[] | "\(.value)=\(.label)"] | join(",")')" \
    "the inline options are the call's options"
  assert_equals "$report" "$(printf '%s\n' "$card" | jq -r '.report')" \
    "the Evidence: path is the call's report"
  pass "a question's prose after its options stays, and its Evidence: path is its report"
}

test_evidence_report_needs_an_evidence_tail() {
  local home out
  home=$(make_mate_home mate-no-evidence)
  printf 'needs-decision [key=captain-hold-t5-1] [at=%s]: captain hold t5: Ship it? a) Yes b) No. The evidence is in /tmp/x.md for now.\n' \
    "$LATER" > "$home/state/mm.status"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  assert_equals "null|Ship it? The evidence is in /tmp/x.md for now." \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "mm.captain-hold-t5-1") | "\(.report)|\(.question)"')" \
    "a path not led by an Evidence: tail is no report"
  pass "only an Evidence: <path> tail names a report"
}

# The cd-forge-arm-login-access card showed "A: you make ...", "B: tea uses
# ..." and "C: keep ..." under values a, b and c: the letter showed twice.
test_mate_backlog_option_uppercase_letter_tags_leave_the_labels() {
  local home out
  home=$(make_mate_home mate-backlog-upper-tags)
  printf 'needs-decision [key=captain-hold-t5-1] [at=%s]: captain hold t5: How should tea reach new repos?\n' \
    "$LATER" > "$home/state/mm.status"
  printf '## Queued\n\n- [ ] t5 - Tea access (hold: how should tea reach new repos?) (hold-kind: captain)\n  Captain hold option: a=A: one unrestricted token (recommended)\n  Captain hold option: b=B: a rob-bot token\n  Captain hold option: c=C: remake a restricted token\n  Captain hold option: d=Dry run first\n\n## Done\n' \
    > "$home/mm-home/data/backlog.md"
  out=$(run_calls "$home" off) || fail "fm-captain-calls failed"
  assert_equals "a|a=one unrestricted token,b=a rob-bot token,c=remake a restricted token,d=Dry run first" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "mm.captain-hold-t5-1") | "\(.recommend)|\([.options[] | "\(.value)=\(.label)"] | join(","))"')" \
    "an uppercase tag of the option's own letter leaves each label"
  pass "a recorded option's uppercase letter tag leaves its label"
}

test_cd_calls_named_by_housekeeping_steers_stay_calls() {
  local out key
  out=$(run_calls "$FIXTURE" "$FIXTURE/prs-fos-merged.tsv") || fail "fm-captain-calls failed"
  for key in cd-870-version-file captain-hold-cd-810-infra-home-1 captain-hold-cd-882-name-1 \
    captain-hold-cd-882-mr-run-1 captain-hold-cd-915-stable-lag-1; do
    expect_where "$out" "cd.$key" calls "a cd call named by a steer or a related resolve"
  done
  pass "cd's five calls stay calls despite steers and resolves of other keys that name them"
}

test_cd_870_version_file_is_a_call_with_its_open_pr() {
  local out
  out=$(run_calls "$FIXTURE" "$FIXTURE/prs-fos-merged.tsv") || fail "fm-captain-calls failed"
  assert_equals "secondmate|cd|cd-870-version-file|open" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "cd.cd-870-version-file") | "\(.source)|\(.home)|\(.decision_key)|\(.prs[0].state)"')" \
    "cd-870-version-file carries its home, key and PR state"
  pass "cd-870-version-file: a plain status key is a call, and its open PR keeps it there"
}

test_captain_hold_key_names_its_task_and_question() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  assert_equals "cd-882-name|What should the new coverage script be called?" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "cd.captain-hold-cd-882-name-1") | "\(.task)|\(.question)"')" \
    "a captain-hold key yields its task and question"
  pass "a captain hold key carries its task id and its question"
}

test_runner_image_calls_survive_resolved_duplicate_keys() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  expect_where "$out" runner-image.captain-hold-gke-cp-lockdown-rollout-1 calls \
    "a call whose duplicate plain key the mate resolved"
  expect_where "$out" runner-image.captain-hold-runner-fuse-rollout-1 calls \
    "a call whose duplicate plain key (equal to the hold id) the mate resolved"
  expect_where "$out" runner-image.runner-fuse-rollout absent "the resolved duplicate key"
  expect_where "$out" runner-image.gke-cp-lockdown-rollout absent "the resolved duplicate key"
  assert_equals "Reach the control plane only over Tailscale?" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "runner-image.captain-hold-gke-cp-lockdown-rollout-1") | .question')" \
    "a re-raised key shows its latest question"
  pass "gke-cp-lockdown-rollout and runner-fuse-rollout: resolving a duplicate key never closes the captain hold"
}

test_exact_key_resolve_closes_the_call() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  expect_where "$out" cd.captain-hold-cd-930-done-1 absent "a key the mate resolved itself"
  expect_where "$out" cd.cd-870-release-mr absent "a plain key the mate resolved itself"
  pass "the mate resolving the exact key closes the call"
}

test_captain_answered_key_is_skipped() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  expect_where "$out" cd.cd-911-answered skipped "a key the captain answered"
  assert_contains "$(printf '%s\n' "$out" | jq -r '.skipped[] | select(.key == "cd.cd-911-answered") | .why')" \
    "answered by the captain" "the skip says the captain answered"
  pass "a key the captain already answered is skipped until the mate closes it"
}

test_remote_and_missing_mates() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  expect_where "$out" far.captain-hold-far-plan-1 calls "a remote mate's open key"
  assert_equals "true" "$(printf '%s\n' "$out" | jq '.calls[] | select(.key == "far.captain-hold-far-plan-1") | .remote')" \
    "the remote call is marked remote"
  assert_equals "cd=read,runner-image=read,far=read,quiet=missing" \
    "$(printf '%s\n' "$out" | jq -r '[.homes[] | "\(.id)=\(.status_log)"] | join(",")')" \
    "every registered mate is listed, in registry order"
  pass "a remote mate's key is a call, and a mate with no status log is reported"
}

test_unknown_pr_state_keeps_the_call() {
  local out
  : > "$FIXTURE/prs-none.tsv"
  out=$(run_calls "$FIXTURE" "$FIXTURE/prs-none.tsv") || fail "fm-captain-calls failed"
  expect_where "$out" fos-merge-19-18-13 calls "a merge ask whose PR states are unknown"
  assert_equals "file|unknown" "$(printf '%s\n' "$out" | jq -r '"\(.pr_check)|\(.calls[] | select(.key == "fos-merge-19-18-13") | .prs[0].state)"')" \
    "unknown PR states are reported as unknown"
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  assert_equals "off" "$(printf '%s\n' "$out" | jq -r '.pr_check')" "PR lookups can be turned off"
  expect_where "$out" fos-merge-19-18-13 calls "a merge ask with PR lookups off"
  pass "an unknown PR state, or no lookups, keeps the call"
}

test_all_nine_misfiled_calls_are_present() {
  local out key n=0
  out=$(run_calls "$FIXTURE" "$FIXTURE/prs-fos-merged.tsv") || fail "fm-captain-calls failed"
  for key in fos-merge-19-18-13 aegis-880-held cd.cd-870-version-file \
    cd.captain-hold-cd-810-infra-home-1 cd.captain-hold-cd-882-name-1 cd.captain-hold-cd-882-mr-run-1 \
    cd.captain-hold-cd-915-stable-lag-1 runner-image.captain-hold-gke-cp-lockdown-rollout-1 \
    runner-image.captain-hold-runner-fuse-rollout-1; do
    case "$(where "$out" "$key")" in
      calls|to_close) n=$((n + 1)) ;;
      *) fail "$key is missing from the model" ;;
    esac
  done
  assert_equals 9 "$n" "all nine calls are visible"
  assert_equals 0 "$(printf '%s\n' "$out" | jq '[.calls[], .to_close[]] | group_by(.key) | map(select(length > 1)) | length')" \
    "card keys are unique"
  pass "all nine calls the board misfiled are visible as calls or in to_close"
}

test_main_worker_question_is_a_call() {
  local out
  out=$(run_calls "$FIXTURE" off) || fail "fm-captain-calls failed"
  expect_where "$out" bcr-grill.grill-bcr-r4 calls "a live main worker's open question"
  assert_equals "main-worker|main|bcr-grill|grill-bcr-r4|true" \
    "$(printf '%s\n' "$out" | jq -r '.calls[] | select(.key == "bcr-grill.grill-bcr-r4") | "\(.source)|\(.home)|\(.task)|\(.decision_key)|\(.decision)"')" \
    "the worker call names main, its task and its key"
  expect_where "$out" home-task.name-pick calls "a live personal worker's question"
  expect_where "$out" bcr-grill.bcr-close-5860 absent "a worker key resolved by the worker"
  expect_where "$out" old-task.old-ask absent "a finished task with no record"
  assert_equals "bcr-grill,home-task" "$(printf '%s\n' "$out" | jq -r '.workers | join(",")')" \
    "the live workers whose logs were read"
  assert_equals "cd,runner-image,far,quiet" "$(printf '%s\n' "$out" | jq -r '[.homes[].id] | join(",")')" \
    "workers are not listed as secondmates"
  pass "a live main worker's open question is a call; a resolved key or a finished task is not"
}

test_work_items_show_at_any_time() {
  local out tz
  # Two local clocks 12 hours apart: at least one of them is outside 09:00-18:00.
  for tz in UTC Etc/GMT-12; do
    out=$(TZ=$tz run_calls "$FIXTURE" off) || fail "fm-captain-calls failed in $tz"
    expect_where "$out" bcr-grill.grill-bcr-r4 calls "a YouTrack question in $tz"
    expect_where "$out" aegis-880-held calls "an aegis hold in $tz"
  done
  pass "a work-project call is a call at any time of day; the model reads no clock"
}

test_reads_without_writing() {
  local before after
  before=$(find "$FIXTURE" -path "$FIXTURE/prs-none.tsv" -prune -o -type f -print0 | sort -z | xargs -0 md5sum)
  run_calls "$FIXTURE" "$FIXTURE/prs-fos-merged.tsv" >/dev/null || fail "fm-captain-calls failed"
  run_calls "$FIXTURE" off >/dev/null || fail "fm-captain-calls failed"
  after=$(find "$FIXTURE" -path "$FIXTURE/prs-none.tsv" -prune -o -type f -print0 | sort -z | xargs -0 md5sum)
  assert_equals "$before" "$after" "no file in the home changed"
  pass "the model writes nothing in the home it reads"
}

test_usage() {
  local out
  out=$("$CALLS" --help) || fail "--help failed"
  assert_contains "$out" "Usage: fm-captain-calls.sh" "--help prints usage"
  "$CALLS" --bogus >/dev/null 2>&1
  expect_code 2 $? "an unknown argument"
  pass "--help prints usage and an unknown argument exits 2"
}

test_unreadable_backlog_exits_1() {
  local home
  home=$(make_home empty)
  rm -f "$home/data/backlog.md"
  in_home "$home" "$CALLS" >/dev/null 2>&1
  expect_code 1 $? "a home with no backlog"
  pass "a home with no backlog exits 1"
}

fm_test_run \
  test_main_worker_question_is_a_call \
  test_work_items_show_at_any_time \
  test_settled_merge_ask_goes_to_close_not_calls \
  test_settled_secondmate_merge_ask_goes_to_close \
  test_answered_non_decision_goes_to_close \
  test_held_merge_ask_with_an_open_pr_stays_a_call \
  test_open_decision_stays_a_call_after_its_mr_merges \
  test_merge_request_noun_is_not_a_merge_ask \
  test_answered_hold_is_dropped \
  test_released_hold_is_dropped \
  test_deferred_hold_is_skipped_until_its_date \
  test_deferred_secondmate_hold_is_skipped_until_its_date \
  test_plain_hold_is_a_call_with_its_options \
  test_a_re_held_task_shows_only_its_current_options \
  test_a_worker_key_on_a_held_task_is_not_a_second_call \
  test_inline_lettered_options_leave_the_question \
  test_mate_inline_recommended_option_is_the_recommend \
  test_mate_keyless_line_does_not_shadow_a_keyed_call \
  test_mate_corr_reply_is_with_firstmate_not_a_call \
  test_mate_hold_waiting_on_main_is_with_firstmate \
  test_mate_captain_decisions_without_corr_stay_calls \
  test_mate_backlog_hold_options_are_the_call_options \
  test_mate_backlog_option_letter_tags_leave_the_labels \
  test_mate_backlog_option_uppercase_letter_tags_leave_the_labels \
  test_mate_inline_options_keep_trailing_prose_and_evidence_report \
  test_mate_long_hold_shows_its_full_text \
  test_mate_hold_evidence_tail_is_always_its_report \
  test_evidence_report_needs_an_evidence_tail \
  test_cd_calls_named_by_housekeeping_steers_stay_calls \
  test_cd_870_version_file_is_a_call_with_its_open_pr \
  test_captain_hold_key_names_its_task_and_question \
  test_runner_image_calls_survive_resolved_duplicate_keys \
  test_exact_key_resolve_closes_the_call \
  test_captain_answered_key_is_skipped \
  test_remote_and_missing_mates \
  test_unknown_pr_state_keeps_the_call \
  test_all_nine_misfiled_calls_are_present \
  test_reads_without_writing \
  test_usage \
  test_unreadable_backlog_exits_1
