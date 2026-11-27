# shellcheck shell=bash
# Shared "does this Captain's Call card state its decision" check.
# Usage: . bin/fm-bearings-card-check-lib.sh; then call
#   fm_bearings_card_link_states <data.json>
#   fm_bearings_card_page_states <data.json> <state-dir> <pages-dir>
#   fm_bearings_undecided_cards <data.json> [<link-states.json>]
#   fm_bearings_status_decision_problem <task> <key> <note>
#
# ONE OWNER for the card check. bin/fm-bearings-board.sh `build` holds back
# every card this check names (cards_to_fix), and bin/fm-watch.sh runs the same
# check on a worker's needs-decision line the moment it lands so it can bounce
# the line back to its worker. Both call this file, so the board and the
# bounce never disagree about what a decision card must say.
#
# THE RULE. A Captain's Call card needs a prompt that asks - its `question` or
# `decide` carries a `?`, or its title does (for a `from_status` card only when
# it has no `question` or `decide`, since its title may come from a body
# sentence that asks, never from one of its options), or any sentence of its
# reason (`context.reason` or `about`) outside its option items ends in `?`,
# even one after a colon list whose lead became the heading - and a way to answer it,
# at least one option of its own besides the injected reconcile choice or a free-text answer. A card whose
# options include `done` and `not-done` asks for an in-person action, so its
# heading (its first prompt, else its title) may instead be the imperative
# sentence that asks for it (is_action in bin/fm-bearings-question-lib.sh), but
# never a statement whose request comes only later - unless it is a `from_status` card,
# whose done/not-done options are the derived default (no hold recorded them),
# so it still needs a prompt that asks and counts them as default options in
# the Option-mark and lettered-choice checks below. A card also needs the decision's own
# values and something to click: its options must be recorded ones - not empty
# and not `options_inferred`, the payload mark for a hold that recorded none -
# unless it carries `free_text: true` (a hold that declared a free-text
# question) or is a done/not-done action card; and it needs a link (`links` or
# `pr_url`) unless it carries `no_link: true`. A card with `from_status: true`
# (a worker status question or a review page the generator raised, which has no
# hold to record choices on) needs only the prompt; the board always gives it a
# free-text answer box, so it always has a way to answer. The booleans
# `free_text`, `no_link`, `options_inferred` and `from_status` are optional.
# Exempt are a merge card (its type is the question) and a page-backed card,
# one carrying `off_board` or with no options and a Lavish page link, whose
# decision is on that page. Any card whose reason (its `context.reason`, else
# its `about`) carries two or more "Option x ...:" marks must offer options
# other than none or a default yes/no (yes, no, approve, decline; for a
# `from_status` card also done/not-done): those marks
# list choices the option reader could not turn into options, so the card is
# named until the reader learns the form or the reason is rewritten. The same
# holds for a reason sentence that asks (carries a `?`) and marks two or more
# choices "(a)", "(b)" ... in order, a mark optionally followed by ", ..." such
# as "(a, recommended)": the card is named rather than shown with no choices.
# A card that offers options and whose shown background (`about`) still lists
# its choices as bare lowercase "a) ... b) ..." marks, at least two running a,
# b, ... in order (option_parse_by("inline-letter") in
# bin/fm-bearings-question-lib.sh, the reader inline_letter_options uses),
# would print its options twice, so it is named: its owner re-posts it without
# the list in the reason. A single "a)" in ordinary prose is no list.
# A card asks one question in its heading - its first prompt (`question`, else
# `decide`), else its title: a heading with two or more `?` (urls aside) or an
# inline numbered list of calls, "(1) ... (2) ..." or "1) ... 2) ..." running
# 1, 2, ... in order, names the card, since those sub-questions belong in its
# options or its body. A reason body may still list numbered calls under one
# heading question.
# A card shows the question of its line whole: a heading that carries the cut
# mark "…" the payload adds when it shortens one (short_text_n in
# bin/fm-bearings-board-payload.sh), which its reason never had, was cut and
# names the card, and so does a background (`about`) of a card with options that
# ends in the bare stub of its asking clause, a modal and its subject alone after
# a clause break (", should the captain?"), its choices taken out into the
# options. Such a card is held back, not reworded.
# A card also lists each link once: two spellings of its `links` urls and
# `pr_url` that differ only by trailing slashes or a `#fragment`, or one url
# repeated within `links`, name the card. A `pr_url` repeated exactly in
# `links` is not a duplicate: the board shows it once, and the payload builder
# emits that shape whenever a reason cites the task's own PR.
# A card must not ask to review or merge a PR/MR that is already over: when the
# card asks for review or merge, a `links` url that the live link states name
# merged or closed names the card, so a card written after its merge request
# merged cannot ask for its review. A card asks for review or merge when any of
# its prompts (`question`, `decide`, `title`) is a merge ask (is_merge_ask in
# bin/fm-bearings-question-lib.sh, read with the card's options) or names a
# review ("review", "reviewed", "re-review" ... as a word). Any other card - a
# rollout, deploy, or other post-merge question that links the PR it follows -
# keeps its merged link and reaches the captain. Only `links` is judged: it
# carries what the hold itself names (its --link values and the urls in its
# reason), while `pr_url` is only the PR the task recorded, which may be an
# earlier, merged round of a question that is still live.
#
# fm_bearings_card_link_states <data.json>: read the live state of every
# GitHub, GitLab or Forgejo PR/MR url in the Captain's Call cards' (merge cards
# aside) `links`, each url once, so one build reads each url once, in parallel,
# each bounded by FM_BEARINGS_BOARD_PR_TIMEOUT seconds (default 5), at most
# FM_BEARINGS_BOARD_PR_MAX urls (default 24), through fm_pr_live_state in
# bin/fm-pr-lib.sh. Prints a JSON object of the urls (trailing slashes and
# `#fragment` dropped) that read merged or closed, mapped to that state. A url
# that is not a PR/MR, an unknown host, a missing forge tool, or a failed or
# slow read records nothing, so the card is left alone.
# FM_BEARINGS_BOARD_PR_CHECK=0 skips every read and prints `{}`. Only the board
# build calls this. The watcher checks each needs-decision line as it lands,
# and a forge read of up to the timeout per url there would stall it, so the
# bounce check reads no link state and the next build catches a stale link.
#
# A card must not link a stale page: a `{page: <id>}` link that the states
# object maps under `page:<id>` to "stale" (fm_bearings_card_page_states)
# names the card, page-backed cards included, since a page that missed its
# worker's latest news shows the captain an out-of-date decision.
#
# fm_bearings_card_page_states <data.json> <state-dir> <pages-dir>: print a
# JSON object mapping `page:<id>` to "stale" for every page id that the
# Captain's Call cards link as `{page: <id>}` and whose page file
# (<pages-dir>/<id>/page.html, else page.md) was last written more than
# FM_BEARINGS_PAGE_STALE_GRACE seconds (default 600) before its worker last
# changed state. The worker is the task the page record
# (<state-dir>/pages/<id>/page.json) names in `task`, else the page id; its
# last state change is the `[at=<epoch>]` stamp of the last working,
# needs-decision, blocked, paused, done or failed line in
# <state-dir>/<task>.status. The grace leaves room for a worker that rebuilds
# its page and reports a little later. A page with no page file, no status
# log, or no stamped state line records nothing, so a missing page is handled
# by the page link rules alone. Only the board build calls this.
#
# fm_bearings_undecided_cards <data.json> [<link-states.json>]: print one
# `<key>: <problem>` line per Captain's Call card in an fm-bearings-board.v1
# payload that fails the rule, <problem> being `missing <field> (<why>)[, ...]`,
# `options given twice (...)`, `heading carries several calls (...)`,
# `heading cut short (...)`, `background ends in a dangling fragment (...)`,
# `duplicate link (<url> ...)` and/or
# `names <url>, already merged|closed, and asks to review or merge it`
# (from the link states fm_bearings_card_link_states printed) and/or
# `stale page (...)` (from the page states fm_bearings_card_page_states
# printed, merged into the same object), joined by `; `.
#
# fm_bearings_status_decision_problem <task> <key> <note>: check one worker
# status needs-decision line - <key> its decision key ("default" when the line
# has none), <note> its text with the key token removed (status_line_note in
# bin/fm-classify-lib.sh) - exactly as the board would. It turns the line into
# the one-row status snapshot the bearings snapshot builds for it (its
# status_question_row: same key slug, verb, source, owner and texts, titled by
# the task id), runs the real board payload builder on that snapshot with every
# forge read off, and applies fm_bearings_undecided_cards to the card it
# yields. Exit 0 when the card states its decision or the line yields no card
# (an announcement the board folds away); exit 1 after printing the card's
# problem text, the same text the board files in cards_to_fix less any
# merged or closed link, which only the build reads (fm_bearings_card_link_states);
# exit 2 when the check itself could not run (jq or the payload builder
# failed), which a caller must not read as a verdict.

