#!/usr/bin/env bash
# Tests for the captain's durable board priority (bin/fm-board-priority.sh):
# the runner records a priority the bearings board sent, once per result and
# only from the board's own source, and recording drops ids whose task or
# decision is closed while keeping every id that is open, held, or uncertain.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRIO="$ROOT/bin/fm-board-priority.sh"
TMP_ROOT=$(fm_test_tmproot fm-board-priority)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/.lavish"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '<html><body>board</body></html>\n' > "$home/.lavish/bearings-board.html"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

home_env() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" "$@"
}

run_lavish() { local home=$1; shift; home_env "$home" "$ROOT/bin/fm-procevent-lavish.sh" "$@"; }
run_procevent() { local home=$1; shift; home_env "$home" "$ROOT/bin/fm-procevent.sh" "$@"; }
run_prio() { local home=$1; shift; home_env "$home" "$PRIO" "$@"; }
tasks_in() { local home=$1; shift; (cd "$home" && tasks-axi "$@"); }

stored() {  # <home>
  run_prio "$1" show | paste -sd, -
}

# One published Lavish poll response carrying the board's priority annotation,
# in the shape the board template queues: tag `priority`, the readable order,
# then the fm-bearings-priority.v1 context.
priority_result() {  # <keys-json-array> <order-json-array>
  local ctx
  ctx=$(jq -cn --argjson k "$1" --argjson o "$2" '{schema:"fm-bearings-priority.v1",keys:$k,order:$o}')
  ctx=${ctx//\"/\\\"}
  cat <<OUT
session:
  status: feedback
  session_ended: false
prompts[1]{tag,text,prompt}:
  "priority","board priority","Board priority, highest first\n\nContext data:\n$ctx"
OUT
}

source_script() {  # <path> <result-text>
  {
    printf '#!/usr/bin/env bash\n'
    printf "cat <<'OUT'\n%s\nOUT\n" "$2"
  } > "$1"
  chmod +x "$1"
}

test_adapter_reads_the_last_priority_of_a_result() {
  local home result out status
  home=$(make_home adapter)
  result="$home/two.result"
  cat > "$result" <<'OUT'
session:
  status: feedback
  session_ended: false
prompts[3]{tag,text,prompt}:
  "priority","p1","Board priority\n\nContext data:\n{\"schema\":\"fm-bearings-priority.v1\",\"keys\":[\"a\",\"b\"],\"order\":[\"a\"]}"
  "choice","x","Context data: {\"schema\":\"fm-bearings-answer.v1\",\"question\":\"a\",\"selection\":\"x\",\"note\":\"\"}"
  "priority","p2","Board priority\n\nContext data:\n{\"schema\":\"fm-bearings-priority.v1\",\"keys\":[\"b\",\"a\"],\"order\":[\"b\"]}"
OUT
  out=$(run_lavish "$home" priority "$result") || fail "the adapter refused a complete priority result: $out"
  assert_equals '{"keys":["b","a"],"order":["b"],"schema":"fm-bearings-priority.v1"}' "$(printf '%s' "$out" | jq -cS .)" \
    "the adapter did not report the last priority the board sent"

  cat > "$result" <<'OUT'
session:
  status: feedback
  session_ended: false
prompts[1]{tag,text,prompt}:
  "choice","x","Context data: {\"schema\":\"fm-bearings-answer.v1\",\"question\":\"a\",\"selection\":\"x\",\"note\":\"\"}"
OUT
  out=$(run_lavish "$home" priority "$result") || fail "the adapter refused a result with no priority"
  assert_equals "" "$out" "a result with no priority reported one"

  cat > "$result" <<'OUT'
session:
  status: feedback
  session_ended: false
prompts[2]{tag,text,prompt}:
  "priority","p1","Board priority\n\nContext data:\n{\"schema\":\"fm-bearings-priority.v1\",\"keys\":[\"a\"],\"order\":[]}"
OUT
  status=0
  run_lavish "$home" priority "$result" >/dev/null 2>&1 || status=$?
  assert_equals 3 "$status" "an incomplete result was not refused as incomplete"
  pass "the adapter reports the last priority a result carries, nothing when none, and refuses an incomplete result"
}

test_runner_records_the_board_priority() {
  local home board sid stub out
  home=$(make_home runner)
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  board="$home/.lavish/bearings-board.html"
  sid=$(run_lavish "$home" source-id "$board") || fail "no source id for the board"
  stub="$home/board-source.sh"
  source_script "$stub" "$(priority_result '["d2","d1","t1"]' '["d2","d1"]')"
  run_procevent "$home" register lavish "$sid" -- "$stub" >/dev/null \
    || fail "could not register the board source"
  out=$(run_procevent "$home" start "$sid" 2>&1) || fail "the board source runner did not complete: $out"
  assert_contains "$out" "$sid.1.result" "the board priority was never durably captured: $out"
  assert_contains "$out" "priority-fed: $sid" "the runner did not record the board priority: $out"
  assert_equals "d2,d1,t1" "$(stored "$home")" "the recorded ranking is not the board's order"
  pass "the runner records a priority the board sent"
}

test_runner_ignores_a_priority_from_another_source() {
  local home other sid stub out
  home=$(make_home foreign)
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  other="$home/.lavish/review.html"
  printf '<html></html>\n' > "$other"
  sid=$(run_lavish "$home" source-id "$other") || fail "no source id for the review page"
  stub="$home/review-source.sh"
  source_script "$stub" "$(priority_result '["x1"]' '["x1"]')"
  run_procevent "$home" register lavish "$sid" -- "$stub" >/dev/null \
    || fail "could not register the review source"
  out=$(run_procevent "$home" start "$sid" 2>&1) || fail "the review source runner did not complete: $out"
  assert_contains "$out" "$sid.1.result" "the review result was never captured: $out"
  assert_not_contains "$out" "priority-fed:" "a page other than the board recorded a priority: $out"
  assert_equals "" "$(stored "$home")" "a priority from another page reached the ranking"
  pass "only the board's own source records a priority"
}

# record is the runner's intake; replaying a result or delivering an older one
# after a newer one must not change the ranking.
test_record_is_once_per_result_and_never_goes_back() {
  local home sid inbox r1 r2 r3 status
  home=$(make_home replay)
  sid=$(run_lavish "$home" source-id "$home/.lavish/bearings-board.html") || fail "no board source id"
  inbox="$home/state/procevent-inbox"
  mkdir -p "$inbox"
  r1="$inbox/$sid.1.result"
  r2="$inbox/$sid.2.result"
  priority_result '["b","a"]' '["b","a"]' > "$r1"
  priority_result '["a","b"]' '["a","b"]' > "$r2"

  run_lavish "$home" priority "$r2" | run_prio "$home" record --source-id "$sid" --result "$r2" >/dev/null \
    || fail "record refused the board's newest result"
  assert_equals "a,b" "$(stored "$home")" "record did not store the board's order"

  status=0
  run_lavish "$home" priority "$r1" | run_prio "$home" record --source-id "$sid" --result "$r1" >/dev/null 2>&1 || status=$?
  assert_not_equals 0 "$status" "record reported an older result as recorded"
  assert_equals "a,b" "$(stored "$home")" "an older result overwrote a newer ranking"

  run_prio "$home" set z >/dev/null || fail "set refused a manual ranking"
  status=0
  run_lavish "$home" priority "$r2" | run_prio "$home" record --source-id "$sid" --result "$r2" >/dev/null 2>&1 || status=$?
  assert_not_equals 0 "$status" "record reported a replayed result as recorded"
  assert_equals "z" "$(stored "$home")" "a replayed result was recorded twice"

  # A capture inbox that was cleared restarts its numbering: the recorded
  # result is gone, so a new first result is newer, not older.
  rm -f -- "$r1" "$r2"
  r3="$inbox/$sid.1.result"
  priority_result '["c"]' '["c"]' > "$r3"
  run_lavish "$home" priority "$r3" | run_prio "$home" record --source-id "$sid" --result "$r3" >/dev/null \
    || fail "record refused a new result after the inbox restarted its numbering"
  assert_equals "z,c" "$(stored "$home")" "a new result after a cleared inbox was not recorded"

  status=0
  printf '%s\n' '{"schema":"fm-bearings-priority.v1","keys":["q"],"order":["q"]}' \
    | run_prio "$home" record --source-id lavish-0000000000000000 --result "$r3" >/dev/null 2>&1 || status=$?
  assert_not_equals 0 "$status" "record accepted a source that is not the board"
  assert_equals "z,c" "$(stored "$home")" "a source that is not the board changed the ranking"
  pass "record stores each board result once and never an older one"
}

add_task() {  # <home> <id> [state]
  tasks_in "$1" add "$2" "Task $2" --repo sample >/dev/null || fail "could not add $2"
  case "${3:-queued}" in
    in_flight) tasks_in "$1" start "$2" >/dev/null || fail "could not start $2" ;;
    done)
      tasks_in "$1" start "$2" >/dev/null || fail "could not start $2"
      tasks_in "$1" "done" "$2" >/dev/null || fail "could not finish $2"
      ;;
  esac
}

