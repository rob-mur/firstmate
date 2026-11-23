#!/usr/bin/env bash
# fm-bearings-snapshot.sh - compact, bounded, TOON-by-default bearings projection.
#
# A thin wrapper OVER the canonical bin/fm-fleet-snapshot.sh. It does not parse
# fleet state itself: it shells out to `fm-fleet-snapshot.sh --json`, projects that
# complete structured contract down to the small set of fields a "pick up where I
# left off" read needs, and renders TOON at the output boundary. The internal data
# model stays JSON (`--json` prints it verbatim); TOON is the default agent-facing
# format per the AXI standard, and TOON/JSON are parity representations of the same
# projected model. The projection is view-specific: it DROPS fields from the bearings
# output, it never removes them from - or otherwise weakens - the canonical snapshot,
# which stays complete.
# Open decision rows retain a bounded summary for overview use and a full question
# for decision presentation, including all options recorded in the hold reason.
#
# By default the canonical snapshot performs bounded concurrent remote-ledger reads
# for registered remote homes under one shared collection budget and may atomically
# refresh its parent-side ledger cache. It MAY surface PR URLs already recorded in
# task meta (recorded_prs), but performs no live GitHub discovery or checks. Live PR
# discovery/checks happen ONLY under --include-prs; all gh coupling lives in that
# branch and never in the canonical snapshot. The default output states explicitly
# (the prs: line and the omitted[] surfaces) what was not requested, so an absence is
# never ambiguous.
#
# --include-mrs lists the captain's open GitLab MRs - every one they authored, Draft
# included, and those they are a requested reviewer on that this view shows
# nowhere else - as
# open_mrs{key,repo,title,url,state,updated} with one state line each (merge state,
# CI, approvals, unresolved threads, last activity). It makes three read-only calls
# against the host in FM_BEARINGS_GITLAB_HOST or glab's configured host - `glab api
# user` for the captain's id, `merge_requests?scope=created_by_me&state=opened` and
# `merge_requests?scope=all&state=opened&reviewer_id=<id>` - plus one detail, one
# approvals and one reviewers read for every MR it lists, at most
# FM_BEARINGS_MR_DETAIL_PARALLEL MRs at a time, each call bounded by
# FM_BEARINGS_MR_TIMEOUT seconds; at most FM_BEARINGS_MRS rows are kept.
# Someone else's MR the captain has already reviewed, requested changes on or
# approved waits on its author, so its state line opens with `waiting on <author>
# (you reviewed|you requested changes|you approved)`; an unreviewed (first or
# re-requested) review, the captain's own MR, or a failed reviewers read adds
# no wait owner.
# GitLab keeps an MR open after its project is archived, so one bounded
# `projects/<id>` read per distinct project (at most FM_BEARINGS_MR_PROJECT_MAX)
# drops the MRs of an archived project; a project it cannot read keeps its MRs.
# The captain's own MR is always listed, so it stays on the board after the
# decision card that named it goes. A review MR is covered, and left out, only
# when its exact URL or full reference (group/project!iid)
# appears where the board shows it: a decision (its text, or the PR its own task
# recorded, which its card links), a queued or landed row, a contribution card,
# or the underway row of the task that records that MR, by its pr_url or its
# visible name or `doing` text. It is never covered by a fuzzy match, a Done record, a status
# line the view cuts short, a recorded PR no row shows, or a wait that another
# task's underway row names, since the board would then not show it as its own. A
# missing glab, no host, no auth, a failure or a timeout leaves open_mrs out, sets
# the mrs: line to `unavailable (...)`, logs one stderr line, and exits 0.
#
# This wrapper consumes canonical status decisions plus canonically normalized
# backlog roles, unresolved blockers, and captain actionability.
# Contributions project cached coverage and required actors from fm-contributions.sh;
# only captain rows are exposed, with counts for the other actors and unmeasured homes. It never infers
# decisions from report or visual-review prose or reimplements snapshot semantics.
# Underway (in_flight) projects every main live worker plus every in-flight
# child, working, paused, blocked or otherwise, from every readable secondmate
# ledger, independently of that home's bearings_state. A ledger from an older
# producer without in_flight_children contributes its active children plus its
# child-state holds. A home served from its last-good cached ledger (freshness
# "cached") keeps those rows; its secondmates[] row carries stale_note ("could
# not read <id>, last seen <time>") and read_failure, each of its underway rows'
# doing starts with that note, and each of its decisions_open rows carries it as
# note. Each row's name is the durable task title when nonblank and
# its durable task id otherwise, so renderers always receive a task-identifying
# label instead of having to substitute run status. A held main task keeps its
# row while it works, while the hold is the captain's (its decision card can go
# between cards) or while it has a PR or MR; only a PR-less external hold leaves
# Underway for its charted gate row. Its pr_url
# is the PR or MR the task recorded (pr= meta, else its backlog PR, title link or
# hold link, else the PR or MR its status log names most often), and its doing names that PR or MR ("MR !900: ...") and says what the
# task waits on in plain words: the current state when read from the status
# log, a review park or a known pipeline step, else the latest status line -
# never a raw pane or source-less reading such as "harness busy". A home classified
# captain_decision because it has an open
# captain hold still contributes each working child as its own Underway row;
# the home row on secondmates[] keeps the decision and gate classification.
# Captain-hold placement follows the canonical snapshot's hold_bucket and
# nothing else, with one exception: a blocked or aged hold whose reason asks a
# question (contains a question mark) is promoted to decisions_open so a real
# question is never hidden in a gate bucket. Every captain-hold row, main or
# secondmate, carries its hold_until and hold_bucket so a consumer can tell a
# dated deferral from a live call, plus hold_set, hold_reconciled and origin for the hand-off
# check below (a decision handed to a worker gains handed_* fields), and the
# choices, answers, notes, and report_path bin/fm-fleet-snapshot.sh documents. A needs-decision or blocked status
# on a task under way, main or secondmate, also reaches decisions_open as a
# source:"status" row with task, decision_key and mate for routing the answer,
# plus reason_earlier when the same key was raised before with other text; a
# secondmate home's row takes its text from the uncut question that home
# publishes, so a question past the bounded summary still reaches the board. A
# secondmate question the parent status log shows (the wake drain's open
# decisions) is read from the parent task itself, so it reaches the board even
# when the home summary is invalid; it is skipped only when the home already
# lists the same question under the same key or as an open question of the
# child task that key names. Only a resolved line closes it: when the home is
# valid with no active work the row stays, with note "<id> reports no active
# work; key not resolved". A finished task whose last
# event names a live review page becomes a source:"review-page" row. The
# buckets are total and mutually exclusive, so every captain hold appears in
# exactly one decision bucket and none can fall through both. An actively worked
# held task may also appear in Underway. A "live" hold is a default Captain's Call
# entry; "blocked", "dated", and "aged" leave the default Captain's Call, render
# as Charted Next gates stating why (the blocking work, the until date, or the
# floored age), and are counted in omitted[].
# --all-decisions reveals every captain hold available within the bounded snapshot
# and drops its gate, so a hold is never in both Captain's Call and Charted Next.
# Aging is a projection safety net only; the durable
# deferral remains re-holding with --until.
#
# Ordinary Charted Next gates are ordered by durable filed date, newest first,
# before the FM_BEARINGS_GATES bound is applied. Gates without a comparable filed
# date keep their input order after dated gates. The synthetic (return-catchup)
# posture row is reserved ahead of that ordering and bound so it always surfaces.
# A gate's title and reason are shortened for the compact chat digest; --fields
# gate-text adds title_full and reason_full to every gate row, carrying the same
# text with only whitespace collapsed, for surfaces such as the /bearings lavish
# board that must never truncate it.
#
# Main-home inventory validity comes from the canonical snapshot's main_inventory
# object (orphan structured in-flight without meta, unstructured current rows).
# Bearings never invents Underway rows from backlog-only ids; it discloses those
# gaps in omitted[] and, when invalid, a Charted Next gate line so the four-section
# chat cannot claim an empty fleet while main current state is broken.
#
# An open away-return catch-up is disclosed the same way, as a single action-free
# (return-catchup) gate row naming the blockers left to clear or the reason the
# catch-up was retained. Reporting is not ordinary captain work, so the gate never
# suppresses the digest; an ACTIVE away window still refuses, because the right
# answer to a chat bearings read there is to run the return first. The board
# build passes --during-away to read through an active away window instead,
# because the captain reads the board while away. bin/fm-afk-return.sh owns the gate.
#
# The landed section merges this home's Done with the canonical snapshot's
# secondmate_landed roll-up (fm-fleet-snapshot.sh), so merges a secondmate managed -
# recorded in ITS OWN backlog, never the main one - are visible. It stays bounded by
# a per-home cap and an overall cap, with omitted[] disclosure of both and of any
# secondmate home whose backlog was unreadable; no live GitHub call is involved.
# The default landed baseline is balanced across homes: each home keeps its internal
# newest-first ordering, homes iterate in deterministic id order, sparse homes do not
# waste capacity, and --all-landed switches back to the complete global newest-first
# order. Which closed rows either side contributes is bin/fm-landed-lib.sh's rule.
#
# Flags:
#   (default)        compact projection with bounded remote-ledger collection, TOON
#   --json           the same projected model as JSON (machine/debug; parity form)
#   --include-prs    ALSO do live GitHub open-PR discovery + checks
#   --fields <list>  opt in to dropped surfaces: bodies,paths,actions,endpoints,gate-text
#   --all-in-flight  include every in-flight task
#   --all-decisions  include every open decision and captain hold in the bounded snapshot
#   --all-secondmates include every aggregated secondmate record
#   --all-landed     include every landed record from every home (default: bounded)
#   --all-reports    include the full scout-report inventory (default: relevant only)
#   --all-queued     include every queued gate present in the bounded snapshot
#   --all-recorded-prs include every locally recorded PR
#   --all-unhealthy  include every unhealthy endpoint
#   --all-pr-repos   query every discovered repository under --include-prs
#   --during-away    build during an active away window instead of refusing (board)
#   -h,--help        usage
#
# Output contract: `fm-bearings.v1`. No locks or reports; the underlying snapshot's
# parent-side remote-ledger cache refresh is the only default fleet-state mutation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/fm-fleet-snapshot.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-landed-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-landed-lib.sh"  # FM_LANDED_JQ_DEFS: the shared landed selector

# Bounds (overridable for tests / large fleets).
FM_BEARINGS_LANDED=${FM_BEARINGS_LANDED:-6}
FM_BEARINGS_LANDED_PER_HOME=${FM_BEARINGS_LANDED_PER_HOME:-$FM_BEARINGS_LANDED}
FM_BEARINGS_IN_FLIGHT=${FM_BEARINGS_IN_FLIGHT:-20}
FM_BEARINGS_DECISIONS=${FM_BEARINGS_DECISIONS:-20}
FM_BEARINGS_SECONDMATES=${FM_BEARINGS_SECONDMATES:-20}
FM_BEARINGS_GATES=${FM_BEARINGS_GATES:-20}
FM_BEARINGS_REPORTS=${FM_BEARINGS_REPORTS:-20}
FM_BEARINGS_RECORDED_PRS=${FM_BEARINGS_RECORDED_PRS:-20}
FM_BEARINGS_UNHEALTHY=${FM_BEARINGS_UNHEALTHY:-20}
FM_BEARINGS_PR_REPOS=${FM_BEARINGS_PR_REPOS:-10}
FM_BEARINGS_PR_LIMIT=${FM_BEARINGS_PR_LIMIT:-20}
FM_BEARINGS_PR_TIMEOUT=${FM_BEARINGS_PR_TIMEOUT:-20}
FM_BEARINGS_MRS=${FM_BEARINGS_MRS:-20}
FM_BEARINGS_MR_DETAIL_PARALLEL=${FM_BEARINGS_MR_DETAIL_PARALLEL:-10}
FM_BEARINGS_MR_PROJECT_MAX=${FM_BEARINGS_MR_PROJECT_MAX:-20}
FM_BEARINGS_MR_TIMEOUT=${FM_BEARINGS_MR_TIMEOUT:-10}
case "$FM_BEARINGS_MR_TIMEOUT" in ''|*[!0-9]*|0) FM_BEARINGS_MR_TIMEOUT=10 ;; esac
case "$FM_BEARINGS_PR_TIMEOUT" in ''|*[!0-9]*|0) FM_BEARINGS_PR_TIMEOUT=20 ;; esac
validate_bound() {  # <name> <value>
  case "$2" in ''|*[!0-9]*|0) echo "fm-bearings-snapshot: $1 must be a positive integer" >&2; exit 2 ;; esac
}
validate_bound FM_BEARINGS_LANDED "$FM_BEARINGS_LANDED"
validate_bound FM_BEARINGS_LANDED_PER_HOME "$FM_BEARINGS_LANDED_PER_HOME"
validate_bound FM_BEARINGS_IN_FLIGHT "$FM_BEARINGS_IN_FLIGHT"
validate_bound FM_BEARINGS_DECISIONS "$FM_BEARINGS_DECISIONS"
validate_bound FM_BEARINGS_SECONDMATES "$FM_BEARINGS_SECONDMATES"
validate_bound FM_BEARINGS_GATES "$FM_BEARINGS_GATES"
validate_bound FM_BEARINGS_REPORTS "$FM_BEARINGS_REPORTS"
validate_bound FM_BEARINGS_RECORDED_PRS "$FM_BEARINGS_RECORDED_PRS"
validate_bound FM_BEARINGS_UNHEALTHY "$FM_BEARINGS_UNHEALTHY"
validate_bound FM_BEARINGS_PR_REPOS "$FM_BEARINGS_PR_REPOS"
validate_bound FM_BEARINGS_PR_LIMIT "$FM_BEARINGS_PR_LIMIT"
validate_bound FM_BEARINGS_MRS "$FM_BEARINGS_MRS"
validate_bound FM_BEARINGS_MR_DETAIL_PARALLEL "$FM_BEARINGS_MR_DETAIL_PARALLEL"
validate_bound FM_BEARINGS_MR_PROJECT_MAX "$FM_BEARINGS_MR_PROJECT_MAX"

