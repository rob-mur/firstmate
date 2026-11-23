#!/usr/bin/env bash
# fm-captain-calls.sh - every open captain call of this home, from one model, as JSON.
#
# Read-only. It reads this home's backlog, its secondmate registry, the
# parent-channel status log of every registered secondmate and the status log
# of every live worker of this home, and it writes
# nothing there: no cache, no cursor, no backlog, no board, no status line.
# Its only scratch is a private temp directory, removed on exit.
#
# A captain call is one of:
#   - a main-backlog task held for the captain: a row in a section other than
#     Done, not checked, with (hold-kind: captain) and a hold reason. A hold
#     whose (hold-until: YYYY-MM-DD) is after today (UTC) is deferred and is
#     not a call; it is listed in skipped[] instead. A hold with an unresolved
#     blocked-by stays a call and carries its blocker ids. Its options and links
#     are the current hold's alone (the row body's first paragraph); a re-held
#     task's earlier holds stay in later paragraphs and are never shown.
#   - an open needs-decision key in the parent status log state/<mate>.status of
#     a secondmate in data/secondmates.md, local or remote (a remote home's
#     status reaches the same parent log). A key raised for a captain hold
#     ("captain hold <task>: ...") whose task, in a local mate's own
#     data/backlog.md (read-only), is an open row with (hold-kind: captain) and
#     a (hold-until: YYYY-MM-DD) after today (UTC) is deferred like a main hold:
#     it is listed in skipped[], not calls[]. A key is open until a later
#     `resolved` (or other closing) line carries the SAME key; bin/fm-classify-lib.sh
#     status_open_decisions owns that fold. A key the captain already answered
#     (bin/fm-captain-hold.sh answered-batch, read-only) is not a call and is
#     listed in skipped[] until the mate closes it (or in to_close[], below,
#     when it is not a decision). Nothing else hands a call off: a steer that
#     names the key, a duplicate key the mate resolved, or a merged PR does not
#     close it.
#   - an open needs-decision key in the status log state/<task>.status of a
#     live worker of this home: a task with a state/<task>.meta record that is
#     not a registered secondmate (a finished task's leftover log has no meta
#     and is not read). Same fold, same answered rule; source "main-worker".
#     Only needs-decision is a captain call; a blocked line is firstmate's.
#     A worker key whose task is a main hold that is a call asks that same
#     call: it is not a second call and is listed in skipped[], so the hold
#     shows once.
#
# Decision or not: every call is classified with the shared board question
# rules (bin/fm-bearings-question-lib.sh is_merge_ask and is_review), read on the
# question with its URLs taken out and the noun "merge request" read as "MR". A merge ask or a review hand-off is not a
# decision; everything else is ("decision": true).
#
# Inline options: a call with no options of its own whose question carries
# them inline as "a) ... b) ... c) ...?" (bin/fm-bearings-question-lib.sh
# inline_letter_options) has them as its options, and its question is the lead
# up to them, ending in "?".
#
# Settled: a call that is not a decision and is already settled - every linked
# PR/MR merged or closed, or the captain already answered it - is not a call.
# It is listed in to_close[] with the evidence that settled it, so main can
# close it (a main hold with bin/fm-captain-hold.sh reconcile close and that
# evidence; a secondmate key by asking the mate to resolve it). It is never
# dropped silently, and this script never closes anything. A decision stays in
# calls[] even when its PRs/MRs have finished: only the captain says it is moot.
#
# Linked PRs/MRs: every GitHub, GitLab or Forgejo PR/MR URL a call names (its
# question, its hold links, its backlog row) is looked up live, read-only, in
# parallel, each lookup bounded by FM_CAPTAIN_CALLS_PR_TIMEOUT seconds
# (default 5), at most FM_CAPTAIN_CALLS_PR_MAX URLs (default 32). A URL is
# matched whole, never by a word inside it. A failed or slow lookup reads
# "unknown", so the call is not settled by it and stays in calls[].
# FM_CAPTAIN_CALLS_PR_CHECK=0 turns the lookups off. FM_CAPTAIN_CALLS_PR_STATES
# names a file of "<url><TAB><merged|closed|open>" lines used instead of live
# lookups (a URL it does not list reads "unknown").
#
# Output (one JSON object on stdout, schema fm-captain-calls.v1):
#   schema, generated (UTC ISO time), home, today, pr_check ("live", "file" or "off"),
#   calls[]   open calls, main holds first in backlog order, then secondmates in
#             registry order and status-log order,
#   to_close[] settled calls that are not decisions (same fields, plus
#             evidence {settled_by, prs[{url,state}], text} and close_with),
#   skipped[] {key, home, task, why} deferred holds (main or secondmate, also
#             with title and question) and captain-answered keys,
#   homes[]   {id, remote, status_log ("read" or "missing")} for every registered mate,
#   workers[] the ids of the live workers whose status logs were read.
# Each call:
#   key       card key, unique in the output: the task id for a main hold,
#             "<mate>.<decision-key>" for a secondmate call,
#             "<task>.<decision-key>" for a worker call
#   source    "main-hold", "secondmate" or "main-worker"
#   home      "main" or the secondmate id ("main" for a worker call)
#   task      the held task id (for a "captain hold <task>: ..." key, that task)
#   decision_key  the status-log key (secondmate and worker calls; null for main holds)
#   decision  false for a merge ask or a review hand-off, else true
#   title, repo, question, options[{value,label}], free_text, no_link,
#   links[{url,label}], blocked_by[], hold_until, raised_at (UTC ISO or null),
#   prs[{url,state}]  state is merged, closed, open or unknown
#
# Exit 0 with the JSON; exit 1 when the backlog cannot be read; exit 2 on usage.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="$DATA/backlog.md"
REGISTRY="$DATA/secondmates.md"

