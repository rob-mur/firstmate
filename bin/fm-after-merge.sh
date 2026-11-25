#!/usr/bin/env bash
# Run, record, or require the after-merge action a task's project declares in
# its registry entry (after-merge= and after-merge-note=, parsed and validated
# by bin/fm-project-mode.sh --after-merge, whose header owns the encoding).
#
# Usage:
#   fm-after-merge.sh <task-id>                    run the declared action
#   fm-after-merge.sh <task-id> --mark-done <how>  record done by hand
#   fm-after-merge.sh <task-id> --require-done     cleanup gate
#
# The project is the basename of the task record's project= path, the same
# registry name every other reader uses. A project that declares no action is
# a silent no-op in every form: nothing is run, printed, recorded, or refused,
# so its merges and cleanups behave exactly as they did without this script.
# A task record with no project= declares nothing either.
#
# Running the one action, ff:<path>@<remote>/<branch>, fetches <remote> into
# the checkout at <path> and fast-forwards <branch> to <remote>/<branch>. It
# stops without changing the checkout when <path> is not a Git work tree, is on
# another branch, has uncommitted tracked changes, or has diverged from the
# target, and it never forces, resets, or stashes; Git's own fast-forward also
# refuses when an untracked file would be overwritten. A checkout already at or
# ahead of the target counts as done.
# Each run records after_merge=done|failed and a one-line after_merge_reason=
# in state/<task-id>.meta under the task's meta lock, replacing earlier values.
# On done it prints "after-merge done: <reason>" and, when the project declares
# a note, "relay to the captain: <note>" and holds that note for the captain as
# a card (see "Captain card" below). On failure it prints an
# "actionable:" line naming the retry and hand-record commands on stderr and
# exits 1.
#
# --mark-done records after_merge=done with "recorded by hand: <how>" when the
# captain or firstmate completed the step another way; it requires a declared
# action and a non-empty <how>.
# --mark-done holds the same card.
# --require-done exits 0 when no action is declared or after_merge=done is
# recorded; otherwise it prints why on stderr, naming both commands, and exits
# 1. A malformed registry token also refuses there.
#
# Callers: bin/fm-pr-merge.sh after a confirmed merge it performed,
# bin/fm-merge-local.sh after a landing, and bin/fm-teardown.sh, which runs
# --require-done before cleaning up a ship task.
# A merge this home only detects (a queued or unconfirmed merge, or one made
# outside firstmate that its merge poll saw) is not run automatically; the
# cleanup gate stops it until this script is run by hand. A PR closed without
# a merge owes nothing and is not gated.
#
# Captain card: a declared note is something only the captain can do (such as
# a command to run on each machine), so a chat line alone can be lost. Each
# time the note is relayed, this script also holds backlog task
# <task-id>-after-merge for the captain through bin/fm-captain-hold.sh hold,
# titled "<note> to put <project> PR <n> live" with the PR's recorded pr= URL in
# the reason and as the card's link (a local-only landing names its branch
# and has no link), and one "done" choice. The task records
# after_merge_card=<card-id> once held, and a rerun, a retry of the merge, or a
# later --mark-done for the same task skips the hold, so one merge yields at
# most one card; the captain's answer closes it the normal way. A hold that
# cannot be made prints an "actionable:" line naming the hand command on
# stderr but does not change the exit status, because the action itself did
# complete and the cleanup gate depends only on that.
# tests/fm-after-merge.test.sh covers this script.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() { echo "usage: fm-after-merge.sh <task-id> [--mark-done <how>|--require-done]" >&2; exit 2; }
[ "$#" -ge 1 ] || usage
ID=$1
shift
fm_pr_task_id_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
ACTION=run
HOW=
case "${1:-}" in
  '') ;;
  --mark-done)
    [ "$#" -eq 2 ] && [ -n "$2" ] || usage
    ACTION=mark
    HOW=$2
    ;;
  --require-done) [ "$#" -eq 1 ] || usage; ACTION=require ;;
  *) usage ;;
esac

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
meta_value() { grep "^$1=" "$META" | tail -1 | cut -d= -f2- || true; }
PROJ=$(meta_value project)
[ -n "$PROJ" ] || exit 0
NAME=$(basename "$PROJ")
SELF="$SCRIPT_DIR/fm-after-merge.sh"
RETRY="$SELF $ID"
MARK="$SELF $ID --mark-done \"<how it was done>\""

decl_rc=0
DECL=$("$SCRIPT_DIR/fm-project-mode.sh" --after-merge "$NAME" 2>/dev/null) || decl_rc=$?
if [ "$decl_rc" -ne 0 ]; then
  # Re-run for the refusal text, so the operator sees which token is wrong.
  "$SCRIPT_DIR/fm-project-mode.sh" --after-merge "$NAME" >/dev/null || true
  echo "actionable: project $NAME declares an after-merge action that cannot be read; correct its registry entry, then run $RETRY (or record it by hand with $MARK)" >&2
  exit 1
fi
[ -n "$DECL" ] || exit 0
IFS=$'\t' read -r KIND CHECKOUT REMOTE BRANCH NOTE <<EOF
$DECL
EOF

