# shellcheck shell=bash
# Shared "is this a question or a wait, and what can the captain answer" rule.
# Usage: . bin/fm-bearings-question-lib.sh; splice "$FM_BEARINGS_QUESTION_JQ_DEFS"
# ahead of a jq program, then call `is_wait($row)`, `is_announcement($row)`,
# `is_review($row)`, `is_merge_ask($row)`, `default_options($row)`, `option_parse` and
# `recover_options`.
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
# answered it with that park; a reason that says it is "not a captain
# decision" (or "not a decision for the captain") is a wait wherever it says
# so; otherwise a reason with a question mark or its
# own option list (option_parse) is a question, even when an option says
# "until" or "wait"; otherwise a hold_until or until date, a hold whose bucket is blocked
# (it waits on another task), a reason that opens with a time gate naming a date
# ("not before 2026-12-01", "revisit after ..."), or a reason that opens with
# parks, pauses, freezes or frozen, resumes, holds until, waits for or on,
# until, or re-runs is a wait. The keyword test is anchored to the start of the
# cleaned reason.
#
# is_announcement($row): a status row (source "status") that only announces a
# page, report, or PR/MR is live or ready ("review page live: <url>", "PR ready:
# <url>") and asks nothing - no question mark, no option list, no choose,
# pick, decide, or which. Such a row is not a decision; the board folds its
# link into the card for the same work and drops the row when no card exists.
#
# is_review($row): a row that asks the captain to review a PR/MR rather than to
# decide about it - a review-ready row, a review-page row, or a reason that names
# a "review page" or asks to review or re-review the PR, MR, merge request, or
# pull request. The captain's own approval of every PR/MR such a row names
# settles it (bin/fm-bearings-board-payload.sh).
#
# is_merge_ask($row): a row whose question is whether to merge its PRs/MRs, so
# their merge or close settles it (bin/fm-bearings-board-payload.sh). It is a
# review row (is_review); an asking sentence that says merge, or approve with a
# PR, MR, pull request, merge request, or pulls/merge_requests URL; a reason
# with no question mark that opens a sentence with merge (as is_action reads
# it); or a recorded or listed option whose label opens with merge. Any other
# question - apply, delete, or deploy after the merge - is not a merge ask,
# whatever its links say.
#
# clean_reason: reason text as the captain reads it - every `corr=<hex>`
# correlation token and a leading "captain hold <id>: " label removed.
#
# option_parse: a reason that lists its own options, split into {lead, options,
# tail} - lead is the text before the first option, tail the text after the
# last, and each option is {value, label}. The forms, tried in order, are
# numbered "(1) ... (2) ..." and "1) ... 2) ...", lettered "(a) ... (b) ..." and
# "A) ... B) ..." (either case) and "A = ...; B = ..." (capitals only), and a
# slash list after "Options:", "Choices:" or "Decision:" ("Options: x / y /
# z."). A parenthesised mark may carry its own recommendation ("(a,
# recommended) ...", "(2; rec) ..."), and an "A = " mark may follow one
# ("rec A = ...", "recommended B = ..."): that option's value is then the
# parse's `recommend`. Markers must run 1, 2, 3 or a, b, c
# from the first, at least two; the last option ends at its sentence end; a
# reason with no such list parses to null. Values are option-<n> or
# option-<letter>. A label is the full option text, never shortened, with URLs
# and a trailing "or"/"and" removed, then put in captain terms: a leading
# "firstmate posts it" becomes "Post it for me" and a leading "I post it" or
# "I will post it" becomes "The worker posts it" or "The worker will post it".
# A label that opens with a lowercase word (hyphens allowed, as in "dry-run")
# followed by more words starts with a capital letter; a single word such as a
# tool name keeps its case.
#
# option_parse_by($kind): option_parse limited to one kind - "number",
# "letter" or "list" - so a reason holding a numbered list and a lettered one
# yields either.
#
# option_refs: the option marks a reason refers to by name, whether or not it
# lists them - a slash run "A/B/C" (numbers only from three, "1/2/3"), "A, B
# or C", or "option 2" / "options A-C" / "options 1 and 3". Letter and number
# runs must start at A or 1 and count up; "A/B test" is not a reference.
#
# recover_options($now; $before): on a card, adds each option its current
# texts ($now) refer to but its choices lack, taken from the first listing of
# that kind in $now, else in its earlier texts ($before, newest first). A
# taken-over label starts with its mark ("A) ..."), and one from an earlier
# text carries a hint saying so. When no text lists them, the card gains
# `malformed`, a sentence naming the options it refers to but does not list,
# and no button stands in for them.
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
#   6. a reason with no question mark and no option list that asks the
#      captain to do the thing in person (is_action: a sentence that opens with
#      dismiss, merge, run, re-run, log in, sign in or re-authenticate,
#      optionally after "please" or "captain, ...") offers done and not done,
#      the not-done choice asking for the reason in the answer box;
#   7. any other reason with no question mark and no option list is a
#      yes-or-no go-ahead and becomes approve and decline.
# The done and not-done values are the captain's report, recorded as the
# answer text; neither sets a close mode, so neither reads as a release.
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
  def phrase_cap: if test("^[a-z][a-z-]* ") then cap else . end;
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
  def option_parse_by($kind):
    . as $q
    | def cut_last: ([match("[.!?](?=[[:space:]]+[A-Z])").offset][0]) as $o | if $o == null then . else .[:($o + 1)] end;
      def run($ms):
        reduce $ms[] as $m ([];
          if (length == 0 and $m.n == 1) or (length > 0 and $m.n == (.[-1].n + 1)) then . + [$m] else . end);
      def marks($re; $kind):
        [ $q | match($re; "g")
          | (.captures | map({(.name): .string}) | add) as $c
          | {offset, length, k: $c.k, rec: ($c.r != null)}
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
            + ([ $r[] | select(.rec) | .value ][0] | if . == null then {} else {recommend: .} end)
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
      "(?<r>(?:,|;|:|[[:space:]]+-)[[:space:]]*(?:recommended|recommendation|rec|preferred)(?![[:alnum:]])[^()]{0,30})?" as $rec
      | if $kind == "number" then
        from_marks(marks("\\((?<k>[0-9]{1,2})" + $rec + "\\)"; "number"))
        // from_marks(marks("(?<![^[:space:]:;,])(?<k>[0-9]{1,2})\\)"; "number"))
      elif $kind == "letter" then
        from_marks(marks("(?<![[:alnum:]])\\((?<k>[A-Za-z])" + $rec + "\\)"; "letter"))
        // from_marks(marks("(?<![^[:space:]:;,])(?<k>[A-Za-z])\\)"; "letter"))
        // from_marks(marks("(?:(?<![[:alnum:]])(?<r>recommended|rec|preferred)[[:space:]]+)?(?<![^[:space:]:;,(])(?<k>[A-Z])[[:space:]]?=[[:space:]]"; "letter"))
      else from_list end;
  def option_parse: option_parse_by("number") // option_parse_by("letter") // option_parse_by("list");
  def option_mark_value: "option-" + (if test("^[0-9]") then . else ascii_downcase end);
  def option_refs:
    . as $q
    | def kind: if test("^[0-9]+$") then "number" else "letter" end;
      def n: if kind == "number" then tonumber else (explode[0] - 64) end;
      def run_ok: length >= 2 and (map(kind) | unique | length) == 1
        and ([range(1; length + 1)] == map(n));
      def spread:
        if length == 2 and (.[0] | kind) == (.[1] | kind) and (.[0] | n) < (.[1] | n) then
          (.[0] | kind) as $k | (.[0] | n) as $a | (.[1] | n) as $b
          | [ range($a; $b + 1) | if $k == "number" then tostring else ([. + 64] | implode) end ]
        else . end;
      [ ( $q | match("(?<![[:alnum:]/])(?:[A-Z]|[1-9])(?:/(?:[A-Z]|[0-9]{1,2}))+(?![[:alnum:]/])(?![[:space:]]?test)"; "g")
          | .string | split("/") | select(run_ok and ((.[0] | kind) == "letter" or length >= 3)) | .[] ),
        ( $q | match("(?<![[:alnum:]])[A-Z](?:,[[:space:]]?[A-Z])*,? or [A-Z](?![[:alnum:]])"; "g")
          | [ .string | scan("[A-Z]") ] | select(run_ok) | .[] ),
        ( $q | match("(?<![[:alnum:]])[Oo]ptions? ((?:[A-Z]|[0-9]{1,2})(?:(?:,[[:space:]]?|,? and |,? or |[[:space:]]?-[[:space:]]?| to |/)(?:[A-Z]|[0-9]{1,2}))*)(?![[:alnum:]])"; "g")
          | .captures[0].string as $s
          | [ $s | scan("[A-Z]|[0-9]{1,2}") ]
          | if ($s | test("-| to ")) then spread else . end | .[] ) ]
      | unique_by([kind, n]);
  def mark_list:
    if length == 1 then "option " + .[0]
    else "options " + (.[:-1] | join(", ")) + " and " + .[-1] end;
  # A card whose text refers to options it does not carry ("A/B/C", "A, B or
  # C", "option 2") takes each missing one from another listing of that kind:
  # first the card'"'"'s own current texts, then its earlier texts newest first, the
  # first that lists every missing one. An option taken over is labelled with
  # its mark, and one taken from an earlier text says so in its hint. When no
  # text lists them, the card keeps its choices and gains `malformed`, a
  # sentence naming the options it refers to but does not list.
  def recover_options($now; $before):
    ([ $now[] | option_refs[] ] | unique_by([(if test("^[0-9]") then 0 else 1 end), (if test("^[0-9]") then tonumber else (explode[0]) end)])) as $refs
    | [ .options[].value ] as $have
    | [ $refs[] | select((option_mark_value | IN($have[])) | not) ] as $missing
    | if ($missing | length) == 0 then .
      else
        reduce ("number", "letter") as $k (.;
          [ $missing[] | select(test("^[0-9]") == ($k == "number")) ] as $m
          | [ $m[] | option_mark_value ] as $mv
          | if ($m | length) == 0 then .
            else
              def covers: select(. != null and ([.options[].value] as $vs | all($mv[]; IN($vs[]))));
              ([ $now[] | option_parse_by($k) | covers ][0]) as $here
              | (if $here == null then ([ $before[] | option_parse_by($k) | covers ][0]) else null end) as $there
              | ($here // $there) as $src
              | if $src == null then .unlisted = ((.unlisted // []) + $m)
                else .options += [ $src.options[] | select(.value | IN($mv[]))
                                   | .label = ((.value | ltrimstr("option-") | ascii_upcase) + ") " + .label)
                                   | if $here == null then . + {hint: "from an earlier message on this question"} else . end ]
                end
            end)
        | if has("unlisted") then
            (.unlisted | mark_list) as $l
            | del(.unlisted) + {malformed: ("This question refers to " + $l + ", which it does not list; answer in your own words.")}
          else . end
      end;
  def asks: test("\\?") or (option_parse != null);
  def is_wait($d):
    (($d.reason_full // $d.reason // "") | clean_reason) as $r
    | if ($d.verb // "") == "review-ready" then false
      elif ($r | test("^[[:space:]]*((parked|deferred|paused|put on hold|on hold)[^.?!]*[^a-z]captain([^a-z]|$)|(the )?captain (has )?(parked|deferred|paused)[^a-z])"; "i")) then true
      elif ($r | test("not (a )?(captain[- ]?decision|decision for the captain|captain call)"; "i")) then true
      elif ($r | asks) then false
      elif (($d.hold_until // $d.until // "") | tostring | length) > 0
           and (($d.hold_until // $d.until) != "-") then true
      elif ($d.hold_bucket // "") == "blocked" then true
      elif ($r | test("^[[:space:]]*(not before|no earlier than|on or after|revisit|check back|time[- ]gated?|after)([^a-z][^.?!]{0,40})?[0-9]{4}-[0-9]{2}-[0-9]{2}"; "i")) then true
      else ($r | test("^[[:space:]]*(parked|paused|frozen|freeze|on hold|held until|hold until|resume|resuming|waiting (for|on|until)|waits? (for|until|on)|until|re-?runs?)([^a-z]|$)"; "i")) end;
  def is_review($d):
    (($d.reason_full // $d.reason // "") | clean_reason) as $r
    | ($d.verb // "") == "review-ready"
      or ($d.source // "") == "review-page"
      or ($r | test("(^|[^a-z])(review page|re-?review (the |this |that )?(mr|pr|merge request|pull request))([^a-z]|$)"; "i"));
  def is_announcement($d):
    (($d.reason_full // $d.reason // "") | clean_reason) as $r
    | ($d.source // "") == "status"
      and ($r | asks | not)
      and ($r | test("(^|[^a-z])(choose|pick|decide|which)([^a-z]|$)"; "i") | not)
      and ($r | test("(^|[^a-z])(review|understand|lavish|report|pr|mr|pull request|merge request)( (page|board))?(( is| now| are))*[[:space:]]*(live|ready|up|posted)([^a-z]|$)"; "i"));
  def action_led($verbs):
    test("(^|[.!;:][[:space:]]+)(please[[:space:]]+)?((the[[:space:]]+)?captain[,:]?[[:space:]]+(to[[:space:]]+|must[[:space:]]+|needs?[[:space:]]+to[[:space:]]+|please[[:space:]]+)?)?(" + $verbs + ")([^a-z-]|$)"; "i");
  def is_action:
    action_led("dismiss|merge|run|re-?run|log[[:space:]]?in(to)?|sign[[:space:]]?in(to)?|re-?auth(enticate)?|re-?login");
  def is_merge_ask($d):
    (($d.reason_full // $d.reason // $d.question // "") | clean_reason) as $q
    | ($q | (split("?")[0] // "") | split(". ") | (last // "")) as $sentence
    | is_review($d)
      or (($q | test("\\?")) and ($sentence | test("(^|[^a-z])merge([^a-z-]|$)"; "i")))
      or (($q | test("\\?")) and ($sentence
            | test("(^|[^a-z])approve([^a-z]|$).*((^|[^a-z])(pr|mr|pull request|merge request)([^a-z]|$)|/pulls?/[0-9]|/merge_requests/[0-9])"; "i")))
      or (($q | test("\\?") | not) and ($q | action_led("merge")))
      or any((($d.choices.options // []) + ((($q | option_parse) // {}).options // []))[];
             (.label // "") | tostring | test("^[[:space:]]*merge([^a-z-]|$)"; "i"));
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
      elif ($q | is_action) then
        [{value: "done", label: "Done"},
         {value: "not-done", label: "Not done (say why)", hint: "Say why in the answer box"}]
      else
        [{value: "approve", label: "Approve / go ahead"}, {value: "decline", label: "Decline"}]
      end;
'
