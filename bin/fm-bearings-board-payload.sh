#!/usr/bin/env bash
# fm-bearings-board-payload.sh - build the /bearings lavish board payload.
#
# The board has one shape every session because this script, not the invoking
# agent, maps the fleet snapshot onto the fm-bearings-board.v1 payload that
# bin/fm-bearings-board.sh `build` validates and renders. The same snapshot
# always yields the same payload; the agent's only optional input is a copy
# overlay carrying short authored copy.
#
# Usage:
#   fm-bearings-board-payload.sh [--snapshot <file|->] [--copy <file>] [--include-prs]
#
# The payload goes to stdout. With no --snapshot the script runs
# `fm-bearings-snapshot.sh --json --all-decisions --during-away --include-mrs`
# itself (--during-away keeps the board building while the captain is away;
# --include-prs is passed through; FM_BEARINGS_BOARD_MR_CHECK=0 drops
# --include-mrs, so the build makes no GitLab call), so every open captain hold - live, blocked, dated, or aged, past the
# snapshot's decision cap - yields at most one card or waiting row; with
# --snapshot it reads that JSON from the file or stdin instead.
#
# Stale rows never reach Captain's Call:
#   - a hold deferred to a later date (hold_until after today, or fleet bucket
#     `dated`), from any home, is a waiting row with `until <date>: <reason>`
#     instead; once that date arrives the hold is a card again, and
#     a lapsed card whose text does not ask asks whether it is still waiting
#     (go ahead / hold it again / free text) when the hold recorded no choices;
#   - a merge-ask card (is_merge_ask in bin/fm-bearings-question-lib.sh) whose
#     every PR/MR (recorded, named in its reason, or its snapshot pr_url) merged
#     or closed is dropped, as is a contribution card whose PR did; any other
#     question stays, since a merged link does not answer it;
#     a review card (is_review in bin/fm-bearings-question-lib.sh) is also
#     dropped once the captain approved every open one (fm_pr_viewer_approved in
#     bin/fm-pr-lib.sh), because the review it asked for is given. Landed artifacts count as
#     merged; open PRs are read live from GitHub, GitLab, and Forgejo through
#     bin/fm-pr-lib.sh, in parallel, each bounded by FM_BEARINGS_BOARD_PR_TIMEOUT
#     seconds (default 5), at most FM_BEARINGS_BOARD_PR_MAX URLs (default 24). A
#     lookup that fails or times out keeps the card. FM_BEARINGS_BOARD_PR_CHECK=0
#     turns the live read off;
#   - a hold whose id is a round (`<base>-r<N>`, `-round<N>`, `-v<N>`) is dropped
#     when the same home has a higher round of the same base in decisions, work
#     under way, landed work, or gates;
#   - a decision the snapshot marks handed (handed_at: after it was last raised,
#     a steer marked with its key by fm-send.sh --handoff-key went to the task
#     it tracks, the hold's answered or released mirror line closed it, or the
#     captain answered it or marked it out of date on the board) is a waiting row
#     saying who has it, until the worker raises a fresh question;
#   - a status row that only announces a page or PR is live or ready
#     (is_announcement in bin/fm-bearings-question-lib.sh) is never a card: its
#     links fold into the card for the same work (same home and task or decision
#     key, or a shared PR/MR URL), and it is dropped when no such card exists;
#   - an unkeyed status decision whose text names, as a whole word, the task id
#     of a captain hold in the same home announces that hold, so it is dropped
#     and the hold card stays the one card for that call; so is a keyed status
#     decision whose task is that captain-held task, so the call shows once.
#
# Mapping (snapshot field -> board section):
#   decisions_open  -> captains_call: one `decision` card per captain-held task id,
#                      titled from the row's full `title_full` (else `title`), `about` from
#                      its full `reason_full` (else `reason`),
#                      `pr_url` and `repo` from the PR the task recorded (else the
#                      snapshot row's `pr_url`), and a
#                      derived default choices (bin/fm-bearings-question-lib.sh: the
#                      reason's own numbered, lettered or listed options in full, a two-way
#                      or, yes/no, done/not done for an action the captain performs, else
#                      approve/decline; an authored overlay `options` still
#                      wins) with reconcile secondary. A hold that recorded its
#                      choices (`choices` from bin/fm-captain-hold.sh hold --option,
#                      --free-text, --link, --no-link) uses them instead: its options
#                      are the card's (an option recorded with no label shows the
#                      reason's own option at its place when every option is bare
#                      and the counts match, else its value in plain words), its links lead the card's `links` (`page:<id>`
#                      becomes `{page}`), and it carries `free_text`/`no_link` when it
#                      declared them; a hold that recorded no options carries
#                      `options_inferred`, which `build` refuses; a worker status
#                      question or review-page card carries `from_status`. Every card, waiting
#                      row, and charted row also carries `context` ({task, reason,
#                      answers[{at, mode, text}], notes, report} from the snapshot's
#                      structured fields; with no recorded report, the local report or
#                      page path the reason names), which the board expands in place. Options the text refers to but does
#                      not list ("A/B/C") come from its other listing or its `reason_earlier`
#                      lines; when none lists them the card carries `malformed`, a sentence
#                      saying so, and no button for them (recover_options). And any
#                      https URLs (and the tailnet review-page origin) in the reason lifted into the card `links`.
#                      A link is labelled by what it points at - `PR <n>`, `MR <n>`,
#                      `Issue <n>` (a YouTrack issue by its id, `Issue APP-5837`), or for a Lavish page `Understand page`, `Review page`,
#                      or `Report` from the words just before it (else `Lavish page`) -
#                      and `question`/`about` show that label in place of the URL, a "?"
#                      written after the URL and a space against the label ("PR 135?");
#                      a title that drops the URL drops that space too. `build`
#                      turns a Lavish page link into its in-place board page. Every
#                      open captain hold is a row here (see --all-decisions above).
#                      A hold whose reason is a wait or park rather than a question moves
#                      to `waiting` instead (see below). Each remaining card leads with
#                      one short `question` (at most 120 characters, a cut asking
#                      sentence keeping its closing "?" and never cut inside a parenthesis that closes right before that "?", first letter
#                      capitalised): for a reason with its own options, the sentence
#                      that introduces them (without a leading "Captain call:" or
#                      "Decision needed:" label), or the first sentence when that asks
#                      and the introducing one is a later lead-in ending in ":"; else the sentence led by "Question:", else
#                      its first sentence ending in "?", else its first sentence; dropped
#                      when it only repeats the title. `about` holds the rest of the
#                      text without the options and without any whole sentence that
#                      only repeats the question. A sentence that guards an action
#                      ("must", "never", "anything else is", or a plan count such as
#                      "0 to add") is never cut: if the cut would lose one, `about`
#                      keeps the whole text. An option the reason marks recommended
#                      ("(a, recommended) ...") is the card's `recommend_value`.
#                      A review-page row whose question and title do not ask gets the
#                      question "Have you reviewed this page?", because the generator
#                      makes that card itself and `build` refuses a card that states
#                      no decision; a hold or status card keeps its own text, so one
#                      that does not ask is refused until its reason or overlay asks.
#                      Every reason shown has its `corr=<hex>`
#                      tokens and its sentences addressed to firstmate ("Firstmate:
#                      ...", "Firstmate, ...") removed (clean_reason in
#                      bin/fm-bearings-question-lib.sh).
#                      A reason answered on its Lavish page (a tailnet page link plus
#                      "is on the ... page", "ready on the ... page", "ready for ...
#                      on its ... page", "the page shows", "answer ... on the page")
#                      is a page-backed card: no question, about, or choices, only its
#                      tailnet page link, titled by what the page is about. It also
#                      carries `off_board`: the question and about it would show, a
#                      free-form answer, and a `malformed` sentence saying its choices
#                      are on its page, less any field the copy overlay authors.
#                      `build` keeps the card page-only when that page is in the
#                      board, else shows `off_board` on it so it can still be answered.
#                      A `source:"status"` row is titled from its decision, never the
#                      asking home: the task its decision key names, else a given title
#                      that is not just the task or home, else that same asking
#                      sentence outside its own options (a choice never titles
#                      it), prefixed `<home>: ` for a secondmate. A status row whose
#                      decision key names a captain-held task in the same home is the
#                      same question: it adds no card or waiting row of its own, and an
#                      asked hold card merges its text into `about` and its
#                      choices into `options`, so no answer choice is lost.
#   contributions.captain
#                   -> captains_call: one link-only `decision` card (key
#                      `contribution.<task>`, `pr_url` the contribution's page, and
#                      a fixed question with a free-text answer) for
#                      each row waiting on the captain with no hold of its own, so
#                      Captain's Call also shows what firstmate never held. A row
#                      whose hold already has a card, or whose PR a card already
#                      carries, adds none.
#   waiting         -> waiting: a captain-held task, or a status blocked line, whose reason
#                      is a wait or park on a condition or date, with nothing for the
#                      captain to answer. The rule: is_wait in
#                      bin/fm-bearings-question-lib.sh owns it - a captain
#                      park is a wait; a question mark or numbered options make a
#                      question; a blocked hold, a blocked line with no decision key
#                      that names what it waits on, a time gate naming a date, or a
#                      reason that opens with wait wording is a wait; the row's
#                      reason shows what it waits on. Waiting rows keep
#                      snapshot order and are not part of the priority list.
#   in_flight       -> underway: every row in snapshot order, with the projected
#                      `name`, and `pr_url` when the row carries an https PR or MR
#                      URL, except a main row in state `done`, a row not
#                      `working` whose `pr_url` merged or closed, and a row not
#                      `working` that a held gate's waiting row already covers;
#                      a second mate's `done` child stays until its home cleans it up.
#   landed          -> landed: every row; `pr_url` and `repo` come from the
#                      artifact or recorded PR when it is one.
#   gates           -> waiting: a held gate (a `hold_kind`, or a future `hold_until`),
#                      keyed `<owner>-<id>`, titled `<owner>: <title>`, its
#                      reason the hold reason, prefixed `until <date>: ` while
#                      `hold_until` is in the future, so every held second-mate
#                      task names its wait;
#                   -> charted: one row per other gate; `(main-inventory)` and
#                      `(return-catchup)` become warning rows (kind warning, never
#                      dispatchable), and a gate with neither blocker nor hold
#                      reason is the only dispatchable row.
#   secondmates, secondmate_reconcile
#                   -> charted warning rows for a home whose books disagree
#                      (`reconcile-<id>`), whose state is unavailable
#                      (`unavailable-<id>`), or that could not be read this time
#                      and shows its last known rows (`stale-<id>`, titled with
#                      the row's `stale_note`, with the read failure as reason).
#   decision `note` -> a card's `detail` (an authored detail wins) and the start of
#                      a waiting row's reason, so a row kept from an unreadable
#                      home, or an open key its idle home no longer carries,
#                      says why.
#   priority        -> the order of captains_call (by card key) and underway (by id):
#                      bin/fm-board-priority.sh holds the captain's ranking, ranked rows
#                      come first in that order, and unranked rows keep snapshot order after.
#   omitted         -> charted_more, from the `gates showing N of M` surface.
#   open_mrs        -> open_mrs: the captain's open GitLab MRs (authored or awaiting
#                      their review) that the rest of the board does not show,
#                      as information rows {key, repo, title, url, state} - never
#                      decision cards or waiting rows; the snapshot's state line,
#                      including any `waiting on <author>` it opens with, passes
#                      through verbatim. The section is absent when the snapshot has
#                      no open_mrs (not requested, or GitLab unavailable).
#
# Copy overlay (--copy): a JSON object whose optional maps are keyed by the row
# key or id they refine, so a missing entry leaves the deterministic default.
#   captains_call  {"<key>": {title, question, about, decide, detail, options, recommend_value,
#                   type, close, risk, pr_url, links, subject, freeform_hint,
#                   allow_freeform, repo, free_text, no_link} | null}   (null drops the card;
#                   an authored `options` clears `options_inferred`)
#   captains_call_extra  [<call item>, ...]   merge, credential, and any other card
#                   waiting on the captain that firstmate did not hold, appended
#   underway       {"<id>": {repo}}
#   landed         {"<id>": {repo, pr_url, subject}}
#   charted        {"<id>": {title, reason, repo, dispatchable, filed}}
# An unknown map or field is refused, so the payload shape cannot drift through
# the overlay. An entry whose key matches no row is reported on stderr and ignored.
# A card's `links` is an array of up to 24 `{url, label}` pointers (https, or http on
# the tailnet Lavish origin the board contract names), `{page, label}` board pages,
# or `{path, label}` absolute file paths; `bin/fm-bearings-board.sh`
# owns that rule and refuses a card whose link breaks it, so a link-only item such
# as a Lavish page needs nothing but a card under captains_call_extra.
# `dispatchable` is ignored on a warning row, and `reconcile` is never accepted as
# an option value (`build` injects it).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board-payload: %s\n' "$*" >&2
  exit 1
}

