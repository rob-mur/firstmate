#!/usr/bin/env bash
# Shared durable, supervisor-facing outcome publication for a confirmed merge.
#
# Both a merge performed by this home and a merge detected by its existing poll
# use this operation, so neither outcome depends on an agent remembering it.
# This operation publishes the poll's local actionable row; the watcher
# immediately delivers that row as observation handling, not a second outcome
# path.
#
# The destination is the home's role, never the caller's choice:
#   - a secondmate home reports upward on its parent channel, resolved and
#     appended through bin/fm-parent-channel-lib.sh under its channel contract;
#   - a main home reports to the captain through the durable wake queue.
# A poll observed in a secondmate home also receives a local durable wake after
# the upward write, so the mate can handle its own poll observation.
# No new state file and no new transport are involved.
#
# Normal operation deduplicates the task's latest canonical PR identity through
# the merge-notification marker owned by bin/fm-pr-lib.sh. Main-home wake keys
# also include that PR identity so distinct PRs for a reused task remain
# distinct in queue presentation. The outcome is published before the marker
# is committed, so a failed commit stays eligible for at-least-once retry and
# may rarely duplicate rather than leave a merge silent.
#
# fm_pr_untrack_outcome_report below is the same kind of outcome for a PR the
# poll stopped tracking without a merge.
#
# Sourced by bin/fm-pr-merge.sh, bin/fm-watch.sh, and tests. No side effects on
# source beyond its sourced libraries.

_FM_MERGE_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-parent-channel-lib.sh"

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_ALREADY_RECORDED=false

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin> [authority]
#
# <origin> says who observed the merge, because that decides whether the
# existing poll path also needs a local wake:
#   self - this home performed the merge.
#   poll - this home's merge poll detected the merge, so the canonical outcome
#          also wakes this home after any upward hop needed by a secondmate.
#   extra - this home merged one of the task's extra PRs (pr_extra=, recorded
#          by bin/fm-pr-check.sh --extra). The task's canonical PR is still
#          open, so this outcome neither reads nor marks the merge-notification
#          marker, writes no ledger merged entry, and never uses the "merge
#          landed" wake that starts cleanup: a secondmate reports
#          "done [key=merged-extra-<id>-<number>]: merged extra PR <url> for
#          <id>" upward, and a main home queues a "check: extra PR merged:"
#          wake, each deduplicated by its exact line or wake key.
# Optional <authority> is away, attended, or external (the retired yolo and
# away-grant values are still accepted for a persisted authority written before
# the words model landed). Away, external, and the retired tags are appended to
# the ledger line; attended remains untagged. The merge entrypoint supplies its
# authority after forge acceptance, while the poll supplies the persisted
# identity-bound value or external when no matching record proves that this
# home authorized the merge.
#
# Returns 0 when the outcome is recorded (or already was), 2 on an invalid
# request, 3 when this home's own role or parent binding cannot be read well
# enough to say where the outcome belongs, and 1 on any other failure to
# record. A caller that has already merged must report a non-zero return rather
# than treat it as success: the merge landed and the record did not.
fm_merge_outcome_report() {  # <home> <state> <task-id> <pr-url> <origin> [authority]
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local authority=${6-} suffix=
  local self_rc=0 destination='' line lock status=0
  local provider host path number
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  case "$origin" in self|poll|extra) ;; *) return 2 ;; esac
  case "$authority" in
    away|external|yolo|away-grant) suffix=" $authority" ;;
    attended|'') ;;
    *) return 2 ;;
  esac
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  [ -d "$state" ] && [ ! -L "$state" ] || return 1

  if destination=$(fm_parent_channel_destination "$home" "$state"); then
    line="done [key=merged-$id]: merged $id $FM_PR_URL$suffix"
    [ "$origin" != extra ] \
      || line="done [key=merged-extra-$id-$number]: merged extra PR $FM_PR_URL for $id$suffix"
  else
    self_rc=$?
    [ "$self_rc" -eq 1 ] || return 3
    destination=''
  fi

  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  if [ "$origin" = extra ]; then
    if [ -n "$destination" ]; then
      fm_parent_channel_append_once "$destination" "$(status_stamp_line "$line")" || return 1
    else
      fm_wake_append check "merged-extra-$id-$FM_PR_URL" \
        "check: extra PR merged: $id $FM_PR_URL$suffix (the task's recorded PR is still open)" || return 1
    fi
    return 0
  fi
  lock="$state/$id.pr-poll-merge-notified.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if fm_pr_poll_merge_already_notified "$state" "$id" \
    "$provider" "$host" "$path" "$number"; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_MERGE_OUTCOME_ALREADY_RECORDED=true
    fm_lock_release "$lock"
    return 0
  fi

  if [ -n "$destination" ]; then
    fm_parent_channel_append_once "$destination" "$(status_stamp_line "$line")" || status=1
  fi
  if [ "$status" -eq 0 ] && { [ "$origin" = poll ] || [ -z "$destination" ]; }; then
    fm_wake_append check "merged-$id-$FM_PR_URL" \
      "check: merge landed: $id $FM_PR_URL$suffix" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_merge_mark_notified "$state" "$id" \
      "$provider" "$host" "$path" "$number" || status=1
  fi
  fm_lock_release "$lock"
  # Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
  [ ! -e "${FM_CONFIG_OVERRIDE:-$home/config}/fleet-ledger" ] || [ "$status" -ne 0 ] || FM_HOME=$home FM_STATE_OVERRIDE=$state "$_FM_MERGE_OUTCOME_LIB_DIR/fm-fleet-ledger.sh" merged "$id" pr "$FM_PR_URL" || true
  return "$status"
}

# fm_pr_untrack_outcome_report <home> <state> <task-id> <pr-url> <reason>
#
# The one plain outcome for a poll that stopped tracking a task's PR without a
# merge, routed by the home's role like the merge outcome above. <reason> is
# closed (closed without merging) or ready (it left draft, so it is ready for
# human review). A secondmate reports "done [key=untracked-<id>]: ..." on its
# parent channel and also wakes itself; a main home queues one
# "check: stopped tracking:" wake keyed by the task and PR. bin/fm-watch.sh
# calls this before it writes the untracked marker (bin/fm-pr-lib.sh), and it
# skips the call once that marker matches, so the outcome is told once.
# Stopping tracking never merges, cleans up, or discards anything.
#
# Returns 0 when recorded, 2 on an invalid request, 3 when this home's role or
# parent binding cannot be read, and 1 on any other failure to record.
fm_pr_untrack_outcome_report() {  # <home> <state> <task-id> <pr-url> <reason>
  local home=$1 state=$2 id=$3 url=$4 reason=$5 text destination='' rc=0
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  case "$reason" in
    closed) text='it was closed without merging' ;;
    ready) text='it left draft and is ready for human review' ;;
    *) return 2 ;;
  esac
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  destination=$(fm_parent_channel_destination "$home" "$state") || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 1 ] || return 3
    destination=''
  fi
  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  if [ -n "$destination" ]; then
    fm_parent_channel_append_once "$destination" \
      "$(status_stamp_line "done [key=untracked-$id]: stopped tracking $id $FM_PR_URL: $text")" || return 1
  fi
  fm_wake_append check "untracked-$id-$FM_PR_URL" \
    "check: stopped tracking: $id $FM_PR_URL - $text" || return 1
}