usage() {
  cat <<'EOF'
Usage: fm-captain-calls.sh [--help]

Print every open captain call of this home (FM_HOME) as one JSON object:
held main-backlog tasks and open decision keys of secondmates and of this
home's live workers. Read-only.

  calls[]     open calls, each marked decision true or false
  to_close[]  settled calls that are not decisions, with the evidence that
              settled them (linked PRs/MRs all merged or closed, or already
              answered) and how main closes them; nothing is closed here
  skipped[]   deferred holds and answered decision keys not yet closed
  homes[]     every registered secondmate and whether its status log was read
  workers[]   the live workers whose status logs were read

Environment:
  FM_HOME                       the home to read (default: this repository)
  FM_CAPTAIN_CALLS_PR_CHECK=0   no PR/MR lookups
  FM_CAPTAIN_CALLS_PR_STATES    file of "<url>\t<state>" lines used instead of lookups
  FM_CAPTAIN_CALLS_PR_TIMEOUT   seconds per lookup (default 5)
  FM_CAPTAIN_CALLS_PR_MAX       most URLs looked up (default 32)

The script header owns the full contract.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-captain-calls: jq is required" >&2; exit 1; }
[ -f "$BACKLOG" ] && [ -r "$BACKLOG" ] || { echo "fm-captain-calls: cannot read $BACKLOG" >&2; exit 1; }

# shellcheck source=bin/fm-hold-reason-lib.sh
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-bearings-question-lib.sh
. "$SCRIPT_DIR/fm-bearings-question-lib.sh"

TODAY=$(date -u +%Y-%m-%d)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TAB=$(printf '\t')

# The URL shapes bin/fm-pr-lib.sh fm_pr_url_parse reads, matched as whole URLs.
PR_URL_RE='https://[^[:space:]<>"()]+/(pull|pulls|-/merge_requests)/[0-9]+'

# --- main holds -------------------------------------------------------------
# One record per structured row: id, section, checked, rest, body lines. The
# row grammar follows bin/fm-fleet-snapshot.sh's markdown parse.
# shellcheck disable=SC2016  # jq program text.
MAIN_JSON=$(jq -R -n '
  def section_state:
    if . == "In flight" then "in_flight" elif . == "Queued" then "queued"
    elif . == "Done" then "done" else "other" end;
  def cap($s; $re): ((($s | capture($re)?) // {}) | .v // null) as $v
    | if $v == null then null else ($v | gsub("^\\s+|\\s+$"; "")) end;
  def metadata($rest; $key): cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
  def row_match($line):
    [$line | capture("^[-*][[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?][0];
  def title_of($rest):
    $rest
    | gsub("<?https?://[^[:space:])\"<>]+>?"; "")
    | reduce range(0; 20) as $_ (.;
        sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority|hold|hold-kind|hold-until):[[:space:]]*[^)]*|(?:since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""))
    | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
    | gsub("[[:space:]]+"; " ") | gsub("^ | $"; "");
  reduce inputs as $line ({section: null, rows: []};
    if ($line | test("^##[[:space:]]+")) then
      .section = ($line | sub("^##[[:space:]]+"; "") | gsub("\\s+$"; "") | section_state)
    elif .section == null then .
    elif row_match($line) != null then
      row_match($line) as $m
      | .rows += [{id: $m.id, section: .section, checked: ($m.check | test("[xX]")), rest: $m.rest, body: []}]
    elif (.rows | length) > 0 and ($line | test("^[[:space:]]+[^[:space:]]")) then
      .rows[-1].body += [$line | gsub("^\\s+|\\s+$"; "")]
    elif (.rows | length) > 0 and ($line | test("^[[:space:]]*$")) then
      .rows[-1].body += [""]
    else . end)
  | {records: [.rows[]
      | select(.section != "done" and (.checked | not))
      | .rest as $rest
      | select(metadata($rest; "hold-kind") == "captain")
      | (cap($rest; ".*\\(hold:[[:space:]]*(?<v>[^)]*)")) as $reason
      | select($reason != null and $reason != "")
      # The current hold is the first body paragraph; a re-held task keeps each
      # earlier hold option and link line in later paragraphs, never shown.
      | (.body | (index("") // length) as $n | .[:$n]) as $header
      | {id, section, rest: $rest,
         title: title_of($rest),
         repo: metadata($rest; "repo"),
         hold_reason: $reason,
         hold_until: metadata($rest; "hold-until"),
         blocked_by: ([$rest | scan("blocked-by:[[:space:]]+(?<id>[^[:space:])]+)") | .[0]] | unique),
         hold_set: ([$header[] | capture("^Captain hold set:[[:space:]]*(?<v>[0-9TZ:-]+)")? | .v][0] // null),
         options: [$header[] | capture("^Captain hold option:[[:space:]]*(?<v>[^=[:space:]]+)(?:=(?<l>.+))?$")?
                   | {value: .v, label: ((.l // .v) | gsub("^\\s+|\\s+$"; ""))}],
         links: [$header[] | capture("^Captain hold link:[[:space:]]*(?<t>[^[:space:]]+)(?:[[:space:]]+(?<l>.*))?$")?
                 | {url: .t, label: ((.l // "") | gsub("^\\s+|\\s+$"; ""))}],
         free_text: any($header[]; test("^Captain hold free text:[[:space:]]*yes$")),
         no_link: any($header[]; test("^Captain hold no link:[[:space:]]*yes$"))}]}
' < "$BACKLOG" | fm_hold_reason_decode_stream json) || {
  echo "fm-captain-calls: cannot parse $BACKLOG" >&2; exit 1; }

# --- secondmate decision keys -----------------------------------------------
# Lines: "<home>\t<remote>\t<status read|missing>\t<answered-id>\t<key>\t<epoch>\t<note>".
# The status-log fold takes seconds on a long log, so each mate is read in the
# background into its own numbered file and the files are joined in registry order.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-captain-calls.XXXXXX") || exit 1
trap 'rm -rf -- "$WORK"' EXIT

mate_rows_one() {  # <id> <remote> [<kind: secondmate|crew>]
  local id=$1 remote=$2 kind=${3:-secondmate} f open line key verb note opened answered rest
  f="$STATE/$id.status"
  if ! { [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ]; }; then
    printf '%s\t%s\tmissing\t\t\t\t\n' "$id" "$remote"
    return 0
  fi
  printf '%s\t%s\tread\t\t\t\t\n' "$id" "$remote"
  open=$(status_open_decisions "$f" "$kind" | awk -F'\t' '$2 == "needs-decision"')
  [ -n "$open" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    answered=${line%%"$TAB"*}
    rest=${line#*"$TAB"}
    key=${rest%%"$TAB"*}
    rest=${rest#*"$TAB"}
    verb=${rest%%"$TAB"*}
    note=${rest#*"$TAB"}
    [ "$verb" = needs-decision ] || continue
    opened=$(status_decision_opened_epoch "$f" "$key" 2>/dev/null) || opened=''
    printf '%s\t%s\tcall\t%s\t%s\t%s\t%s\n' "$id" "$remote" "$answered" "$key" "$opened" "$note"
  done <<EOF
$(printf '%s\n' "$open" | status_open_decisions_tag_answered "$id" "$f")
EOF
}

# Main's own workers: every task with a live record (state/<task>.meta) and a
# status log that is not a registered secondmate, read with the worker fold.
# Their rows carry "worker" in the remote column.
mate_rows() {
  local line n=0 f id mates=' '
  mkdir -p "$WORK/mates"
  if [ -f "$REGISTRY" ] && [ -r "$REGISTRY" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "- "*) ;; *) continue ;; esac
      secondmate_registry_parse_line "$line" || continue
      n=$((n + 1))
      mates="$mates$SECONDMATE_REGISTRY_ID "
      mate_rows_one "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_REMOTE" > "$WORK/mates/$(printf '%04d' "$n")" 2>/dev/null &
    done < "$REGISTRY"
  fi
  for f in "$STATE"/*.status; do
    [ -f "$f" ] || continue
    id=${f##*/}
    id=${id%.status}
    case "$mates" in *" $id "*) continue ;; esac
    [ -f "$STATE/$id.meta" ] || continue
    n=$((n + 1))
    mate_rows_one "$id" worker crew > "$WORK/mates/$(printf '%04d' "$n")" 2>/dev/null &
  done
  wait
  [ "$n" -gt 0 ] || return 0
  cat "$WORK"/mates/*
}

# A local secondmate's own captain holds deferred to a date, read-only from its
# data/backlog.md: one "<mate>\t<task>\t<YYYY-MM-DD>" line per open row (not in
# Done, not checked) with (hold-kind: captain) and (hold-until: <date>). A
# remote mate's backlog is not on this machine, so its keys keep no date.
mate_until_rows() {
  local line b
  [ -f "$REGISTRY" ] && [ -r "$REGISTRY" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] && continue
    b="$SECONDMATE_REGISTRY_HOME/data/backlog.md"
    [ -f "$b" ] && [ -r "$b" ] || continue
    awk -v mate="$SECONDMATE_REGISTRY_ID" '
      /^##[[:space:]]/ { done = ($0 ~ /^##[[:space:]]+Done[[:space:]]*$/); next }
      done { next }
      /^[-*][[:space:]]+\[ \][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]/ {
        if ($0 !~ /[(,][[:space:]]*hold-kind:[[:space:]]*captain[[:space:]]*[,)]/) next
        if (!match($0, /[(,][[:space:]]*hold-until:[[:space:]]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) next
        u = substr($0, RSTART, RLENGTH); sub(/.*hold-until:[[:space:]]*/, "", u)
        id = $0; sub(/^[-*][[:space:]]+\[ \][[:space:]]+/, "", id); sub(/[[:space:]].*/, "", id)
        printf "%s\t%s\t%s\n", mate, id, u
      }' "$b" 2>/dev/null
  done < "$REGISTRY"
}

# shellcheck disable=SC2016  # jq program text.
UNTIL_JSON=$(mate_until_rows | jq -R -n '[inputs | split("\t") | {mate: .[0], task: .[1], until: .[2]}]')

# shellcheck disable=SC2016  # jq program text.
MATE_JSON=$(mate_rows | jq -R -n '
  [inputs | split("\t")
   | {home: .[0], worker: (.[1] == "worker"), remote: (.[1] == "1"), kind: .[2], answered: .[3], key: .[4],
      opened: .[5], note: (.[6:] | join("\t"))}]')

# --- assemble the calls before the PR lookups --------------------------------
# A call is a decision unless the shared board question rules read it as a
# merge ask or a review hand-off. They read the question with every URL taken
# out and "merge request" read as "MR", so a word inside a URL
# (".../-/merge_requests/880") or the noun "merge request" never makes a merge ask.
# shellcheck disable=SC2016  # jq program text.
CALLS_JSON=$(jq -n --argjson main "$MAIN_JSON" --argjson mates "$MATE_JSON" --argjson until "$UNTIL_JSON" \
  --arg today "$TODAY" --arg pr_re "$PR_URL_RE" "$FM_BEARINGS_QUESTION_JQ_DEFS"'
  def urls_in: [scan("https?://[^[:space:]<>\"()]+") | sub("[.,;:?!]+$"; "")];
  def pr_urls_in: [.[] | select(test("^" + $pr_re + "$"))] | unique;
  def strip_urls: gsub("<?https?://[^[:space:]<>\"()]+>?"; "");
  def iso($epoch): if ($epoch | test("^[0-9]+$")) then ($epoch | tonumber | todate) else null end;
  def classify:
    {reason: ((.question // "") | strip_urls | gsub("merge[ -]requests?"; "MR"; "i")),
     choices: {options: .options}} as $d
    | . + {decision: ((is_merge_ask($d) or is_review($d)) | not)};
  # A call with no options of its own whose question carries them inline as
  # "a) ... b) ... c) ...?" takes them as its options and asks only its lead.
  def inline_options:
    if (.options | length) > 0 then .
    else ((.question // "") | inline_letter_options) as $p
      | if $p == null then . else . + {question: $p.question, options: $p.options} end end;
  ([$main.records[]
     | {key: .id, source: "main-hold", home: "main", task: .id, decision_key: null,
        title, repo, question: .hold_reason, options: [.options[] | {value, label}], free_text, no_link,
        links: ([.links[] | {url, label}] + ([(.hold_reason | urls_in[]), (.rest | urls_in[])]
                          | map({url: ., label: ""}))
                | unique_by(.url)),
        blocked_by, hold_until, raised_at: .hold_set} | inline_options | classify]) as $holds
  | ([$mates[] | select(.kind == "call" and .worker)
     | {key: (.home + "." + .key), source: "main-worker", home: "main", task: .home,
        decision_key: .key, title: .home, repo: null,
        question: .note, options: [], free_text: true, no_link: false,
        links: ([.note | urls_in[]] | unique | map({url: ., label: ""})),
        blocked_by: [], hold_until: null, raised_at: iso(.opened), answered} | inline_options | classify]) as $worker_calls
  | ([$mates[] | select(.kind == "call" and (.worker | not))
     | (.note | capture("^captain hold (?<t>[A-Za-z0-9._-]+):[[:space:]]*(?<q>.*)$")? // null) as $h
     | .home as $mate
     | {key: (.home + "." + .key), source: "secondmate", home, remote, task: ($h.t // null),
        decision_key: .key, title: ($h.t // .key), repo: null,
        question: ($h.q // .note), options: [], free_text: true, no_link: false,
        links: ([.note | urls_in[]] | unique | map({url: ., label: ""})),
        blocked_by: [],
        hold_until: (if $h == null then null
                     else ([$until[] | select(.mate == $mate and .task == $h.t) | .until][0] // null) end),
        raised_at: iso(.opened), answered} | inline_options | classify]) as $mate_calls
  | def deferred: .hold_until != null and .hold_until > $today;
  # A live worker key on a task that is itself held for the captain asks the
  # same call: the hold is the one call, so the worker key is skipped.
  ([$holds[] | select(deferred | not) | .task]) as $held_tasks
  | def on_held_task: .source == "main-worker" and (.task as $t | $held_tasks | index([$t])) != null;
  {calls: ([$holds[] | select(deferred | not)]
             + [$worker_calls[], $mate_calls[] | select(.answered == "" and (deferred | not) and (on_held_task | not))
                | del(.answered)])
           | map(. + {pr_urls: ([.links[].url] | pr_urls_in)}),
     answered: [$worker_calls[], $mate_calls[] | select(.answered != "")],
     skipped: ([$holds[], ($mate_calls[] | select(.answered == "")) | select(deferred)
                | {key, home, task, title, question, why: ("deferred until " + .hold_until)}]
               + [$worker_calls[] | select(.answered == "" and on_held_task)
                  | {key, home, task, title, question,
                     why: ("task " + .task + " is held for the captain; its hold is the one call")}]),
     homes: [$mates[] | select(.kind != "call" and (.worker | not)) | {id: .home, remote, status_log: .kind}],
     workers: [$mates[] | select(.kind != "call" and .worker) | .home]}')

# --- linked PR/MR states ------------------------------------------------------
pr_state_live() {  # <url> -> "<url>\t<merged|closed|open>" or nothing
  local url=$1 record state merged
  fm_pr_url_parse "$url" || return 0
  case "$FM_PR_PROVIDER" in
    github) set -- github "$FM_PR_HOST" "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER" ;;
    gitlab|forgejo) set -- "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" ;;
    *) return 0 ;;
  esac
  # shellcheck disable=SC2016  # The inner script expands after bash -c receives positional args.
  record=$(fm_run_timed "$PR_TIMEOUT" bash -c '
    . "$1"; p=$2; shift 2
    "fm_pr_${p}_read_record" "$@" || exit 1
    printf "state=%s\nmerged=%s\n" "$FM_PR_RECORD_STATE" "$FM_PR_RECORD_MERGED"
  ' _ "$SCRIPT_DIR/fm-pr-lib.sh" "$@" 2>/dev/null) || return 0
  state=$(printf '%s\n' "$record" | sed -n 's/^state=//p' | head -1 | tr '[:upper:]' '[:lower:]')
  merged=$(printf '%s\n' "$record" | sed -n 's/^merged=//p' | head -1)
  if [ "$merged" = true ] || [ "$state" = merged ]; then state=merged
  elif [ "$state" = closed ]; then state=closed
  elif [ "$state" = open ] || [ "$state" = opened ]; then state=open
  else return 0; fi
  printf '%s\t%s\n' "$url" "$state"
}

PR_CHECK="live"
PR_STATES='{}'
pr_urls=$(printf '%s\n' "$CALLS_JSON" | jq -r --argjson max "${FM_CAPTAIN_CALLS_PR_MAX:-32}" \
  '[.calls[].pr_urls[]] | unique | .[:$max][]')
if [ "${FM_CAPTAIN_CALLS_PR_CHECK:-1}" = 0 ]; then
  PR_CHECK="off"
elif [ -n "${FM_CAPTAIN_CALLS_PR_STATES:-}" ]; then
  PR_CHECK="file"
  if [ -f "$FM_CAPTAIN_CALLS_PR_STATES" ] && [ -r "$FM_CAPTAIN_CALLS_PR_STATES" ]; then
    PR_STATES=$(jq -R -n '[inputs | split("\t") | select(length >= 2) | {key: .[0], value: .[1]}] | from_entries' \
      < "$FM_CAPTAIN_CALLS_PR_STATES") || PR_STATES='{}'
  fi
elif [ -n "$pr_urls" ]; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  PR_TIMEOUT=${FM_CAPTAIN_CALLS_PR_TIMEOUT:-5}
  pr_tmp="$WORK/prs"
  mkdir -p "$pr_tmp"
  i=0
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    i=$((i + 1))
    pr_state_live "$u" > "$pr_tmp/$i" 2>/dev/null &
  done <<EOF
$pr_urls
EOF
  wait
  PR_STATES=$(cat "$pr_tmp"/* 2>/dev/null | jq -R -n \
    '[inputs | split("\t") | select(length >= 2) | {key: .[0], value: .[1]}] | from_entries') || PR_STATES='{}'
fi
[ -n "$PR_STATES" ] || PR_STATES='{}'

# --- calls, settled calls to close, and skipped ------------------------------
# A call that is not a decision and is already settled (every linked PR/MR
# merged or closed, or the captain already answered it) leaves calls[] for
# to_close[] with the evidence that settled it. A decision stays a call even
# when its PRs/MRs have finished: only the captain can say it is moot. Nothing
# here closes anything; to_close[].close_with names how main closes it.
# shellcheck disable=SC2016  # jq program text.
printf '%s\n' "$CALLS_JSON" | jq --argjson states "$PR_STATES" --arg check "$PR_CHECK" \
  --arg now "$NOW" --arg today "$TODAY" --arg home "$FM_HOME" '
  def finished: (.prs | length) > 0 and all(.prs[]; .state == "merged" or .state == "closed");
  def close_with:
    if .source == "main-hold"
    then "bin/fm-captain-hold.sh reconcile close " + .task + " --evidence-file <file holding evidence.text>"
    elif .source == "main-worker"
    then "steer " + .task + " to resolve [key=" + .decision_key + "] with evidence.text"
    else "ask " + .home + " to resolve [key=" + .decision_key + "] with evidence.text" end;
  def closer: if .source == "main-worker" then .task else .home end;
  def to_close($by; $text): . + {evidence: {settled_by: $by, prs, text: $text}} | . + {close_with: close_with};
  [.calls[] | . + {prs: [.pr_urls[] | {url: ., state: ($states[.] // "unknown")}]} | del(.pr_urls)] as $all
  | [.answered[] | . + {prs: []}] as $answered
  | {schema: "fm-captain-calls.v1", generated: $now, home: $home, today: $today, pr_check: $check,
     calls: [$all[] | select(.decision or (finished | not))],
     to_close: ([$all[] | select((.decision | not) and finished)
                 | to_close("every linked PR/MR merged or closed";
                     "Not a decision and already settled: every linked PR/MR is merged or closed ("
                     + ([.prs[] | .url + " " + .state] | join(", ")) + "), checked " + $now + ".")]
               + [$answered[] | select(.decision | not)
                  | to_close("answered by the captain in " + .answered;
                      "Not a decision and already settled: the captain answered it in " + .answered + ".")
                  | del(.answered)]),
     skipped: (.skipped
               + [$answered[] | select(.decision)
                  | {key, home, task, why: ("answered by the captain in " + .answered + "; waiting for " + closer + " to close it")}]),
     homes, workers}'
