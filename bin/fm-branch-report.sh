#!/usr/bin/env bash
# fm-branch-report.sh - the supervision branch's report surface off Pi: the
# command twin of the Pi branch extension's fm_branch_report tool, for a
# branch session run by the supervision host (docs/supervision-host.md).
#
# It records exactly one handled fleet event in the durable outcome store
# (bin/fm-branch-outcome.sh owns the store) and gives the host the receipt it
# requires before it counts a wake handled. It enforces the same scoping the
# Pi tool does (docs/pi-supervision-branch.md "Components and their owners"):
# while the host's current turn claims signal or stale rows, only the tasks
# those rows resolve to may be reported - `fleet` and any remembered task are
# refused before the store is touched - and a claim that names no task (a
# heartbeat review, or a claimed heartbeat or check row) is unscoped. The
# claimed task set comes from .pi/extensions/lib/fm-branch-dispatch.ts through
# the host's turn record; this script only compares against it.
#
# Usage:
#   fm-branch-report.sh --task <id|fleet> --verdict routine|captain \
#       --summary <text> [--silent true|false] [--inform true|false] \
#       [--ask <question?>] [--wake <text>]
#
# The verdict criteria are owned by bin/fm-branch-prompt.sh ("Verdict: routine
# or captain"); --silent true is legal only for a routine outcome.
# --inform true marks a captain outcome that MAIN has nothing to act on, only
# to relay (docs/supervision-host.md "Captain outcomes"); it is legal only for
# a captain outcome and defaults to false, so an unmarked captain outcome
# stays one MAIN acts on. The mark lives in the host's receipt, never in the
# outcome store, so the stored row and its delivery are those of any captain
# row.
# --wake defaults to the wake reason the host recorded for the turn.
# --ask <question?> marks a captain outcome that needs the captain's decision
# or a step only the captain can take; it is legal only for a captain outcome
# MAIN acts on (not --inform true) and must end in "?", or the report is
# refused with exit 2 and nothing recorded. Only an --ask outcome holds a
# captain call; every other outcome, captain or routine, holds nothing. Before
# an --ask outcome is recorded this script makes sure an open captain hold
# carries it (bin/fm-captain-hold.sh `covered`): an existing hold on the task,
# or one gating or originating from it, is enough, and so is a call the task's
# secondmate already holds in its own home (an open `captain-hold-<id>-<n>`
# decision on the task's parent-channel status file), which the stored summary
# then names as "(held in the <task> home as <ids>)"; otherwise it holds a new
# `<task>-captain` row (`fleet-captain-<epoch>` for the fleet) with the
# question as its reason, the task as its origin, a free-text answer, and the
# question's https URLs as its links (no link when it names none), so the
# card reaches the board ready to answer. A home with no automatic backlog
# skips this; a hold that cannot be read or created refuses with exit 1 and
# records nothing.
#
# Only the branch actor of a live host turn may report: FM_SUPERVISION_ACTOR
# must be "branch" and FM_BRANCH_REPORT_TURN must name the host's current turn
# record ($STATE/.supervision-host-turn), so a report typed after its turn
# ended, or from any other shell, is refused. Exit codes: 0 recorded, 1 the
# store refused or failed (nothing recorded), 2 usage, 3 refused (actor, turn,
# or scope).
#
# A non-silent row an away turn recorded after the captain returned (the turn
# record says posture=away, or predates the posture field, and no away record
# remains: none, or quiet mode's, whose captain is present; bin/fm-afk-contract.sh
# AWAY OR QUIET) may be missing from the return brief, so it is also queued
# for MAIN as a durable check wake keyed supervision-host-return:<seq>,
# presented by the drain until MAIN acknowledges it. bin/fm-afk-return.sh
# archives the record before it reads the store and this check follows the
# append, so every visible row is in the brief, queued, or both: the relay does
# not depend on the host surviving its turn or on its owner delivering the
# host's own handback. Silent outcomes remain in the store but are not queued
# or relayed as notes. An attended turn queues nothing: its captain rows reach
# MAIN through the host's branch-outcome exit and the drain's BRANCH OUTCOMES
# section (bin/fm-wake-drain.sh), and its routine rows stay in the store.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TURN_FILE="$STATE/.supervision-host-turn"
RECEIPTS="$STATE/.supervision-host-receipts"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"

usage() {
  sed -n '/^# Usage:/,/^#       \[--wake/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

refuse() {
  printf 'report refused: %s\n' "$1" >&2
  exit 3
}

TASK='' VERDICT='' SUMMARY='' SILENT=false INFORM=false ASK='' ASK_SET=0 WAKE='' WAKE_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) TASK=${2:-}; shift 2 || usage ;;
    --verdict) VERDICT=${2:-}; shift 2 || usage ;;
    --summary) SUMMARY=${2:-}; shift 2 || usage ;;
    --silent) SILENT=${2:-}; shift 2 || usage ;;
    --inform) INFORM=${2:-}; shift 2 || usage ;;
    --ask) ASK=${2:-}; ASK_SET=1; shift 2 || usage ;;
    --wake) WAKE=${2:-}; WAKE_SET=1; shift 2 || usage ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