test_recording_drops_closed_ids_and_keeps_open_ones() {
  local home ctx mate
  home=$(make_home prune)
  add_task "$home" open-task
  add_task "$home" busy-task in_flight
  add_task "$home" held-call
  tasks_in "$home" hold held-call --reason "pick a route" --kind captain >/dev/null \
    || fail "could not hold the captain call"
  add_task "$home" done-task "done"
  add_task "$home" asker in_flight
  add_task "$home" mate-task "done"
  cat > "$home/data/done-archive.md" <<'EOF'
- [x] archived-task - Task archived-task
- [x] archived-asker - Task archived-asker
EOF
  {
    printf 'needs-decision [key=still-open]: which way?\n'
    printf 'needs-decision [key=answered]: this or that?\n'
    printf 'resolved [key=answered]: this\n'
  } > "$home/state/asker.status"
  mate="$TMP_ROOT/mate-home"
  mkdir -p "$mate/data"
  printf '## Queued\n\n- [ ] mate-task - a task in the mate home\n' > "$mate/data/backlog.md"
  printf -- '- cd - a second mate (home: %s; scope: things; projects: ; added 2026-11-01)\n' "$mate" \
    > "$home/data/secondmates.md"

  ctx="$home/ctx.json"
  jq -n '{schema:"fm-bearings-priority.v1",
    keys:["status.asker.answered","held-call","done-task","archived-task","status.asker.still-open",
          "status.archived-asker.default","review.archived-task","review.done-task",
          "status.cd.cd-1-decisions","cd/mate-task","mate-task","unknown-id","contribution.done-task",
          "open-task","busy-task"],
    order:["status.asker.answered","held-call","done-task","archived-task","status.asker.still-open",
           "status.archived-asker.default","review.archived-task","review.done-task",
           "status.cd.cd-1-decisions","cd/mate-task","mate-task","unknown-id","contribution.done-task"]}' > "$ctx"
  run_prio "$home" set --from-ctx "$ctx" || fail "the board priority was refused"
  assert_equals "held-call,status.asker.still-open,review.done-task,status.cd.cd-1-decisions,cd/mate-task,mate-task,unknown-id,contribution.done-task,open-task,busy-task" \
    "$(stored "$home")" "recording did not drop exactly the closed ids"
  pass "recording drops closed tasks and answered decisions and keeps open, held, and uncertain ids"
}

test_an_unreadable_backlog_drops_nothing() {
  local home ctx
  home=$(make_home unreadable)
  cat > "$home/data/done-archive.md" <<'EOF'
- [x] archived-task - Task archived-task
EOF
  printf 'backend = "nonexistent-backend"\n' > "$home/.tasks.toml"
  ctx="$home/ctx.json"
  jq -n '{schema:"fm-bearings-priority.v1",keys:["archived-task","other"],order:["archived-task"]}' > "$ctx"
  run_prio "$home" set --from-ctx "$ctx" 2>/dev/null || fail "the board priority was refused"
  assert_equals "archived-task,other" "$(stored "$home")" "an unreadable backlog still dropped ids"
  pass "an unreadable backlog keeps every id"
}

fm_test_run \
  test_adapter_reads_the_last_priority_of_a_result \
  test_runner_records_the_board_priority \
  test_runner_ignores_a_priority_from_another_source \
  test_record_is_once_per_result_and_never_goes_back \
  test_recording_drops_closed_ids_and_keeps_open_ones \
  test_an_unreadable_backlog_drops_nothing
