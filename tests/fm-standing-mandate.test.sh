#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031 # each tick subshell sets its own home on purpose.
# Behavior of a secondmate's standing-mandate facts: the dated rest record, the
# idle marker its summary publication keeps, the one "stopped with standing
# work" rule, the bearings and board row it drives, and the parent watcher's
# once-per-episode wake, plus the mate's own drive and offered-item-taken wakes
# and the turn-end supervision need they create.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-standing-mandate-lib.sh
. "$ROOT/bin/fm-standing-mandate-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-standing-mandate)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# A main home plus one firstmate-shaped secondmate home registered with
# <posture>.  Sets W_MAIN and W_SM.
new_world() {  # <name> <posture-or-empty>
  local w="$TMP_ROOT/$1" field=
  W_MAIN="$w/main"
  W_SM="$w/sm"
  mkdir -p "$W_MAIN/state" "$W_MAIN/data" "$W_MAIN/config" "$W_MAIN/projects" \
    "$W_SM/state" "$W_SM/data" "$W_SM/config" "$W_SM/projects" "$W_SM/bin"
  printf 'sm\n' > "$W_SM/.fm-secondmate-home"
  printf 'instructions\n' > "$W_SM/AGENTS.md"
  printf '# Backlog\n\n## Queued\n' > "$W_SM/data/backlog.md"
  [ -z "$2" ] || field="posture: $2; "
  printf -- '- sm - fixture mate (home: %s; scope: fixture work; projects: ; %sadded 2026-11-01)\n' \
    "$W_SM" "$field" > "$W_MAIN/data/secondmates.md"
  printf 'window=firstmate:fm-sm\nkind=secondmate\nhome=%s\n' "$W_SM" > "$W_MAIN/state/sm.meta"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$W_MAIN" > "$W_SM/.fm-secondmate-parent"
}

iso_in() {  # <seconds-from-now> -> UTC minute
  local t=$(( $(date +%s) + $1 ))
  date -u -d "@$t" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$t" +%Y-%m-%dT%H:%MZ
}

rest() {  # <args...>
  FM_HOME="$W_SM" "$ROOT/bin/fm-secondmate-rest.sh" "$@" 2>&1
}

publish_summary() {  # publishes the mate's summary and keeps its idle marker
  FM_HOME="$W_SM" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary \
    > "$W_SM/state/home-summary.json" || fail "the mate summary failed"
  fm_standing_mandate_idle_update "$W_SM/state" "$W_SM/state/home-summary.json"
}

backdate_idle() {  # <seconds-ago>
  printf '%s\n' "$(( $(date +%s) - $1 ))" > "$W_SM/state/.idle-since"
  publish_summary
}

stopped() {  # <json-object> <now> <grace>
  jq -r --argjson now "$2" --argjson grace "$3" "$FM_STANDING_MANDATE_JQ"'
    mandate_stopped_since($now; $grace) // "null"' <<<"$1"
}

test_rest_record_is_active_only_until_its_date() {
  local st="$TMP_ROOT/rest/state" now=1000000
  mkdir -p "$st"
  fm_mandate_rest_active "$st" "$now" && fail "a missing rest record counted as active"
  assert_equals "$(fm_mandate_rest_json "$st" "$now")" null "a missing rest record should print null"

  fm_mandate_rest_write "$st" $((now + 600)) 2026-11-25T12:10Z "waiting on the weekly import" "$now" \
    || fail "the rest write failed"
  fm_mandate_rest_active "$st" "$now" || fail "a dated rest was not active before its date"
  assert_equals "$(fm_mandate_rest_json "$st" "$now" | jq -r '.until + " " + .reason')" \
    "2026-11-25T12:10Z waiting on the weekly import" "the rest JSON lost its date or reason"
  fm_mandate_rest_active "$st" $((now + 600)) && fail "a rest stayed active at its until date"
  assert_equals "$(fm_mandate_rest_json "$st" $((now + 601)))" null "an expired rest should print null"

  printf 'until_epoch=soon\nreason=broken\n' > "$(fm_mandate_rest_path "$st")"
  fm_mandate_rest_active "$st" "$now" && fail "a malformed rest record counted as active"
  pass "a rest record is active only while well formed and before its date"
}