FM_BEARINGS_CARD_CHECK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-bearings-question-lib.sh
. "$FM_BEARINGS_CARD_CHECK_DIR/fm-bearings-question-lib.sh"

# The PR/MR-shaped urls in a payload's Captain's Call cards' `links`, merge
# cards aside, normalised as link_norm does in fm_bearings_undecided_cards.
fm_bearings_card_pr_urls() {  # <data.json>
  jq -r '
    [ .captains_call[]? | select(.type != "merge")
      | .links[]?.url | strings
      | sub("#.*$"; "") | sub("/+$"; "")
      | select(test("^https://[^[:space:]]+/(pull|pulls|-/merge_requests)/[0-9]+$")) ]
    | unique[]' "$1"
}

fm_bearings_card_link_states() {  # <data.json>
  local urls tmp u i=0 max timeout states
  if [ "${FM_BEARINGS_BOARD_PR_CHECK:-1}" = 0 ]; then echo '{}'; return 0; fi
  urls=$(fm_bearings_card_pr_urls "$1" 2>/dev/null) || urls=""
  if [ -z "$urls" ]; then echo '{}'; return 0; fi
  max=${FM_BEARINGS_BOARD_PR_MAX:-24}
  timeout=${FM_BEARINGS_BOARD_PR_TIMEOUT:-5}
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-card-links.XXXXXX") || { echo '{}'; return 0; }
  while IFS= read -r u; do
    [ "$i" -lt "$max" ] || break
    i=$((i + 1))
    (
      # shellcheck source=bin/fm-pr-lib.sh
      . "$FM_BEARINGS_CARD_CHECK_DIR/fm-pr-lib.sh" && fm_pr_live_state "$u" "$timeout" 0
    ) >"$tmp/$i" 2>/dev/null &
  done <<EOF
$urls
EOF
  wait
  states=$(cat "$tmp"/* 2>/dev/null | jq -R -s '
    split("\n") | map(select(length > 0) | split("\t") | select(.[1] == "merged" or .[1] == "closed")
                      | {key: .[0], value: .[1]}) | from_entries' 2>/dev/null) || states=""
  rm -rf -- "$tmp"
  [ -n "$states" ] || states='{}'
  printf '%s\n' "$states"
}

fm_bearings_card_page_states() {  # <data.json> <state-dir> <pages-dir>
  local ids id task status at file mtime grace out='{}'
  grace=${FM_BEARINGS_PAGE_STALE_GRACE:-600}
  case $grace in ''|*[!0-9]*) grace=600 ;; esac
  ids=$(jq -r '[.captains_call[]?.links[]?.page | strings
                | select(test("^[a-z0-9][a-z0-9-]{0,63}$"))] | unique[]' "$1" 2>/dev/null) || ids=""
  for id in $ids; do
    task=$(jq -r '.task | strings | select(test("^[A-Za-z0-9._-]+$"))' "$2/pages/$id/page.json" 2>/dev/null) || task=""
    [ -n "$task" ] || task=$id
    status="$2/$task.status"
    [ -f "$status" ] || continue
    at=$(sed -nE 's/^(working|needs-decision|blocked|paused|done|failed)([[:space:]][^:]*)?\[at=([0-9]+)\].*/\3/p' "$status" | tail -n 1)
    [ -n "$at" ] || continue
    file="$3/$id/page.html"
    [ -f "$file" ] || file="$3/$id/page.md"
    [ -f "$file" ] || continue
    mtime=$(stat -c %Y -- "$file" 2>/dev/null || stat -f %m -- "$file" 2>/dev/null) || continue
    case $mtime in ''|*[!0-9]*) continue ;; esac
    if [ "$((mtime + grace))" -lt "$at" ]; then
      out=$(printf '%s\n' "$out" | jq -c --arg k "page:$id" '. + {($k): "stale"}') || return 1
    fi
  done
  printf '%s\n' "$out"
}