TASK=$(printf '%s' "$TASK" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
SUMMARY=$(printf '%s' "$SUMMARY" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
ASK=$(printf '%s' "$ASK" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
case "$VERDICT" in routine|captain) ;; *) VERDICT= ;; esac
case "$SILENT" in true|false) ;; *) usage ;; esac
case "$INFORM" in true|false) ;; *) usage ;; esac
if [ -z "$TASK" ] || [ -z "$SUMMARY" ] || [ -z "$VERDICT" ]; then
  echo "invalid report: --task, --verdict (routine|captain), and --summary are required" >&2
  exit 2
fi
if [ "$SILENT" = true ] && [ "$VERDICT" != routine ]; then
  echo "invalid report: --silent true requires the routine verdict" >&2
  exit 2
fi
if [ "$INFORM" = true ] && [ "$VERDICT" != captain ]; then
  echo "invalid report: --inform true requires the captain verdict" >&2
  exit 2
fi
if [ "$ASK_SET" -eq 1 ]; then
  if [ "$VERDICT" != captain ] || [ "$INFORM" = true ]; then
    echo "invalid report: --ask requires the captain verdict without --inform true" >&2
    exit 2
  fi
  case "$ASK" in
    *'?') ;;
    *)
      echo "invalid report: --ask must be the question the captain answers, ending in '?'" >&2
      exit 2
      ;;
  esac
fi

[ "${FM_SUPERVISION_ACTOR:-}" = branch ] \
  || refuse "only the supervision branch reports outcomes; MAIN acts on them instead"
TURN=${FM_BRANCH_REPORT_TURN:-}
case "$TURN" in
  ''|*[!A-Za-z0-9._-]*) refuse "no supervision wake is being handled by this shell" ;;
esac

turn_field() {  # <name>
  sed -n "s/^$1=//p" "$TURN_FILE" 2>/dev/null | head -n 1
}

[ -f "$TURN_FILE" ] && [ ! -L "$TURN_FILE" ] \
  || refuse "the wake this shell was handling is over; report only while handling a wake"
[ "$(turn_field turn)" = "$TURN" ] \
  || refuse "the wake this shell was handling is over; report only while handling a wake"

if [ "$(turn_field unscoped)" != 1 ]; then
  TASKS=$(turn_field tasks)
  case " $TASKS " in
    *" $TASK "*) ;;
    *)
      refuse "the wake being handled (row $(turn_field rows)) names ${TASKS:-no task}, not $TASK; report only that task, never fleet or a task from memory"
      ;;
  esac
fi

[ "$WAKE_SET" -eq 1 ] || WAKE=$(turn_field wake)

captain_hold() {  # <captain-hold args...>
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" "$@"
}

# The distinct https URLs the question names, trailing punctuation trimmed,
# one per line and at most the 8 a card shows.
ask_links() {
  printf '%s\n' "$ASK" | grep -oE "https://[^[:space:]<>\"'()]+" \
    | sed -E 's/[].,;:!?]+$//' \
    | grep -E '^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?([/?#][^[:space:]]*)?$' \
    | awk '!seen[$0]++' | head -n 8
}

# The captain holds a secondmate already keeps open in its own home for this
# task, comma-separated: each one publishes an open
# `needs-decision [key=captain-hold-<id>-<n>]` on its parent-channel status
# file here (bin/fm-captain-hold.sh `hold`), so the call is already on the
# board and a main hold would only repeat it.
mate_home_holds() {
  local open key ids=''
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh" || return 1
  open=$(status_open_decisions "$STATE/$TASK.status" secondmate) || return 1
  while IFS= read -r key; do
    key=${key%%$'\t'*}
    case "$key" in captain-hold-?*-[0-9]*) ;; *) continue ;; esac
    key=${key#captain-hold-}
    key=${key%-*}
    case ",$ids," in *",$key,"*) ;; *) ids=${ids:+$ids,}$key ;; esac
  done <<EOF
$open
EOF
  printf '%s' "$ids"
}