test_stopped_rule_needs_every_condition() {
  local now=1000000 base
  base='{"posture":"drive","valid":true,"state":"no_active_work","generated_epoch":999900,"idle_since":998000,"mandate_rest":null}'
  assert_equals "$(stopped "$base" "$now" 900)" 998000 "a drive mate idle past the grace should be stopped"
  assert_equals "$(stopped "$base" "$now" 3000)" null "a mate idle less than the grace was stopped"
  assert_equals "$(stopped "$(jq -c '.posture="routed"' <<<"$base")" "$now" 900)" null "a routed mate was stopped"
  assert_equals "$(stopped "$(jq -c 'del(.posture)' <<<"$base")" "$now" 900)" null "a mate with no posture was stopped"
  assert_equals "$(stopped "$(jq -c '.state="working"' <<<"$base")" "$now" 900)" null "a working mate was stopped"
  assert_equals "$(stopped "$(jq -c '.valid=false' <<<"$base")" "$now" 900)" null "an invalid summary was stopped"
  assert_equals "$(stopped "$(jq -c '.generated_epoch=990000' <<<"$base")" "$now" 900)" null \
    "a summary older than 30 minutes was stopped"
  assert_equals "$(stopped "$(jq -c '.idle_since=null' <<<"$base")" "$now" 900)" null "a summary with no idle epoch was stopped"
  assert_equals "$(stopped "$(jq -c '.mandate_rest={until_epoch:1000600}' <<<"$base")" "$now" 900)" null \
    "a mate on an active rest was stopped"
  assert_equals "$(stopped "$(jq -c '.mandate_rest={until_epoch:999999}' <<<"$base")" "$now" 900)" 998000 \
    "an expired rest still excused the mate"
  pass "the stopped rule needs drive, a fresh valid idle summary, the grace, and no active rest"
}

test_summary_keeps_one_idle_epoch_per_episode() {
  local first again
  new_world episode drive
  publish_summary
  first=$(jq -r '.idle_since' "$W_SM/state/home-summary.json")
  case "$first" in ''|null|*[!0-9]*) fail "an idle summary carried no idle epoch: $first" ;; esac
  assert_equals "$(cat "$W_SM/state/.idle-since")" "$first" "the idle marker did not record the episode start"
  printf '%s\n' 1234 > "$W_SM/state/.idle-since"
  publish_summary
  again=$(jq -r '.idle_since' "$W_SM/state/home-summary.json")
  assert_equals "$again" 1234 "a later publication did not keep the episode's first idle epoch"

  printf '{"state":"working","idle_since":null}\n' > "$TMP_ROOT/working.json"
  fm_standing_mandate_idle_update "$W_SM/state" "$TMP_ROOT/working.json"
  assert_absent "$W_SM/state/.idle-since" "a working summary did not end the idle episode"
  printf '%s\n' 1234 > "$W_SM/state/.idle-since"
  printf '{"state":"unknown","idle_since":null}\n' > "$TMP_ROOT/unknown.json"
  fm_standing_mandate_idle_update "$W_SM/state" "$TMP_ROOT/unknown.json"
  assert_equals "$(cat "$W_SM/state/.idle-since")" 1234 "an unknown summary ended the idle episode"

  fm_mandate_rest_write "$W_SM/state" $(( $(date +%s) + 3600 )) 2026-11-25T13:00Z "import window" "$(date +%s)"
  publish_summary
  assert_equals "$(jq -r '.mandate_rest.reason' "$W_SM/state/home-summary.json")" "import window" \
    "the summary did not carry the active rest"
  pass "the published summary keeps one idle epoch per episode and carries an active rest"
}