SNAPSHOT=""
COPY=""
INCLUDE_PRS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot) shift; [ "$#" -gt 0 ] || fail "--snapshot needs a file or -"; SNAPSHOT=$1 ;;
    --copy) shift; [ "$#" -gt 0 ] || fail "--copy needs a file"; COPY=$1 ;;
    --include-prs) INCLUDE_PRS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

. "$SCRIPT_DIR/fm-bearings-question-lib.sh"  # FM_BEARINGS_QUESTION_JQ_DEFS: the shared question/wait rule
command -v jq >/dev/null 2>&1 || fail "jq is required"

if [ -z "$SNAPSHOT" ]; then
  set -- --json --all-decisions --during-away
  [ "$INCLUDE_PRS" = 0 ] || set -- "$@" --include-prs
  [ "${FM_BEARINGS_BOARD_MR_CHECK:-1}" = 0 ] || set -- "$@" --include-mrs
  SNAP_JSON=$("$SCRIPT_DIR/fm-bearings-snapshot.sh" "$@") || fail "snapshot failed"
elif [ "$SNAPSHOT" = - ]; then
  SNAP_JSON=$(cat)
else
  [ -r "$SNAPSHOT" ] || fail "cannot read snapshot: $SNAPSHOT"
  SNAP_JSON=$(cat "$SNAPSHOT")
fi

COPY_JSON='{}'
if [ -n "$COPY" ]; then
  [ -r "$COPY" ] || fail "cannot read copy overlay: $COPY"
  COPY_JSON=$(cat "$COPY")
fi

printf '%s\n' "$SNAP_JSON" | jq -e '.schema == "fm-bearings.v1"' >/dev/null 2>&1 \
  || fail "input is not an fm-bearings.v1 snapshot"
printf '%s\n' "$COPY_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || fail "copy overlay is not a JSON object"

