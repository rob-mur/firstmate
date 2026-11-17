#!/usr/bin/env bash
# tests/fm-wake-drain-cards-to-fix.test.sh - the drain must name every
# Captain's Call card the board build held back as needing a fix, by its owning
# task and key, so main re-posts it as a clean keyed decision, and must stay
# silent when the build held nothing back. The board build writes the list
# (bin/fm-bearings-board.sh); this pins only what the drain presents from it.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-cards-to-fix-tests)

# Pin a home that does not run the supervision host, so BRANCH OUTCOMES stays
# out of the drain (bin/fm-supervision-engine-lib.sh owns the gate).
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

test_a_held_back_card_is_named_by_task_and_key() {
  local dir state out
  dir=$(make_case held-back)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'alpha-fix\talpha-fix\tmissing options (no recorded choices)\nbeta\tbeta.question\tmissing question (title is not a question)\n' \
    > "$state/board-cards-to-fix"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "the drain failed with cards to fix: $(cat "$out")"
  grep -F 'CARDS TO FIX' "$out" >/dev/null || fail "the drain printed no CARDS TO FIX section: $(cat "$out")"
  grep -F 'alpha-fix [key=alpha-fix]: missing options (no recorded choices)' "$out" >/dev/null \
    || fail "the drain did not name the first card by task and key: $(cat "$out")"
  grep -F 'beta [key=beta.question]: missing question (title is not a question)' "$out" >/dev/null \
    || fail "the drain did not name the second card by task and key: $(cat "$out")"
  grep -F 're-post' "$out" >/dev/null || fail "the drain did not say to re-post the cards: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "the second drain failed: $(cat "$out")"
  grep -F 'alpha-fix [key=alpha-fix]' "$out" >/dev/null \
    || fail "a card still held back was not named again on the next drain: $(cat "$out")"
  pass "every held-back card is named by task and key on each drain until the board shows it"
}

test_no_section_when_nothing_is_held_back() {
  local dir state out
  dir=$(make_case none-held-back)
  state="$dir/state"
  out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "the drain failed with no cards to fix"
  if grep -F 'CARDS TO FIX' "$out" >/dev/null; then
    fail "the drain printed CARDS TO FIX with no list: $(cat "$out")"
  fi
  : > "$state/board-cards-to-fix"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "the drain failed with an empty list"
  if grep -F 'CARDS TO FIX' "$out" >/dev/null; then
    fail "the drain printed CARDS TO FIX for an empty list: $(cat "$out")"
  fi
  pass "the drain is silent when the board held no card back"
}

test_a_branch_drain_leaves_cards_to_main() {
  local dir state out
  dir=$(make_case branch-actor)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'alpha-fix\talpha-fix\tmissing link\n' > "$state/board-cards-to-fix"
  FM_SUPERVISION_ACTOR=branch FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>&1 || true
  if grep -F 'CARDS TO FIX' "$out" >/dev/null; then
    fail "a branch drain presented main's cards to fix: $(cat "$out")"
  fi
  pass "only main's drain presents the cards to fix"
}

test_a_held_back_card_is_named_by_task_and_key
test_no_section_when_nothing_is_held_back
test_a_branch_drain_leaves_cards_to_main
