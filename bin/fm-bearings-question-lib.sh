# shellcheck shell=bash
# Shared "is this a question or a wait, and what can the captain answer" rule.
# Usage: . bin/fm-bearings-question-lib.sh; splice "$FM_BEARINGS_QUESTION_JQ_DEFS"
# ahead of a jq program, then call `is_wait($row)`, `is_announcement($row)`
# and `default_options($row)`.
#
# ONE OWNER for the board's question rules. The bearings snapshot decides which
# non-live holds still reach the board as questions, and the board payload
# decides which rows are cards versus waiting rows and what choices a card
# offers. Both read the same reason text, so the wait test and the default
# choices live here and neither program restates them.
#
# is_wait($row): a reason whose first sentence records that the captain parked,
# deferred, or paused it ("Parked by the captain on <date> ...") is a wait even
# when it also carries the question to ask later, because the captain already
# answered it with that park; otherwise a reason with a question mark or
# numbered options "(1) ... (2) ..." is a question, even when an option says
# "until" or "wait"; otherwise a hold_until or until date, a hold whose bucket is blocked
# (it waits on another task), a reason that opens with a time gate naming a date
# ("not before 2026-12-01", "revisit after ..."), or a reason that opens with
# parks, pauses, resumes, holds until, waits for or on, until, or re-runs is a
# wait. The keyword test is anchored to the start of the cleaned reason.
#
# is_announcement($row): a status row (source "status") that only announces a
# page, report, or PR/MR is live or ready ("review page live: <url>", "PR ready:
# <url>") and asks nothing - no question mark, no numbered options, no choose,
# pick, decide, or which. Such a row is not a decision; the board folds its
# link into the card for the same work and drops the row when no card exists.
#
# clean_reason: reason text as the captain reads it - every `corr=<hex>`
# correlation token and a leading "captain hold <id>: " label removed.
#
# default_options($row): the choices a question card offers when no copy overlay
# authors its own, read from the cleaned reason and tried in order -
#   1. numbered sub-questions "(1) ... (2) ..." become one choice each
#      (values option-1, option-2, ...), and lettered ones "(a) ... (b) ..."
#      likewise (values option-a, option-b, ...);
#   2. an asking sentence that offers "A or B" becomes those two alternatives,
#      whatever word leads it ("Should pdm ship a module, or only document it?");
#   3. an asking sentence led by an auxiliary verb (should, do, can, is, ...)
#      with no alternatives becomes yes and no;
#   4. any other question offers no choices, so the card takes a free-text
#      answer rather than choices that do not fit it;
#   5. a reason with no question mark becomes approve and decline.
# The asking sentence is the last sentence before the first question mark.
# The board's `build` appends the standard reconcile choice after these, and a
# payload never authors it.
# shellcheck disable=SC2016  # jq program text, not shell expansion
FM_BEARINGS_QUESTION_JQ_DEFS='
  def clean_reason:
    tostring
    | gsub("(?<![^[:space:]])corr=[0-9a-f]+(?:[[:space:]]+|$)"; "")
    | sub("^[[:space:]]+"; "")
    | sub("^captain hold [^:]+: "; "");
  def is_wait($d):
    (($d.reason_full // $d.reason // "") | clean_reason) as $r
    | if ($d.verb // "") == "review-ready" then false
      elif ($r | test("^[[:space:]]*((parked|deferred|paused|put on hold|on hold)[^.?!]*[^a-z]captain([^a-z]|$)|(the )?captain (has )?(parked|deferred|paused)[^a-z])"; "i")) then true
      elif ($r | test("\\?|\\([0-9]+\\)")) then false
      elif (($d.hold_until // $d.until // "") | tostring | length) > 0
           and (($d.hold_until // $d.until) != "-") then true
      elif ($d.hold_bucket // "") == "blocked" then true
      elif ($r | test("^[[:space:]]*(not before|no earlier than|on or after|revisit|check back|time[- ]gated?|after)([^a-z][^.?!]{0,40})?[0-9]{4}-[0-9]{2}-[0-9]{2}"; "i")) then true
      else ($r | test("^[[:space:]]*(parked|paused|on hold|held until|hold until|resume|resuming|waiting (for|on|until)|waits? (for|until|on)|until|re-?runs?)([^a-z]|$)"; "i")) end;
  def is_announcement($d):
    (($d.reason_full // $d.reason // "") | clean_reason) as $r
    | ($d.source // "") == "status"
      and ($r | test("\\?|\\([0-9]+\\)") | not)
      and ($r | test("(^|[^a-z])(choose|pick|decide|which)([^a-z]|$)"; "i") | not)
      and ($r | test("(^|[^a-z])(review|understand|lavish|report|pr|mr|pull request|merge request)( (page|board))?(( is| now| are))*[[:space:]]*(live|ready|up|posted)([^a-z]|$)"; "i"));
  def choice_label:
    sub("^[[:space:]]+"; "") | sub("[[:space:]?.;,:]+$"; "")
    | (if length > 90 then .[:87] + "..." else . end);
  def default_options($d):
    (($d.reason_full // $d.reason // $d.question // "") | clean_reason) as $q
    | ([ $q | scan("\\([0-9]+\\)[[:space:]]*(.+?)(?=[[:space:]]*\\([0-9]+\\)|$)") | .[0] | choice_label
         | select(length > 0) ]) as $numbered
    | ([ $q | scan("(?<![[:alnum:]])\\(([a-z])\\)[[:space:]]*(.+?)(?=[[:space:]]*\\([a-z]\\)|$)")
         | {letter: .[0], label: (.[1] | choice_label)} ]) as $lettered
    | ($q | (split("?")[0] // "") | split(". ") | (last // "") | split(": ") | (last // "")
       | sub("^[[:space:]]+"; "")) as $sentence
    | ($sentence | (split(" ")[0] // "") | ascii_downcase | gsub("[^a-z]"; "")) as $first
    | [ $sentence | split(" or ")[] ] as $alts
    | if ($d.verb // "") == "review-ready" then
        [{value: "reviewed", label: "Reviewed, carry on"}, {value: "later", label: "Not yet, keep it on the board"}]
      elif ($numbered | length) >= 2 then
        [ range(0; $numbered | length) as $i
          | {value: ("option-" + (($i + 1) | tostring)), label: $numbered[$i]} ]
      elif ($lettered | length) >= 2
           and ($lettered | map(.letter)) == ([range(0; $lettered | length)] | map([97 + .] | implode))
           and all($lettered[]; (.label | length) > 0) then
        [ $lettered[] | {value: ("option-" + .letter), label: .label} ]
      elif ($q | test("\\?")) and ($alts | length) == 2 and ($sentence | length) <= 160
           and all($alts[]; choice_label | length > 0) then
        [ range(0; 2) as $i
          | {value: ("option-" + (($i + 1) | tostring)),
             label: ($alts[$i] | choice_label | (.[:1] | ascii_upcase) + .[1:])} ]
      elif ($first | IN("should","shall","do","does","did","can","could","is","are","was","were","will","would","may","might","must","has","have","had","ok","okay","want","need"))
           and ($q | test("\\?")) and ($alts | length) == 1 then
        [{value: "yes", label: "Yes"}, {value: "no", label: "No"}]
      elif ($q | test("\\?")) then
        []
      else
        [{value: "approve", label: "Approve / go ahead"}, {value: "decline", label: "Decline"}]
      end;
'
