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
# captain-hold-runner-fuse-rollout-1.
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
EOF

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
  test_settled_merge_ask_goes_to_close_not_calls \
  test_settled_secondmate_merge_ask_goes_to_close \
  test_answered_non_decision_goes_to_close \
  test_held_merge_ask_with_an_open_pr_stays_a_call \
  test_open_decision_stays_a_call_after_its_mr_merges \
  test_merge_request_noun_is_not_a_merge_ask \
  test_answered_hold_is_dropped \
  test_released_hold_is_dropped \
  test_deferred_hold_is_skipped_until_its_date \
  test_plain_hold_is_a_call_with_its_options \
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
