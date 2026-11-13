# shellcheck shell=bash
# Shared "is this a question or a wait, and what can the captain answer" rule.
# Usage: . bin/fm-bearings-question-lib.sh; splice "$FM_BEARINGS_QUESTION_JQ_DEFS"
# ahead of a jq program, then call `is_wait($row)`, `is_announcement($row)`,
# `default_options($row)` and `option_parse`.
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
# answered it with that park; otherwise a reason with a question mark or its
# own option list (option_parse) is a question, even when an option says
# "until" or "wait"; otherwise a hold_until or until date, a hold whose bucket is blocked
# (it waits on another task), a reason that opens with a time gate naming a date
# ("not before 2026-12-01", "revisit after ..."), or a reason that opens with
# parks, pauses, resumes, holds until, waits for or on, until, or re-runs is a
# wait. The keyword test is anchored to the start of the cleaned reason.
#
# is_announcement($row): a status row (source "status") that only announces a
# page, report, or PR/MR is live or ready ("review page live: <url>", "PR ready:
# <url>") and asks nothing - no question mark, no option list, no choose,
# pick, decide, or which. Such a row is not a decision; the board folds its
# link into the card for the same work and drops the row when no card exists.
#
# clean_reason: reason text as the captain reads it - every `corr=<hex>`
# correlation token and a leading "captain hold <id>: " label removed.
#
# option_parse: a reason that lists its own options, split into {lead, options,
# tail} - lead is the text before the first option, tail the text after the
# last, and each option is {value, label}. The forms, tried in order, are
# numbered "(1) ... (2) ..." and "1) ... 2) ...", lettered "(a) ... (b) ..." and
# "A) ... B) ..." (either case), and a slash list after "Options:", "Choices:"
# or "Decision:" ("Options: x / y / z."). Markers must run 1, 2, 3 or a, b, c
# from the first, at least two; the last option ends at its sentence end; a
# reason with no such list parses to null. Values are option-<n> or
# option-<letter>. A label is the full option text, never shortened, with URLs
# and a trailing "or"/"and" removed, then put in captain terms: a leading
# "firstmate posts it" becomes "Post it for me" and a leading "I post it" or
# "I will post it" becomes "The worker posts it" or "The worker will post it".
# A label that opens with a lowercase word followed by more words starts with a
# capital letter; a single word such as a tool name keeps its case.
#
# default_options($row): the choices a question card offers when no copy overlay
# authors its own, read from the cleaned reason and tried in order -
#   1. a review-ready row offers reviewed and later;
#   2. a reason that lists its own options (option_parse) offers exactly those;
#   3. an asking sentence that offers "A or B" becomes those two alternatives,
#      whatever word leads it ("Should pdm ship a module, or only document it?");
#   4. an asking sentence led by an auxiliary verb (should, do, can, is, ...)
#      with no alternatives becomes yes and no;
#   5. any other question offers no choices, so the card takes a free-text
#      answer rather than choices that do not fit it;
#   6. a reason with no question mark and no option list is a yes-or-no
#      go-ahead and becomes approve and decline.
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
  def choice_label:
    gsub("( (at|on|in|see|via))? ?https?://[^[:space:]]*[^[:space:].,;:!?]"; "")
    | gsub("[[:space:]]+"; " ")
    | sub("^ "; "") | sub("[[:space:]?.;,:]+$"; "")
    | sub("[.;,]?[[:space:]]+(or|and)$"; ""; "i") | sub("[[:space:]?.;,:]+$"; "");
  def cap: (.[:1] | ascii_upcase) + .[1:];
  def phrase_cap: if test("^[a-z]+ ") then cap else . end;
  def captain_terms:
    def stem: if test("(ch|sh|ss|x|z|o)es$") then .[:-2] elif test("[^aeiou]ies$") then .[:-3] + "y" elif test("s$") then .[:-1] else . end;
    def third: if test("(ch|sh|ss|x|z|o)$") then . + "es" elif test("[^aeiou]y$") then .[:-1] + "ies" else . + "s" end;
    if test("^(the )?first ?mate [a-z]+s([^a-z]|$)"; "i") then
      capture("^(the )?first ?mate (?<v>[a-z]+s)(?<rest>([^a-z].*)?)$"; "i")
      | (.v | ascii_downcase | stem | cap) + .rest + " for me"
    elif test("^I(\u0027ll| will| can| could| would| should| may| might)? [a-z]") then
      capture("^I(?<aux>(\u0027ll| will| can| could| would| should| may| might)?) (?<v>[a-z]+)(?<rest>.*)$")
      | if .aux == "" then "The worker " + (.v | third) + .rest
        else "The worker " + (.aux | sub("^\u0027ll$"; " will") | ltrimstr(" ")) + " " + .v + .rest end
    else . end;
  def option_parse:
    . as $q
    | def cut_last: ([match("[.!?](?=[[:space:]]+[A-Z])").offset][0]) as $o | if $o == null then . else .[:($o + 1)] end;
      def run($ms):
        reduce $ms[] as $m ([];
          if (length == 0 and $m.n == 1) or (length > 0 and $m.n == (.[-1].n + 1)) then . + [$m] else . end);
      def marks($re; $kind):
        [ $q | match($re; "g")
          | {offset, length, k: (.captures[0].string)}
          | . + {n: (if $kind == "number" then (.k | tonumber) else (.k | ascii_downcase | explode[0] - 96) end),
                 value: ("option-" + (if $kind == "number" then .k else (.k | ascii_downcase) end))} ];
      def from_marks($ms):
        run($ms) as $r
        | if ($r | length) < 2 then null
          else
            [ range(0; $r | length) as $i
              | $r[$i] as $m
              | ($m.offset + $m.length) as $s
              | if $i + 1 < ($r | length) then {value: $m.value, text: $q[$s:$r[$i + 1].offset], end: $r[$i + 1].offset}
                else ($q[$s:] | cut_last) as $t | {value: $m.value, text: $t, end: ($s + ($t | length))} end ] as $o
            | {lead: $q[:$r[0].offset], tail: $q[($o[-1].end):],
               options: [ $o[] | {value, label: (.text | choice_label | captain_terms | phrase_cap)} ]}
            | if all(.options[]; .label | length > 0) then . else null end
          end;
      def from_list:
        ([ $q | match("(?<![[:alnum:]])(?:[Oo]ptions|[Cc]hoices|[Dd]ecision)[[:space:]]*:[[:space:]]*"; "g") ][0]) as $m
        | if $m == null then null
          else $q[($m.offset + $m.length):] as $after
            | (([ $after | match("[.!?](?=[[:space:]]|$)").offset ][0]) // ($after | length)) as $e
            | [ $after[:$e] | split(" / ")[] | choice_label | captain_terms | phrase_cap ] as $items
            | if ($items | length) >= 2 and all($items[]; length > 0) then
                {lead: $q[:$m.offset], tail: $after[($e + 1):],
                 options: [ range(0; $items | length) as $i | {value: ("option-" + (($i + 1) | tostring)), label: $items[$i]} ]}
              else null end
          end;
      ( from_marks(marks("\\((?<k>[0-9]{1,2})\\)"; "number"))
        // from_marks(marks("(?<![^[:space:]:;,])(?<k>[0-9]{1,2})\\)"; "number"))
        // from_marks(marks("(?<![[:alnum:]])\\((?<k>[A-Za-z])\\)"; "letter"))
        // from_marks(marks("(?<![^[:space:]:;,])(?<k>[A-Za-z])\\)"; "letter"))
        // from_list );
  def asks: test("\\?") or (option_parse != null);
  def is_wait($d):
    (($d.reason_full // $d.reason // "") | clean_reason) as $r
    | if ($d.verb // "") == "review-ready" then false
      elif ($r | test("^[[:space:]]*((parked|deferred|paused|put on hold|on hold)[^.?!]*[^a-z]captain([^a-z]|$)|(the )?captain (has )?(parked|deferred|paused)[^a-z])"; "i")) then true
      elif ($r | asks) then false
      elif (($d.hold_until // $d.until // "") | tostring | length) > 0
           and (($d.hold_until // $d.until) != "-") then true
      elif ($d.hold_bucket // "") == "blocked" then true
      elif ($r | test("^[[:space:]]*(not before|no earlier than|on or after|revisit|check back|time[- ]gated?|after)([^a-z][^.?!]{0,40})?[0-9]{4}-[0-9]{2}-[0-9]{2}"; "i")) then true
      else ($r | test("^[[:space:]]*(parked|paused|on hold|held until|hold until|resume|resuming|waiting (for|on|until)|waits? (for|until|on)|until|re-?runs?)([^a-z]|$)"; "i")) end;
  def is_announcement($d):
    (($d.reason_full // $d.reason // "") | clean_reason) as $r
    | ($d.source // "") == "status"
      and ($r | asks | not)
      and ($r | test("(^|[^a-z])(choose|pick|decide|which)([^a-z]|$)"; "i") | not)
      and ($r | test("(^|[^a-z])(review|understand|lavish|report|pr|mr|pull request|merge request)( (page|board))?(( is| now| are))*[[:space:]]*(live|ready|up|posted)([^a-z]|$)"; "i"));
  def default_options($d):
    (($d.reason_full // $d.reason // $d.question // "") | clean_reason) as $q
    | ($q | option_parse) as $parsed
    | ($q | (split("?")[0] // "") | split(". ") | (last // "") | split(": ") | (last // "")
       | sub("^[[:space:]]+"; "")) as $sentence
    | ($sentence | (split(" ")[0] // "") | ascii_downcase | gsub("[^a-z]"; "")) as $first
    | [ $sentence | split(" or ")[] ] as $alts
    | if ($d.verb // "") == "review-ready" then
        [{value: "reviewed", label: "Reviewed, carry on"}, {value: "later", label: "Not yet, keep it on the board"}]
      elif $parsed != null then
        $parsed.options
      elif ($q | test("\\?")) and ($alts | length) == 2 and ($sentence | length) <= 160
           and all($alts[]; choice_label | length > 0) then
        [ range(0; 2) as $i
          | {value: ("option-" + (($i + 1) | tostring)),
             label: ($alts[$i] | choice_label | captain_terms | cap)} ]
      elif ($first | IN("should","shall","do","does","did","can","could","is","are","was","were","will","would","may","might","must","has","have","had","ok","okay","want","need"))
           and ($q | test("\\?")) and ($alts | length) == 1 then
        [{value: "yes", label: "Yes"}, {value: "no", label: "No"}]
      elif ($q | test("\\?")) then
        []
      else
        [{value: "approve", label: "Approve / go ahead"}, {value: "decline", label: "Decline"}]
      end;
'
