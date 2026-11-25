#!/usr/bin/env bash
# tests/fm-classify-captain-next-step.test.sh - status_captain_next_step in
# bin/fm-classify-lib.sh: the step only the captain can do that a ship's newest
# done line names. Teardown and the fleet snapshot ask it so such a step never
# leaves the record without an open captain hold. These tests drive the real
# function over crafted status files and assert its result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-captain-next-step-tests)

status_with() {  # <name> <line>...
  local file="$TMP_ROOT/$1.status"
  shift
  printf '%s\n' "$@" > "$file"
  printf '%s\n' "$file"
}

# The dotfiles DNS rollout's ready line named the enablement steps only the
# captain could take after the merge.
test_names_the_dns_enablement_steps() {
  local file out
  file=$(status_with dns 'working: wiring DoT' \
    'done [at=1795600000]: PR ready https://github.com/example/dotfiles/pull/62 next: captain runs snrs per host, work-laptop sudo activate, Android Private DNS manual steps — all in PR body')
  out=$(status_captain_next_step "$file") || fail "the DNS enablement steps were not named"
  assert_contains "$out" "captain runs snrs per host" "the step lost its words: $out"
  assert_contains "$out" "Android Private DNS manual steps" "the step was cut short: $out"
  pass "the DNS ready line names its captain-only enablement steps"
}

test_a_step_the_landing_discharges_is_not_captain_only() {
  local line file
  for line in 'done: PR ready https://github.com/example/x/pull/1 next: captain reviews https://github.com/example/x/pull/1' \
    'done: ready in branch fm/x - next: captain review.' \
    'done: ready - next: captain to merge' \
    'done: ready in branch fm/x'; do
    file=$(status_with landing "$line")
    ! status_captain_next_step "$file" >/dev/null || fail "a step the landing discharges was named: $line"
  done
  file=$(status_with merge-then 'done: ready - next: Captain must merge then run setup.')
  status_captain_next_step "$file" >/dev/null || fail "a step after the merge was not named"
  pass "review, merge, or approve alone is not captain-only, but a step after it is"
}

test_only_the_newest_done_line_counts() {
  local file
  file=$(status_with newer \
    'done: PR ready next: captain runs snrs per host' \
    'working: rework after review' \
    'done: PR ready, nothing left for anyone')
  ! status_captain_next_step "$file" >/dev/null || fail "an older done line's step was named"
  file=$(status_with not-done 'blocked: next: captain runs snrs per host')
  ! status_captain_next_step "$file" >/dev/null || fail "a line that is not done was read"
  ! status_captain_next_step "$TMP_ROOT/missing.status" >/dev/null || fail "a missing status named a step"
  pass "only the newest done line is read"
}

fm_test_run \
  test_names_the_dns_enablement_steps \
  test_a_step_the_landing_discharges_is_not_captain_only \
  test_only_the_newest_done_line_counts
