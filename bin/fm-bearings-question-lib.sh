# shellcheck shell=bash
# Shared "is this a question or a wait, and what can the captain answer" rule.
# Usage: . bin/fm-bearings-question-lib.sh; splice "$FM_BEARINGS_QUESTION_JQ_DEFS"
# ahead of a jq program, then call `is_wait($row)` and `default_options($row)`.
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
# answered it with that park; otherwise a reason with a question mark is a
# question; otherwise a hold_until or until date, or a reason that parks, pauses,
# resumes, holds until, waits for or on, or says until or re-runs, is a wait.
#
# default_options($row): the choices a question card offers when no copy overlay
# authors its own, tried in order -
#   1. numbered sub-questions "(1) ... (2) ..." become one choice each
#      (values option-1, option-2, ...);
#   2. a question not led by an auxiliary verb that offers "A or B" becomes
#      those two alternatives;
#   3. a question led by an auxiliary verb (should, do, can, is, ...) becomes
#      yes and no;
#   4. anything else becomes approve and decline.
# The board's `build` appends the standard reconcile choice after these, and a
# payload never authors it.
# shellcheck disable=SC2016  # jq program text, not shell expansion
FM_BEARINGS_QUESTION_JQ_DEFS='
  def is_wait($d):
    (($d.reason_full // $d.reason // "") | tostring) as $r
    | if ($d.verb // "") == "review-ready" then false
      elif ($r | test("^[[:space:]]*((parked|deferred|paused|put on hold|on hold)[^.?!]*[^a-z]captain([^a-z]|$)|(the )?captain (has )?(parked|deferred|paused)[^a-z])"; "i")) then true
      elif ($r | test("\\?")) then false
      elif (($d.hold_until // $d.until // "") | tostring | length) > 0
           and (($d.hold_until // $d.until) != "-") then true
      else ($r | test("(^|[^a-z])(parked|paused|on hold|held until|hold until|resume|resuming|waiting (for|on)|wait (for|until|on)|until|re-?runs?)([^a-z]|$)"; "i")) end;
  def choice_label:
    sub("^[[:space:]]+"; "") | sub("[[:space:]?.;,:]+$"; "")
    | (if length > 90 then .[:87] + "..." else . end);
  def default_options($d):
    (($d.reason_full // $d.reason // $d.question // "") | tostring) as $q
    | ([ $q | scan("\\([0-9]+\\)[[:space:]]*(.+?)(?=[[:space:]]*\\([0-9]+\\)|$)") | .[0] | choice_label
         | select(length > 0) ]) as $numbered
    | ($q | sub("^[[:space:]]+"; "") | (split(" ")[0] // "") | ascii_downcase | gsub("[^a-z]"; "")) as $first
    | (($q | (split("?")[0] // "") | split(". ") | (last // "") | split(": ") | (last // "")) as $sentence
       | [ $sentence | split(" or ")[] ]) as $alts
    | if ($d.verb // "") == "review-ready" then
        [{value: "reviewed", label: "Reviewed, carry on"}, {value: "later", label: "Not yet, keep it on the board"}]
      elif ($numbered | length) >= 2 then
        [ range(0; $numbered | length) as $i
          | {value: ("option-" + (($i + 1) | tostring)), label: $numbered[$i]} ]
      elif ($first | IN("should","shall","do","does","did","can","could","is","are","was","were","will","would","may","might","must","has","have","had","ok","okay","want","need"))
           and ($q | test("\\?")) then
        [{value: "yes", label: "Yes"}, {value: "no", label: "No"}]
      elif ($q | test("\\?")) and ($alts | length) == 2 and ($q | length) <= 160 then
        [ range(0; 2) as $i
          | {value: ("option-" + (($i + 1) | tostring)),
             label: ($alts[$i] | choice_label | (.[:1] | ascii_upcase) + .[1:])} ]
      else
        [{value: "approve", label: "Approve / go ahead"}, {value: "decline", label: "Decline"}]
      end;
'
