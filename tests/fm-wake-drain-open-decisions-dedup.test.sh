#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions-dedup.test.sh - behavior tests for the
# OPEN DECISIONS repeat-print dedup in bin/fm-wake-drain.sh. They drive the real
# drain over successive invocations and assert on its printed output: an
# unchanged block becomes a one-line pointer, a new or changed decision always
# prints in full, and the full list stays reachable.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
unset FM_OPEN_DECISIONS_FULL

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-dedup-tests)

drain() {  # <state> <out>
  FM_STATE_OVERRIDE="$1" "$DRAIN" > "$2" 2>/dev/null || fail "drain failed"
}

test_unchanged_block_prints_a_pointer_and_stays_reachable() {
  local dir state out
  dir=$(make_case dedup-pointer)
  state="$dir/state"
  out="$dir/out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"

  drain "$state" "$out"
  grep -F 'pick REST or RPC' "$out" >/dev/null || fail "first drain did not print the decision in full"

  drain "$state" "$out"
  if grep -F 'pick REST or RPC' "$out" >/dev/null; then fail "unchanged drain reprinted the decision: $(cat "$out")"; fi
  grep -F 'OPEN DECISIONS: 1 still open, unchanged since' "$out" >/dev/null || fail "unchanged drain printed no pointer: $(cat "$out")"
  grep -F -- '--open-decisions' "$out" >/dev/null || fail "pointer does not name the reprint command"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --open-decisions > "$out" || fail "--open-decisions failed"
  grep -F 'task1 [key=api-shape] needs-decision: pick REST or RPC' "$out" >/dev/null || fail "--open-decisions did not print the block in full: $(cat "$out")"
  grep -F "resolve-key" "$out" >/dev/null || fail "--open-decisions dropped the answerer hint"
  pass "an unchanged block becomes a pointer and --open-decisions prints it in full"
}

test_new_or_changed_decision_prints_in_full() {
  local dir state out
  dir=$(make_case dedup-changed)
  state="$dir/state"
  out="$dir/out"
  printf 'needs-decision [key=a]: first question\n' > "$state/task1.status"
  drain "$state" "$out"
  drain "$state" "$out"
  grep -F 'unchanged since' "$out" >/dev/null || fail "precondition: second drain should be a pointer"

  printf 'blocked [key=b]: second problem\n' > "$state/task2.status"
  drain "$state" "$out"
  grep -F 'first question' "$out" >/dev/null || fail "a newly opened decision did not reprint the whole block"
  grep -F 'second problem' "$out" >/dev/null || fail "the new decision was not printed"

  printf 'resolved [key=b]: handled\n' >> "$state/task2.status"
  drain "$state" "$out"
  grep -F 'first question' "$out" >/dev/null || fail "a closed decision changing the block did not reprint it in full"
  if grep -F 'second problem' "$out" >/dev/null; then fail "closed decision still printed"; fi
  pass "a new or changed decision always prints the full block"
}

test_reopening_after_empty_prints_in_full() {
  local dir state out
  dir=$(make_case dedup-reopen)
  state="$dir/state"
  out="$dir/out"
  printf 'needs-decision [key=a]: same question\n' > "$state/task1.status"
  drain "$state" "$out"
  printf 'resolved [key=a]: ok\n' >> "$state/task1.status"
  drain "$state" "$out"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then fail "resolved decision still listed"; fi
  [ ! -e "$state/.open-decisions-presented" ] || fail "empty block left a dedup record behind"
  printf 'needs-decision [key=a]: same question\n' >> "$state/task1.status"
  drain "$state" "$out"
  grep -F 'same question' "$out" >/dev/null || fail "an identical decision reopened after being cleared printed only a pointer"
  pass "a decision that reopens after the block emptied prints in full"
}

test_force_full_env_always_prints() {
  local dir state out
  dir=$(make_case dedup-force)
  state="$dir/state"
  out="$dir/out"
  printf 'needs-decision [key=a]: forced question\n' > "$state/task1.status"
  drain "$state" "$out"
  FM_OPEN_DECISIONS_FULL=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null || fail "forced drain failed"
  grep -F 'forced question' "$out" >/dev/null || fail "FM_OPEN_DECISIONS_FULL=1 did not print in full"
  pass "FM_OPEN_DECISIONS_FULL=1 forces the full block"
}

test_pointer_is_far_smaller_than_the_block() {
  local dir state out full i
  dir=$(make_case dedup-size)
  state="$dir/state"
  out="$dir/out"
  for i in 1 2 3 4 5 6; do
    printf 'needs-decision [key=k%s]: %0180d padding so the block is large\n' "$i" 0 > "$state/task$i.status"
  done
  drain "$state" "$out"
  full=$(wc -c < "$out" | tr -d '[:space:]')
  drain "$state" "$out"
  [ "$(wc -c < "$out" | tr -d '[:space:]')" -lt $((full / 3)) ] || fail "the unchanged drain was not much smaller than the full block"
  pass "an unchanged six-decision drain is a fraction of the full block"
}

run_tests() {
  test_unchanged_block_prints_a_pointer_and_stays_reachable
  test_new_or_changed_decision_prints_in_full
  test_reopening_after_empty_prints_in_full
  test_force_full_env_always_prints
  test_pointer_is_far_smaller_than_the_block
}
run_tests