# Make sure an open captain hold carries this --ask outcome (see the header).
ensure_captain_hold() {
  local rc=0 id title out links url
  [ -d "$DATA" ] || return 0
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh" || return 1
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh" || return 1
  fm_backlog_transition_applies "$CONFIG" "$DATA" captain || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *)
      echo "whether this home's backlog can hold the captain outcome could not be read${FM_BACKLOG_TRANSITION_ERROR:+: $FM_BACKLOG_TRANSITION_ERROR} (nothing recorded)" >&2
      return 1
      ;;
  esac
  if [ "$TASK" = fleet ]; then
    id="fleet-captain-$(date +%s)"
    title="Captain call from fleet supervision"
    set -- hold "$id" --title "$title" --reason "$ASK"
  else
    rc=0
    out=$(captain_hold covered "$TASK" 2>&1) || rc=$?
    case "$rc" in
      0) return 0 ;;
      1) ;;
      *)
        printf 'whether an open captain hold carries %s could not be read (nothing recorded)\n%s\n' "$TASK" "$out" >&2
        return 1
        ;;
    esac
    MATE_HOLDS=$(mate_home_holds) || {
      printf 'whether the %s home already holds this call could not be read (nothing recorded)\n' "$TASK" >&2
      return 1
    }
    [ -z "$MATE_HOLDS" ] || return 0
    id="$TASK-captain"
    rc=0
    captain_hold open "$id" --distinguish-absent >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ] || id="$TASK-captain-$(date +%s)"
    set -- hold "$id" --title "Captain call from $TASK" --origin "$TASK" --reason "$ASK"
  fi
  set -- "$@" --free-text
  links=$(ask_links)
  if [ -n "$links" ]; then
    while IFS= read -r url; do set -- "$@" --link "$url"; done <<EOF
$links
EOF
  else
    set -- "$@" --no-link
  fi
  if ! out=$(captain_hold "$@" 2>&1); then
    printf 'the captain outcome could not be held for the captain as %s (nothing recorded)\n%s\n' "$id" "$out" >&2
    return 1
  fi
  CAPTAIN_HOLD_ID=$id
}

CAPTAIN_HOLD_ID='' MATE_HOLDS=''
if [ "$ASK_SET" -eq 1 ]; then
  ensure_captain_hold || exit 1
fi
[ -z "$MATE_HOLDS" ] || SUMMARY="$SUMMARY (held in the $TASK home as $MATE_HOLDS)"

set -- append --task "$TASK" --verdict "$VERDICT" --summary "$SUMMARY" --silent "$SILENT"
[ -z "$WAKE" ] || set -- "$@" --wake "$WAKE"
if ! SEQ=$("$SCRIPT_DIR/fm-branch-outcome.sh" "$@"); then
  echo "outcome store append failed (nothing recorded)" >&2
  exit 1
fi
MARK=act
[ "$INFORM" != true ] || MARK=inform
printf '%s\t%s\t%s\t%s\t%s\n' "$TURN" "$SEQ" "$VERDICT" "$TASK" "$MARK" >> "$RECEIPTS" || {
  echo "recorded seq $SEQ, but the host receipt could not be written; the host will hand this wake to MAIN" >&2
  exit 1
}
[ -z "$CAPTAIN_HOLD_ID" ] || printf 'held for the captain as %s, so the outcome shows on the board\n' "$CAPTAIN_HOLD_ID"
[ -z "$MATE_HOLDS" ] || printf 'already held in the %s home as %s, so no main captain hold was added\n' "$TASK" "$MATE_HOLDS"
if [ "$SILENT" = true ]; then
  printf 'recorded seq %s [routine]; silent outcome remains in the outcome store\n' "$SEQ"
  exit 0
fi
if [ "$(turn_field posture)" = attended ]; then
  if [ "$VERDICT" = captain ] && ! fm_afk_contract_away_present "$STATE"; then
    if [ "$INFORM" = true ]; then
      printf 'recorded seq %s [captain, informational]; it opens no MAIN turn and MAIN prints it at its next drain\n' "$SEQ"
    else
      printf 'recorded seq %s [captain]; MAIN processes it from its next drain\n' "$SEQ"
    fi
  else
    printf 'recorded seq %s [%s]; it waits in the outcome store for MAIN\n' "$SEQ" "$VERDICT"
  fi
  exit 0
fi
if ! fm_afk_contract_away_present "$STATE"; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if ! fm_wake_append check "supervision-host-return:$SEQ" \
    "check: supervision-host outcome $SEQ for $TASK [$VERDICT] was recorded after the captain returned, so the return brief may not show it; relay it to the captain: $SUMMARY"; then
    printf 'recorded seq %s [%s], but the captain has returned and its relay to MAIN could not be queued; the host hands this turn to MAIN\n' "$SEQ" "$VERDICT" >&2
    exit 0
  fi
  printf 'recorded seq %s [%s]; the captain has returned, so it is queued for MAIN to relay\n' "$SEQ" "$VERDICT"
  exit 0
fi
printf 'recorded seq %s [%s]; it waits in the outcome store for MAIN\n' "$SEQ" "$VERDICT"