overlay_errors=$(printf '%s\n' "$COPY_JSON" | jq -r '
  { captains_call: ["title","about","decide","detail","options","recommend_value","type","close",
                    "risk","pr_url","links","subject","freeform_hint","allow_freeform","repo","question",
                    "free_text","no_link"],
    underway: ["repo"],
    landed: ["repo","pr_url","subject"],
    charted: ["title","reason","repo","dispatchable","filed"] } as $allowed
  | ( keys[] | select(. as $k | ["captains_call","captains_call_extra","underway","landed","charted"]
                              | index($k) | not) | "unknown section: \(.)" ),
    ( . as $c | $allowed | to_entries[] | .key as $sec | .value as $ok
      | ($c[$sec] // {}) | to_entries[] | select(.value != null) | .key as $id
      | .value | keys[] | select(. as $f | $ok | index($f) | not)
      | "\($sec).\($id) has unknown field: \(.)" ),
    ( (.captains_call // {}) | to_entries[] | select(.value != null) | .value.options[]?
      | select(.value == "reconcile") | "captains_call options may not author reconcile" ),
    ( (.captains_call_extra // [])[] | .options[]? | select(.value == "reconcile")
      | "captains_call_extra options may not author reconcile" )
' 2>&1) || fail "copy overlay is malformed: $overlay_errors"
[ -z "$overlay_errors" ] || fail "copy overlay refused: $(printf '%s' "$overlay_errors" | head -n1)"

# the captain's durable priority (bin/fm-board-priority.sh), highest first
PRIO_JSON=$("$SCRIPT_DIR/fm-board-priority.sh" show 2>/dev/null | jq -R . | jq -s . 2>/dev/null) || PRIO_JSON='[]'
[ -n "$PRIO_JSON" ] || PRIO_JSON='[]'

# Live state of every PR/MR a decision or contribution names, so a card whose
# PR/MR already merged or closed leaves the board. A PR/MR a review card names
# (is_review) that is still open is also checked for the captain's own approval
# (fm_pr_viewer_approved) and reads "approved" when they gave it. Each lookup is
# one bounded forge read (fm_pr_live_state in bin/fm-pr-lib.sh); a failed, slow,
# or unparseable lookup records nothing, and an unknown state keeps its card.
PR_STATES_JSON='{}'
if [ "${FM_BEARINGS_BOARD_PR_CHECK:-1}" != 0 ]; then
  PR_TIMEOUT=${FM_BEARINGS_BOARD_PR_TIMEOUT:-5}
  PR_MAX=${FM_BEARINGS_BOARD_PR_MAX:-24}
  pr_urls=$(printf '%s\n' "$SNAP_JSON" | jq -r --argjson max "$PR_MAX" "$FM_BEARINGS_QUESTION_JQ_DEFS"'
    . as $s
    | ([ ($s.landed // [])[] | .artifact | strings ]) as $landed
    | [ ($s.decisions_open // [])[] as $d
        | (if is_review($d) then 1 else 0 end) as $rv
        | ( ($s.recorded_prs // [])[] | select(.id == $d.id) | .url ),
          ($d.pr_url // empty),
          ( ($d.reason_full // $d.reason // "") | tostring
            | scan("https://[^[:space:]<>\"()]+?/(?:pull|pulls|-/merge_requests)/[0-9]+") )
        | {u: ., rv: $rv} ]
      + [ ($s.contributions.captain // [])[] | {u: .url, rv: 0} ]
      + [ ($s.in_flight // [])[] | select(.state != "working") | {u: .pr_url, rv: 0} ]
    | map(select(.u | strings | test("^https://")))
    | group_by(.u) | map({u: .[0].u, rv: (map(.rv) | max)})
    | map(select(.u as $u | $landed | index($u) | not)) | .[:$max][]
    | "\(.u)\t\(.rv)"' 2>/dev/null) || pr_urls=""
  if [ -n "$pr_urls" ]; then
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    . "$SCRIPT_DIR/fm-pr-lib.sh"
    pr_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-board-pr.XXXXXX")
    trap 'rm -rf "$pr_tmp"' EXIT
    i=0
    while IFS="$(printf '\t')" read -r u rv; do
      i=$((i + 1))
      fm_pr_live_state "$u" "$PR_TIMEOUT" "$rv" >"$pr_tmp/$i" 2>/dev/null &
    done <<URLS
$pr_urls
URLS
    wait
    PR_STATES_JSON=$(cat "$pr_tmp"/* 2>/dev/null \
      | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries' 2>/dev/null) \
      || PR_STATES_JSON='{}'
    [ -n "$PR_STATES_JSON" ] || PR_STATES_JSON='{}'
  fi
fi

jq -n --argjson snap "$SNAP_JSON" --argjson copy "$COPY_JSON" --argjson prio "$PRIO_JSON" --argjson pr_states "$PR_STATES_JSON" --arg today "$(date -u +%Y-%m-%d)" "$FM_BEARINGS_QUESTION_JQ_DEFS"'
  def card_fields: ["title","about","decide","detail","options","recommend_value","type","close",
                    "risk","pr_url","links","subject","freeform_hint","allow_freeform","repo","question",
                    "free_text","no_link"];
  def underway_fields: ["repo"];
  def landed_fields: ["repo","pr_url","subject"];
  def charted_fields: ["title","reason","repo","dispatchable","filed"];

  def https_url: type == "string" and test("^https://[^[:space:]]+$");
  def repo_of_url:
    if https_url | not then null
    elif test("^https://[^/]+/[^/]+/[^/]+/(pulls?|issues)/") then
      capture("^https://[^/]+/[^/]+/(?<r>[^/]+)/(pulls?|issues)/").r
    elif test("^https://[^/]+/.+/[^/]+/-/") then
      capture("^https://[^/]+/.+/(?<r>[^/]+)/-/").r
    else null end;
  def nz($d): if . == null or . == "" or . == "-" then $d else . end;
  # A text matched literally inside a regex.
  def re_escape: gsub("(?<c>[\\\\^$.|?*+()\\[\\]{}])"; "\\\(.c)");
  # A sentence that guards an action: it says what must or must never happen,
  # what anything else means, or the plan count to expect ("0 to add").
  def guard_sentence:
    test("(?<![[:alnum:]])(?:[Mm]ust|MUST|[Nn]ever|NEVER|[Aa]nything else is|[0-9]+ to (?:add|change|destroy|import))(?![[:alnum:]])");
  # The identity a card link is deduplicated by: its url, board page or file path.
  def link_key: .url // (if has("page") then "page:" + .page else "path:" + (.path // "") end);
  # A bare option value in plain words: a known review-gate value reads as its
  # phrase, any other slug as its words.
  def option_words:
    {"cleared-merge": "Cleared to merge", "changes-needed": "Changes requested"}[.]
    // (gsub("[-_.]+"; " ") | sub("^ +"; "") | sub(" +$"; "") | cap);
  def pr_for($id; $contrib; $recorded):
    ( ([$contrib[] | select(.task == $id) | .url][0])
      // ([$recorded[] | select(.id == $id) | .url][0]) ) as $u
    | if ($u | https_url) then $u else null end;
  def overlay($section; $id; $allowed):
    (($copy[$section] // {})[$id] // {}) | with_entries(select(.key as $k | $allowed | index($k)));
  # What a board item expands to show in place: its task, the full hold or gate
  # reason, each recorded captain answer with its date and words, the task notes,
  # and its report, all from the snapshot structured fields; a row with no
  # recorded report takes the local report or page path its reason names (a
  # ".../report.md" first, else the first absolute .md or .html path).
  def context_of($d):
    ( {task: (($d.task // $d.id // $d.key) | if type == "string" and length > 0 then . else null end),
       reason: (($d.reason_full // $d.reason) | nz(null)
                | if . == null then null else (tostring | clean_reason | nz(null)) end),
       answers: [ ($d.answers // [])[] | objects
                  | {at: (.at // null), mode: (.mode // null), text: ((.text // "") | tostring)}
                  | select(.text != "") ][:12],
       notes: [ ($d.notes // [])[] | strings | select(length > 0) ][:12],
       report: (($d.report_path | if type == "string" and length > 0 then . else null end)
                // ((($d.reason_full // $d.reason // "") | tostring
                     | [ scan("(?<![^[:space:](])/[^[:space:]()<>\"\u0027;,]+[.](?:md|html)(?![[:alnum:]])") ]) as $p
                    | ([ $p[] | select(test("/report[.]md$")) ][0] // $p[0])))} )
    | with_entries(select(.value != null and .value != []));

  ($snap.contributions.captain // []) as $contrib
  | ($snap.recorded_prs // []) as $recorded
  | ($snap.in_flight // []) as $in_flight
  | ($snap.landed // []) as $landed_rows
  | (($snap.omitted // []) | map(.surface)) as $omitted

  | def released($d):
      ((if $d | has("held") then $d.held else "yes" end) | tostring | ascii_downcase)
      | (. == "no" or . == "false");
    ( [ $snap.decisions_open[]? | select(released(.) | not) ]
      | reduce .[] as $d ([]; if (map(.key) | index($d.key)) then . else . + [$d] end) ) as $held
  # A hold deferred to a future date (hold_until after today, or the dated
  # bucket) is a waiting row with its date, main and secondmate alike, never a call.
  | def deferred($d):
      ($d.hold_bucket // "") == "dated"
      or ( (($d.hold_until // "") | tostring) as $u
           | ($u | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")) and (($u[:10]) > $today) );
    # A hold whose time gate has passed (hold_until today or earlier) is back on
    # the captain: a decision card, never a waiting row, whatever its reason says.
    def lapsed($d):
      (($d.hold_until // "") | tostring) as $u
      | ($u | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")) and (($u[:10]) <= $today);
    ( [ $held[] | select(deferred(.)) ] ) as $deferred
  | ( [ $held[] | select(deferred(.) | not) ] ) as $held
  # A row whose every PR/MR is merged or closed (live forge state, or a landed
  # artifact) is finished work, and a row an explicit later round of the same
  # task in the same home has superseded is stale; neither reaches the board.
  | ( [ $landed_rows[] | .artifact | strings ] ) as $landed_urls
  | def pr_state($u): if ($landed_urls | index($u)) then "merged" else ($pr_states[$u] // null) end;
    def row_urls($d):
      [ pr_for($d.id; $contrib; $recorded), $d.pr_url,
        ( ($d.reason_full // $d.reason // "") | tostring
          | scan("https://[^[:space:]<>\"()]+?/(?:pull|pulls|-/merge_requests)/[0-9]+") ) ]
      | map(strings) | unique;
    # "approved" (the captain approved it) is open work, except that it settles
    # a review card (is_review): the review it asked for is given.
    def pr_finished($urls; $review):
      ($urls | length) > 0
      and all($urls[]; pr_state(.) as $st
                       | $st == "merged" or $st == "closed" or ($review and $st == "approved"));
    def pr_finished($urls): pr_finished($urls; false);
    def round_of:
      ([capture("^(?<b>.+?)-(?:r|round-?|v)(?<n>[0-9]{1,2})$")][0]
       | if . == null then null else {b, n: (.n | tonumber)} end) as $m
      | $m // {b: ., n: 1};
    ( [ ($snap.decisions_open // [])[] | {o: (.owner // "(main)"), id: ((.id // "") | split("/") | last)} ]
      + [ $in_flight[] | (.id // "") | if test("/") then {o: split("/")[0], id: (split("/") | last)} else {o: "(main)", id: .} end ]
      + [ $landed_rows[] | {o: (.owner // "(main)"), id: (.id // "")} ]
      + [ ($snap.gates // [])[] | {o: (.owner // "(main)"), id: (.id // "")} ]
      | map(select(.id != "") | . + {r: (.id | round_of)}) ) as $known
  | def superseded($d):
      (($d.id // "") | split("/") | last) as $id
      | ($d.owner // "(main)") as $o
      | ($id | round_of) as $r
      | $id != "" and any($known[]; .o == $o and .r.b == $r.b and .r.n > $r.n);
    ( [ $held[] | select(((is_merge_ask(.) and pr_finished(row_urls(.); is_review(.))) or superseded(.)) | not) ] ) as $held
  # A card link is labelled by what it points at, never by its raw URL: a
  # PR/MR/issue number from the URL shape, or for a Lavish page the kind the
  # text just before the URL names (understand, review, report). Question and
  # about text show that label in place of each URL, with a "?" written after
  # the URL and a space ("on <url> ?") put against the label ("on PR 135?"),
  # and a kind word the text already writes before the URL shown once
  # ("(PR <url>)" reads "(PR 133)", not "(PR PR 133)"). A link the text already
  # names by kind and number ("issue 942 (<url>)", "PR 938 (<url>)") drops its
  # parenthesis, and a link to a comment reads "Comment on issue 932". A
  # YouTrack issue link reads by its bare id ("APP-5837").
  # The run of bare URLs and absolute file paths (each maybe with a "(note)")
  # that ends a reason after its last sentence is the card links, not its
  # prose: trailing_cited cuts it from the text, its URLs become links as any
  # other, and each path becomes a `{path, label}` link labelled by its file
  # name and note ("youtrack-changes.md (Round 5)"), after the web links.
  # A URL holding a placeholder ("https://host/v1/clientIds/<CLIENT_ID>:x") is
  # an address to fill in, not a link: it stays whole in the text and the part
  # before the placeholder never becomes a link.
  | def card_urls:
      scan("(?:https://|http://dev-1\\.tailf848b0\\.ts\\.net:4387)[^[:space:]\"()]*")
      | select(test("<[A-Za-z_][A-Za-z0-9_-]*>") | not)
      | sub("[<>].*$"; "") | sub("[.,;:!?]+$"; "");
    def link_label($u; $t):
      ((($t | split($u)[0]) // "") | .[-80:] | sub("^.*([.;!?,]|\\([0-9]+\\))[[:space:]]"; "") | ascii_downcase) as $pre
      | ($u | test("#(issuecomment-|note_|discussion_r)[0-9]+$")) as $comment
      | if $comment and ($u | test("/(-/merge_requests|pulls?|(-/)?issues)/[0-9]+#"))
        then "Comment on " + (link_label($u | sub("#.*$"; ""); $t)
                              | if startswith("Issue ") then "issue " + .[6:] else . end)
        elif ($u | test("/-/merge_requests/[0-9]+")) then "MR " + ($u | capture("/-/merge_requests/(?<n>[0-9]+)").n)
        elif ($u | test("/pulls?/[0-9]+")) then "PR " + ($u | capture("/pulls?/(?<n>[0-9]+)").n)
        elif ($u | test("/(-/)?issues/[0-9]+")) then "Issue " + ($u | capture("/issues/(?<n>[0-9]+)").n)
        elif ($u | test("/issue/[A-Z][A-Z0-9]*-[0-9]+(?:[/?#]|$)")) then ($u | capture("/issue/(?<n>[A-Z][A-Z0-9]*-[0-9]+)").n)
        elif ($u | test("^http://dev-1\\.tailf848b0\\.ts\\.net:4387")) then
          (if ($pre | test("understand")) then "Understand page"
           elif ($pre | test("review")) then "Review page"
           elif ($pre | test("report")) then "Report"
           else "Lavish page" end)
        else ($u | sub("^https://"; "") | split("/")[0]) end;
    # label_urls(false) labels only a link its kind word already leads, and
    # keeps every other URL as written.
    def label_urls($all):
      . as $t | reduce ([$t | card_urls] | unique | sort_by(-length))[] as $u
        ($t; link_label($u; $t) as $l
          | ($l | capture("^(?<k>PR|MR|Issue) (?<n>[0-9]+)$") // null) as $c
          | (if $all then split($u + " ?") | join($u + "?") else . end | split($u)) as $parts
          | reduce $parts[1:][] as $part ($parts[0];
              ({PR: "PR|pull request", MR: "MR|merge request", Issue: "issue"}[$c.k // ""]) as $kw
              | if $c != null and ($part | startswith(")"))
                   and test("(?:^|[^[:alnum:]])(?:" + $kw + ") #?" + $c.n + " [(]$"; "i")
                then sub(" [(]$"; "") + $part[1:]
                else
                  (if $c != null and test("(?:^|[^[:alnum:]])" + $c.k + " $"; "i") then $c.n
                   elif $all then $l else $u end) as $shown
                  | . + $shown + $part end));
    def labelled_urls: label_urls(true);
    def cited_item: "(?<url>https?://[^[:space:]<>\"()]+)|(?<path>/[\\w.@~+-]+(?:/[\\w.@~+-]+)+)(?:[[:space:]]+\\((?<note>[^()]*)\\))?";
    def trailing_cited_at:
      [ match("(?<=[.?!])(?:[[:space:]]+(?:" + cited_item + "))+[[:space:]]*$") ][0].offset;
    def trailing_cited: trailing_cited_at as $o | if $o == null then . else .[:$o] end;
    def cited_paths:
      trailing_cited_at as $o
      | if $o == null then []
        else [ .[$o:] | match(cited_item; "g") | (.captures | map({(.name): .string}) | add)
               | select(.path != null)
               | {path, label: ((.path | split("/") | last) + (if (.note // "") != "" then " (" + .note + ")" else "" end))} ]
        end;
  # A status decision row (source "status") carries the asking task or home as its
  # title; the card title says what the question is instead.
  # A sentence cut short keeps its closing "?", so a long asking sentence still
  # reads as a question and the decision check in build still sees it ask.
  # It drops each URL with the word before it, except a link its own kind word
  # leads, which shows as its number ("deploy X (PR 133)?").
  # An asking sentence too long to show whole that ends in a clause which asks
  # ("..., so how should I deploy X?") is cut to that clause, whole, unless the
  # clause before it is a lead-in it completes ("when X is seen, should the run
  # go red?"), which keeps its subject.
  # A comma-led relative clause (", which ...", ", who ...", ", that ...") only
  # qualifies the clause before it, so it is never that asking clause; a too-long
  # sentence ending in one is cut to the main clause before it ("Shall I merge
  # PR 29, which makes ...?" reads "Shall I merge PR 29?"). One that
  # ends in a parenthesis drops that parenthesis whole ("Which comments should
  # go on MR 887 (verdict: ...)?" reads "... on MR 887?"), and a cut never
  # ends inside a parenthesis that closes right before the "?".
  # Any other too-long heading (short_text_n($n; true)) first drops its inner parenthetical
  # asides ("Review PR 894 (#697 ...), now that it is complete?" reads
  # "Review PR 894, now that it is complete?"), else is cut at its last clause boundary
  # (", with ...", "; ...", " - ...") that keeps at least half of it
  # ("Should X stay a human apply, with all other infra applied by Y?" reads
  # "Should X stay a human apply?"); a heading (short_text_n($n; true)) with
  # no such boundary is shown whole rather than cut mid-clause.
    def short_text_n($n; $whole):
      tostring | label_urls(false) | gsub("[[:space:]]+"; " ") | sub("^ "; "")
      | (sentences[0] // .)
      | gsub("( (at|on|in|see|via))? ?https?://[^[:space:]]*[^[:space:].,;:!?](?: (?=[?]))?"; "")
      | sub("[[:space:]]*[.,;:]$"; "")
      | if length > $n and endswith("?") then
          . as $s
          | [match("(?:,(?! (?:which|who|that) )|;|[[:space:]]-) (?:(?:so|and|but|then|now|or) )?(?<q>(?:how|what|which|who|when|where|why|whether|should|shall|can|could|will|would|do|does|did|is|are|may|must|might) [^,;]*[?])$"; "i")][0] as $m
          | ($m.captures[0].string // null) as $c
          # A clause the asking one completes ("when X, should Y?") is its subject.
          | ($m != null and ($s[:$m.offset] | sub("^.*[:;.!?][[:space:]]+"; "")
                             | test("^(?:when|whenever|if|once|after|before|unless|until|while|since|because|although|though|given|as soon as|in case|where|wherever)[[:space:]]"; "i"))) as $lead_in
          | if $c != null and ($c | length) <= $n and ($lead_in | not) then $c | cap else . end
        else . end
      | if length > $n and endswith("?") then
          . as $s
          | ([ match(", (?=(?:which|who|that) )"; "gi").offset
               | select(($s[:.] | [scan("[(]")] | length) == ($s[:.] | [scan("[)]")] | length))
               | select($s[. + 2:] | gsub("\\([^()]*\\)"; "") | test("[,;]") | not) ] | min) as $o
          | if $o != null and $o > 0 then $s[:$o] + "?" else . end
        else . end
      | if length > $n and test("[^[:space:]][[:space:]]*\\([^()]*\\)[?]$") then
          (sub("[[:space:]]*\\([^()]*\\)[?]$"; "") + "?") as $a
          | if ($a | length) <= $n then $a else . end
        else . end
      | if $whole and length > $n and endswith("?")
           and (gsub("[[:space:]]+\\([^()]*\\)(?=[,;:]? )"; "") | length <= $n) then
          gsub("[[:space:]]+\\([^()]*\\)(?=[,;:]? )"; "")
        else . end
      | if length > $n and endswith("?") then
          . as $s
          | ([ match("(?:, (?=(?:with|while|which|since|because|so|but|then|unless|before|after|given|where|when|if|although|though|as|now that) )|; | - )"; "gi").offset
               | select(. + 1 <= $n and . >= ($n / 2))
               | select(($s[:.] | [scan("[(]")] | length) == ($s[:.] | [scan("[)]")] | length)) ] | max) as $o
          | if $o != null then ($s[:$o] | sub("[[:space:],;:-]+$"; "")) + "?" else . end
        else . end
      | if length <= $n or ($whole and endswith("?")) then .
        else endswith("?") as $asks | test("[)][?]$") as $paren_asks
          | (.[:(if $asks then $n - 2 else $n - 1 end)] | sub(" [^ ]*$"; "")
             | if $paren_asks and ([scan("[(]")] | length) > ([scan("[)]")] | length)
               then sub("[[:space:]]*[(][^()]*$"; "") else . end)
          + (if $asks then "…?" else "…" end) end;
    def short_text_n($n): short_text_n($n; false);
    def short_text: short_text_n(80);
    # The sentence that asks: one led by "Question:" (prefix dropped), else the
    # first ending in "?", else the first sentence.
    def ask_sentence:
      clean_reason | gsub("[[:space:]]+"; " ") | sub("^ "; "")
      | sentences as $s
      | ( ([ $s[] | select(test("^Question:[[:space:]]*"; "i")) | sub("^Question:[[:space:]]*"; ""; "i") ][0])
          // ([ $s[] | select(test("[?]$")) ][0])
          // $s[0] // "" )
      | sub("^\\([0-9a-z]\\)[[:space:]]*"; "");
    def task_title($owner; $k):
      ( [ $snap.decisions_open[]?
          | select((.verb // "") == "captain-hold" and (.owner // "(main)") == $owner
                   and (.key == $k or ((.id // "") | split("/") | last) == $k))
          | (.title_full // .title) | select(. != null) | nz(null) | select(. != null) ][0] )
      // ( [ $in_flight[] | select(.id == (if $owner == "(main)" then $k else $owner + "/" + $k end))
             | .name | nz(null) | select(. != null) ][0] )
      // ( [ ($snap.gates // [])[] | select(.id == $k and (.owner // "(main)") == $owner)
             | .title | nz(null) | select(. != null) ][0] );
    def status_title($d):
      ($d.owner // "(main)") as $owner
      | ($d.decision_key // "default") as $k
      | (($d.title_full // $d.title // "") | tostring) as $given
      | ( (if $k != "default" then task_title($owner; $k) else null end)
          // (if $given != "" and ([$d.task, $d.id, $d.mate, $owner, $d.key] | index($given) | not)
              then $given else null end)
          // ((($d.reason_full // $d.reason // "") | clean_reason
               # An asking sentence inside the options the reason lists is a choice,
               # not the question, so it never titles the card.
               | (option_parse) as $p | if $p == null then . else $p.lead + " " + $p.tail end
               | ask_sentence | short_text) | nz(null))
          // (if $k != "default" then $k else $d.key end) ) as $t
      | if $owner != "(main)" and ($t | startswith($owner + ": ") | not) then $owner + ": " + $t else $t end;
    [ $held[] | if (.source // "") == "status" then .title_full = status_title(.) else . end ] as $held
  # A status line that only announces a live page or ready PR asks nothing: its
  # link folds into the card for the same task or PR/MR (below), and the line
  # itself is never a card or a waiting row.
  | ( [ $held[] | select(is_announcement(.) and (is_wait(.) | not)) ] ) as $announced
  | ( [ $held[] | select(is_announcement(.) and (is_wait(.) | not) | not) ] ) as $held
  # A decision handed to a worker after it was raised (handed_at, set by
  # bin/fm-bearings-snapshot.sh) no longer waits on the captain: it is a wait
  # until the worker raises a fresh question.
  | def handed($d): ($d.handed_at // null) != null;
    def waitlike($d): (is_wait($d) and (lapsed($d) | not)) or handed($d);
    def handed_reason($d):
      (($d.handed_at | tostring | .[:16] | sub("T"; " ")) + " UTC") as $when
      | if $d.handed_via == "reconcile" then
          "Marked out of date on the board at " + $when + "; firstmate is checking it"
        elif $d.handed_via == "board" then
          "Answered on the board at " + $when
          + "; it comes back only if the question is raised again"
        else
          "With " + ($d.handed_task // "the worker") + " since " + $when
          + "; it raises a fresh question when it needs the captain"
        end;
    ( [ $held[] | select(waitlike(.) | not) ] ) as $asked
  # One question, one card: a status decision whose key names a captain-held
  # task in the same home is the same question, so it folds into that hold card
  # with its text and choices. A hold that is a wait absorbs nothing, so a
  # status question about a parked task still shows.
  | def same_question($s; $h):
      ($s.source // "") == "status" and ($h.verb // "") == "captain-hold"
      and (($s.decision_key // "default") != "default")
      and (($s.owner // "(main)") == ($h.owner // "(main)"))
      and ($h.key == $s.decision_key or (($h.id // "") | split("/") | last) == $s.decision_key);
    # An unkeyed status decision that names a captain-held task of the same home
    # by its id announces that hold ("...; card cd-930-identity"): it is dropped,
    # not a second card, and the hold card stays as it is.
    def names_hold($s; $h):
      ($s.source // "") == "status" and ($h.verb // "") == "captain-hold"
      and (($s.decision_key // "default") == "default")
      and (($s.owner // "(main)") == ($h.owner // "(main)"))
      and ((($h.id // "") | split("/") | last) as $id
           | $id != ""
           and ([$s.reason_full, $s.reason, $s.question] | map(strings) | join(" ")
                | test("(^|[^A-Za-z0-9_-])" + ($id | gsub("(?<c>[^A-Za-z0-9_-])"; "\\\(.c)"))
                       + "($|[^A-Za-z0-9_-])")));
    # A keyed status decision of a task that is itself captain-held in the same
    # home asks the call of that hold under another key: it is dropped, not a second
    # card, and the hold card stays as it is.
    def on_held_task($s; $h):
      ($s.source // "") == "status" and ($h.verb // "") == "captain-hold"
      and (($s.decision_key // "default") != "default")
      and (($s.owner // "(main)") == ($h.owner // "(main)"))
      and ((($h.id // "") | split("/") | last) as $id | $id != "" and ($s.task // "") == $id);
    ( [ $asked[] | select((.verb // "") == "captain-hold") ] ) as $asked_holds
  | ( [ $held[] | select(. as $r | any($asked_holds[]; same_question($r; .) or names_hold($r; .) or on_held_task($r; .)))
        | .key ] ) as $folded
  | ( [ $asked[] | . as $r
        | if ($folded | index([$r.key])) then empty
          elif ($r.verb // "") == "captain-hold" then
            . + {twins: [ $held[] | select(same_question(.; $r)) ]}
          else . end ]
      | def task_of($r): [$r.task, $r.decision_key, (($r.id // "") | split("/") | last), $r.key] | map(strings | select(. != "default"));
        def same_work($a; $c):
          (($a.owner // "(main)") == ($c.owner // "(main)")
           and ((task_of($a) - (task_of($a) - task_of($c))) | length) > 0)
          or ((row_urls($a) - (row_urls($a) - row_urls($c))) | length) > 0;
        map(. as $c | . + {announced: [ $announced[] | select(same_work(.; $c)) ]}) ) as $question_rows
  | ( [ $held[] | select(waitlike(.)) | select(.key as $k | $folded | index([$k]) | not)
        | . as $d
        | { key: $d.key,
            title: (($d.title_full // $d.title // $d.summary // $d.key) | nz($d.key)),
            reason: ((if handed($d) then handed_reason($d)
                      else (($d.reason_full // $d.reason) | nz(null) | if . == null then "waiting" else (clean_reason | nz("waiting")) end) end)
                     | if ($d.note // null) == null then . else $d.note + " - " + . end),
            repo: ([$in_flight[] | select(.id == $d.id or .id == $d.key) | .repo][0] // null),
            context: context_of($d) } ] ) as $waiting
  # The heading of a text that lists its own options comes from the text
    # before the options: the sentence that introduces them when it ends in a
    # colon ("Merge PR 13: (1) ..."), else its asking sentence, without a
    # trailing colon or dash. Words that only introduce the options
    # ("... reviewer? Options: (1) ...") are not that sentence. A text with an
    # asking sentence before a colon lead-in asks the first such sentence, not
    # the lead-in ("Which tool draws it? Two ways to add sign-in: 1) ...").
    # A last sentence led by a decision label ("Captain call: the re-run must
    # either") is the heading; the card question drops that label.
  | def decision_label: "^(?:Captain(?:\u0027s)? (?:call|decision)|Decision(?: needed)?)[[:space:]]*:[[:space:]]*";
    def lead_sentence:
      gsub("[[:space:]]+"; " ") | sub("^ "; "")
      | sub("(?:^|(?<=[.!?]) )(?:the )?(?:options|choices|alternatives)(?: (?:are|would be))?[[:space:]]*:[[:space:]]*$"; ""; "i")
      | [ sentences[] | select(length > 0) ] as $all
      | ($all[-1] // "") as $last
      | if ($last | test(decision_label + "[^[:space:]]"; "i"))
        then $last
        elif test(":[[:space:]]*$") and (test("Question:"; "i") | not)
        then ([ $all[:-1][] | select(test("[?]$")) ][0] // $last)
        else ask_sentence end
      | sub("[[:space:]:;,-]+$"; "");
    # The body shows the lead and tail of a text; its options are the choices on the card.
    # Words that only introduce the options ("Options are", "Choices:") go with them.
    # A tail that only repeats a link label adds nothing the card links lack.
    # A list whose marks name none of the options a hold recorded ($recorded,
    # their values) is not the card choices but part of the text, such as
    # numbered steps on a card with lettered options, so it stays.
    # A lead that runs into its options with no sentence end takes the "?"
    # that closes the option run ("so should I a) ... or c) ...?"), else ".".
    def without_options($recorded):
      . as $whole
      | (option_parse) as $p
      | if $p == null then .
        elif ($recorded | length) > 0
             and ([ $p.options[].value | ltrimstr("option-") | ascii_downcase ]
                  | any(. as $v | $recorded | index($v)) | not)
        then .
        else [ ($p.lead | sub("[[:space:]:;,-]+$"; "")
                | sub("(?:^|(?<=[.!?])[[:space:]]+)(?:the )?(?:options|choices|alternatives)(?: (?:are|would be))?$"; ""; "i")
                | if length > 0 and (test("[.?!]$") | not)
                  then . + (if $whole[:(($whole | length) - ($p.tail | length))] | test("[?][[:space:]]*$") then "?" else "." end)
                  else . end),
               ($p.tail | sub("^[[:space:]]+"; "")
                | if test("^((Comment on (PR|MR|issue) [0-9]+)|(PR|MR|Issue) [0-9]+|[A-Z][a-z]+ page|Report)[.]?$") then "" else . end) ]
             | map(select(length > 0)) | join(" ") end;
    # A decision answered on a Lavish page: its text holds a tailnet page link
    # and says the question is on that page.
    def page_phrase: "(?:is|are) (?:now |all )?on (?:one|the|a|this|its|that) (?:[a-z0-9-]+ ){0,2}page|(?:(?<=ready)|(?<=live)) on (?:one|the|a|this|its|that) (?:[a-z0-9-]+ ){0,2}page|(?<=ready) for [^.?!]{0,60}? on (?:one|the|a|this|its|that) (?:[a-z0-9-]+ ){0,2}page|the page (?:now )?(?:shows|has|holds|asks|carries|lists)|(?:answer|pick|choose|decide|reply|respond)[^.?!]{0,40} on the page";
    def page_backed: test("http://dev-1\\.tailf848b0\\.ts\\.net:4387/") and test(page_phrase; "i");
    def page_subject:
      [match(page_phrase; "i")][0].offset as $o
      | .[:$o] | gsub("[[:space:]]+"; " ") | sub("[[:space:]:;,.-]+$"; "")
      | (sentences | last // "");
    ( $question_rows
      | map(
          . as $d
          | (pr_for($d.id; $contrib; $recorded)
             // (if ($d.pr_url | https_url) then $d.pr_url else null end)) as $pr
          | ( {
              key: $d.key,
              type: "decision",
              repo: ( ($pr | repo_of_url)
                      // ([$in_flight[] | select(.id == $d.id or .id == $d.key) | .repo][0])
                      // ([ ($d.reason_full // $d.reason // ""), (($d.twins // [])[] | (.reason_full // .reason // "")) ]
                          | map(tostring | card_urls | repo_of_url | strings) | .[0])
                      // null ),
              title: (($d.title_full // $d.title // $d.summary // $d.key) | nz($d.key)),
              options: ( [ default_options($d)[], ($d.twins // [])[] as $tw | default_options($tw)[] ]
                         | reduce .[] as $o ([];
                             if any(.[]; (.label | ascii_downcase) == ($o.label | ascii_downcase)) then .
                             elif any(.[]; .value == $o.value) then . + [$o + {value: ($o.value + "-" + ((length + 1) | tostring))}]
                             else . + [$o] end) ),
              allow_freeform: true,
              freeform_hint: "answer in your own words (say later to defer)",
              context: context_of($d)
            }
            # The heading is one short asking sentence; the full cleaned text
            # (with the text of any folded twin) is the body, each URL shown as its
            # link label, and a heading that only repeats the title is dropped so
            # the title leads instead.
            + ( [ ($d.reason_full // $d.reason), (($d.twins // [])[] | (.reason_full // .reason)) ]
                | map(nz(null) | select(. != null) | clean_reason | trailing_cited | nz(null) | select(. != null) | labelled_urls)
                | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end) as $texts
                | (($d.title_full // $d.title // $d.summary // $d.key) | nz($d.key) | tostring) as $title
                | (($texts | max_by(length)) // null) as $long
                # A question whose "?" closes its inline option run ("how should X do
                # Y: (a) ... (b) ...?") keeps that "?" on the heading cut from its lead.
                # A lead that ends its own sentence, or options that ask questions of
                # their own, keep the heading as it is.
                | (if $long == null then null else ($long | option_parse) end) as $parsed
                | (if $long == null then null
                   elif $parsed != null then ($parsed.lead | lead_sentence | short_text_n(120; true) | nz(null)
                     | if . != null
                          and (test("[?]$") | not)
                          and ($parsed.lead | test("[.?!][[:space:]]*$") | not)
                          and ([$parsed.options[].label | test("[?]")] | any | not)
                          and ($long[:(($long | length) - ($parsed.tail | length))] | test("[?][[:space:]]*$"))
                       then . + "?" else . end)
                   else ($long | ask_sentence | short_text_n(120; true) | nz(null)) end) as $q_named
                # A URL the heading names only by its host ("v1.1.1 (<url>) to")
                # is a card link, so the heading drops that host label with its
                # parentheses or the word leading it ("at", "on", "in", "see", "via").
                | ( [ ($d.reason_full // $d.reason), (($d.twins // [])[] | (.reason_full // .reason)) ]
                    | map(strings | . as $t | card_urls | link_label(.; $t)
                          | select(test("^[a-z0-9-]+(?:[.][a-z0-9-]+)+$"))) | unique ) as $hosts
                | ($q_named | if . == null then null
                   else reduce $hosts[] as $h (.;
                          ($h | re_escape) as $e
                          | gsub("(?:[[:space:]]+(?:at|on|in|see|via))?[[:space:]]*\\(" + $e + "\\)"
                                 + "|(?:[[:space:]]+(?:at|on|in|see|via))?[[:space:]]+" + $e + "(?=[[:space:]?.,;:!]|$)"; ""))
                     | sub("[[:space:]]+(?=[?.!]$)"; "")
                   end) as $q0
                | (if $q0 == null then null else ($q0 | sub(decision_label; ""; "i") | cap) end) as $q
                | (if ($d.verb // "") == "review-ready" then $texts else ( [ (($d.choices // {}) | if type == "object" then (.options // []) else [] end)[]
                           | objects | .value | strings | ascii_downcase ] ) as $recorded
                       | [ $texts[] | without_options($recorded) ] end) as $body
                | ($q != null and $title != $q and ($title | endswith(": " + $q) | not)) as $asks
                # The body drops each whole sentence that only repeats the heading:
                # one that starts the text or follows a sentence end, never the
                # end of a longer sentence.
                | ($body | join("\n\n")) as $whole
                | ($whole
                   | ($q0 // "" | sub("[.?!]+$"; "")) as $qs
                   | if $asks and length > ($qs | length) then
                       gsub("(?:^|(?<=[.?!][[:space:]]))" + ($qs | re_escape) + "[.?!](?:[ \t]+|\n|$)"; "")
                       | sub("[[:space:]]+$"; "")
                     else . end
                   # A sentence that carries a guard ("must", "never", "anything
                   # else is", an expected plan count) is never cut from the
                   # body: when any is missing, the whole body stays. The
                   # heading shown whole is not missing.
                   | . as $cut
                   | (if $asks then $q0 // "" | sub("[[:space:]?.!:]+$"; "") else null end) as $shown
                   | if all($whole | sentences[] | select(guard_sentence)
                            | select(sub("[[:space:]?.!:]+$"; "") != $shown);
                            . as $g | $cut | contains($g))
                     then $cut else $whole end) as $about
                | (if $asks then {question: $q} else {} end)
                  + (if ($about | length) > 0 and $about != $q0
                        and ($about | sub("[[:space:]?.!:]+$"; "")) != ($q0 // "" | sub("[[:space:]?.!:]+$"; ""))
                     then {about: $about} else {} end) )
            + (if $pr != null then {pr_url: $pr} else {} end)
            + ( [ ( ($d.announced // [])[] | ((.reason_full // .reason // "") | tostring) as $t
                    | $t | card_urls | {url: ., label: link_label(.; $t)} ),
                  ( ([($d.reason_full // $d.reason // ""), (($d.twins // [])[] | (.reason_full // .reason // ""))] | map(tostring) | join(" ")) as $t
                    | $t | card_urls | {url: ., label: link_label(.; $t)} ) ]
                | reduce .[] as $l ([]; if any(.[]; .url == $l.url) then . else . + [$l] end)
                | . + ( [ ($d.reason_full // $d.reason), (($d.twins // [])[] | (.reason_full // .reason)) ]
                        | map(nz(null) | select(. != null) | clean_reason | cited_paths[])
                        | reduce .[] as $l ([]; if any(.[]; .path == $l.path) then . else . + [$l] end) )
                | .[:24]
                | reduce .[] as $l ([];
                    ([.[] | select(.label == $l.label or (.label | startswith($l.label + " (")))] | length) as $n
                    | . + [if $n > 0 then $l + {label: ($l.label + " (" + (($n + 1) | tostring) + ")")} else $l end])
                | if length > 0 then {links: .} else {} end ) )
          # A card whose text refers to options it does not carry takes them
          # from its own or earlier text, else says it refers to options it
          # does not list (recover_options in bin/fm-bearings-question-lib.sh).
          | if ($d.verb // "") == "review-ready" then .
            else recover_options(
                   [ ($d.reason_full // $d.reason), (($d.twins // [])[] | (.reason_full // .reason)) ]
                   | map(nz(null) | select(. != null) | clean_reason);
                   [ ($d.reason_earlier // [])[], (($d.twins // [])[] | (.reason_earlier // [])[]) ]
                   | map(tostring | clean_reason) | reverse)
            end
          # The choices and links the hold recorded (bin/fm-captain-hold.sh hold
          # --option/--link/--free-text/--no-link) are the card own: recorded
          # options replace the ones read from its text, recorded links lead, and
          # a `page:<id>` link opens that board page in place. A hold that
          # recorded no options carries options_inferred, which build refuses.
          | (($d.choices // {}) | if type == "object" then . else {} end) as $ch
          | ( [ ($ch.links // [])[] | objects | select(.target | type == "string" and length > 0)
                | . as $l
                | if ($l.target | startswith("page:"))
                  then {page: $l.target[5:], label: (($l.label // "") | nz("Board page"))}
                  else {url: $l.target, label: (($l.label // "") | nz(link_label($l.target; $l.target)))} end ]
              + (.links // [])
              | reduce .[] as $l ([]; ($l | link_key) as $k
                                      | if any(.[]; link_key == $k) then . else . + [$l] end)
              | .[:24] ) as $ls
          | if ($ls | length) > 0 then .links = $ls else . end
          # A recorded option with no label of its own (the snapshot gives it
          # its value) is shown in words: when every recorded option is bare
          # and the reason lists the same number of its own options, each takes
          # the reason option at its place, recommendation included; else its
          # value reads as words (option_words). Recorded options whose values
          # are the letters the reason lists, in order ("a=reads" for "a) reads
          # - why ... (recommended); b) ..."), take the reason options the same
          # way, so the card keeps each explanation and the recommendation.
          | ( [ ($d.reason_full // $d.reason), (($d.twins // [])[] | (.reason_full // .reason)) ]
              | map(nz(null) | select(. != null) | clean_reason | option_parse | select(. != null)) | .[0] ) as $own
          | [ ($ch.options // [])[] | objects ] as $ro
          | ($ro | all(((.label // "") | nz(null)) as $l | $l == null or $l == .value)) as $bare
          | ($own != null and ($own.options | length) == ($ro | length)
             and ([ range(0; $ro | length) as $i
                    | (($ro[$i].value // "") | tostring | ascii_downcase)
                      == ($own.options[$i].value | ltrimstr("option-") | ascii_downcase) ] | all)) as $lettered
          | if ($ro | length) > 0
            then (if ($bare or $lettered) and $own != null and ($own.options | length) == ($ro | length)
                  then .options = [ range(0; $ro | length) as $i | {value: $ro[$i].value, label: $own.options[$i].label} ]
                       | ([ range(0; $ro | length) | select($own.options[.].value == $own.recommend) ][0]) as $ri
                       | if $ri != null then .recommend_value = $ro[$ri].value else . end
                  # A recorded label that ends in "(recommended)" or "(preferred)"
                  # marks that option as the card recommendation, and the marker
                  # leaves the label.
                  else "[[:space:]]*\\((?i:recommended|preferred)\\)[[:space:].;,]*$" as $mark
                       | .options = [ $ro[] | . as $o | (($o.label // "") | nz(null)) as $l
                                    | {value: $o.value,
                                       label: (if $l == null or $l == $o.value then ($o.value | option_words)
                                               elif ($l | test($mark)) then ($l | sub($mark; "") | nz($l))
                                               else $l end)} ]
                       | ([ $ro[] | select((.label // "") | test($mark)) | .value ][0]) as $mv
                       | if $mv != null then .recommend_value = $mv else . end end)
                 | del(.malformed)
            elif ($d.verb // "") == "captain-hold" and ($ch.free_text != true) then .options_inferred = true
            else . end
          | if $ch.free_text == true then .free_text = true else . end
          | if $ch.no_link == true then .no_link = true else . end
          # A worker status question or a review page the generator raised has
          # no hold to record choices on.
          | if ($d.source // "") == "status" or ($d.verb // "") == "review-ready"
            then .from_status = true else . end
          # An option the reason itself marks recommended is the card recommendation.
          | ( if ($d.verb // "") == "review-ready" then null
              else [ ($d.reason_full // $d.reason), (($d.twins // [])[] | (.reason_full // .reason)) ]
                   | map(nz(null) | select(. != null) | clean_reason | option_parse | .recommend? // empty)
                   | .[0] end ) as $rec
          | if $rec != null and any(.options[]; .value == $rec) then .recommend_value = $rec else . end
          # The generator makes a review-page card itself, so it always asks: when
          # neither its heading nor its title asks, it asks whether the captain
          # has reviewed the page (fm-bearings-board.sh build refuses a card
          # that states no decision).
          | if ($d.verb // "") == "review-ready"
               and (((.question // "") + " " + (.title // "")) | contains("?") | not)
            then .question = "Have you reviewed this page?" else . end
          # A lapsed hold the generator returned to the board asks whether
          # it is still waiting when its own text does not ask, offering a
          # fresh date or a go-ahead (or a free-text answer) when the hold
          # recorded no choices of its own, so build does not refuse it.
          | if lapsed($d) and (((.question // "") + " " + (.title // "")) | contains("?") | not)
            then .question = ("Its hold until " + ((($d.hold_until // "") | tostring)[:10])
                              + " has passed: is it still waiting?")
                 | if .options_inferred == true
                   then .options = [{value: "go", label: "Go ahead now"},
                                    {value: "keep-waiting", label: "Still waiting, hold it again"}]
                        | .free_text = true | del(.options_inferred, .malformed)
                        | if ((.links // []) | length) == 0 and ((.pr_url // "") | length) == 0
                          then .no_link = true else . end
                   else . end
            else . end
          # A decision answered on its Lavish page shows only the link to that
          # page: no recap, no choices, and a title that names what the page is
          # about rather than the sentence pointing at it.
          | ( [ ($d.reason_full // $d.reason), (($d.twins // [])[] | (.reason_full // .reason)) ]
              | map(nz(null) | select(. != null) | clean_reason)
              | [ .[] | select(page_backed) ][0] ) as $paged
          | if $paged == null then .
            else ( ($paged | page_subject) as $subject
                   | ($d.owner // "(main)") as $owner
                   # What the card shows when its page is not in the board.
                   | ( {allow_freeform: true,
                        freeform_hint: "answer in your own words (say later to defer)",
                        malformed: "Its choices are on its Lavish page, which the board does not show; answer in your own words."}
                       + (if .question != null then {question} else {} end)
                       + (if .about != null then {about} else {} end) ) as $off
                   | .title as $t
                   # A title cut short before the page phrase is still the sentence pointing at the page.
                   | ($t | sub("^" + ($owner | gsub("[^A-Za-z0-9 _-]"; ".")) + ": "; "") | sub("…$"; "") | ascii_downcase) as $stem
                   | (($t | test(page_phrase; "i"))
                      or (($t | endswith("…")) and ($stem | length) > 0
                          and ($paged | gsub("[[:space:]]+"; " ") | ascii_downcase | startswith($stem)))) as $points
                   | { key, type, repo, context,
                       title: (if $points and ($subject | length) > 0 and ($subject | length) <= 120
                               then (if $owner != "(main)" and ($t | startswith($owner + ": ")) then $owner + ": " else "" end) + $subject
                               else $t end),
                       options: [], allow_freeform: false, off_board: $off }
                     + with_entries(select(.key == "free_text" or .key == "no_link" or .key == "from_status"))
                     + ( [ (.links // [])[] | select(.page != null or ((.url // "") | startswith("http://dev-1.tailf848b0.ts.net:4387/"))) ]
                         | if length > 0 then {links: .} else {} end ) )
            end
          # A decision from a home that could not be read this time shows why
          # it may be out of date; an authored detail still wins.
          | if ($d.note // null) != null and (.detail // null) == null then . + {detail: $d.note} else . end
          # A lettered option read from the text ("(a) ... (b) ...") answers as
          # its letter, as the question names it and as a hold records it: the
          # parser value option-a becomes a, and the recommendation with it.
          # A letter another option on the card already uses keeps its value.
          | ( [ (.options // [])[].value ] ) as $vals
          | ( reduce $vals[] as $v ({};
                if ($v | test("^option-[a-z]$")) and (($v | ltrimstr("option-")) | IN($vals[]) | not)
                then .[$v] = ($v | ltrimstr("option-")) else . end) ) as $letters
          | if ($letters | length) == 0 then .
            else .options |= map(.value = ($letters[.value] // .value))
                 | if (.recommend_value | type) == "string"
                   then .recommend_value = ($letters[.recommend_value] // .recommend_value) else . end
            end
          | overlay("captains_call"; $d.key; card_fields) as $ov
          | . + $ov
          | if ($ov | has("options")) then del(.malformed, .options_inferred) else . end
          | if has("recommend_value") and ($ov | has("recommend_value") | not)
               and (.recommend_value as $rv | any(.options[]; .value == $rv) | not)
            then del(.recommend_value) else . end
          | if has("off_board") then
              .off_board |= ( with_entries(select(.key as $k | $ov | has($k) | not))
                              | if ($ov | has("options")) then del(.malformed) else . end )
            else . end
          | . as $card
          | select((($copy.captains_call // {}) | has($d.key) | not)
                   or ($copy.captains_call[$d.key] != null))
          | $card )
    ) as $cards
  | ( [ $contrib[]
        | select((.hold // null) == null and (.url | https_url) and (.task | type == "string"))
        | select(pr_finished([.url]) | not)
        | . as $c
        | select(($cards | any(.key == $c.task or .pr_url? == $c.url)) | not)
        | { key: ("contribution." + (.task | gsub("[^A-Za-z0-9._-]"; "-"))),
            type: "decision",
            repo: (.url | repo_of_url),
            title: ((.url | repo_of_url | nz("")) as $r
                    | (if $r == "" then $c.task else $r + " #" + ($c.url | split("/") | last) end)),
            about: ($c.reason | nz("waiting on the captain")),
            # The generator makes this card itself, so it always asks (fm-bearings-board.sh build
            # refuses a card that states no decision).
            question: "What should happen with this contribution?",
            pr_url: .url,
            options: [], allow_freeform: true, free_text: true,
            freeform_hint: "answer in your own words (say later to defer)",
            context: {task: $c.task, reason: ($c.reason | nz("waiting on the captain"))} }
        | . as $card
        | select((($copy.captains_call // {}) | has($card.key) | not)
                 or ($copy.captains_call[$card.key] != null)) ]
      | reduce .[] as $d ([]; if (map(.key) | index($d.key)) then . else . + [$d] end)
      | map(. + overlay("captains_call"; .key; card_fields)) ) as $contrib_cards
  | ($cards + $contrib_cards + ($copy.captains_call_extra // [])) as $captains_call

  # A gate the fleet holds (a hold kind, such as an external wait or a future
  # date) waits on that hold: a waiting row naming it, never a charted row.
  | def future($u): (($u // "") | tostring) as $s | ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")) and ($s[:10] > $today);
    def held_gate($r): ($r.id | test("^\\(") | not) and ((($r.hold_kind // "") != "") or future($r.hold_until));
    def until_reason($u; $text):
      (if future($u) then "until " + (($u | tostring)[:10]) + ": " else "" end) + $text;
    def owner_title($o; $t): (if $o == "(main)" then "" else $o + ": " end) + $t;
    ( [ ($snap.gates // [])[] | select(held_gate(.))
        | . as $r | ($r.owner // "(main)") as $o
        | { key: ((if $o == "(main)" then $r.id else $o + "-" + $r.id end) | gsub("[^A-Za-z0-9._-]"; "-") | .[:128]),
            title: owner_title($o; (($r.title_full // $r.title) | nz($r.id))),
            reason: until_reason($r.hold_until;
                      (($r.reason_full // $r.reason) | nz(null)
                       | if . == null then "waiting" else (tostring | clean_reason | nz("waiting")) end)),
            repo: ([$in_flight[] | select(.id == $r.id or .id == ($o + "/" + $r.id)) | .repo][0] // null),
            context: context_of($r),
            owner_id: (if $o == "(main)" then $r.id else $o + "/" + $r.id end) } ] ) as $gate_waits
  # A main row that is done has left the fleet work; a secondmate child that
  # is done stays under way until its home cleans it up, since that home has
  # not landed it. Any row not working whose PR/MR has merged or closed is
  # finished, and a row whose task waits on a fleet hold shows as that wait.
  | ( [ $gate_waits[] | .owner_id ] ) as $waiting_ids
  | ( [ $in_flight[]
        | select(.state != "done" or ((.id // "") | test("/")))
        | select(.state == "working" or (pr_finished([.pr_url | strings]) | not))
        | select(.state == "working" or (.id as $i | $waiting_ids | index($i) | not))
        | . as $r
        | { id, name: (.name | nz($r.id)), repo: (.repo // null),
            state: (.state | nz("unknown")), doing: (.doing | nz("-")),
            kind: (.kind | nz("task")) }
          + (if ($r.pr_url | type) == "string" and ($r.pr_url | startswith("https://"))
             then {pr_url: $r.pr_url} else {} end)
          + overlay("underway"; .id; underway_fields) ] ) as $underway

  | ( [ $landed_rows[]
        | . as $r
        | (if (.artifact | https_url) then .artifact else pr_for(.id; $contrib; $recorded) end) as $pr
        | { id, repo: ($pr | repo_of_url), what: (.what | nz($r.id)), owner: (.owner | nz("(main)")) }
          + (if $pr != null then {pr_url: $pr} else {} end)
          + overlay("landed"; .id; landed_fields) ] ) as $landed

  | ( [ $snap.gates[]? | select(held_gate(.) | not)
        | . as $r | (.id | test("^\\(")) as $synthetic
        | { id: (.id | gsub("^\\(|\\)$"; "")),
            repo: null,
            title: (.title | nz($r.id)),
            reason: ($r.reason | nz("")),
            dispatchable: (($synthetic | not) and ($r.blocked_by | nz("")) == "" and ($r.reason | nz("")) == ""),
            filed: (.filed // null) }
          + (if $synthetic then {} else {context: context_of($r)} end)
          + (if $synthetic then {kind: "warning"} else {kind: "queued"} end)
        | if .kind == "warning" then .dispatchable = false else . end
        | . as $row
        | . + overlay("charted"; $row.id; charted_fields)
        | if .kind == "warning" then .dispatchable = false else . end
        | if .filed == null then del(.filed) else . end ] ) as $gate_rows

  | ( ($snap.secondmate_reconcile // [])
      | map(select(.kind != null) | {key: .id, value: .}) | from_entries ) as $mismatch
  | ( [ ($snap.secondmates // [])[]
        | . as $m
        | ( if ($m.stale_note // null) != null then
              { id: ("stale-" + ($m.id | gsub("[()]"; ""))), repo: null,
                title: $m.stale_note,
                reason: (($m.read_failure // null) | nz("showing the last rows read")),
                dispatchable: false, kind: "warning" }
            else empty end ),
          ( if $mismatch[$m.id] != null then
            { id: ("reconcile-" + $m.id), repo: null,
              title: ($m.id + " books disagree with its task records"),
              reason: ($mismatch[$m.id].kind + ": " + (($mismatch[$m.id].ids // []) | join(", "))),
              dispatchable: false, kind: "warning" }
          elif $m.state == "unknown" then
            { id: ("unavailable-" + ($m.id | gsub("[()]"; ""))), repo: null,
              title: ($m.id + " state unavailable"),
              reason: ($m.reason | nz("state unknown")),
              dispatchable: false, kind: "warning" }
          else empty end )
        | . as $row | . + overlay("charted"; $row.id; charted_fields)
        | .dispatchable = false ] ) as $home_rows

  | ( [ $omitted[] | capture("^gates showing (?<n>[0-9]+) of (?<m>[0-9]+)$")? ]
      | (.[0] // null) ) as $gates_cut

  | ( [ $deferred[]
        | . as $d | ($d.owner // "(main)") as $o
        | { key: (($d.id // $d.key) | gsub("[^A-Za-z0-9._-]"; "-") | .[:128]),
            title: owner_title($o; (($d.title_full // $d.title // $d.summary // $d.key) | nz($d.key))),
            reason: ("until " + ((($d.hold_until // "") | tostring | .[:10]) | nz("a later date")) + ": "
                     + (($d.reason_full // $d.reason) | nz("deferred"))),
            repo: ([$in_flight[] | select(.id == $d.id or .id == $d.key) | .repo][0] // null),
            context: context_of($d) } ] ) as $deferred_waits

  | ($gate_rows + $home_rows) as $charted

  | def ranked($v): ($prio | index($v)) as $i | if $i == null then 1000000 else $i end;
    def by_priority(k): to_entries | sort_by([ranked(.value | k), .key]) | map(.value);
  { schema: "fm-bearings-board.v1",
      home: $snap.home,
      generated: $snap.generated,
      prs_live: (($snap.prs // "") | startswith("checked")),
      captains_call: ($captains_call | by_priority(.key)),
      underway: ($underway | by_priority(.id)),
      waiting: ($waiting + $deferred_waits + ($gate_waits | map(del(.owner_id)))),
      landed: $landed,
      charted: $charted }
    + (if $gates_cut != null then {charted_more: (($gates_cut.m | tonumber) - ($gates_cut.n | tonumber))} else {} end)
    + (if ($snap.open_mrs | type) == "array"
       then {open_mrs: [$snap.open_mrs[] | {key, repo, title, url, state}]} else {} end)
' || fail "could not build the payload"
