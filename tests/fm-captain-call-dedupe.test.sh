#!/usr/bin/env bash
# Behavior tests for captain-call dedupe: a keyed decision the captain already
# answered on its captain call is never shown to the captain again, while any
# decision whose recorded answer does not clearly match still shows.
# The match is owned by `fm-captain-hold.sh answered` and applied through
# status_open_decisions_tag_answered (bin/fm-classify-lib.sh); these tests drive
# the real hold script, wake drain, and fleet snapshot over isolated homes.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-call-dedupe)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

ANSWER_AT=2026-07-14T12:00:00Z
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
ANSWER_EPOCH=$(fm_utc_iso_to_epoch "$ANSWER_AT")
BEFORE=$((ANSWER_EPOCH - 3600))
AFTER=$((ANSWER_EPOCH + 3600))

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'MD'
## In flight

## Queued

## Done
MD
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" treehouse no-mistakes gh gh-axi
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) printf 'zsh\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$home"
}

in_home() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$@"
}

# Holds <call-id> for the captain with <origin> as its origin, then records the
# captain's answer at ANSWER_AT, which closes the call.
answer_call() {  # <home> <origin> <call-id>
  local home=$1 origin=$2 id=$3
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id" --title "Call $id" \
    --reason "captain must decide" --origin "$origin" >/dev/null \
    || fail "could not hold $id"
  printf 'Go with REST.\n' > "$home/decision-$id.txt"
  FM_CAPTAIN_HOLD_NOW=$ANSWER_AT in_home "$home" "$ROOT/bin/fm-captain-hold.sh" \
    answer "$id" --decision-file "$home/decision-$id.txt" >/dev/null \
    || fail "could not answer $id"
}

test_answered_matches_only_a_clear_recorded_answer() {
  local home out
  home=$(make_home answered)
  answer_call "$home" worker-a api-shape
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold still-open --title "Open call" \
    --reason "captain must decide" --origin worker-a >/dev/null || fail "could not hold still-open"

  out=$(in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answered worker-a api-shape --opened-at "$BEFORE") \
    || fail "an answer recorded after the question opened was not matched"
  [ "$out" = api-shape ] || fail "answered printed the wrong call id: $out"

  if in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answered worker-a api-shape --opened-at "$AFTER" >/dev/null; then
    fail "a question raised again after the answer was treated as answered"
  fi
  if in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answered worker-b api-shape --opened-at "$BEFORE" >/dev/null; then
    fail "an answer recorded for another origin was matched"
  fi
  if in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answered worker-a still-open --opened-at "$BEFORE" >/dev/null; then
    fail "a call still waiting on the captain was treated as answered"
  fi
  if in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answered worker-a no-such-call --opened-at "$BEFORE" >/dev/null; then
    fail "an unknown call was treated as answered"
  fi
  pass "answered matches only a closed call for the same origin answered after the question opened"
}

test_answered_matches_a_legacy_derived_call_id() {
  local home out
  home=$(make_home legacy)
  answer_call "$home" worker-a worker-a-decision-db
  out=$(in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answered worker-a db --opened-at "$BEFORE") \
    || fail "the legacy <origin>-decision-<key> call id was not matched"
  [ "$out" = worker-a-decision-db ] || fail "answered printed the wrong legacy id: $out"
  pass "answered matches the legacy derived call id"
}