# meta_replace <key> <value> [<key> <value>]...: replace those keys in the
# task record under its meta lock, keeping every other line.
meta_replace() {
  local lock tmp
  local -a drop=()
  local i
  for ((i = 1; i <= $#; i += 2)); do drop+=(-e "^${!i}="); done
  lock=$(fm_meta_lock_path "$META") || { echo "error: cannot lock task $ID's record" >&2; return 1; }
  fm_lock_acquire_wait "$lock" || { echo "error: cannot lock task $ID's record" >&2; return 1; }
  tmp=$(mktemp "$STATE/.after-merge-$ID.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  if { grep -v "${drop[@]}" "$META" || true; } >"$tmp" &&
    printf '%s=%s\n' "$@" >>"$tmp" &&
    mv "$tmp" "$META"; then
    fm_lock_release "$lock"
    return 0
  fi
  rm -f "$tmp"
  fm_lock_release "$lock"
  echo "error: could not record the after-merge result in $META" >&2
  return 1
}

record() {  # <done|failed> <reason>
  meta_replace after_merge "$1" after_merge_reason "$2"
}

# relay_note: print the note for the captain and hold it as a captain card,
# once per task (see "Captain card" in the header).
relay_note() {
  local card url num title reason
  local -a link=(--no-link)
  [ -n "$NOTE" ] || return 0
  echo "relay to the captain: $NOTE"
  card="$ID-after-merge"
  [ "$(meta_value after_merge_card)" = "$card" ] && return 0
  url=$(meta_value pr)
  title="$(printf '%s' "${NOTE:0:1}" | tr '[:lower:]' '[:upper:]')${NOTE:1}"
  if [ -n "$url" ]; then
    num=${url%/}
    num=${num##*/}
    case "$num" in
      ''|*[!0-9]*) title="$title to put this $NAME PR live" ;;
      *) title="$title to put $NAME PR $num live" ;;
    esac
    reason="$title - $url"
    link=(--link "$url")
  else
    title="$title to put the $NAME change live"
    reason="$title (landed locally from branch $(meta_value branch))"
  fi
  if "$SCRIPT_DIR/fm-captain-hold.sh" hold "$card" --title "$title" --repo "$NAME" \
    --reason "$reason" --option "done=Done" "${link[@]}" >/dev/null; then
    meta_replace after_merge_card "$card" || true
  else
    echo "actionable: could not hold the after-merge note for the captain; hold it by hand with $SCRIPT_DIR/fm-captain-hold.sh hold $card --title \"$title\" --repo $NAME --reason \"$reason\" --option done=Done ${link[*]}" >&2
  fi
  return 0
}

case "$ACTION" in
  require)
    [ "$(meta_value after_merge)" = "done" ] && exit 0
    reason=$(meta_value after_merge_reason)
    echo "refused: project $NAME declares an after-merge action ($KIND $CHECKOUT to $REMOTE/$BRANCH) that task $ID has not recorded as done${reason:+ (last attempt: $reason)}; run it with $RETRY, or after doing it another way record it with $MARK" >&2
    exit 1
    ;;
  mark)
    record "done" "recorded by hand: $HOW"
    echo "after-merge recorded done by hand for task $ID"
    relay_note
    exit 0
    ;;
esac

fail() {  # <reason>
  record failed "$1" || true
  echo "actionable: after-merge for task $ID did not run: $1; nothing was changed, so fix the checkout and run $RETRY, or after doing it another way record it with $MARK" >&2
  exit 1
}

[ "$KIND" = ff ] || fail "unknown action $KIND"
[ -d "$CHECKOUT" ] || fail "$CHECKOUT does not exist"
top=$(git -C "$CHECKOUT" rev-parse --show-toplevel 2>/dev/null) || fail "$CHECKOUT is not a Git checkout"
[ "$(cd "$top" && pwd -P)" = "$(cd "$CHECKOUT" && pwd -P)" ] || fail "$CHECKOUT is inside another checkout, not its top"
cur=$(git -C "$CHECKOUT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ "$cur" = "$BRANCH" ] || fail "$CHECKOUT is on '${cur:-a detached HEAD}', not $BRANCH"
[ -z "$(git -C "$CHECKOUT" status --porcelain --untracked-files=no)" ] || fail "$CHECKOUT has uncommitted changes"
git -C "$CHECKOUT" fetch --quiet "$REMOTE" || fail "could not fetch $REMOTE in $CHECKOUT"
target=$(git -C "$CHECKOUT" rev-parse --verify --quiet "refs/remotes/$REMOTE/$BRANCH^{commit}") || fail "$CHECKOUT has no $REMOTE/$BRANCH after the fetch"
head=$(git -C "$CHECKOUT" rev-parse --verify HEAD)
if [ "$head" = "$target" ]; then
  reason="$CHECKOUT already at $REMOTE/$BRANCH (${target:0:12})"
elif git -C "$CHECKOUT" merge-base --is-ancestor "$target" "$head"; then
  reason="$CHECKOUT already contains $REMOTE/$BRANCH (${target:0:12})"
elif git -C "$CHECKOUT" merge-base --is-ancestor "$head" "$target"; then
  git -C "$CHECKOUT" merge --ff-only --quiet "refs/remotes/$REMOTE/$BRANCH" >/dev/null 2>&1 ||
    fail "git refused to fast-forward $CHECKOUT to $REMOTE/$BRANCH, for example over an untracked file"
  reason="fast-forwarded $CHECKOUT ${head:0:12} -> ${target:0:12} ($REMOTE/$BRANCH)"
else
  fail "$CHECKOUT has diverged from $REMOTE/$BRANCH"
fi
record "done" "$reason" || exit 1
echo "after-merge done: $reason"
relay_note
