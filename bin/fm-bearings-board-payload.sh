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
# `fm-bearings-snapshot.sh --json --all-decisions` itself (--include-prs is passed
# through), so every open captain hold - live, blocked, dated, or aged, past the
# snapshot's decision cap - yields exactly one card or waiting row and none is
# charted as a gate; with --snapshot it reads that JSON from the file or stdin instead.
#
# Mapping (snapshot field -> board section):
#   decisions_open  -> captains_call: one `decision` card per captain-held task id,
#                      titled from the row's full `title_full` (else `title`), `about` from
#                      its full `reason_full` (else `reason`),
#                      `pr_url` and `repo` from the PR the task recorded, and a
#                      derived default choices (bin/fm-bearings-question-lib.sh: yes/no,
#                      numbered or lettered parts, two-way or, else approve/decline; an authored
#                      overlay `options` still wins) with reconcile secondary, and any
#                      https URLs (and the tailnet review-page origin) in the reason lifted into the card `links`. Every
#                      open captain hold is a row here (see --all-decisions above).
#                      A hold whose reason is a wait or park rather than a question moves
#                      to `waiting` instead (see below). Each remaining card leads with
#                      one short `question` (at most 120 characters): the reason's
#                      sentence led by "Question:", else its first sentence ending in
#                      "?", else its first sentence, dropped when it only repeats the
#                      title. Every reason shown has its `corr=<hex>` tokens removed
#                      (clean_reason in bin/fm-bearings-question-lib.sh).
#                      A `source:"status"` row is titled from its decision, never the
#                      asking home: the task its decision key names, else a given title
#                      that is not just the task or home, else that same asking
#                      sentence, prefixed `<home>: ` for a secondmate. A status row whose
#                      decision key names a captain-held task in the same home is the
#                      same question: it adds no card or waiting row of its own, and an
#                      asked hold card merges its text into `about` and its
#                      choices into `options`, so no answer choice is lost.
#   contributions.captain
#                   -> captains_call: one link-only `decision` card (key
#                      `contribution.<task>`, `pr_url` the contribution's page) for
#                      each row waiting on the captain with no hold of its own, so
#                      Captain's Call also shows what firstmate never held. A row
#                      whose hold already has a card, or whose PR a card already
#                      carries, adds none.
#   waiting         -> waiting: a captain-held task whose reason is a wait or park on a
#                      condition or date, with nothing for the captain to answer. The rule:
#                      a reason whose first sentence records that the captain parked,
#                      deferred, or paused it is a wait; else a reason with a question
#                      mark is a question; otherwise a reason that
#                      opens with or contains park/paused/on hold/hold until/resume/
#                      waiting for|on/until/re-runs is a wait; a hold carrying an `until`
#                      date is a wait; anything else is a question. Waiting rows keep
#                      snapshot order and are not part of the priority list.
#   in_flight       -> underway: every row except state `done`, in snapshot order,
#                      with the projected `name`.
#   landed          -> landed: every row; `pr_url` and `repo` come from the
#                      artifact or recorded PR when it is one.
#   gates           -> charted: one row per gate; `(main-inventory)` and
#                      `(return-catchup)` become warning rows (kind warning, never
#                      dispatchable), and a gate with neither blocker nor hold
#                      reason is the only dispatchable row.
#   secondmates, secondmate_reconcile
#                   -> charted warning rows for a home whose books disagree
#                      (`reconcile-<id>`) or whose state is unavailable
#                      (`unavailable-<id>`).
#   priority        -> the order of captains_call (by card key) and underway (by id):
#                      bin/fm-board-priority.sh holds the captain's ranking, ranked rows
#                      come first in that order, and unranked rows keep snapshot order after.
#   omitted         -> charted_more, from the `gates showing N of M` surface.
#
# Copy overlay (--copy): a JSON object whose optional maps are keyed by the row
# key or id they refine, so a missing entry leaves the deterministic default.
#   captains_call  {"<key>": {title, question, about, decide, detail, options, recommend_value,
#                   type, close, risk, pr_url, links, subject, freeform_hint,
#                   allow_freeform, repo} | null}   (null drops the card)
#   captains_call_extra  [<call item>, ...]   merge, credential, and any other card
#                   waiting on the captain that firstmate did not hold, appended
#   underway       {"<id>": {repo}}
#   landed         {"<id>": {repo, pr_url, subject}}
#   charted        {"<id>": {title, reason, repo, dispatchable, filed}}
# An unknown map or field is refused, so the payload shape cannot drift through
# the overlay. An entry whose key matches no row is reported on stderr and ignored.
# A card's `links` is an array of up to 8 `{url, label}` pointers (https, or http on
# the tailnet Lavish origin the board contract names); `bin/fm-bearings-board.sh`
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
  if [ "$INCLUDE_PRS" = 1 ]; then
    SNAP_JSON=$("$SCRIPT_DIR/fm-bearings-snapshot.sh" --json --all-decisions --include-prs) || fail "snapshot failed"
  else
    SNAP_JSON=$("$SCRIPT_DIR/fm-bearings-snapshot.sh" --json --all-decisions) || fail "snapshot failed"
  fi
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
                    "risk","pr_url","links","subject","freeform_hint","allow_freeform","repo","question"],
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