test_board_shows_a_stopped_drive_mate_only() {
  local snap rows
  new_world board drive
  backdate_idle 2000
  snap=$(FM_HOME="$W_MAIN" "$ROOT/bin/fm-bearings-snapshot.sh" --json) || fail "the bearings snapshot failed"
  assert_equals "$(jq -r '.secondmates[0].posture' <<<"$snap")" drive "the bearings row lost the posture"
  case "$(jq -r '.secondmates[0].stopped_since' <<<"$snap")" in
    20*Z) ;;
    *) fail "a drive mate idle past the grace showed no stopped time: $snap" ;;
  esac
  rows=$(FM_HOME="$W_MAIN" "$ROOT/bin/fm-bearings-board-payload.sh" --snapshot - <<<"$snap" | jq -c '[.charted[] | select(.id == "stopped-sm")]')
  assert_equals "$(jq -r '.[0].kind + " " + .[0].title' <<<"$rows")" \
    "warning sm stopped: standing work, nothing under way" "the board did not show the stopped mate"

  fm_mandate_rest_write "$W_SM/state" $(( $(date +%s) + 3600 )) 2026-11-25T13:00Z "import window" "$(date +%s)"
  publish_summary
  snap=$(FM_HOME="$W_MAIN" "$ROOT/bin/fm-bearings-snapshot.sh" --json) || fail "the bearings snapshot failed"
  assert_equals "$(jq -r '.secondmates[0].stopped_since' <<<"$snap")" null "a resting mate showed as stopped"

  new_world board-routed ""
  backdate_idle 2000
  snap=$(FM_HOME="$W_MAIN" "$ROOT/bin/fm-bearings-snapshot.sh" --json) || fail "the bearings snapshot failed"
  assert_equals "$(jq -r '.secondmates[0].posture + " " + (.secondmates[0].stopped_since // "null")' <<<"$snap")" \
    "routed null" "an idle routed mate showed as stopped"
  pass "the board shows a stopped row for an idle drive mate and none for a resting or routed one"
}

# Run the parent watcher's stopped tick in a subshell that sourced the watcher
# for the main home; prints each wake reason the tick raised.
watcher_tick() {
  (
    export FM_HOME="$W_MAIN" FM_STATE_OVERRIDE="$W_MAIN/state" FM_SECONDMATE_STOPPED_TICK_SECS=0
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-watch.sh"
    # shellcheck disable=SC2329 # called by the sourced tick
    wake() { printf 'WAKE %s\n' "$1"; }
    secondmate_stopped_tick || printf 'TICK FAILED\n'
  )
}

test_watcher_wakes_once_per_stop_episode() {
  local out
  new_world watch drive
  backdate_idle 600
  out=$(watcher_tick)
  assert_equals "$out" "" "the watcher woke before the hour threshold"

  backdate_idle 4000
  out=$(watcher_tick)
  assert_equals "$out" "WAKE check: secondmate sm stopped with standing work" "a stopped drive mate did not wake the parent"
  assert_contains "$(cat "$W_MAIN/state/.wake-queue" 2>/dev/null)" "secondmate-stopped-sm-" "the wake was not queued durably"
  out=$(watcher_tick)
  assert_equals "$out" "" "the same stop episode woke the parent twice"

  backdate_idle 5000
  out=$(watcher_tick)
  assert_equals "$out" "WAKE check: secondmate sm stopped with standing work" "a new stop episode did not wake the parent"

  fm_mandate_rest_write "$W_SM/state" $(( $(date +%s) + 3600 )) 2026-11-25T13:00Z "import window" "$(date +%s)"
  backdate_idle 6000
  out=$(watcher_tick)
  assert_equals "$out" "" "a resting mate woke the parent"
  assert_absent "$W_MAIN/state/.secondmate-stopped-woken-sm" "the episode marker survived the end of the stop"
  pass "the parent watcher wakes once per stop episode and never for a resting mate"
}

