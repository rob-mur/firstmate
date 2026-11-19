# shellcheck shell=bash
# Shared "does this Captain's Call card state its decision" check.
# Usage: . bin/fm-bearings-card-check-lib.sh; then call
#   fm_bearings_undecided_cards <data.json>
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
# it has no `question` or `decide`, since its title may come from an option or
# body sentence that asks) - and a way to answer it, at least one option of its
# own besides the injected reconcile choice or a free-text answer. A card whose
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
# decision is on that page.
#
# fm_bearings_undecided_cards <data.json>: print one `<key>: missing <field>
# (<why>)[, <field> (<why>)]` line per Captain's Call card in an
# fm-bearings-board.v1 payload that fails the rule.
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
# `missing ...` problem text, the same text the board files in cards_to_fix;
# exit 2 when the check itself could not run (jq or the payload builder
# failed), which a caller must not read as a verdict.

FM_BEARINGS_CARD_CHECK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

fm_bearings_undecided_cards() {  # <data.json>
  jq -r '
    def text: if type == "string" then gsub("^[[:space:]]+|[[:space:]]+$"; "") else "" end;
    def asks: text | contains("?");
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
    | ((.links // [] | length) > 0 or ((.pr_url // "") | length) > 0 or .no_link == true) as $linked
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
        (if ($raised | not) and ($linked | not)
         then "link (no link: re-hold with --link <url|page:id> or --no-link)" else empty end) ]
    | select(length > 0)
    | "\($key): missing \(join(", "))"
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
      "$slug: missing "*) printf '%s\n' "${line#"$slug: "}"; rc=1 ;;
    esac
  done <<EOF
$undecided
EOF
  return "$rc"
}