usage() {
  cat <<'EOF'
usage: fm-bearings-snapshot.sh [--json] [--include-prs] [--include-mrs] [--fields <list>]
                               [--all-in-flight] [--all-decisions]
                               [--all-secondmates] [--all-landed]
                               [--all-reports] [--all-queued]
                               [--all-recorded-prs] [--all-unhealthy]
                               [--all-pr-repos] [--during-away]

Compact bearings projection over fm-fleet-snapshot.sh. TOON by default.
Default collection performs bounded concurrent remote-ledger reads for registered
remote homes under one shared snapshot budget and may refresh the parent-side cache.
--include-prs additionally performs live GitHub discovery and checks.
An active away window refuses (exit 3) unless --during-away is given, which the
board build passes so the captain can read the board while away.

Default fields: schema, home, generated, prs, in_flight{id,kind,state,repo,name,doing,
    pr_url (the PR or MR the task names as its own, else null)},
  secondmates{id,state,doing,provenance,freshness,age_seconds,contradiction,reason,
    stale_note,read_failure},
  secondmate_reconcile{id,spawn_gen,host,kind,ids},
  decisions_open{id,key,verb,title,reason,title_full,reason_full,summary,question,owner,
    hold_until,hold_bucket,hold_set,hold_reconciled,origin,choices,answers,notes,report_path
      (captain holds only),
    handed_at,handed_via,handed_task,raised_at (handed decisions only),
    pr_url (a PR or MR its home recorded, when the reason links none),
    note (a row kept from an unreadable home or an idle home's open key)},
  landed{id,what,artifact,owner},
  gates{id,title,blocked_by,reason,owner,filed,title_full,reason_full,answers,notes,report_path,
    hold_kind,hold_until},
  reports{id,path}, recorded_prs{id,url},
  unhealthy_endpoints{...} (only when non-empty), omitted{surface,reveal}.
Default gates are selected newest filed first before their bound; undated gates
  retain input order after dated gates. With --all-decisions the bound cuts only
  unheld gates: a gate with a hold_kind or hold_until is always kept.
Decision presentation uses question, the full title and hold reason; summary
  remains a bounded overview and must not substitute for the question/options.
landed merges this home's Done with registered secondmate homes' Done, bounded by
  a per-home cap (FM_BEARINGS_LANDED_PER_HOME) and an overall cap (FM_BEARINGS_LANDED),
  with omitted[] disclosure. Default selection is balanced across deterministic home
  order while preserving each home's internal newest-first order; sparse homes do
  not waste capacity. --all-landed reveals the full global newest-first set.
For every registered secondmate, readable structured facts from its own home are
  authoritative, including independently trustworthy surfaces from a partial summary.
  Parent events and bounded terminal reads are labeled fallback or contradiction
  evidence and never become current work. The provenance and freshness fields
  distinguish live and cached ledgers; a home without either is explicitly unreadable.
Opt-in surfaces: --fields bodies|paths|actions|endpoints|gate-text
  (gate-text adds untruncated gates{title_full,reason_full}), --all-in-flight,
  --all-decisions (all open decisions and captain holds in the bounded snapshot),
  --all-secondmates, --all-landed, --all-reports, --all-queued, --all-recorded-prs,
  --all-unhealthy, --all-pr-repos, --include-prs (adds candidate_prs),
  --include-mrs (adds open_mrs{key,repo,title,url,state,updated}: every open GitLab
  MR the captain authored, Draft included, and those awaiting their review that no
  decision, queued, landed or contribution row, nor the underway row of the task that
  records it, shows by URL or full reference; the mrs: line says whether they were
  checked or unavailable).
Raise FM_BEARINGS_PR_LIMIT to expand per-repository open-PR results.
--include-mrs bounds: FM_BEARINGS_GITLAB_HOST (default: glab's configured host),
  FM_BEARINGS_MR_TIMEOUT seconds per glab call (10), FM_BEARINGS_MR_DETAIL_PARALLEL
  listed MRs read in detail at a time (10; every listed MR is read),
  FM_BEARINGS_MR_PROJECT_MAX projects checked for archiving (20),
  FM_BEARINGS_MRS rows kept (20).
EOF
}

FORMAT=toon
INCLUDE_PRS=0
INCLUDE_MRS=0
ALL_REPORTS=0
ALL_QUEUED=0
ALL_IN_FLIGHT=0
ALL_DECISIONS=0
ALL_SECONDMATES=0
ALL_LANDED=0
ALL_RECORDED_PRS=0
ALL_UNHEALTHY=0
ALL_PR_REPOS=0
DURING_AWAY=0
FIELDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --include-prs) INCLUDE_PRS=1 ;;
    --include-mrs) INCLUDE_MRS=1 ;;
    --all-reports) ALL_REPORTS=1 ;;
    --all-queued) ALL_QUEUED=1 ;;
    --all-in-flight) ALL_IN_FLIGHT=1 ;;
    --all-decisions) ALL_DECISIONS=1 ;;
    --all-secondmates) ALL_SECONDMATES=1 ;;
    --all-landed) ALL_LANDED=1 ;;
    --all-recorded-prs) ALL_RECORDED_PRS=1 ;;
    --all-unhealthy) ALL_UNHEALTHY=1 ;;
    --all-pr-repos) ALL_PR_REPOS=1 ;;
    --during-away) DURING_AWAY=1 ;;
    --fields) shift; FIELDS=${1:-} ;;
    --fields=*) FIELDS=${1#--fields=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-bearings-snapshot: jq not found" >&2; exit 1; }

# The shared read-only away-return owner is consulted, not obeyed. An active
# away window still refuses a chat read: the correct answer to a bearings
# request then is to run the return first. --during-away (the board build)
# reads through it, because the captain uses the board instead of chat while
# away and a refusal would freeze it. Return CATCH-UP is different - the captain is
# back and asking for the picture, so the catch-up posture is reported as
# content (a Charted Next gate row) and collection continues. bin/fm-afk-return.sh
# owns both the gate format and the branch distinction; bearings reproduces
# neither. Acting on the fleet still waits for its `check`.
RETURN_CATCHUP=null
GUARD_RC=0
GUARD_ERR=$("$SCRIPT_DIR/fm-afk-return.sh" guard 2>&1 >/dev/null) || GUARD_RC=$?
if [ "$GUARD_RC" -eq 3 ] && [ "$DURING_AWAY" = 1 ]; then
  GUARD_RC=0
elif [ "$GUARD_RC" -ne 0 ] && [ "$GUARD_RC" -ne 4 ]; then
  [ -z "$GUARD_ERR" ] || printf '%s\n' "$GUARD_ERR" >&2
  exit "$GUARD_RC"
fi
if [ "$GUARD_RC" -eq 4 ]; then
  CATCHUP_LINE=$("$SCRIPT_DIR/fm-afk-return.sh" catchup-summary) || CATCHUP_LINE=""
  CATCHUP_BLOCKERS=${CATCHUP_LINE%%$'\t'*}
  case "$CATCHUP_BLOCKERS" in ''|*[!0-9]*) CATCHUP_BLOCKERS=0 ;; esac
  CATCHUP_REASON=""
  case "$CATCHUP_LINE" in *"$(printf '\t')"*) CATCHUP_REASON=${CATCHUP_LINE#*$'\t'} ;; esac
  RETURN_CATCHUP=$(jq -n --argjson blockers "$CATCHUP_BLOCKERS" --arg reason "$CATCHUP_REASON" \
    '{pending:true,blockers:$blockers,reason:$reason}')
fi

NOW=${FM_BEARINGS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
if [ "$ALL_LANDED" = 1 ] || [ "$ALL_SECONDMATES" = 1 ]; then
  if [ "$ALL_LANDED" = 1 ]; then
    SNAP=$(FM_SNAPSHOT_NOW="$NOW" FM_SNAPSHOT_SECONDMATES=0 FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=0 "$FLEET" --json) || exit $?
  else
    SNAP=$(FM_SNAPSHOT_NOW="$NOW" FM_SNAPSHOT_SECONDMATES=0 "$FLEET" --json) || exit $?
  fi
else
  SNAP=$(FM_SNAPSHOT_NOW="$NOW" "$FLEET" --json) || exit $?
fi
HOME_LABEL=$(printf '%s' "$SNAP" | jq -er '.fm_home | strings | split("/") | (.[-2:] | join("/"))') \
  || { echo "fm-bearings-snapshot: invalid canonical snapshot" >&2; exit 1; }

# The PR or MR an Under way row names when its task recorded none: the canonical
# snapshot reads only a GitHub pull URL from a status log, so a GitLab MR task
# reaches here with no pr.url. Read-only: the PR or MR URL its status log names
# most often, the first named winning a tie.
TASK_PRS=$(printf '%s' "$SNAP" | jq -r '
    .tasks[]? | select(.kind != "secondmate" and (.pr.url // null) == null
                       and (.paths.status_log.present == true))
    | [.id, .paths.status_log.path] | @tsv' \
  | while IFS=$'\t' read -r task_id task_log; do
      [ -n "$task_id" ] && [ -f "$task_log" ] || continue
      grep -Eo 'https://[^[:space:])"<>]+/(-/merge_requests|pulls?)/[0-9]+' "$task_log" 2>/dev/null \
        | jq -R -s -c --arg id "$task_id" '
            split("\n") | map(select(. != "")) as $u
            | if $u == [] then empty else
                ($u | group_by(.) | map({url: .[0], n: length})) as $g
                | ($g | map(.n) | max) as $top
                | {key: $id, value: first($u[] as $x | $g[] | select(.url == $x and .n == $top) | .url)}
              end'
    done | jq -s -c 'from_entries')
[ -n "$TASK_PRS" ] || TASK_PRS='{}'

# --- optional live GitHub PR enrichment -------------------------------------
PR_STATUS='not_requested (run: /bearings include PRs)'
CANDIDATE_PRS='[]'
PR_REPOS_TOTAL=0
PR_REPOS_SHOWN=0
PR_ROWS_CAPPED=0
PR_ROWS_MIN_TOTAL=0

# Parse owner/repo from an https or ssh GitHub remote/PR URL; empty if not GitHub.
repo_slug() {  # <url>
  printf '%s' "$1" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p' | sed 's#\.git$##; s#/pull/.*$##; s#/$##'
}

# Bounded gh call; prints stdout, non-zero on timeout/failure. gh only.
# bin/fm-timeout-lib.sh owns the bound itself.
gh_bounded() {  # <args...>
  fm_run_timed "$FM_BEARINGS_PR_TIMEOUT" \
    env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"
}

if [ "$INCLUDE_PRS" = 1 ]; then
  if ! command -v gh >/dev/null 2>&1; then
    PR_STATUS='unavailable (gh not found)'
  else
    # Candidate repos: recorded pr= URLs plus live worktree origins. Deduped.
    repos=""
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      s=$(repo_slug "$u"); [ -n "$s" ] || continue
      case " $repos " in *" $s "*) : ;; *) repos="$repos $s" ;; esac
    done <<EOF
$(printf '%s' "$SNAP" | jq -r '.tasks[].pr.url // empty')
EOF
    while IFS= read -r wt; do
      [ -n "$wt" ] || continue
      [ -d "$wt" ] || continue
      u=$(git -C "$wt" remote get-url origin 2>/dev/null) || continue
      s=$(repo_slug "$u"); [ -n "$s" ] || continue
      case " $repos " in *" $s "*) : ;; *) repos="$repos $s" ;; esac
    done <<EOF