test_rest_command_records_and_reports_a_bounded_rest() {
  local out until rc
  new_world rest-cmd drive
  out=$(rest --reason "nothing to do") && fail "a rest with no date was accepted: $out"
  assert_absent "$W_SM/state/.mandate-rest" "a refused rest wrote a record"
  out=$(rest --until "$(iso_in 3600)") && fail "a rest with no reason was accepted: $out"
  out=$(rest --until "$(iso_in 90000)" --reason "long break") && fail "a rest past 24 hours was accepted: $out"
  assert_contains "$out" "24 hours" "the long-rest refusal did not name the cap"
  out=$(rest --until "$(iso_in -120)" --reason "late") && fail "a rest in the past was accepted: $out"
  out=$(rest --until tomorrow --reason "vague") && fail "a non-UTC rest date was accepted: $out"
  assert_absent "$W_SM/state/.mandate-rest" "a refused rest wrote a record"
  out=$(FM_HOME="$W_MAIN" "$ROOT/bin/fm-secondmate-rest.sh" --until "$(iso_in 3600)" --reason "main" 2>&1) \
    && fail "a main home declared a rest: $out"

  until=$(iso_in 7200)
  rc=0
  out=$(rest --until "$until" --reason "waiting on the weekly import") || rc=$?
  assert_equals "$rc" 0 "a valid rest was refused: $out"
  fm_mandate_rest_active "$W_SM/state" "$(date +%s)" || fail "the valid rest was not recorded as active"
  assert_equals "$MANDATE_REST_REASON" "waiting on the weekly import" "the record lost the reason"
  assert_contains "$(tail -1 "$W_MAIN/state/sm.status")" "paused [at=" "the parent line is not a stamped pause"
  assert_contains "$(tail -1 "$W_MAIN/state/sm.status")" "until $until: waiting on the weekly import" \
    "the parent line did not carry the rest date and reason"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$ROOT/bin/fm-classify-lib.sh"
  assert_equals "$(status_paused_until "$(tail -1 "$W_MAIN/state/sm.status")")" "$MANDATE_REST_UNTIL_EPOCH" \
    "the parent cannot read the rest date from the pause line"
  pass "the rest command refuses an undated, unexplained, or over-long rest and reports a valid one"
}

# Run a secondmate home's own standing-mandate tick in a subshell that sourced
# the watcher for that home; prints each wake reason the tick raised.
mate_tick() {
  (
    export FM_HOME="$W_SM" FM_STATE_OVERRIDE="$W_SM/state"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-watch.sh"
    # shellcheck disable=SC2329 # called by the sourced tick
    wake() { printf 'WAKE %s\n' "$1"; }
    standing_mandate_tick || printf 'TICK FAILED\n'
  )
}

set_posture() {  # <canonical-posture>
  printf '%s\n' "$1" > "$W_SM/config/secondmate-posture"
}

age_marker() {  # <file> <episode-seconds-ago> <count> <last-seconds-ago>
  local now
  now=$(date +%s)
  printf '%s %s %s\n' "$(( now - $2 ))" "$3" "$(( now - $4 ))" > "$1"
}

test_wake_backoff_is_15m_then_1h_then_4h() {
  local s=1000000
  fm_standing_mandate_wake_due "$s" 0 0 $(( s + 899 )) && fail "the first wake came before 15 minutes"
  fm_standing_mandate_wake_due "$s" 0 0 $(( s + 900 )) || fail "the first wake did not come at 15 minutes"
  fm_standing_mandate_wake_due "$s" 1 $(( s + 900 )) $(( s + 900 + 3599 )) && fail "the second wake came before 1 hour"
  fm_standing_mandate_wake_due "$s" 1 $(( s + 900 )) $(( s + 900 + 3600 )) || fail "the second wake did not come at 1 hour"
  fm_standing_mandate_wake_due "$s" 2 $(( s + 5000 )) $(( s + 5000 + 14399 )) && fail "a later wake came before 4 hours"
  fm_standing_mandate_wake_due "$s" 5 $(( s + 5000 )) $(( s + 5000 + 14400 )) || fail "a later wake did not come at 4 hours"
  fm_standing_mandate_wake_due "" 0 0 "$s" && fail "a missing episode start was due"
  pass "the standing-mandate wake backs off 15 minutes, then 1 hour, then every 4 hours"
}

