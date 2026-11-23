# shellcheck shell=bash
# Shared "does this Captain's Call card state its decision" check.
# Usage: . bin/fm-bearings-card-check-lib.sh; then call
#   fm_bearings_card_link_states <data.json>
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
# sentence that asks, never from one of its options) - and a way to answer it,
# at least one option of its own besides the injected reconcile choice or a free-text answer. A card whose
# options include `done` and `not-done` asks for an in-person action, so its
# prompt may be an imperative sentence. A card also needs the decision's own
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
# other than none or a default yes/no (yes, no, approve, decline): those marks
# list choices the option reader could not turn into options, so the card is
# named until the reader learns the form or the reason is rewritten.
# A card also lists each link once: two spellings of its `links` urls and
# `pr_url` that differ only by trailing slashes or a `#fragment`, or one url
# repeated within `links`, name the card. A `pr_url` repeated exactly in
# `links` is not a duplicate: the board shows it once, and the payload builder
# emits that shape whenever a reason cites the task's own PR.
# A card must not ask about a PR/MR that is already over: a `links` url that
# the live link states name merged or closed names the card, so a card written
# after its merge request merged cannot ask for its review. Only `links` is
# judged: it carries what the hold itself names (its --link values and the
# urls in its reason), while `pr_url` is only the PR the task recorded, which
# may be an earlier, merged round of a question that is still live.
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
# fm_bearings_undecided_cards <data.json> [<link-states.json>]: print one
# `<key>: <problem>` line per Captain's Call card in an fm-bearings-board.v1
# payload that fails the rule, <problem> being `missing <field> (<why>)[, ...]`,
# `duplicate link (<url> ...)` and/or `names <url>, already merged|closed`
# (from the link states fm_bearings_card_link_states printed), joined by `; `.
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

fm_bearings_undecided_cards() {  # <data.json> [<link-states.json>]
  local states='{}'
  if [ -n "${2:-}" ]; then states=$(cat -- "$2") || return 1; fi
  jq -r --argjson states "$states" '
    def text: if type == "string" then gsub("^[[:space:]]+|[[:space:]]+$"; "") else "" end;
    def asks: text | contains("?");
    def link_norm: sub("#.*$"; "") | sub("/+$"; "");
    .captains_call[]
    | select(.type != "merge")
    | .options |= map(select(.value != "reconcile"))
    | select(has("off_board") | not)
    | select(((.options | length) == 0)
             and any(.links[]?; has("page")
                     or ((.url // "") | test("^http://dev-1\\.tailf848b0\\.ts\\.net:4387(?:[/?#]|$)")))
             | not)
    | .key as $key
    | ([.question, .decide] | map(text) | map(select(length > 0))) as $prompts
    | (any(.options[]; .value == "done") and any(.options[]; .value == "not-done")) as $action
    | (.from_status == true) as $raised
    | ([ (.context.reason // .about // "") | strings
         | match("(?<![[:alnum:]])[Oo][Pp][Tt][Ii][Oo][Nn] [A-Za-z0-9](?![[:alnum:]])[^.:?!]{0,40}:"; "g") ] | length) as $marks
    | ((.links // [] | length) > 0 or ((.pr_url // "") | length) > 0 or .no_link == true) as $linked
    | [ .links[]?.url | strings | select(length > 0) ] as $urls
    | ( [ ([ $urls[], (.pr_url | strings | select(length > 0)) ] | unique | group_by(link_norm)[]
           | select(length > 1) | .[0] | link_norm),
          ($urls | group_by(.)[] | select(length > 1) | .[0] | link_norm) ] | unique ) as $dups
    | ( $urls | map(link_norm) | unique
        | map(select($states[.] != null) | "names \(.), already \($states[.])") ) as $over
    | [ (if ($prompts | length) == 0 and (.title | asks | not) and ($action | not)
         then "question (no question or decide prompt, and the title is not a question)"
         elif ($prompts | length) > 0 and (any($prompts[]; asks) | not)
              and ($raised or (.title | asks | not)) and ($action | not)
         then "question (\($prompts[0] | if length > 80 then .[:79] + "…" else . end) is not a question)"
         else empty end),
        (if (.options | length) == 0 and .allow_freeform != true and ($raised | not)
         then "options (no options and no free-text answer)"
         elif ($raised | not) and .free_text != true and ($action | not)
              and ((.options | length) == 0 or .options_inferred == true)
         then "options (no recorded choices: re-hold with --option <value>=<label> or --free-text)"
         else empty end),
        (if ($marks >= 2)
              and ((.options | length) == 0
                   or all(.options[]; .value | IN("yes", "no", "approve", "decline")))
         then "options (the reason lists \($marks) Option marks but the card offers \(if (.options | length) == 0 then "no options" else "only a default yes/no" end): write each as \"Option a: ...\")"
         else empty end),
        (if ($raised | not) and ($linked | not)
         then "link (no link: re-hold with --link <url|page:id> or --no-link)" else empty end) ] as $missing
    | [ (if ($missing | length) > 0 then "missing \($missing | join(", "))" else empty end),
        ($dups[] | "duplicate link (\(.) is listed more than once: keep one)"),
        $over[] ]
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