$(printf '%s' "$SNAP" | jq -r '.tasks[] | select(.kind != "secondmate") | .paths.worktree.path // empty')
EOF

    for repo in $repos; do PR_REPOS_TOTAL=$((PR_REPOS_TOTAL + 1)); done
    nrepos=0; npr=0; nwarn=0; ncapped=0; rows='[]'
    pr_fetch_limit=$((FM_BEARINGS_PR_LIMIT + 1))
    # The task side of the mapping rides a temp file, not an argv element: a
    # fleet snapshot exceeds the ~128KB per-argument exec cap on large fleets,
    # and an E2BIG there would drop the repo's PR rows into the warning count.
    tasks_file=$(mktemp "${TMPDIR:-/tmp}/fm-bearings-tasks.XXXXXX") \
      || { echo "fm-bearings-snapshot: cannot create a temporary tasks file" >&2; exit 1; }
    printf '%s' "$SNAP" | jq '.tasks // []' > "$tasks_file"
    for repo in $repos; do
      if [ "$ALL_PR_REPOS" != 1 ] && [ "$nrepos" -ge "$FM_BEARINGS_PR_REPOS" ]; then break; fi
      nrepos=$((nrepos + 1))
      out=$(gh_bounded pr list --repo "$repo" --state open --limit "$pr_fetch_limit" \
        --json number,title,url,headRefName,reviewDecision,mergeable,statusCheckRollup 2>/dev/null) \
        || { nwarn=$((nwarn + 1)); continue; }
      [ -n "$out" ] || out='[]'
      repo_result=$(printf '%s' "$out" | jq --arg repo "$repo" --argjson limit "$FM_BEARINGS_PR_LIMIT" --slurpfile tasks "$tasks_file" '
        ($tasks[0] // []) as $all_tasks
        | def task_for_branch($ref):
            ( [ $all_tasks[] | select((.branch // ("fm/" + .id)) == $ref) | .id ] | .[0] )
            // (if ($ref | startswith("fm/")) then ($ref | ltrimstr("fm/")) else "-" end);
        [ .[] | {
          num:(.number|tostring),
          repo:$repo,
          task:task_for_branch(.headRefName // ""),
          url:(.url // "-"),
          review:(.reviewDecision // "none"),
          mergeable:(.mergeable // "UNKNOWN"),
          checks:(
            (.statusCheckRollup // []) as $c
            | if ($c|length) == 0 then "none"
              elif any($c[]; (.conclusion // .state // "") as $s | ($s=="FAILURE" or $s=="ERROR" or $s=="TIMED_OUT" or $s=="CANCELLED" or $s=="ACTION_REQUIRED")) then "failing"
              elif any($c[]; ((.status // "") != "COMPLETED") and ((.state // "") != "SUCCESS")) then "pending"
              else "passing" end)
        } ] as $rows | {returned:($rows | length), rows:$rows[:$limit]}') || { nwarn=$((nwarn + 1)); continue; }
      returned=$(printf '%s' "$repo_result" | jq '.returned')
      repo_rows=$(printf '%s' "$repo_result" | jq '.rows')
      cnt=$(printf '%s' "$repo_rows" | jq 'length')
      [ "$returned" -gt "$FM_BEARINGS_PR_LIMIT" ] && ncapped=$((ncapped + 1))
      npr=$((npr + cnt))
      rows=$(jq -n --argjson a "$rows" --argjson b "$repo_rows" '$a + $b')
    done
    rm -f "$tasks_file"
    PR_REPOS_SHOWN=$nrepos
    PR_ROWS_CAPPED=$ncapped
    PR_ROWS_MIN_TOTAL=$((npr + ncapped))
    CANDIDATE_PRS=$rows
    warnnote=""
    [ "$nwarn" -gt 0 ] && warnnote="; ${nwarn} repo(s) unavailable"
    cappednote=""
    [ "$ncapped" -gt 0 ] && cappednote="; ${npr} shown, at least ${PR_ROWS_MIN_TOTAL} open; capped in ${ncapped} repo(s)"
    if [ "$ncapped" -gt 0 ]; then
      PR_STATUS="checked (${nrepos} repos${cappednote}${warnnote})"
    else
      PR_STATUS="checked (${nrepos} repos, ${npr} open${warnnote})"
    fi
  fi
fi

# --- projection: canonical snapshot -> fm-bearings.v1 model (JSON) ----------
BEARINGS_TODAY=${NOW%%T*}
case "$BEARINGS_TODAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) BEARINGS_TODAY=$(date -u +%Y-%m-%d) ;;
esac
MODEL=$(printf '%s' "$SNAP" | jq \
  --arg home "$HOME_LABEL" \
  --arg now "$NOW" \
  --arg today "$BEARINGS_TODAY" \
  --arg prs "$PR_STATUS" \
  --arg fields "$FIELDS" \
  --argjson landed_n "$FM_BEARINGS_LANDED" \
  --argjson landed_per_home_n "$FM_BEARINGS_LANDED_PER_HOME" \
  --argjson in_flight_n "$FM_BEARINGS_IN_FLIGHT" \
  --argjson decisions_n "$FM_BEARINGS_DECISIONS" \
  --argjson secondmates_n "$FM_BEARINGS_SECONDMATES" \
  --argjson gates_n "$FM_BEARINGS_GATES" \
  --argjson reports_n "$FM_BEARINGS_REPORTS" \
  --argjson recorded_prs_n "$FM_BEARINGS_RECORDED_PRS" \
  --argjson unhealthy_n "$FM_BEARINGS_UNHEALTHY" \
  --argjson include_prs "$INCLUDE_PRS" \
  --argjson all_in_flight "$ALL_IN_FLIGHT" \
  --argjson all_decisions "$ALL_DECISIONS" \
  --argjson all_secondmates "$ALL_SECONDMATES" \
  --argjson all_landed "$ALL_LANDED" \
  --argjson all_reports "$ALL_REPORTS" \
  --argjson all_queued "$ALL_QUEUED" \
  --argjson all_recorded_prs "$ALL_RECORDED_PRS" \
  --argjson all_unhealthy "$ALL_UNHEALTHY" \
  --argjson pr_repos_total "$PR_REPOS_TOTAL" \
  --argjson pr_repos_shown "$PR_REPOS_SHOWN" \
  --argjson pr_rows_capped "$PR_ROWS_CAPPED" \
  --argjson pr_rows_min_total "$PR_ROWS_MIN_TOTAL" \
  --argjson return_catchup "$RETURN_CATCHUP" \
  --argjson task_prs "$TASK_PRS" \
  --argjson candidate_prs "$CANDIDATE_PRS" "$FM_LANDED_JQ_DEFS"'
  def oneline: if . == null then null else (tostring | gsub("\\s+"; " ")) end;
  def trunc($n): if . == null then null else
    (oneline | if (length > $n) then (.[:$n] + "…") else . end) end;
  def fit($n):
    tostring | gsub("\\s+"; " ")
    | if $n <= 0 then ""
      elif length > $n then (if $n == 1 then "…" else (.[:($n - 1)] + "…") end)
      else . end;
  # The short name of a task PR or MR, for an Under way row: "MR !900", "PR #12".
  def pr_ref($u):
    if $u == null then null
    elif ($u | test("/-/merge_requests/[0-9]+")) then
      "MR !" + ($u | capture("/-/merge_requests/(?<n>[0-9]+)").n)
    elif ($u | test("/pulls?/[0-9]+")) then
      "PR #" + ($u | capture("/pulls?/(?<n>[0-9]+)").n)
    else "PR" end;
  # The note of the latest status line. A dated pause ("paused [at=..] until 15:33Z:
  # waiting on CI") keeps its whole deadline, which a split at the first colon
  # would cut to "33Z: waiting on CI".
  def event_note($ev):
    ($ev.raw // "") as $raw
    | ($raw | capture("^[a-z-]+(?:\\s+\\[[^\\]]*\\])*\\s+until\\s+(?<t>\\S+?):\\s+(?<n>.*)$") // null) as $u
    | if $u != null then "until " + $u.t + ": " + $u.n else ($ev.note // "") end;
  # A worker fault a pane, endpoint or source-less reading reports, in plain
  # words with the wait it leaves ("worker stopped; waits on a relaunch or
  # cleanup (<window>)"), or null when the reading names none.
  def worker_fault($cs):
    ($cs.detail // "") as $d
    | ($cs.source // "") as $src
    | if $src == "none" then
        (if ($d | startswith("backend target gone: ")) then
           "worker stopped; waits on a relaunch or cleanup ("
           + ($d | ltrimstr("backend target gone: ") | sub(" \\(.*$"; "")) + ")"
         elif ($d | startswith("backend unreachable")) then "worker unreachable; waits on its host"
         elif ($d | startswith("worktree gone")) then "isolated copy gone; waits on cleanup"
         elif ($d | startswith("no metadata for")) then "no task record; waits on cleanup"
         else null end)
      elif $src == "remote-endpoint" and ($d | startswith("alive on ") | not) then
        "remote worker unreachable"
        + ($d | capture(" on (?<h>[^ ]+)") // {} | if .h then " on " + .h else "" end)
        + "; waits on its host"
      else null end;
  # What an Under way task waits on, in plain words. A current state read from
  # the task status log, a review park or a known pipeline step already speaks
  # plain words. A pane or source-less reading ("harness busy", "state unknown,
  # no current-state source available") does not, so the row names a worker
  # fault in plain words or falls back to the latest status line.
  def current_wait($cs; $ev):
    ($cs.detail // "") as $d
    | ($cs.source // "") as $src
    | event_note($ev) as $n
    | ($ev.state // "") as $s
    | worker_fault($cs) as $f
    | if $d != "" and $d != ($ev.note // "") and ($src == "status-log" or $src == "review-park"
                       or ($src == "run-step" and ($cs.state // "unknown") != "unknown"))
      then $d
      elif $f != null then $f + (if $n == "" then "" else " (last: " + $n + ")" end)
      elif $n == "" then (if $src == "status-log" or $src == "review-park" then $d
                          elif ($cs.state // "") == "working" then "working" else "no update yet" end)
      elif $s == "blocked" then "blocked: " + $n
      elif $s == "needs-decision" then "waiting on the captain: " + $n
      elif $s == "failed" then "failed: " + $n
      elif $s == "resolved" then "resumed: " + $n
      elif $s == "paused" then "paused " + (if ($n | startswith("until ")) then "" else "- " end) + $n
      else $n end;
  # The doing of an Under way row: the wait, naming the PR or MR of the row when it has one.
  def row_doing($pr; $w):
    (if $pr == null then $w
     else pr_ref($pr) as $ref
       | ($w | split("MR " + $pr) | join($ref) | split("PR " + $pr) | join($ref)
          | split($pr) | join($ref)) as $w
       | if ($w | trunc(80) | contains($ref)) then $w else $ref + ": " + $w end end)
    | trunc(90);
  def live_captain_call: .hold_bucket == "live";
  # A hold whose reason asks a question is a question for the captain wherever the
  # bucketing put it: blocked and aged holds stay on the board. A dated hold is the
  # deliberate deferral and stays out until its date.
  def promoted_question_hold:
    (.hold_bucket == "blocked" or .hold_bucket == "aged")
    and ((.hold_reason // .reason_full // .reason // "") | tostring | test("\\?"));
  def projected_deferred_hold:
    .hold_bucket != null and .hold_bucket != "live" and (promoted_question_hold | not);
  def bounded_blocker_note($n):
    ((.unresolved_blocker_ids // []) | map(tostring)) as $ids
    | reduce range(0; $ids | length) as $i
        ({shown:[]};
         ($ids[0:($i + 1)]) as $candidate
         | (($ids | length) - ($i + 1)) as $remaining
         | ("blocked-by " + ($candidate | join(","))
            + (if $remaining > 0 then " +\($remaining) more" else "" end)) as $rendered
         | if ($rendered | length) <= $n then .shown = $candidate else . end)
    | .shown as $shown
    | (($ids | length) - ($shown | length)) as $remaining
    | if ($shown | length) == 0 then "blocked-by +\($remaining) more"
      else ("blocked-by " + ($shown | join(","))
            + (if $remaining > 0 then " +\($remaining) more" else "" end))
      end;
  def hold_note:
    if .hold_bucket == "blocked" then bounded_blocker_note(70)
    elif .hold_bucket == "dated" then ("until " + (.hold_until // "-"))
    elif .hold_bucket == "aged" and .hold_age_days != null then
      ("held " + (.hold_age_days | tostring) + "d")
    else null end;
  def hold_gate_reason:
    (.hold_reason // .blocked_reason // "-") as $base
    | (hold_note) as $note
    | if $note == null then $base else ($note + ": " + $base) end;
  def full_hold_gate_reason:
    (.hold_reason // .blocked_reason // "-") as $base
    | (if .hold_bucket == "blocked" then
         ("blocked-by " + ((.unresolved_blocker_ids // []) | map(tostring) | join(",")))
       else hold_note end) as $note
    | if $note == null then $base else ($note + ": " + $base) end;
  def hold_summary($title; $base):
    (hold_note) as $note
    | if $note == null then (($title + ": " + $base) | trunc(90))
      else ($note | length) as $note_n
      | (86 - $note_n) as $context_n
      | if $context_n < 2 then ($note | fit(90))
        else ([46, ($context_n / 2 | floor)] | min) as $title_n
        | (($title | fit($title_n)) + ": " + $note + ": "
           + ($base | fit($context_n - $title_n)))
        end
      end;
  # Status-log needs-decision and blocked events are questions for the captain.
  # Keys reserved for relays and hold mirrors are not (see fm-classify-lib.sh).
  def status_question_row($owner; $mate; $t; $title):
    select(.verb == "needs-decision" or .verb == "blocked")
    | select((.key // "default") | tostring | test("^(pending-reply-|remote-reply-continuity-|captain-hold-)") | not)
    | (.key // "default") as $k
    | (("status." + (if $mate == null then "" else $mate + "." end) + $t + "." + $k)
       | gsub("[^A-Za-z0-9._-]"; "-") | .[:128]) as $slug
    # A secondmate home row carries its uncut text as question beside the
    # bounded summary; a parent status row carries the uncut text as summary.
    | ((.question // .summary) | if . == null then null else tostring end) as $full
    | {id:(if $mate == null then $t else $mate + "/" + $t end),key:$slug,verb:.verb,
       source:"status",task:$t,decision_key:$k,mate:$mate,
       title:($title | trunc(60)),reason:(($full // "-") | trunc(80)),
       title_full:$title,reason_full:($full // "-"),
       summary:hold_summary($title; ($full // "captain decision pending")),
       question:($full // "-"),owner:$owner}
      + (if ((.earlier // []) | length) > 0 then {reason_earlier:.earlier} else {} end);
  # A finished task whose last event names a live Lavish review page is a page
  # the captain has not opened yet: it is a question card linking to that page.
  def review_page_row($t):
    (($t.hints.last_event_text // "") | sub("^[a-z-]+ (\\[at=[0-9]+\\])?:? ?"; "")) as $text
    | select(($t.current_state.state // "") == "done")
    | select($text | test("https?://[^[:space:]]+/session/[0-9a-f]{8,}"))
    | ($t.backlog.title // $t.id) as $title
    | {id:$t.id,key:(("review." + $t.id) | gsub("[^A-Za-z0-9._-]"; "-") | .[:128]),
       verb:"review-ready",source:"review-page",task:$t.id,decision_key:null,mate:null,
       title:($title | trunc(60)),reason:($text | trunc(80)),
       title_full:$title,reason_full:$text,
       summary:hold_summary($title; $text),
       question:("Review page ready: " + $text),owner:"(main)"};
  def as_gate($owner):
    {id, title:(.title | trunc(60)),
     blocked_by:((.unresolved_blocker_ids // []) | if length > 0 then join(",") else "-" end | trunc(120)),
     reason:(hold_gate_reason | trunc(40)), owner:$owner,
     filed:((.since // null) | trunc(40)),
     title_full:(.title | oneline), reason_full:(full_hold_gate_reason | oneline),
     card_title:(.title_full // .title // null),
     card_reason:(.hold_reason_full // .hold_reason // .blocked_reason // null),
     answers:(.hold_answers // .answers // []),notes:(.body_notes // .notes // []),
     report_path:(.report_path // null),
     hold_kind:(.hold_kind // null), hold_until:(.hold_until // null)};
  def gate_text($wanted):
    if $wanted then . else del(.title_full, .reason_full) end;
  def round_robin_landed($n):
    . as $groups
    | [range(0; (($groups | map(length) | max) // 0)) as $i
       | $groups[]
       | select(length > $i)
       | .[$i]][:$n];
  ($fields | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) as $fl
  | (($fl | index("bodies")) != null) as $f_bodies
  | (($fl | index("paths")) != null) as $f_paths
  | (($fl | index("actions")) != null) as $f_actions
  | (($fl | index("endpoints")) != null) as $f_endpoints
  | (($fl | index("gate-text")) != null) as $f_gate_text
  | ([ .backlog.records[] | select(landed_record)
       | {id, title, kind, hold_kind, pr_url, report_path, local_note, completion,
          home:"(main)", home_id:"(main)"} ]) as $main_done
  | ((.secondmate_landed.records) // []) as $mate_done
  | ($main_done + $mate_done) as $all_landed_rows
  | ([ $all_landed_rows | group_by(.home_id)[]
       | sort_by([(.completion.date // ""), .id]) | reverse
       | (if $all_landed == 1 then . else .[:$landed_per_home_n] end) ]) as $per_home_groups
  | ($per_home_groups | add // []) as $per_home_capped
  | ([ $all_landed_rows | group_by(.home_id)[] | select(length > $landed_per_home_n) ] | length) as $home_cap_dropped
  | ($per_home_capped | sort_by([(.completion.date // ""), .id]) | reverse) as $landed_sorted
  | (if $all_landed == 1 then $landed_sorted else ($per_home_groups | round_robin_landed($landed_n)) end) as $done
  | ($done | map(.id)) as $done_ids
  | ([.tasks[] | select(.kind != "secondmate") | .id]) as $live_ids
  | ([.tasks[] | select(.kind != "secondmate" and .current_state.state == "working") | .id]) as $working_ids
  | ($live_ids + $done_ids) as $rel_ids
  | ([ .tasks[]
       | select(.endpoint.exists == false or .endpoint.agent_alive == "dead")
       | {id, backend, target:(.endpoint.target // "-"), exists:.endpoint.exists, agent:.endpoint.agent_alive} ]
     + [ (.secondmate_current.records // [])[] as $m | $m.endpoints[]?
         | select(.endpoint.exists == false or .endpoint.agent_alive == "dead")
         | {id:($m.id + "/" + .id),backend:"secondmate-home",target:(.endpoint.target // "-"),exists:.endpoint.exists,agent:.endpoint.agent_alive} ]) as $unhealthy_all
  | ([ (.secondmate_current.records // [])[]
       | ([.decisions_open[]? | select(.source == "backlog" and .verb == "captain-hold"
            and live_captain_call)]) as $captain_holds
       | ([.holds[]? | select(.source == "backlog")]) as $backlog_holds
       | . as $rec
       | . + {
           stale_note:(if .freshness.status == "cached"
                       then "could not read " + .id + ", last seen " + (.freshness.observed_at // "an unknown time")
                       else null end),
           # Every in-flight child, whatever its state. A summary from an older
           # producer lists only working children, so its child-state holds
           # are added back with the state its endpoint row records.
           bearings_in_flight:(if (.in_flight_children | type) == "array" then .in_flight_children
             else (.active_children // [])
               + [ .holds[]? | select(.source == "child-state") | . as $h
                   | {id,kind:null,
                      state:(([$rec.endpoints[]? | select(.id == $h.id) | .state][0]) // "held"),
                      repo:null,name:(.title // null),source:"child-state",
                      doing:(.reason // "held")} ] end),
           bearings_captain_holds:$captain_holds,
           bearings_holds:(if .current.state == "captain_decision" then $backlog_holds else .holds end),
           bearings_state:(
             if .current.state == "captain_decision" then
               if ($captain_holds | length) > 0 then "captain_decision"
               elif (.active_children | length) > 0 then "active_child_work"
               elif ($backlog_holds | length) > 0 then "externally_held"
               else "unknown" end
             else .current.state end)
         } ]) as $secondmate_views
  | ([ if .secondmate_current.registry.available == false then
         {id:"(registry)",state:"unknown",doing:(.secondmate_current.registry.reason // "Registered secondmate table unavailable"),
          provenance:(.secondmate_current.registry.provenance // "registered-table"),
          freshness:(.secondmate_current.registry.freshness.status // "unavailable"),
          age_seconds:null,contradiction:false,reason:(.secondmate_current.registry.reason // "Registered secondmate table unavailable")}
       else empty end ]
     + [ $secondmate_views[]
       | {id,state:.bearings_state,
          doing:((if .bearings_state == "active_child_work" then
                    ([.active_children[] | .id + ": " + (.doing // .state)] | join("; "))
                  elif .bearings_state == "captain_decision" then
                    ([.bearings_captain_holds[] | .summary] | join("; "))
                  elif .bearings_state == "externally_held" then
                    ([.bearings_holds[] | .id + ": " + (.reason // "held")] | join("; "))
                  elif .bearings_state == "no_active_work" then "No active child work"
                  else (.current.reason // "Current home state unavailable") end) | trunc(120)),
          provenance:(if .provenance.summary_source == "remote-ledger-cache"
                         or .provenance.summary_source == "local-ledger-cache" then "structured-home-cache"
                      else .provenance.selected end),freshness:.freshness.status,
          age_seconds:.freshness.age_seconds,contradiction:(.contradiction // false),
          reason:(.current.reason // "-"),stale_note,
          read_failure:(.freshness.read_failure // null)} ]) as $secondmates_all
  | ([ .tasks[]
       | select(.kind != "secondmate")
       | select(.backlog.current_role != "program")
       | (.pr.url // .backlog.pr_url
          // first(((.backlog.links // [])[]?, (.backlog.hold_choices.links // [])[]?.target?)
                   | strings | select(test("^https://[^[:space:]]+/(-/merge_requests|pulls?)/[0-9]+$")))
          // $task_prs[.id] // null) as $pr
       # A held task keeps its row while it works, while the captain holds it
       # (its decision card can go between cards) and while it has a PR or MR;
       # only a PR-less external hold leaves, for its charted gate row.
       | select(.backlog.current_role != "held" or .current_state.state == "working"
                or .backlog.hold_kind == "captain" or $pr != null)
       | {id, kind,
        state: .current_state.state,
        repo:(.backlog.repo // .project // null),
        name:((.backlog.title // "") as $name
              | (if ($name | test("[^[:space:]]")) then $name else .id end) | trunc(70)),
        pr_url: $pr,
        doing: row_doing($pr; current_wait(.current_state // {}; .paths.status_log.last_event // {}))
      } ]
     + [ $secondmate_views[] as $m
         | $m.bearings_in_flight[]?
         | {id:($m.id + "/" + .id),
            kind:(.kind // "secondmate"),
            state:(.state // "working"),
            repo:(.repo // null),
            name:((.name // "") as $name
                  | (if (($name | type) == "string" and ($name | test("[^[:space:]]")))
                     then $name else ($m.id + "/" + .id) end) | trunc(70)),
            pr_url:((.pr_url // null) | if type == "string" and startswith("https://") then . else null end),
            doing:((if ((.source // null) | IN("run-step", "pane", "status-log", "remote-endpoint", "review-park", "none") | not) then ((.doing // .state) | trunc(90))
                    else row_doing((.pr_url // null) | if type == "string" and startswith("https://") then . else null end;
                                   current_wait({source, state, detail:(.doing // "")}; .last_event // {})) end) as $d
                   | if $m.stale_note == null then $d else $m.stale_note + " - " + $d end)} ]) as $in_flight_all
  | ([ .backlog.records[]
         | . as $record
         | select(.structured and .hold_bucket != null)
         | select(($all_decisions == 1) or live_captain_call or promoted_question_hold)
         | {id,key:.id,verb:"captain-hold",
            title:(.title | trunc(60)),reason:((.hold_reason // "-") | trunc(80)),
            title_full:(.title // .id),reason_full:(.hold_reason // "-"),
            summary:hold_summary(.title; .hold_reason),
            question:(.title + ": " + .hold_reason),owner:"(main)",
            hold_until:(.hold_until // null),hold_bucket:(.hold_bucket // null),
            hold_set:(.hold_set // null),hold_reconciled:(.hold_reconciled // null),
            origin:([(.body_lines // [])[]
                     | capture("^Captain hold origin:[[:space:]]*(?<v>[^[:space:]]+)")?
                     | .v][0] // null),
            choices:(.hold_choices // {options:[],links:[],free_text:false,no_link:false}),
            answers:(.hold_answers // []),notes:(.body_notes // []),
            report_path:(.report_path // null)} ]
     + [ . as $root | .tasks[]? | . as $t
         # An open parent-log question stays until a resolved line closes it.
         # When the home reports no active work the row says so, because the
         # home no longer carries the work that raised it.
         | (if $t.kind == "secondmate"
                and ([ ($root.secondmate_current.records // [])[]
                       | select(.id == $t.id and .provenance.summary_valid == true
                                and .current.state == "no_active_work") ] | length) > 0
            then $t.id + " reports no active work; key not resolved"
            else null end) as $idle_note
         # The same decision already carried by the home own status log is not
         # listed twice: the parent row names it by the same key, or by the
         # child task whose own log raised it (a relay keys it by that task).
         | (.hints.open_decisions // [])[]
         | select($t.kind != "secondmate"
                  or (.key as $k | [ ($root.secondmate_current.records // [])[]
                        | select(.id == $t.id) | .decisions_open[]?
                        | select(.source == "status" and (.key == $k or .id == $k)) ] | length) == 0)
         | status_question_row((if $t.kind == "secondmate" then $t.id else "(main)" end);
                               null; $t.id; ($t.backlog.title // $t.id))
         | if $idle_note == null then . else . + {note:$idle_note} end ]
     + [ .tasks[]? | . as $t | review_page_row($t) ]
     + [ (.secondmate_current.records // [])[] as $m
         | ([ $m.decisions_open[]?
              | select(.source == "backlog" and .verb == "captain-hold")
              | select(($all_decisions == 1) or live_captain_call or promoted_question_hold)
              | {id:($m.id + "/" + .id),key,verb,
                 title:((.summary // .id) | trunc(60)),reason:((.reason // "-") | trunc(80)),
                 title_full:(.title_full // .summary // .id),reason_full:(.reason_full // .reason // "-"),
                 summary:hold_summary((.summary // .id);
                                      (.reason // "captain decision pending")),
                 question:(.question // ((.summary // .id) + ": " + (.reason // "captain decision pending"))),owner:$m.id,
                 hold_until:(.hold_until // null),hold_bucket:(.hold_bucket // null),
                 hold_set:(.hold_set // null),hold_reconciled:(.hold_reconciled // null),
                 origin:(.origin // null),
                 choices:(.choices // {options:[],links:[],free_text:false,no_link:false}),
                 answers:(.answers // []),notes:(.notes // []),
                 report_path:(.report_path // null)} ]
            + [ $m.queued[]?
                | select($all_decisions == 1 and .hold_kind == "captain")
                | select(.id as $id
                         | [$m.decisions_open[]?
                            | select(.source == "backlog" and .verb == "captain-hold")
                            | .id]
                         | index($id) | not)
                | {id:($m.id + "/" + .id),key:.id,verb:"captain-hold",
                   title:((.title // .id) | trunc(60)),reason:((.hold_reason // "-") | trunc(80)),
                   title_full:(.title_full // .title // .id),reason_full:(.hold_reason_full // .hold_reason // "-"),
                   summary:hold_summary((.title // .id);
                                        (.hold_reason // "captain decision pending")),
                   question:(.question // ((.title // .id) + ": " + (.hold_reason // "captain decision pending"))),owner:$m.id,
                   hold_until:(.hold_until // null),hold_bucket:(.hold_bucket // null),
                   choices:(.choices // {options:[],links:[],free_text:false,no_link:false}),
                   answers:(.answers // []),notes:(.notes // []),
                   report_path:(.report_path // null)} ]
            + [ $m.decisions_open[]?
                | select(.source == "status")
                | status_question_row($m.id; $m.id; .id; .id) ])[] ]
     # A row whose home could not be read this time is its last known row.
     | ([ $secondmate_views[] | select(.stale_note != null) | {key:.id,value:.stale_note} ]
        | from_entries) as $stale_notes
     | map(. as $d
           | ($stale_notes[$d.owner] // null) as $stale
           | if $stale == null then .
             else . + {note:(if ($d.note // null) == null then $stale else $stale + "; " + $d.note end)} end)
    ) as $decisions_all
  | ([ .backlog.records[]
         | . as $record
         | select(.structured and projected_deferred_hold) ]
     + [ (.secondmate_current.records // [])[] | .queued[]?
         | select(.hold_kind == "captain" and projected_deferred_hold) ]
     | length) as $decisions_marked_deferred
  | (if ($return_catchup.pending // false) then
       ((if ($return_catchup.blockers // 0) > 0 then
           "\($return_catchup.blockers) blocker(s) to clear before ordinary work"
         elif (($return_catchup.reason // "") != "") then
           ("catch-up retained: " +
            ($return_catchup.reason | sub("[,;] *catch-up stays gated$"; "")))
         else "away-return catch-up is still open" end) as $title
       | [{id:"(return-catchup)",
           title:($title | trunc(60)),
           blocked_by:"-",
           reason:"away-return catch-up",
           owner:"(main)",
           filed:null,
           title_full:($title | oneline),
           reason_full:"away-return catch-up"}])
     else [] end) as $return_catchup_gate
  | ((if (.main_inventory.valid == false) then
        [{id:"(main-inventory)",
          title:((.main_inventory.reason // "main inventory invalid") | trunc(60)),
          blocked_by:"-",
          reason:"main inventory",
          owner:"(main)",
          filed:null,
          title_full:((.main_inventory.reason // "main inventory invalid") | oneline),
          reason_full:"main inventory"}]
      else [] end)
     + [ .backlog.records[]
         | . as $record
         | select(.structured and
             (.hold_bucket != null or .state == "queued" or
              (.state == "in_flight" and .current_role == "held" and ($working_ids | index($record.id) | not))))
         | select(.captain_actionable != true)
         | select((.hold_bucket == null) or ($all_decisions == 0 and (promoted_question_hold | not)))
         | as_gate("(main)") ]
     + [ (.secondmate_current.records // [])[] as $m
         | select($m.provenance.selected == "structured-home")
         | $m.queued[]?
         | select(.captain_actionable != true)
         | select((.hold_bucket == null) or ($all_decisions == 0 and (promoted_question_hold | not)))
         | as_gate($m.id) ]) as $gates_all
  | ([ .scout_reports[]
       | . as $r
       | select(($all_reports == 1) or (($rel_ids | index($r.id)) != null))
       | {id, path} ]) as $reports_all
  | ([ .tasks[] | select(.kind != "secondmate" and .pr.url != null and .pr.source == "meta") | {id, url:.pr.url} ]) as $recorded_prs_all
  | def filed_epoch:
      (.filed // null) as $filed
      | if ($filed | type) != "string" then null
        elif ($filed | test("T")) then try ($filed | fromdateiso8601) catch null
        else try (($filed + "T00:00:00Z") | fromdateiso8601) catch null end;
    def newest_filed_first:
      to_entries
      | sort_by((.value | filed_epoch) as $epoch
          | if $epoch == null then [1, 0, .key] else [0, -$epoch, .key] end)
      | map(.value);
    # The gate bound cuts only unheld gates when every decision is requested
    # (--all-decisions): a gate the fleet holds (hold_kind or hold_until) is
    # an open wait the board must show, so it is never cut.
    def bound_gates:
      if $all_queued == 1 then .
      else reduce .[] as $g ({n: 0, out: []};
             if $all_decisions == 1 and ((($g.hold_kind // "") != "") or (($g.hold_until // "") != ""))
             then .out += [$g]
             elif .n < $gates_n then .n += 1 | .out += [$g]
             else . end)
           | .out end;
    ($gates_all | newest_filed_first | bound_gates) as $gates_shown
    | . as $snap
  | {
      schema: "fm-bearings.v1",
      home: $home,
      generated: $now,
      prs: $prs,
      contributions:(
        ([$snap.contributions + {owner:"(main)"}]
          + [($snap.secondmate_current.records // [])[] as $m | if $m.contributions == null then null else $m.contributions + {owner:$m.id} end])
        | map(if . != null and .owner != "(main)" and .known > 0 and (.valid_until // 0) < ($now | fromdateiso8601)
              then .complete=false | .proven_clear=false | .checked=0 | .captain=[]
                | .unmeasured=(.unmeasured // 0)
                | .counts={captain:0,fleet:(.known - .unmeasured),maintainer:0,nobody:0}
              else . end) as $homes
        | ([$homes[] | select(. != null)]) as $measured
        | {scope:"owned contributions per home",known:([$measured[].known] | add // 0),
           checked:([$measured[].checked] | add // 0),
           counts:{captain:([$measured[].counts.captain] | add // 0),fleet:([$measured[].counts.fleet] | add // 0),
                   maintainer:([$measured[].counts.maintainer] | add // 0),nobody:([$measured[].counts.nobody] | add // 0)},
           complete:(all($homes[]; . != null and .complete) and ($snap.secondmate_current.truncated // 0) == 0
                     and $snap.secondmate_current.registry.available != false
                     and $snap.secondmate_current.registry.input_truncated != true
                     and $snap.secondmate_current.registry.records_truncated != true),
           proven_clear:(all($homes[]; . != null and .proven_clear) and ($snap.secondmate_current.truncated // 0) == 0
                     and $snap.secondmate_current.registry.available != false
                     and $snap.secondmate_current.registry.input_truncated != true
                     and $snap.secondmate_current.registry.records_truncated != true),
           unmeasured_homes:([$homes[] | select(. == null)] | length),
           unreadable_records:([$measured[].unreadable_records] | add // 0),
           unmeasured:([$measured[].unmeasured] | add // 0),
           stale_verdicts:([$measured[].stale_verdicts] | add // 0),
           missing_verdicts:([$measured[].missing_verdicts] | add // 0),
           captain_omitted:([$measured[].captain_omitted] | add // 0),
           captain:[$measured[] as $h | $h.captain[]? | . + {owner:$h.owner}]}),
      in_flight: (if $all_in_flight == 1 then $in_flight_all else $in_flight_all[:$in_flight_n] end),
      secondmates: (if $all_secondmates == 1 then $secondmates_all else $secondmates_all[:$secondmates_n] end),
      secondmate_reconcile: [ (.secondmate_current.records // [])[]
        | select(.reconcile_inventory != null)
        | {id, spawn_gen:(.spawn_gen // null), host:(.host // null), kind:(.reconcile_inventory.kind // null), ids:((.reconcile_inventory.ids // []) | map(select(type == "string")) | sort)} ],
      decisions_open: (if $all_decisions == 1 then $decisions_all else $decisions_all[:$decisions_n] end),
      landed: ($done | map({id, what:(.title | trunc(70)),
                            artifact:(landed_artifact // "-"),owner:.home_id})),
      gates: ($return_catchup_gate
              + $gates_shown
              | map(gate_text($f_gate_text))),
      reports: (if $all_reports == 1 then $reports_all else $reports_all[:$reports_n] end),
      recorded_prs: (if $all_recorded_prs == 1 then $recorded_prs_all else $recorded_prs_all[:$recorded_prs_n] end)
    }
  | . + (if ($unhealthy_all | length) > 0 then
           {unhealthy_endpoints:(if $all_unhealthy == 1 then $unhealthy_all else $unhealthy_all[:$unhealthy_n] end)}
         else {} end)
  | . + (if $include_prs == 1 then {candidate_prs:$candidate_prs} else {} end)
  | . + (if $f_bodies then {bodies:[ $snap.backlog.records[] | select(.structured and (.state == "queued" or .state == "done")) | {id, body:((.body_excerpt // .raw // "-") | trunc(200))} ]} else {} end)
  | . + (if $f_paths then {paths:[ $snap.tasks[] | {id, worktree:(.paths.worktree.path // "-"), home:(.paths.home.path // "-"), status:.paths.status_log.path, report:.paths.report.path} ]} else {} end)
  | . + (if $f_actions then {actions:[ $snap.tasks[] | {id, watch:(.actions.watch // .actions.send // "-"), steer:(.actions.steer // .actions.send // "-")} ]} else {} end)
  | . + (if $f_endpoints then {endpoints:[ $snap.tasks[] | {id, backend, target:(.endpoint.target // "-"), exists:.endpoint.exists, agent:.endpoint.agent_alive} ]} else {} end)
  | . + {omitted: (
      [ (if $f_bodies then empty else {surface:"backlog item bodies", reveal:"--fields bodies"} end),
        (if $f_paths then empty else {surface:"task paths", reveal:"--fields paths"} end),
        (if $f_actions then empty else {surface:"watch/steer actions", reveal:"--fields actions"} end),
        (if $f_endpoints then empty else {surface:"healthy endpoint detail", reveal:"--fields endpoints"} end),
        (if $f_gate_text then empty else {surface:"full gate title and reason text", reveal:"--fields gate-text"} end),
        (if $all_reports == 1 then empty else {surface:"full scout-report inventory", reveal:"--all-reports"} end),
        (if $all_landed == 0 and ($per_home_capped | length) > ($done | length) then {surface:("landed showing \($done | length) of \($per_home_capped | length)" + (($done | map(.home_id) | unique | map(select(. != "(main)")) | length) as $k | if $k > 0 then " (incl. \($k) secondmate home(s))" else "" end)), reveal:"--all-landed"} else empty end),
        (if $all_landed == 0 and $home_cap_dropped > 0 then {surface:("landed per-home capped at \($landed_per_home_n) for \($home_cap_dropped) home(s)"), reveal:"--all-landed"} else empty end),
        (if (($snap.secondmate_landed.unreadable // []) | length) > 0 then {surface:("secondmate home(s) with unreadable structured state: \(($snap.secondmate_landed.unreadable // []) | length)"), reveal:"inspect the listed secondmate home ledgers"} else empty end),
        (if $all_landed == 0 and (($snap.secondmate_landed.truncated // []) | length) > 0 then {surface:("secondmate home Done capped at the snapshot layer for \(($snap.secondmate_landed.truncated // []) | length) home(s)"), reveal:"--all-landed"} else empty end),
        ((($snap.main_inventory.orphan_in_flight // []) | length) as $n
         | if $n > 0 then {surface:("main in-flight backlog item(s) have no child metadata: \($n)"), reveal:"inspect main data/backlog.md In flight vs state/*.meta"} else empty end),
        ((($snap.main_inventory.unstructured_current_count // 0)) as $n
         | if $n > 0 then {surface:("main unstructured current backlog row(s): \($n)"), reveal:"inspect main data/backlog.md In flight and Queued free-form rows"} else empty end),
        (if $all_in_flight == 0 and ($in_flight_all | length) > $in_flight_n then {surface:("in_flight showing \($in_flight_n) of \($in_flight_all | length)"), reveal:"--all-in-flight"} else empty end),
        (($snap.secondmate_current.records // [])[] as $m
         | ([($m.omitted // [])[] | select(.surface == "active_children") | .count] | add // 0) as $n
         | if $n > 0 then {surface:("secondmate " + $m.id + " active children omitted by snapshot bound: \($n)"), reveal:"raise FM_SNAPSHOT_SECONDMATE_CHILDREN"} else empty end),
        (if $all_secondmates == 0 and ($secondmates_all | length) > $secondmates_n then {surface:("secondmates showing \($secondmates_n) of \($secondmates_all | length)"), reveal:"--all-secondmates"} else empty end),
        (if (($snap.secondmate_current.truncated // 0) > 0) then {surface:("registered secondmates omitted by snapshot bound: \($snap.secondmate_current.truncated)"), reveal:"raise FM_SNAPSHOT_SECONDMATES"} else empty end),
        (if $snap.secondmate_current.registry.input_truncated == true then {surface:"secondmate registry input truncated by bounded read", reveal:"raise FM_SNAPSHOT_REGISTRY_LINES or FM_SNAPSHOT_REGISTRY_BYTES"} else empty end),
        (if $snap.secondmate_current.registry.records_truncated == true then {surface:"secondmate registry records omitted by bounded read", reveal:"raise FM_SNAPSHOT_REGISTRY_RECORDS"} else empty end),
        (if $snap.secondmate_current.registry.available == false then {surface:("secondmate registry unavailable: " + ($snap.secondmate_current.registry.reason // "read failed")), reveal:"inspect data/secondmates.md"} else empty end),
        (($snap.secondmate_current.records // [])[]
         | select(.provenance.summary_source == "remote-ledger-cache" or .provenance.summary_source == "local-ledger-cache")
         | {surface:("secondmate " + .id + " served from cached home ledger"
                     + (if .freshness.read_failure then ": " + .freshness.read_failure else "" end)),
            reveal:(if .provenance.summary_source == "local-ledger-cache"
                    then "inspect the home and its home ledger publication"
                    else "inspect the home ledger publication and remote route" end)}),
        (([($snap.secondmate_current.records // [])[] | select(.parent_event.activity_scan.input_truncated == true or .parent_event.activity_scan.retained_truncated == true)] | length) as $n | if $n > 0 then {surface:("secondmate parent activity evidence truncated for \($n) record(s)"), reveal:"raise FM_SNAPSHOT_PARENT_ACTIVITY_LINES, FM_SNAPSHOT_PARENT_ACTIVITY_BYTES, or FM_SNAPSHOT_PARENT_ACTIVITIES"} else empty end),
        (([($snap.secondmate_current.records // [])[] | select(.parent_event.activity_scan.available == false)] | length) as $n | if $n > 0 then {surface:("secondmate parent activity evidence unavailable for \($n) record(s)"), reveal:"inspect the parent status logs"} else empty end),
        (if $all_decisions == 0 and ($decisions_all | length) > $decisions_n then {surface:("decisions_open showing \($decisions_n) of \($decisions_all | length)"), reveal:"--all-decisions"} else empty end),
        (if $all_decisions == 0 and $decisions_marked_deferred > 0 then {surface:("captain holds bucketed blocked, dated, or aged: \($decisions_marked_deferred)"), reveal:"--all-decisions"} else empty end),
        (if ($gates_shown | length) < ($gates_all | length) then {surface:("gates showing \($gates_shown | length) of \($gates_all | length)"), reveal:"--all-queued"} else empty end),
        (if $all_reports == 0 and ($reports_all | length) > $reports_n then {surface:("reports showing \($reports_n) of \($reports_all | length)"), reveal:"--all-reports"} else empty end),
        (if $all_recorded_prs == 0 and ($recorded_prs_all | length) > $recorded_prs_n then {surface:("recorded_prs showing \($recorded_prs_n) of \($recorded_prs_all | length)"), reveal:"--all-recorded-prs"} else empty end),
        (if $all_unhealthy == 0 and ($unhealthy_all | length) > $unhealthy_n then {surface:("unhealthy_endpoints showing \($unhealthy_n) of \($unhealthy_all | length)"), reveal:"--all-unhealthy"} else empty end),
        (if $include_prs == 1 and $pr_repos_total > $pr_repos_shown then {surface:("PR repositories showing \($pr_repos_shown) of \($pr_repos_total)"), reveal:"--all-pr-repos"} else empty end),
        (if $include_prs == 1 and $pr_rows_capped > 0 then {surface:("candidate_prs showing \($candidate_prs | length) of at least \($pr_rows_min_total); capped in \($pr_rows_capped) repo(s)"), reveal:"raise FM_BEARINGS_PR_LIMIT"} else empty end),
        (if $include_prs == 1 then empty else {surface:"live PR discovery + checks", reveal:"--include-prs"} end) ]) }
') || { echo "fm-bearings-snapshot: projection failed" >&2; exit 1; }

# --- handed-off decisions -----------------------------------------------------
# A decision row is handed off when, after the decision was last raised, the
# captain's answer or the work it waits on went to a worker. An open decision
# is the captain's until it resolves, so a hand-off needs positive evidence in
# the durable record of each home involved, never the hold reason and never
# prose: a steer (state/<task>.inbox, pending or handled) whose record carries
# the explicit `handoff-key=<key>` header that `fm-send.sh --handoff-key` writes
# - the hold id, sent to a task the hold tracks (the hold id, its recorded
# origin, or a task a `captain-held` line names) or, for a hold a secondmate
# owns, from main to that secondmate; or the decision key, sent to the task that
# raised it (a `default` key is never marked, so only the board hands it); the
# hold's parent-log mirror `resolved [key=captain-hold-<id>-<n>]` line, which
# bin/fm-captain-hold.sh writes when the hold is answered or released; a
# pending reconcile request for it, which the captain's board selection records
# when a card is out of date; or the captain's own answer to that card on the
# board (board_answer_records), which hands every kind of row - a captain hold
# in any home, a status question, and a review page - so a card the captain
# answered or marked out of date never asks again. A steer whose text only
# names a key (a duplicate cleanup, a re-raise request, a process rule) is not
# a hand-off, and neither is a marked steer that tells the worker to wait for
# the captain (for example "stay parked until the captain answers" or "keep the
# question held: the captain decides"). A `resolved` line whose plain key only
# equals the hold id (a worker closing its own duplicate key) is not a hand-off
# either. The decision is raised at the latest of its hold set stamp, its
# latest hold reconciled stamp (a re-hold after a reconcile request), and
# every needs-decision or blocked line its tracked tasks append, so a worker
# that raises a fresh question puts the decision back in front of the captain;
# a hold is also raised by every `captain-held` line naming it, and a review
# page by its task's latest done line.
# A handed row gains handed_at, handed_via (steer, resolved, reconcile, or board),
# handed_task, and raised_at; it stays in decisions_open, and the board payload
# shows it as a wait instead of a Captain's Call.
handoff_records() {  # <home-label> <state-dir>
  local label=$1 st=$2
  [ -d "$st" ] || return 0
  # shellcheck disable=SC2016 # the awk program is single-quoted on purpose.
  find "$st" -maxdepth 3 -type f \( -path "$st/*.inbox/*.msg" -o -path "$st/*.inbox/handled/*.msg" \
      -o -path "$st/*.status" -o -path "$st/*.meta" -o -path "$st/reconcile-requests/*.request" \) -print0 2>/dev/null \
    | xargs -0 -r awk -v label="$label" -v st="$st/" '
      function flush() {
        if (kind == "S" && at != "") printf "%s\tS\t%s\t%s\t%s\t%s\n", label, task, at, keys, body
        if (kind == "R" && at != "") printf "%s\tR\t%s\t%s\t\n", label, task, at
      }
      function oneline(s) { gsub(/[\t\r\n]/, " ", s); return s }
      FNR == 1 {
        flush(); kind = ""; at = ""; body = ""; keys = ""; inbody = 0
        rel = substr(FILENAME, length(st) + 1)
        if (rel ~ /\.inbox\//) { kind = "S"; task = rel; sub(/\.inbox\/.*$/, "", task) }
        else if (rel ~ /^reconcile-requests\//) { kind = "R"; task = rel; sub(/^.*\//, "", task); sub(/\.request$/, "", task) }
        else if (rel ~ /^[^\/]+\.meta$/) { kind = "P"; task = rel; sub(/\.meta$/, "", task) }
        else if (rel !~ /\//) { kind = "L"; task = rel; sub(/\.status$/, "", task) }
        if (task !~ /^[A-Za-z0-9._-]+$/) kind = ""
      }
      kind == "S" && !inbody {
        if ($0 == "--") inbody = 1
        else if ($0 ~ /^at=/) at = substr($0, 4)
        else if ($0 ~ /^handoff-key=[A-Za-z0-9._-]+$/) keys = keys (keys == "" ? "" : " ") substr($0, 13)
        next
      }
      kind == "S" { if (length(body) < 2000) body = substr(body " " oneline($0), 1, 2000); next }
      kind == "R" { if ($0 ~ /^requested=/) at = substr($0, 11); next }
      kind == "P" { if ($0 ~ /^pr=https:\/\/[^[:space:]]+$/) printf "%s\tP\t%s\t%s\n", label, task, substr($0, 4); next }
      kind == "L" {
        if (!match($0, /^(needs-decision|blocked|resolved|captain-held|done)[ :]/)) next
        verb = $0; sub(/[ :].*$/, "", verb)
        key = "default"
        if (match($0, /\[key=[^]]*\]/)) key = substr($0, RSTART + 5, RLENGTH - 6)
        a = ""
        if (match($0, /\[at=[0-9]+\]/)) a = substr($0, RSTART + 4, RLENGTH - 5)
        text = $0; sub(/^[^:]*: ?/, "", text)
        printf "%s\tL\t%s\t%s\t%s\t%s\t%s\n", label, task, verb, key, a, substr(oneline(text), 1, 300)
      }
      END { flush() }'
}

# Every answer the captain gave on this home's board: one record per answer
# card in a captured board result (state/procevent-inbox/lavish-*.result whose
# page is a .lavish/bearings-board.html), dated by the result's capture
# time, keyed by the card it answered, with its selection. "later" on a review
# card keeps the card, and an answer with neither a selection nor a note says
# nothing, so neither is recorded. Only the newest FM_BEARINGS_BOARD_RESULTS
# results (default 2000) are read.
board_answer_records() {  # <state-dir>
  local st=$1 limit=${FM_BEARINGS_BOARD_RESULTS:-2000} stamps
  [ -d "$st/procevent-inbox" ] || return 0
  case "$limit" in ''|*[!0-9]*) limit=2000 ;; esac
  stamps=$(find "$st/procevent-inbox" -maxdepth 1 -type f -name 'lavish-*.result' -print0 2>/dev/null \
    | { xargs -0 -r stat -c '%Y %n' 2>/dev/null || find "$st/procevent-inbox" -maxdepth 1 -type f \
          -name 'lavish-*.result' -print0 2>/dev/null | xargs -0 -r stat -f '%m %N' 2>/dev/null; } \
    | sort -rn | head -n "$limit")
  [ -n "$stamps" ] || return 0
  # shellcheck disable=SC2016 # the awk program is single-quoted on purpose.
  printf '%s\n' "$stamps" | awk '
    function field(s, name,   v) {
      if (!match(s, "\"" name "\": \"[^\"]*\"")) return ""
      v = substr(s, RSTART, RLENGTH); sub(/^"[a-z]+": "/, "", v); sub(/"$/, "", v)
      return v
    }
    {
      at = $1; file = substr($0, length($1) + 2); board = 0; n = 0
      while ((getline line < file) > 0) {
        n++
        if (n <= 3 && line ~ /^  file: /) board = (line ~ /\/\.lavish\/bearings-board\.html$/)
        if (n == 3 && !board) break
        if (!board || index(line, "fm-bearings-answer.v1") == 0) continue
        s = line; gsub(/\\"/, "\"", s)
        key = field(s, "question"); sel = field(s, "selection"); note = field(s, "note")
        if (key !~ /^[A-Za-z0-9._\/-]+$/ || sel == "later" || (sel == "" && note == "")) continue
        printf "(main)\tB\t%s\t%s\t%s\n", key, at, sel
      }
      close(file)
    }'
}

MAIN_STATE="${FM_STATE_OVERRIDE:-$(printf '%s' "$SNAP" | jq -r '.fm_home')/state}"
MATE_HOMES=$(printf '%s' "$SNAP" | jq -r '
  (.secondmate_current.records // [])[]
  | select((.provenance.structured_home | type) == "string")
  | select(((.provenance.summary_source // "") | startswith("remote")) | not)
  | select(.id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
  | [.id, .provenance.structured_home] | @tsv')
HANDOFF_EVIDENCE=$(mktemp "${TMPDIR:-/tmp}/fm-bearings-handoff.XXXXXX") \
  || { echo "fm-bearings-snapshot: cannot create a temporary file" >&2; exit 1; }
trap 'rm -f "$HANDOFF_EVIDENCE"' EXIT
{
  {
    handoff_records "(main)" "$MAIN_STATE"
    board_answer_records "$MAIN_STATE"
    while IFS=$'\t' read -r mate_id mate_home; do
      [ -n "$mate_id" ] && [ -d "$mate_home/state" ] || continue
      handoff_records "$mate_id" "$mate_home/state"
    done <<<"$MATE_HOMES"
  } | jq -R -s '
    def epoch: if test("^[0-9]+$") then tonumber
               else (try fromdateiso8601 catch null) end;
    [ split("\n")[] | select(length > 0) | split("\t")
      | if .[1] == "S" then {home:.[0], kind:"steer", task:.[2], at:(.[3] | epoch),
                             handoff_keys:((.[4] // "") | split(" ") | map(select(length > 0))), body:(.[5] // "")}
        elif .[1] == "R" then {home:.[0], kind:"request", task:.[2], at:(.[3] | epoch)}
        elif .[1] == "B" then {home:.[0], kind:"board", key:.[2], at:(.[3] | epoch), selection:(.[4] // "")}
        elif .[1] == "P" then {home:.[0], kind:"pr", task:.[2], url:(.[3] // "")}
        else {home:.[0], kind:"status", task:.[2], verb:.[3], key:.[4],
              at:(if .[5] == "" then null else (.[5] | epoch) end), text:(.[6] // "")} end ]
    | group_by(.home) | map({key:.[0].home, value:.}) | from_entries' >"$HANDOFF_EVIDENCE"
} || printf '{}\n' >"$HANDOFF_EVIDENCE"

MODEL=$(printf '%s' "$MODEL" | jq --slurpfile evs "$HANDOFF_EVIDENCE" '
  def iso: if . == null then null else todate end;
  def set_epoch:
    if (type) != "string" then null
    elif test("T") then (try fromdateiso8601 catch null)
    else (try ((. + "T00:00:00Z") | fromdateiso8601) catch null) end;
  def word_re: "(^|[^A-Za-z0-9._-])" + gsub("\\."; "\\.") + "($|[^A-Za-z0-9._-])";
  def names($id): test($id | word_re);
  def wait_steer:
    test("(once|when|until|after) the captain (answers|decides|replies|rules|responds)|the captain (decides|will decide)|stay(s)? parked|keep (it|the [a-z -]+) held|wait(ing|s)? (for|on) the captain|until the captain"; "i");
  # Marked steers after the raise that hand off $key: only the explicit
  # handoff-key header counts, and a marked steer that still tells the worker
  # to wait for the captain does not.
  def handoff_steers($recs; $after; $key):
    [ $recs[] | select(.kind == "steer" and .at != null and .at > $after)
      | select((.handoff_keys // []) | index($key))
      | select(.body | wait_steer | not) ];
  # The earliest hand-off after the raise, as the flat fields a row gains.
  def handed($cands; $raised):
    ($cands | sort_by(.at) | first) as $h
    | if $h == null then {}
      else {handed_at:($h.at | iso), handed_via:$h.via, handed_task:$h.task,
            raised_at:($raised | iso)} end;
  ($evs[0] // {}) as $ev
  | ($ev["(main)"] // []) as $main
  # The captain answered this very card on the board after it was raised.
  | def board_answers($key; $raised):
      [ $main[] | select(.kind == "board" and .key == $key and .at != null and .at > $raised)
        | {at, via:"board", task:"firstmate"} ];
  .decisions_open |= map(
      . as $row
      | (if .verb == "captain-hold" then
           (if .owner == "(main)" then "(main)" else .owner end) as $home
           | ($ev[$home] // []) as $recs
           | .key as $id
           | ($id | tostring) as $id
           | ([ $recs[] | select(.kind == "status" and .verb == "captain-held" and (.text | names($id))) | .task ]
              + [$id] + (if $row.origin == null then [] else [$row.origin] end) | unique) as $tracked
           | ("^captain-hold-" + ($id | gsub("\\."; "\\.")) + "-[0-9]+$") as $mirror
           | ($recs + (if $home == "(main)" then [] else
                         [ $main[] | select(.task == $home)
                           | select(.kind != "status" or .key == $id or (.key | test($mirror))) ] end)) as $scope
           | ([ $scope[] | select(.kind == "status" and .at != null)
                | select(.verb == "needs-decision" or .verb == "blocked"
                         or (.verb == "captain-held" and (.text | names($id))))
                | select((.task as $t | $tracked | index($t)) or (.key | test($mirror))) | .at ]
              + [ ($row.hold_set | set_epoch) // 0, ($row.hold_reconciled | set_epoch) // 0 ] | max) as $raised
           | handed(
               [ handoff_steers($recs; $raised; $id)[]
                 | select(.task as $t | $tracked | index($t))
                 | . + {via:"steer"} ]
               + [ handoff_steers([ $main[] | select($home != "(main)" and .task == $home) ]; $raised; $id)[]
                   | . + {via:"steer"} ]
               + [ $scope[] | select(.kind == "status" and .verb == "resolved" and .at != null and .at > $raised)
                   | select(.key | test($mirror)) | . + {via:"resolved"} ]
               + [ $recs[] | select(.kind == "request" and .task == $id and .at != null and .at > $raised)
                   | . + {via:"reconcile", task:"firstmate"} ]
               + board_answers($row.key; $raised);
               $raised)
         elif .source == "status" then
           (if .mate == null then "(main)" else .mate end) as $home
           | ($ev[$home] // []) as $recs
           | .task as $task | (.decision_key // "default") as $k
           | ([ $recs[] | select(.kind == "status" and .task == $task and .key == $k and .at != null)
                | select(.verb == "needs-decision" or .verb == "blocked") | .at ] | max) as $raised
           | if $raised == null then {}
             else handed(
               [ handoff_steers([ $recs[] | select(.task == $task) ]; $raised; $k)[]
                 | select($k != "default") | . + {via:"steer"} ]
               + board_answers($row.key; $raised);
               $raised) end
         elif .source == "review-page" then
           .task as $task
           | ([ $main[] | select(.kind == "status" and .task == $task and .verb == "done" and .at != null)
                | .at ] | max // 0) as $raised
           | handed(board_answers($row.key; $raised); $raised)
         else {} end) as $h
      | . + $h)
  # A decision whose reason links no PR/MR gains the pr_url its home recorded:
  # the one a task the row tracks recorded (the hold id or origin, the asking
  # task), else, when the reason names a number ("PR 91", "MR 874", "!874",
  # "#91"), the single PR/MR that home recorded with that number. A bare "#91"
  # names only a PR/MR in the repository of a link the reason already carries
  # (prose "#N" is usually an issue), so with no link it names nothing. A
  # status question a secondmate raised in the main log (owner the mate, no
  # mate) uses the home of that mate. A hold recorded with no link
  # (choices.no_link) never takes the PR of a task it tracks, only one its
  # reason names by number.
  | def pr_re: "https://[^[:space:]<>\"()]+?/(?:pull|pulls|-/merge_requests)/[0-9]+";
    def pr_repo: sub("/(?:-/merge_requests|pulls|pull)/[0-9]+$"; "");
    def in_repo($urls): pr_repo as $p
      | any($urls[]; if test("/-/") then sub("/-/.*$"; "") == $p
                     else . == $p or startswith($p + "/") end);
    .decisions_open |= map(
      ((.reason_full // .reason // "") | tostring) as $r
      | if ($r | test(pr_re)) or ((.pr_url // "") != "") then .
        else
          (if .verb == "captain-hold" then (.owner // "(main)")
           elif .source == "status" then (.mate // .owner // "(main)") else "(main)" end) as $home
          | [ ($ev[$home] // [])[] | select(.kind == "pr" and (.url | test("^" + pr_re + "$"))) ] as $prs
          | (if (.choices.no_link // false) then [] else [.key, .origin, .task] | map(strings) end) as $own
          | [ $r | scan("https://[^[:space:]<>\"()]+") | sub("[.,;:!?]+$"; "") ] as $links
          | [ $r | scan("(?:\\b(?:pr|mr|pull request|merge request)[[:space:]]*#?|\\B!)([0-9]+)(?![0-9])|\\B#([0-9]+)(?![0-9])"; "i")
              | if .[1] != null then {n:.[1], bare:true} else {n:.[0], bare:false} end ] as $nums
          | [ $prs[] | select(.task as $t | $own | index($t)) | .url ] as $mine
          | ( if ($nums | length) == 0 then ($mine | unique | if length == 1 then .[0] else null end)
              else first( $nums[] as $n
                          | def named: endswith("/" + $n.n) and (($n.bare | not) or in_repo($links));
                          ([ $mine[] | select(named) ] | unique) as $m
                          | ([ $prs[] | .url | select(named) ] | unique) as $any
                          | if ($m | length) == 1 then $m[0]
                            elif ($any | length) == 1 then $any[0] else empty end ) // null
              end ) as $u
          | if $u == null then . else . + {pr_url: $u} end
        end)')

# --- optional live GitLab MR listing ----------------------------------------
# Under --include-mrs only: every open GitLab MR the captain authored, and those
# awaiting their review that the rest of this view does not show. One bounded user call
# for the captain's id and two bounded list calls against the configured host
# (merged by project and iid), one bounded project read per distinct project to
# drop MRs of an archived project, then one bounded detail, approvals and
# reviewers call per listed MR (every one of the FM_BEARINGS_MRS kept, so none
# shows CI or approvals unknown for want of a read), in waves of at most FM_BEARINGS_MR_DETAIL_PARALLEL
# MRs so a long list neither fans out unboundedly nor runs past a few timeouts.
# Read-only. An authored MR (from the created_by_me list, or authored by the
# captain's id) is never covered. A review MR is covered when its exact web_url or full reference
# (group/project!iid), not followed by another digit, appears in a projected
# section the board shows (decisions, gates, landed, captain contributions), is
# the recorded PR of an open decision's own task (its card links it), or appears
# as the pr_url or in the name or `doing` text of the underway row of the task
# that records it;
# there is no fuzzy match. The canonical snapshot text is deliberately not
# consulted: its Done records and full status lines name MRs the board never
# shows, which would hide them from every card and row. recorded_prs alone and
# a wait on another task's MR do not cover either, for the same reason. A
# missing glab, no host, or a failed or timed-out call leaves open_mrs out, says
# so on the mrs line, and writes one line to stderr; it never fails the snapshot.
MR_STATUS='not_requested (run: /bearings include MRs)'
OPEN_MRS=null
if [ "$INCLUDE_MRS" = 1 ]; then
  mr_unavailable() { MR_STATUS="unavailable ($1)"; echo "fm-bearings-snapshot: GitLab MRs unavailable ($1)" >&2; }
  glab_bounded() { fm_run_timed "$FM_BEARINGS_MR_TIMEOUT" env GLAB_NO_PROMPT=1 GLAB_CHECK_UPDATE=false glab "$@" </dev/null; }
  if ! command -v glab >/dev/null 2>&1; then
    mr_unavailable "glab not found"
  else
    mr_host=${FM_BEARINGS_GITLAB_HOST:-}
    [ -n "$mr_host" ] || mr_host=$(glab_bounded config get host 2>/dev/null | head -n 1) || mr_host=""
    mr_host=$(printf '%s' "$mr_host" | tr -d '[:space:]')
    case "$mr_host" in *[!A-Za-z0-9.:-]*) mr_host="" ;; esac
    if [ -z "$mr_host" ]; then
      mr_unavailable "no GitLab host configured"
    elif ! mr_uid=$(glab_bounded api --hostname "$mr_host" user 2>/dev/null \
          | jq -er 'select(type == "object" and (.id | type) == "number") | .id' 2>/dev/null) \
      || ! mr_authored=$(glab_bounded api --hostname "$mr_host" \
        "merge_requests?scope=created_by_me&state=opened&per_page=100" 2>/dev/null) \
      || ! mr_reviewing=$(glab_bounded api --hostname "$mr_host" \
        "merge_requests?scope=all&state=opened&reviewer_id=$mr_uid&per_page=100" 2>/dev/null) \
      || ! mr_list=$(printf '%s\n%s\n' "$mr_authored" "$mr_reviewing" \
        | jq -s -c --argjson uid "$mr_uid" 'if length == 2 and all(.[]; type == "array")
                    then .[0] as $mine
                    | add | map(select(type == "object")) | unique_by([.project_id, .iid])
                    | map(. as $m | . + {authored: (any($mine[]; type == "object"
                                                       and .project_id == $m.project_id and .iid == $m.iid)
                                                   or (.author.id // null) == $uid)})
                    else error("not a list") end' 2>/dev/null); then
      mr_unavailable "glab api failed or timed out on $mr_host"
    else
      mr_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings-mrs.XXXXXX")
      mr_coverage_failed() { rm -rf "$mr_tmp"; echo "fm-bearings-snapshot: MR coverage projection failed" >&2; exit 1; }
      mr_rec=$(printf '%s' "$SNAP" | jq -c \
        '[.tasks[] | select(.kind != "secondmate" and .pr.url != null and .pr.source == "meta") | {id, url:.pr.url}]') \
        || mr_coverage_failed
      # What the board shows: decision cards and waiting rows (their text and
      # the PR a decision's own task recorded, which its card links), queued
      # and charted rows, landed rows and contribution cards. An underway row
      # shows only its name, its cut `doing` and its pr_url link, and covers only the MR its own
      # task records - a wait it names on another task's MR is not that MR's row.
      printf '%s\n' "$MODEL" | jq --argjson rec "$mr_rec" '
        ([.decisions_open[]?.id] | map(strings)) as $ids
        | {decisions_open, gates, landed, contributions: (.contributions.captain // null),
           decision_prs: [$rec[] | select(.id as $i | any($ids[]; . == $i)) | .url]}' > "$mr_tmp/known" \
        || mr_coverage_failed
      printf '%s' "$MODEL" | jq -c --argjson rec "$mr_rec" '
        [.in_flight[]? | select(.state != "done") | . as $r
         | {text: ("\(.name // "") \(.doing // "")"),
            named: ($r.pr_url // null),
            own: ([$rec[] | select(.id == $r.id) | .url] + [$r.pr_url // empty] | map(strings))}
         | select(.own != [])]' > "$mr_tmp/rows" \
        || mr_coverage_failed
      # The captain's own MRs (Draft included) and the uncovered review MRs,
      # newest activity first. An own MR stays listed even when a card names it:
      # the card goes once its decision is answered, and the MR is still open.
      mr_uncovered=$(printf '%s' "$mr_list" | jq -c --rawfile known "$mr_tmp/known" --slurpfile rows "$mr_tmp/rows" '
        def names($t; $s): ($s | length) > 0 and
          any($t | indices($s)[]; ($t[(. + ($s | length)):(. + ($s | length) + 1)] | test("^[0-9]") | not));
        def shown($s): names($known; $s);
        def own_row($u; $s): any($rows[0][]; any(.own[]; . == $u) and (.named == $u or names(.text; $s)));
        [ .[] | select(type == "object" and (.iid | type) == "number" and (.project_id | type) == "number"
                       and ((.web_url // "") | startswith("https://")))
          | .web_url as $u | (.references.full // "") as $ref
          | select(.authored == true
                   or ((shown($u) or shown($ref) or own_row($u; $u) or own_row($u; $ref)) | not)) ]
        | sort_by(.updated_at // "") | reverse')
      # GitLab keeps an MR "opened" after its project is archived and does not
      # honour the list call's archive filter everywhere, so read each distinct
      # project once (bounded, in parallel) and drop the MRs of an archived one.
      # A project that cannot be read keeps its MRs.
      while read -r pid; do
        [ -n "$pid" ] || continue
        ( glab_bounded api --hostname "$mr_host" "projects/$pid" > "$mr_tmp/p-$pid" 2>/dev/null || rm -f "$mr_tmp/p-$pid" ) &
      done <<EOF
$(printf '%s' "$mr_uncovered" | jq -r --argjson cap "$FM_BEARINGS_MR_PROJECT_MAX" '[.[].project_id] | unique | .[:$cap][]')
EOF
      wait
      mr_archived=$(for f in "$mr_tmp"/p-*; do
          [ -f "$f" ] || continue
          jq -c 'select(type == "object" and .archived == true and (.id | type) == "number") | .id' "$f" 2>/dev/null
        done | jq -s -c '.')
      [ -n "$mr_archived" ] || mr_archived='[]'
      mr_uncovered=$(printf '%s' "$mr_uncovered" | jq -c --argjson arch "$mr_archived" \
        '[ .[] | select(.project_id as $p | $arch | index($p) | not) ]')
      mr_total=$(printf '%s' "$mr_uncovered" | jq 'length')
      i=0
      while IFS=$'\t' read -r pid iid; do
        [ -n "$pid" ] || continue
        if [ "$i" -gt 0 ] && [ $((i % FM_BEARINGS_MR_DETAIL_PARALLEL)) = 0 ]; then wait; fi
        i=$((i + 1))
        ( glab_bounded api --hostname "$mr_host" "projects/$pid/merge_requests/$iid" > "$mr_tmp/d-$pid-$iid" 2>/dev/null || rm -f "$mr_tmp/d-$pid-$iid" ) &
        ( glab_bounded api --hostname "$mr_host" "projects/$pid/merge_requests/$iid/approvals" > "$mr_tmp/a-$pid-$iid" 2>/dev/null || rm -f "$mr_tmp/a-$pid-$iid" ) &
        ( glab_bounded api --hostname "$mr_host" "projects/$pid/merge_requests/$iid/reviewers" > "$mr_tmp/r-$pid-$iid" 2>/dev/null || rm -f "$mr_tmp/r-$pid-$iid" ) &
      done <<EOF
$(printf '%s' "$mr_uncovered" | jq -r --argjson cap "$FM_BEARINGS_MRS" '.[:$cap][] | "\(.project_id)\t\(.iid)"')
EOF
      wait
      # The detail map grows with every listed MR, so it reaches jq as a file:
      # an argument that size overflows the kernel's argument limit.
      for f in "$mr_tmp"/d-* "$mr_tmp"/a-* "$mr_tmp"/r-*; do
          [ -f "$f" ] || continue
          jq -c --arg k "${f##*/}" 'select(type == (if ($k | startswith("r-")) then "array" else "object" end))
            | {key:$k, value:.}' "$f" 2>/dev/null
        done | jq -s 'from_entries' > "$mr_tmp/details"
      [ -s "$mr_tmp/details" ] || printf '{}' > "$mr_tmp/details"
      OPEN_MRS=$(printf '%s' "$mr_uncovered" | jq -c --slurpfile detf "$mr_tmp/details" --argjson cap "$FM_BEARINGS_MRS" \
        --argjson uid "$mr_uid" '
        $detf[0] as $det
        |
        # Someone else'"'"'s MR the captain already reviewed waits on its author;
        # a missing reviewers read names no one.
        def wait_owner($r):
          (.author.username // "") as $who
          | if (.author.id // null) == $uid or ($r | type) != "array" or ($who | type) != "string" or $who == ""
            then empty
            else ({reviewed:"you reviewed", requested_changes:"you requested changes", approved:"you approved"}
                  [first($r[] | select(type == "object" and .user.id == $uid) | .state | strings) // ""])
                 | select(. != null) | "waiting on \($who) (\(.))" end;
        def merge_state:
          if .draft == true or .detailed_merge_status == "draft_status" then "draft"
          elif .has_conflicts == true or .detailed_merge_status == "conflict" then "has conflicts"
          else ({mergeable:"mergeable", discussions_not_resolved:"threads open", ci_must_pass:"waiting on CI",
                 ci_still_running:"waiting on CI", not_approved:"needs approval", need_rebase:"needs rebase",
                 checking:"checking", unchecked:"checking", blocked_status:"blocked by another MR",
                 not_open:"not open"}[.detailed_merge_status // ""]
                // ((.detailed_merge_status // "merge state unknown") | gsub("_"; " "))) end;
        def ci($d):
          if $d == null then "CI unknown"
          elif $d.head_pipeline == null then "no CI run"
          else ({success:"CI passing", failed:"CI failing", canceled:"CI canceled", skipped:"CI skipped",
                 manual:"CI waiting on a manual job", running:"CI running", pending:"CI pending",
                 created:"CI pending", preparing:"CI pending", waiting_for_resource:"CI pending"}[$d.head_pipeline.status // ""]
                // ("CI " + ($d.head_pipeline.status // "unknown"))) end;
        def approvals($a):
          if $a == null then "approvals unknown"
          else ($a.approved_by // [] | length) as $n | "\($n) approval" + (if $n == 1 then "" else "s" end) end;
        [ .[:$cap][] | "\(.project_id)-\(.iid)" as $id
          | {key:("mr-" + $id),
             repo:((.web_url | split("/-/")[0] | split("/") | last) // "-"),
             title:((.title // "") | if . == "" then "MR !\(.iid)" else . end),
             url:.web_url,
             state:([wait_owner($det["r-" + $id]), merge_state, ci($det["d-" + $id]), approvals($det["a-" + $id]),
                     (if .blocking_discussions_resolved == false then "threads open" else "threads resolved" end),
                     "last activity " + ((.updated_at // "unknown") | .[0:10])]
                    | reduce .[] as $p ([]; if index([$p]) then . else . + [$p] end) | join(", ")),
             updated:(.updated_at // "")} ]')
      rm -rf "$mr_tmp"
      mr_shown=$(printf '%s' "$OPEN_MRS" | jq 'length')
      MR_STATUS="checked ($mr_host, $mr_shown open MR(s): own, or reviews no task covers)"
      if [ "$mr_total" -gt "$mr_shown" ]; then
        MR_STATUS="checked ($mr_host, showing $mr_shown of $mr_total open MR(s): own, or reviews no task covers)"
      fi
    fi
  fi
fi
# open_mrs reaches jq as a file for the same argument-limit reason.
open_mrs_file=$(mktemp "${TMPDIR:-/tmp}/fm-bearings-open-mrs.XXXXXX")
printf '%s' "$OPEN_MRS" > "$open_mrs_file"
MODEL=$(printf '%s' "$MODEL" | jq --arg mrs "$MR_STATUS" --slurpfile open_mrs_f "$open_mrs_file" \
  --argjson include_mrs "$INCLUDE_MRS" --argjson cap "$FM_BEARINGS_MRS" '
  $open_mrs_f[0] as $open_mrs
  | .omitted as $om
  | del(.omitted) + {mrs:$mrs}
  + (if $open_mrs == null then {} else {open_mrs:$open_mrs} end)
  + {omitted: ($om + (if $include_mrs == 1 then [] else [{surface:"captain'"'"'s open GitLab MRs", reveal:"--include-mrs"}] end))}') \
  || { rm -f "$open_mrs_file"; echo "fm-bearings-snapshot: MR projection failed" >&2; exit 1; }
rm -f "$open_mrs_file"

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

# --- TOON renderer (output boundary; parity with the JSON model) ------------
# Nested objects use indented keys; arrays of uniform scalar objects use
# the tabular array form
# (key[N]{fields}: + comma rows at +2 indent), and the empty-array form (key: []),
# per the TOON spec. Quoting follows the spec exactly.
TOON=$(printf '%s\n' "$MODEL" | jq -r '
  def q:
    tostring
    | if (. == "")
        or test("^\\s|\\s$")
        or (. == "true" or . == "false" or . == "null")
        or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
        or test("[:\"\\\\\\[\\]{},]")
        or test("[[:cntrl:]]")
        or test("^-")
      then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
      else . end;
  def scal:
    if . == null then "null"
    elif type == "boolean" then (if . then "true" else "false" end)
    elif type == "number" then tostring
    else q end;
  def emit($k; $v):
    if ($v | type) == "object" then
      "\($k): ", ($v | to_entries[] | emit(.key;.value) | "  " + .)
    elif ($v | type) == "array" then
      if ($v | length) == 0 then "\($k): []"
      else
        ($v[0] | keys_unsorted) as $ks
        | ( "\($k)[\($v | length)]{\($ks | map(q) | join(","))}:",
            ($v[] as $row | "  " + ([ $ks[] as $kk | ($row[$kk] | scal) ] | join(","))) )
      end
    else "\($k): " + ($v | scal)
    end;
  [ to_entries[] | emit(.key; .value) ] | join("\n")
') || { echo "fm-bearings-snapshot: TOON rendering failed" >&2; exit 1; }
printf '%s\n' "$TOON"