test_drive_mate_wakes_itself_on_the_backoff() {
  local out
  new_world self-drive drive
  set_posture drive
  backdate_idle 600
  assert_equals "$(mate_tick)" "" "a drive mate woke itself before 15 minutes idle"

  backdate_idle 960
  out=$(mate_tick)
  assert_equals "$out" "WAKE check: standing mandate idle: 16m with no work in flight, no captain question, no dated hold" \
    "an idle drive mate did not wake itself"
  assert_contains "$(cat "$W_SM/state/.wake-queue" 2>/dev/null)" "standing-mandate-idle-" "the wake was not queued durably"
  assert_equals "$(mate_tick)" "" "the drive mate woke again before the 1 hour back-off"

  age_marker "$W_SM/state/.mandate-idle-wake" 4600 1 3700
  printf '%s\n' "$(( $(date +%s) - 4600 ))" > "$W_SM/state/.idle-since"
  publish_summary
  assert_contains "$(mate_tick)" "WAKE check: standing mandate idle: 76m" "the second wake did not come after 1 hour"
  assert_equals "$(mate_tick)" "" "the drive mate woke again before the 4 hour back-off"

  fm_mandate_rest_write "$W_SM/state" $(( $(date +%s) + 3600 )) 2026-11-25T13:00Z "import window" "$(date +%s)"
  age_marker "$W_SM/state/.mandate-idle-wake" 30000 2 20000
  printf '%s\n' "$(( $(date +%s) - 30000 ))" > "$W_SM/state/.idle-since"
  publish_summary
  assert_equals "$(mate_tick)" "" "a resting drive mate woke itself"

  set_posture routed
  rm -f "$W_SM/state/.mandate-rest"
  publish_summary
  assert_equals "$(mate_tick)" "" "a routed mate woke itself"
  pass "an idle drive mate wakes itself on the back-off, and a resting or routed mate does not"
}

hold_offer() {  # <task-id>
  FM_HOME="$W_SM" "$ROOT/bin/fm-captain-hold.sh" hold "$1" --title "Next work" \
    --reason "Which item should start next?" --option a=APP-1 --option b=APP-2 --no-link >/dev/null 2>&1 \
    || fail "the offer card hold failed"
}

test_offer_cards_read_from_the_summary() {
  local out
  new_world offers 'duty offered-item-taken'
  hold_offer next-work
  publish_summary
  out=$(fm_standing_mandate_offer_cards "$W_SM/state/home-summary.json" "$(date +%s)") || fail "a fresh summary was unreadable"
  assert_equals "$out" "complete"$'\n'"next-work" "the open offer card was not listed once"
  fm_standing_mandate_offer_cards "$W_SM/state/home-summary.json" $(( $(date +%s) + 4000 )) >/dev/null \
    && fail "a summary older than 30 minutes was read"
  jq -c '.omitted=[{surface:"queued"}]' "$W_SM/state/home-summary.json" > "$TMP_ROOT/partial.json"
  assert_equals "$(fm_standing_mandate_offer_cards "$TMP_ROOT/partial.json" "$(date +%s)" | head -1)" partial \
    "a summary that omitted holds did not read as partial"
  pass "offer cards come from a fresh summary, with a partial summary marked"
}