jq -n --argjson snap "$SNAP_JSON" --argjson copy "$COPY_JSON" --argjson prio "$PRIO_JSON" --arg today "$(date -u +%Y-%m-%d)" "$FM_BEARINGS_QUESTION_JQ_DEFS"'
  def card_fields: ["title","about","decide","detail","options","recommend_value","type","close",
                    "risk","pr_url","links","subject","freeform_hint","allow_freeform","repo","question"];
  def underway_fields: ["repo"];
  def landed_fields: ["repo","pr_url","subject"];
  def charted_fields: ["title","reason","repo","dispatchable","filed"];

  def https_url: type == "string" and test("^https://[^[:space:]]+$");
  def repo_of_url:
    if https_url | not then null
    elif test("^https://[^/]+/[^/]+/[^/]+/(pull|issues)/") then
      capture("^https://[^/]+/[^/]+/(?<r>[^/]+)/(pull|issues)/").r
    elif test("^https://[^/]+/.+/[^/]+/-/") then
      capture("^https://[^/]+/.+/(?<r>[^/]+)/-/").r
    else null end;
  def nz($d): if . == null or . == "" or . == "-" then $d else . end;
  def pr_for($id; $contrib; $recorded):
    ( ([$contrib[] | select(.task == $id) | .url][0])
      // ([$recorded[] | select(.id == $id) | .url][0]) ) as $u
    | if ($u | https_url) then $u else null end;
  def overlay($section; $id; $allowed):
    (($copy[$section] // {})[$id] // {}) | with_entries(select(.key as $k | $allowed | index($k)));

  ($snap.contributions.captain // []) as $contrib
  | ($snap.recorded_prs // []) as $recorded
  | ($snap.in_flight // []) as $in_flight
  | ($snap.landed // []) as $landed_rows
  | (($snap.omitted // []) | map(.surface)) as $omitted

  | def released($d):
      ( ((if $d | has("held") then $d.held else "yes" end) | tostring | ascii_downcase)
        | (. == "no" or . == "false") )
      or ( (($d.hold_until // "") | tostring) as $u
           | ($u | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")) and (($u[:10]) <= $today) );
    ( [ $snap.decisions_open[]? | select(released(.) | not) ]
      | reduce .[] as $d ([]; if (map(.key) | index($d.key)) then . else . + [$d] end) ) as $held
  # A status decision row (source "status") carries the asking task or home as its
  # title; the card title says what the question is instead.
  | def short_text_n($n):
      tostring | gsub("[[:space:]]+"; " ") | sub("^ "; "")
      | ([match("^.*?[.?!](?=[[:space:]]|$)").string][0] // .)
      | gsub("( (at|on|in|see|via))? ?https?://[^[:space:]]*[^[:space:].,;:!?]"; "")
      | sub("[[:space:]]*[.,;:]$"; "")
      | if length > $n then (.[:($n - 1)] | sub(" [^ ]*$"; "")) + "…" else . end;
    def short_text: short_text_n(80);
    # The sentence that asks: one led by "Question:" (prefix dropped), else the
    # first ending in "?", else the first sentence.
    def ask_sentence:
      clean_reason | gsub("[[:space:]]+"; " ") | sub("^ "; "")
      | [ scan("[^[:space:]].*?(?:[.?!](?=[[:space:]]|$)|$)") ] as $s
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
          // ((($d.reason_full // $d.reason // "") | ask_sentence | short_text) | nz(null))
          // (if $k != "default" then $k else $d.key end) ) as $t
      | if $owner != "(main)" and ($t | startswith($owner + ": ") | not) then $owner + ": " + $t else $t end;
    [ $held[] | if (.source // "") == "status" then .title_full = status_title(.) else . end ] as $held
  | ( [ $held[] | select(is_wait(.) | not) ] ) as $asked
  # One question, one card: a status decision whose key names a captain-held
  # task in the same home is the same question, so it folds into that hold card
  # with its text and choices. A hold that is a wait absorbs nothing, so a
  # status question about a parked task still shows.
  | def same_question($s; $h):
      ($s.source // "") == "status" and ($h.verb // "") == "captain-hold"
      and (($s.decision_key // "default") != "default")
      and (($s.owner // "(main)") == ($h.owner // "(main)"))
      and ($h.key == $s.decision_key or (($h.id // "") | split("/") | last) == $s.decision_key);
    ( [ $asked[] | select((.verb // "") == "captain-hold") ] ) as $asked_holds
  | ( [ $held[] | select(. as $r | any($asked_holds[]; same_question($r; .))) | .key ] ) as $folded
  | ( [ $asked[] | . as $r
        | if ($folded | index([$r.key])) then empty
          elif ($r.verb // "") == "captain-hold" then
            . + {twins: [ $held[] | select(same_question(.; $r)) ]}
          else . end ] ) as $question_rows
  | ( [ $held[] | select(is_wait(.)) | select(.key as $k | $folded | index([$k]) | not)
        | . as $d
        | { key: $d.key,
            title: (($d.title_full // $d.title // $d.summary // $d.key) | nz($d.key)),
            reason: (($d.reason_full // $d.reason) | nz(null) | if . == null then "waiting" else (clean_reason | nz("waiting")) end),
            repo: ([$in_flight[] | select(.id == $d.id or .id == $d.key) | .repo][0] // null) } ] ) as $waiting
  | ( $question_rows
      | map(
          . as $d
          | pr_for($d.id; $contrib; $recorded) as $pr
          | ( {
              key: $d.key,
              type: "decision",
              repo: ( ($pr | repo_of_url)
                      // ([$in_flight[] | select(.id == $d.id or .id == $d.key) | .repo][0])
                      // null ),
              title: (($d.title_full // $d.title // $d.summary // $d.key) | nz($d.key)),
              options: ( [ default_options($d)[], ($d.twins // [])[] as $tw | default_options($tw)[] ]
                         | reduce .[] as $o ([];
                             if any(.[]; (.label | ascii_downcase) == ($o.label | ascii_downcase)) then .
                             elif any(.[]; .value == $o.value) then . + [$o + {value: ($o.value + "-" + ((length + 1) | tostring))}]
                             else . + [$o] end) ),
              allow_freeform: true,
              freeform_hint: "answer in your own words (say later to defer)"
            }
            # The heading is one short asking sentence; the full cleaned text
            # (with the text of any folded twin) is the body, and a heading that only
            # repeats the title is dropped so the title leads instead.
            + ( [ ($d.reason_full // $d.reason), (($d.twins // [])[] | (.reason_full // .reason)) ]
                | map(nz(null) | select(. != null) | clean_reason | nz(null) | select(. != null))
                | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end) as $texts
                | (($d.title_full // $d.title // $d.summary // $d.key) | nz($d.key) | tostring) as $title
                | (($texts | max_by(length)) // null) as $long
                | (if $long == null then null else ($long | ask_sentence | short_text_n(120) | nz(null)) end) as $q
                | (if $q != null and $title != $q and ($title | endswith(": " + $q) | not)
                   then {question: $q} else {} end)
                  + (if ($texts | length) > 0 and ($texts | join("\n\n")) != $q
                     then {about: ($texts | join("\n\n"))} else {} end) )
            + (if $pr != null then {pr_url: $pr} else {} end)
            + ( [ (([($d.reason_full // $d.reason // ""), (($d.twins // [])[] | (.reason_full // .reason // ""))] | map(tostring) | join(" ")) | scan("(?:https://|http://dev-1\\.tailf848b0\\.ts\\.net:4387)[^[:space:]<>\"()]*") )
                  | sub("[.,;:!?]+$"; "") ] | unique | .[:5]
                | if length > 0 then {links: map({url: ., label: (sub("^https?://"; "") | .[:60])})} else {} end ) )
          + overlay("captains_call"; $d.key; card_fields)
          | . as $card
          | select((($copy.captains_call // {}) | has($d.key) | not)
                   or ($copy.captains_call[$d.key] != null))
          | $card )
    ) as $cards
  | ( [ $contrib[]
        | select((.hold // null) == null and (.url | https_url) and (.task | type == "string"))
        | . as $c
        | select(($cards | any(.key == $c.task or .pr_url? == $c.url)) | not)
        | { key: ("contribution." + (.task | gsub("[^A-Za-z0-9._-]"; "-"))),
            type: "decision",
            repo: (.url | repo_of_url),
            title: ((.url | repo_of_url | nz("")) as $r
                    | (if $r == "" then $c.task else $r + " #" + ($c.url | split("/") | last) end)),
            about: ($c.reason | nz("waiting on the captain")),
            pr_url: .url,
            options: [], allow_freeform: true,
            freeform_hint: "answer in your own words (say later to defer)" }
        | . as $card
        | select((($copy.captains_call // {}) | has($card.key) | not)
                 or ($copy.captains_call[$card.key] != null)) ]
      | reduce .[] as $d ([]; if (map(.key) | index($d.key)) then . else . + [$d] end)
      | map(. + overlay("captains_call"; .key; card_fields)) ) as $contrib_cards
  | ($cards + $contrib_cards + ($copy.captains_call_extra // [])) as $captains_call

  | ( [ $in_flight[] | select(.state != "done") | . as $r
        | { id, name: (.name | nz($r.id)), repo: (.repo // null),
            state: (.state | nz("unknown")), doing: (.doing | nz("-")),
            kind: (.kind | nz("task")) }
          + overlay("underway"; .id; underway_fields) ] ) as $underway

  | ( [ $landed_rows[]
        | . as $r
        | (if (.artifact | https_url) then .artifact else pr_for(.id; $contrib; $recorded) end) as $pr
        | { id, repo: ($pr | repo_of_url), what: (.what | nz($r.id)), owner: (.owner | nz("(main)")) }
          + (if $pr != null then {pr_url: $pr} else {} end)
          + overlay("landed"; .id; landed_fields) ] ) as $landed

  | ( [ $snap.gates[]?
        | . as $r | (.id | test("^\\(")) as $synthetic
        | { id: (.id | gsub("^\\(|\\)$"; "")),
            repo: null,
            title: (.title | nz($r.id)),
            reason: ($r.reason | nz("")),
            dispatchable: (($synthetic | not) and ($r.blocked_by | nz("")) == "" and ($r.reason | nz("")) == ""),
            filed: (.filed // null) }
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
        | if $mismatch[$m.id] != null then
            { id: ("reconcile-" + $m.id), repo: null,
              title: ($m.id + " books disagree with its task records"),
              reason: ($mismatch[$m.id].kind + ": " + (($mismatch[$m.id].ids // []) | join(", "))),
              dispatchable: false, kind: "warning" }
          elif $m.state == "unknown" then
            { id: ("unavailable-" + ($m.id | gsub("[()]"; ""))), repo: null,
              title: ($m.id + " state unavailable"),
              reason: ($m.reason | nz("state unknown")),
              dispatchable: false, kind: "warning" }
          else empty end
        | . as $row | . + overlay("charted"; $row.id; charted_fields)
        | .dispatchable = false ] ) as $home_rows

  | ( [ $omitted[] | capture("^gates showing (?<n>[0-9]+) of (?<m>[0-9]+)$")? ]
      | (.[0] // null) ) as $gates_cut

  | ($gate_rows + $home_rows) as $charted

  | def ranked($v): ($prio | index($v)) as $i | if $i == null then 1000000 else $i end;
    def by_priority(k): to_entries | sort_by([ranked(.value | k), .key]) | map(.value);
  { schema: "fm-bearings-board.v1",
      home: $snap.home,
      generated: $snap.generated,
      prs_live: (($snap.prs // "") | startswith("checked")),
      captains_call: ($captains_call | by_priority(.key)),
      underway: ($underway | by_priority(.id)),
      waiting: $waiting,
      landed: $landed,
      charted: $charted }
    + (if $gates_cut != null then {charted_more: (($gates_cut.m | tonumber) - ($gates_cut.n | tonumber))} else {} end)
' || fail "could not build the payload"