test_wake_drain_does_not_ask_an_answered_decision_again() {
  local home out
  home=$(make_home drain)
  answer_call "$home" worker-a api-shape
  printf 'needs-decision [at=%s] [key=api-shape]: pick REST or RPC\n' "$BEFORE" > "$home/state/worker-a.status"
  printf 'needs-decision [at=%s] [key=api-shape]: pick REST or RPC\n' "$AFTER" > "$home/state/worker-b.status"
  # worker-c's db question carries no recorded time, so whether the captain's
  # answer came after it is uncertain and it keeps being asked.
  answer_call "$home" worker-c db
  printf 'needs-decision [key=db]: pick a database\n' > "$home/state/worker-c.status"

  out=$(in_home "$home" "$ROOT/bin/fm-wake-drain.sh") || fail "drain failed"

  printf '%s\n' "$out" | grep -F 'worker-a [key=api-shape] already answered on captain call api-shape' >/dev/null \
    || fail "the answered decision was not listed as already answered: $out"
  if printf '%s\n' "$out" | grep -F 'worker-a [key=api-shape] needs-decision' >/dev/null; then
    fail "the answered decision was still asked: $out"
  fi
  printf '%s\n' "$out" | grep -F 'worker-b [key=api-shape] needs-decision: pick REST or RPC' >/dev/null \
    || fail "a decision from another worker lost its ask: $out"
  printf '%s\n' "$out" | grep -F 'worker-c [key=db] needs-decision: pick a database' >/dev/null \
    || fail "a decision with an uncertain match lost its ask: $out"
  pass "the wake drain lists an answered decision for relay instead of asking it again"
}

test_snapshot_drops_an_answered_decision() {
  local home out
  home=$(make_home snapshot)
  mkdir -p "$home/mate-home"
  answer_call "$home" mate-a api-shape
  for id in mate-a mate-b; do
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$home/mate-home" "project=$home/mate-home" \
      "harness=codex" "kind=secondmate" "mode=secondmate" "home=$home/mate-home" "projects=alpha"
  done
  {
    printf 'needs-decision [at=%s] [key=api-shape]: pick REST or RPC\n' "$BEFORE"
    printf 'needs-decision [at=%s] [key=db]: pick a database\n' "$BEFORE"
  } > "$home/state/mate-a.status"
  printf 'needs-decision [at=%s] [key=api-shape]: pick REST or RPC\n' "$AFTER" > "$home/state/mate-b.status"

  out=$(in_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "snapshot failed"

  printf '%s' "$out" | jq -e '
    (.tasks[] | select(.id == "mate-a") | .hints.open_decisions | map(.key)) == ["db"]
  ' >/dev/null || fail "the answered decision still surfaced, or the unanswered one was lost: $out"
  printf '%s' "$out" | jq -e '
    (.tasks[] | select(.id == "mate-b") | .hints.open_decisions | map(.key)) == ["api-shape"]
  ' >/dev/null || fail "a decision re-raised after the answer was dropped: $out"
  pass "the fleet snapshot drops only the decision the captain already answered"
}

test_overdue_reminder_skips_an_answered_decision() {
  local home reason
  home=$(make_home reminder)
  answer_call "$home" worker-a api-shape
  touch "$home/config/open-decision-reminders"
  printf 'needs-decision [at=%s] [key=api-shape]: pick REST or RPC\n' "$BEFORE" > "$home/state/worker-a.status"
  printf 'needs-decision [at=%s] [key=db]: pick a database\n' "$((BEFORE + 60))" > "$home/state/worker-b.status"
  # The watcher is sourced in a subshell bound to this isolated home only.
  reason=$(
    export PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config"
    # shellcheck source=bin/fm-watch.sh
    . "$ROOT/bin/fm-watch.sh"
    FM_OPEN_DECISION_OVERDUE_SECS=100
    open_decision_reminder_tick "$AFTER" >/dev/null || exit 1
    printf '%s\n' "$OPEN_DECISION_REMINDER"
  ) || fail "the reminder tick failed"
  case "$reason" in
    *'worker-b key=db'*) ;;
    *) fail "the reminder chased an answered decision instead of the open one: $reason" ;;
  esac
  pass "the overdue reminder never chases a decision the captain already answered"
}

test_answered_matches_only_a_clear_recorded_answer
test_answered_matches_a_legacy_derived_call_id
test_overdue_reminder_skips_an_answered_decision
test_wake_drain_does_not_ask_an_answered_decision_again
test_snapshot_drops_an_answered_decision