test_intake_mate_wakes_when_an_offer_is_taken() {
  local out
  new_world intake 'duty offered-item-taken'
  set_posture 'duty offered-item-taken'
  hold_offer next-work
  publish_summary
  assert_equals "$(mate_tick)" "" "an open offer card woke the mate"
  assert_equals "$(cat "$W_SM/state/.offered-open")" next-work "the open offer card was not recorded"

  printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$W_SM/data/backlog.md"
  publish_summary
  out=$(mate_tick)
  assert_equals "$out" "WAKE check: offered-item-taken: next-work left the captain hold" \
    "a taken offer card did not wake the mate"
  assert_equals "$(mate_tick)" "" "a taken card woke the mate twice"

  age_marker "$W_SM/state/.offered-refill-wake" 4000 1 3700
  assert_equals "$(mate_tick)" "WAKE check: offered-item-taken: no offer card is open" \
    "an empty offer queue did not wake the mate after 1 hour"

  hold_offer more-work
  publish_summary
  assert_equals "$(mate_tick)" "" "a fresh offer card still woke the mate"
  assert_absent "$W_SM/state/.offered-refill-wake" "a fresh offer card did not end the empty episode"
  pass "the intake mate wakes when an offer card leaves the hold and while none is open"
}

test_intake_mate_wakes_with_no_offer_open() {
  new_world intake-empty 'duty offered-item-taken'
  set_posture 'duty offered-item-taken'
  publish_summary
  assert_equals "$(mate_tick)" "" "an empty offer queue woke the mate at once"
  age_marker "$W_SM/state/.offered-refill-wake" 1000 0 0
  assert_equals "$(mate_tick)" "WAKE check: offered-item-taken: no offer card is open" \
    "an empty offer queue did not wake the mate after 15 minutes"
  fm_mandate_rest_write "$W_SM/state" $(( $(date +%s) + 3600 )) 2026-11-25T13:00Z "queue drained" "$(date +%s)"
  age_marker "$W_SM/state/.offered-refill-wake" 9000 1 5000
  assert_equals "$(mate_tick)" "" "a resting intake mate woke itself"
  pass "an intake mate with no offer open wakes after 15 minutes unless it rests"
}

sup_mandate() {  # prints FM_SUP_MANDATE FM_SUP_NEEDED for the mate home
  (
    # shellcheck source=bin/fm-supervision-lib.sh
    . "$ROOT/bin/fm-supervision-lib.sh"
    fm_supervision_status "$W_SM/state"
    printf '%s %s\n' "$FM_SUP_MANDATE" "$FM_SUP_NEEDED"
  )
}

test_standing_work_is_a_supervision_need() {
  new_world sup drive
  set_posture drive
  publish_summary
  assert_equals "$(sup_mandate)" "true true" "an idle drive mate did not need supervision"
  fm_mandate_rest_write "$W_SM/state" $(( $(date +%s) + 3600 )) 2026-11-25T13:00Z "import window" "$(date +%s)"
  assert_equals "$(sup_mandate)" "false false" "a resting drive mate still needed supervision"
  rm -f "$W_SM/state/.mandate-rest"
  set_posture 'duty offered-item-taken'
  assert_equals "$(sup_mandate)" "true true" "an intake mate did not need supervision"
  set_posture routed
  assert_equals "$(sup_mandate)" "false false" "a routed mate needed supervision"
  rm -f "$W_SM/.fm-secondmate-home"
  set_posture drive
  assert_equals "$(sup_mandate)" "false false" "a home with no secondmate marker needed supervision"
  pass "a drive or intake mate with no rest needs a live watcher, and other homes do not"
}

fm_test_run test_rest_record_is_active_only_until_its_date test_rest_command_records_and_reports_a_bounded_rest test_stopped_rule_needs_every_condition \
  test_summary_keeps_one_idle_epoch_per_episode test_board_shows_a_stopped_drive_mate_only \
  test_watcher_wakes_once_per_stop_episode test_wake_backoff_is_15m_then_1h_then_4h \
  test_drive_mate_wakes_itself_on_the_backoff test_offer_cards_read_from_the_summary \
  test_intake_mate_wakes_when_an_offer_is_taken test_intake_mate_wakes_with_no_offer_open \
  test_standing_work_is_a_supervision_need