fm_bearings_undecided_cards() {  # <data.json> [<link-states.json>]
  local states='{}'
  if [ -n "${2:-}" ]; then states=$(cat -- "$2") || return 1; fi
  # shellcheck disable=SC2016  # jq program text.
  jq -r --argjson states "$states" "$FM_BEARINGS_QUESTION_JQ_DEFS"'
    def text: if type == "string" then gsub("^[[:space:]]+|[[:space:]]+$"; "") else "" end;
    def asks: text | contains("?");
    def link_norm: sub("#.*$"; "") | sub("/+$"; "");
    .captains_call[]
    | select(.type != "merge")
    | .options |= map(select(.value != "reconcile"))
    | select(has("off_board") | not)
    | ([ .links[]?.page | strings | select($states["page:" + .] == "stale")
         | "stale page (\(.) was not rebuilt after its worker last reported: rebuild it)" ] | unique) as $stale
    | (((.options | length) == 0)
       and any(.links[]?; has("page")
               or ((.url // "") | test("^http://dev-1\\.tailf848b0\\.ts\\.net:4387(?:[/?#]|$)")))) as $page_backed
    | select(($page_backed | not) or ($stale | length) > 0)
    | .key as $key
    | ([.question, .decide] | map(text) | map(select(length > 0))) as $prompts
    | (.from_status == true) as $raised
    # Done/not-done marks an in-person action only when a hold recorded it: on
    # a status-raised card it is the derived default, as generic as yes/no.
    | (any(.options[]; .value == "done") and any(.options[]; .value == "not-done")) as $done_pair
    | ($done_pair and ($raised | not)) as $action
    # It may stand in for the question only when its heading is the imperative
    # itself ("Dismiss review 623 ..."), never a statement ("PR 1074 adds ...").
    | ($action and (($prompts[0] // (.title | text)) | sentences | (first // "") | is_action)) as $action_asked
    | ((.options | length) == 0
       or all(.options[]; .value | IN("yes", "no", "approve", "decline"))
       or ($raised and all(.options[]; .value | IN("done", "not-done")))) as $generic
    | (if (.options | length) == 0 then "no options"
       elif $done_pair then "only a default done/not done" else "only a default yes/no" end) as $offers
    # A reason that asks anywhere outside its option items, even after a
    # colon list whose lead became the heading ("Four calls: 1) ... 4) ....
    # Do you accept all four?"), states its question; an asking sentence
    # inside an item is a choice, never the question.
    | any((.context.reason, .about) | strings
          | (option_parse as $o | if $o == null then . else $o.lead + " " + $o.tail end)
          | sentences[]; test("[?][[:space:]]*$")) as $reason_asks
    | ([ (.context.reason // .about // "") | strings
         | match("(?<![[:alnum:]])[Oo][Pp][Tt][Ii][Oo][Nn] [A-Za-z0-9](?![[:alnum:]])[^.:?!]{0,40}:"; "g") ] | length) as $marks
    | ([ (.context.reason // .about // "") | strings
         | splits("(?<=[.!?])[[:space:]]+") | select(contains("?"))
         | [ match("(?<![[:alnum:]])[(](?<k>[a-z])(?:[,;][^()]*)?[)]"; "g") | .captures[0].string ]
         | . as $k | [ range(0; length) | select($k[.] == ([97 + .] | implode)) ]
         | until(length == 0 or (.[-1] == length - 1); .[:-1]) | length ] | max // 0) as $letters
    | ((.links // [] | length) > 0 or ((.pr_url // "") | length) > 0 or .no_link == true) as $linked
    | [ .links[]?.url | strings | select(length > 0) ] as $urls
    | ( [ ([ $urls[], (.pr_url | strings | select(length > 0)) ] | unique | group_by(link_norm)[]
           | select(length > 1) | .[0] | link_norm),
          ($urls | group_by(.)[] | select(length > 1) | .[0] | link_norm) ] | unique ) as $dups
    | ( [.question, .decide, .title] | map(text) | map(select(length > 0)) ) as $asked
    | ( any($asked[]; test("(^|[^a-z-])(re-?)?review(s|ed|ing)?([^a-z-]|$)"; "i"))
        or (.options as $o | any($asked[]; {reason_full: ., choices: {options: $o}} | is_merge_ask(.))) ) as $pr_ask
    | ( if $pr_ask then $urls | map(link_norm) | unique
          | map(select($states[.] != null) | "names \(.), already \($states[.]), and asks to review or merge it")
        else [] end ) as $over
    | [ (if $reason_asks then empty
         elif ($prompts | length) == 0 and (.title | asks | not) and ($action_asked | not)
         then "question (no question or decide prompt, and the title is not a question)"
         elif ($prompts | length) > 0 and (any($prompts[]; asks) | not)
              and ($raised or (.title | asks | not)) and ($action_asked | not)
         then "question (\($prompts[0] | if length > 80 then .[:79] + "…" else . end) is not a question)"
         else empty end),
        (if (.options | length) == 0 and .allow_freeform != true and ($raised | not)
         then "options (no options and no free-text answer)"
         elif ($raised | not) and .free_text != true and ($action | not)
              and ((.options | length) == 0 or .options_inferred == true)
         then "options (no recorded choices: re-hold with --option <value>=<label> or --free-text)"
         else empty end),
        (if ($marks >= 2) and $generic
         then "options (the reason lists \($marks) Option marks but the card offers \($offers): write each as \"Option a: ...\")"
         else empty end),
        (if ($marks < 2) and ($letters >= 2) and $generic
         then "options (the question offers lettered (a)/(b) choices but the card offers \($offers): write each as \"Option a: ...\")"
         else empty end),
        (if ($raised | not) and ($linked | not)
         then "link (no link: re-hold with --link <url|page:id> or --no-link)" else empty end) ] as $missing
    | ((.options | length) > 0
       and ((.about // "") | strings | option_parse_by("inline-letter")) != null) as $twice
    # The heading is the first prompt, else the title. Urls are dropped so a `?` in a
    # query string is not counted as a question.
    | ((($prompts[0] // (.title | text)) | gsub("https?://[^[:space:]]+"; "")) as $head
       | ([ $head | match("[?]"; "g") ] | length) as $q
       | ([ $head | match("(?<![[:alnum:]])[(]?(?<n>[1-9])[)]"; "g") | .captures[0].string | tonumber ]
          | . as $n | [ range(0; length) | select($n[.] == . + 1) ]
          | until(length == 0 or (.[-1] == length - 1); .[:-1]) | length) as $calls
       | if $calls >= 2 then "a numbered list of \($calls) calls"
         elif $q >= 2 then "\($q) questions"
         else null end) as $packed
    # A heading the payload cut short carries its cut mark "…" (short_text_n in
    # bin/fm-bearings-board-payload.sh), which the source text never had: it is
    # not the complete question the line asks.
    | (((.context.reason // .about // "") | strings | contains("…")) as $source_cut
       | [$prompts[0] // (.title | text)] | map(select(contains("…") and ($source_cut | not)))[0]
       // null) as $cut
    # An about line whose choices were cut away can be left as the bare stub
    # of the asking clause ("..., should the captain?"): a modal and its
    # subject alone after a clause break, with nothing left to decide.
    | ((.options | length) > 0
       and ((.about // "") | strings | gsub("[[:space:]]+$"; "")
            | test("(?:[,;:]|[[:space:]](?:or|and|but|so|then))[[:space:]]+(?:should|shall|can|could|will|would|do|does|did|may|must|might)[[:space:]]+(?:the[[:space:]]+)?[^[:space:]?]+[?]$"; "i"))) as $dangling
    | [ (if ($missing | length) > 0 then "missing \($missing | join(", "))" else empty end),
        (if $packed != null then "heading carries several calls (it asks \($packed): ask one question there and put the sub-questions in the options or the body)" else empty end),
        (if $cut != null then "heading cut short (\"\($cut | if length > 80 then .[:79] + "…" else . end)\" is not the complete question the line asks: re-post with one short asking sentence first)" else empty end),
        (if $dangling then "background ends in a dangling fragment (\"\((.about | gsub("[[:space:]]+$"; "") | [match("[^,;:]*$")][0].string | sub("^[[:space:]]+"; "")))\" lost its choices: re-post with the question as its own sentence before the choices)" else empty end),
        (if $twice then "options given twice (the background lists lettered a) b) choices as well as the card options: re-post without the list in the reason)" else empty end),
        ($dups[] | "duplicate link (\(.) is listed more than once: keep one)"),
        $over[] ]
    | if $page_backed then [] else . end
    | . + $stale
    | select(length > 0)
    | "\($key): \(join("; "))"
  ' "$1"
}

fm_bearings_status_decision_problem() {  # <task> <key> <note>
  local task=$1 key=$2 note=$3 snapshot slug payload undecided line rc=0
  snapshot=$(jq -cn --arg t "$task" --arg k "$key" --arg n "$note" '
    def trunc($n): tostring | gsub("\\s+"; " ") | if length > $n then .[:$n] + "…" else . end;
    (("status." + $t + "." + $k) | gsub("[^A-Za-z0-9._-]"; "-") | .[:128]) as $slug
    | {schema:"fm-bearings.v1",prs:"unchecked",
       decisions_open:[{id:$t,key:$slug,verb:"needs-decision",source:"status",task:$t,
                        decision_key:$k,mate:null,title:($t | trunc(60)),reason:($n | trunc(80)),
                        title_full:$t,reason_full:$n,summary:(($t + ": " + $n) | trunc(90)),
                        question:$n,owner:"(main)"}],
       in_flight:[],landed:[],recorded_prs:[],contributions:{captain:[]},gates:[],secondmates:[]}
  ') || return 2
  slug=$(printf '%s' "$snapshot" | jq -r '.decisions_open[0].key') || return 2
  payload=$(mktemp "${TMPDIR:-/tmp}/fm-card-check.XXXXXX") || return 2
  if ! printf '%s\n' "$snapshot" \
    | FM_BEARINGS_BOARD_PR_CHECK=0 FM_BEARINGS_BOARD_MR_CHECK=0 \
      "$FM_BEARINGS_CARD_CHECK_DIR/fm-bearings-board-payload.sh" --snapshot - > "$payload" 2>/dev/null \
    || ! undecided=$(fm_bearings_undecided_cards "$payload" 2>/dev/null); then
    rm -f -- "$payload"
    return 2
  fi
  rm -f -- "$payload"
  while IFS= read -r line; do
    case "$line" in
      "$slug: "?*) printf '%s\n' "${line#"$slug: "}"; rc=1 ;;
    esac
  done <<EOF
$undecided
EOF
  return "$rc"
}
