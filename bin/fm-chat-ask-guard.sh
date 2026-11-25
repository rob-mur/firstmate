#!/usr/bin/env bash
# fm-chat-ask-guard.sh - Claude Stop hook that stops a captain ask from living
# only in chat.
#
# The captain's board (bin/fm-captain-calls.sh) shows held tasks and keyed
# decisions only. An ask made only in the main session's chat ("shall I ...?",
# "you need to run ...", "your call") never reaches it unless that session also
# holds a card through bin/fm-captain-hold.sh. This hook is the deterministic
# backstop for that: when the turn's final assistant message asks the captain
# for something and nothing covers it, it blocks that turn end once and tells
# the session the exact hold command to run.
#
# It is on by default in a plain Claude primary checkout. A home turns it off
# with a config/chat-ask-guard file whose first non-comment line is "off";
# docs/configuration.md "Chat ask guard" owns that gate. It is silent in a crew
# worktree, in a marked secondmate home (a Stop block there would leave the
# parent recording the mate idle while it is still working), for a Cursor
# payload, and for Grok.
#
# Final message: the payload's last_assistant_message when it is a string,
# otherwise the text blocks of the last assistant transcript entry of this
# turn. The turn starts at the last user transcript entry that is a genuine
# prompt or wake: not a tool result, not isMeta, and not "Stop hook feedback".
# A Stop block's own feedback is such a skipped entry, so a block does not
# start a new turn.
#
# Ask heuristic, on the final message with fenced code, inline code, and URLs
# removed, split into sentences at . ! ? and line breaks:
#   - The exact reply "Captain, shipshape." is never an ask.
#   - A question that is a label is never an ask when text answers it: a
#     markdown heading line, or a bold **...?** or __...?__ span at the start
#     of a line (after any list or quote marker), followed by more text on its
#     line or on a later line ("**What do you like most about your job?** The
#     team ..." quoting a form's fields). The same label as the message's last
#     text is still read.
#   - A sentence that relays rather than asks is never an ask: I've, I have, I,
#     it, has or have passed, sent, told, relayed, recorded, forwarded, handed,
#     replaced, withdrawn or reported ("I've passed your pick to the worker",
#     "I've sent your question to the worker: why not ...?").
#   - A sentence ending in "?" is an ask when it names the captain or the
#     reader (you, your, captain), offers an action (shall/should/can/may I or
#     we, want me), asks for a go-ahead (ok, okay, go ahead, proceed, merge,
#     approve), or names a decision.
#   - Any other sentence is an ask when it carries a request cue and is
#     neither negated, generic, nor hypothetical. Request cues: your call,
#     go-ahead, sign-off or ok; need(s)/needed, waiting on or for, awaiting,
#     waits for, ready for, or for your decision, approval, word, pick,
#     choice, review, input, answer, verdict, read, go-ahead, call or ok; your
#     decision/pick/choice is or followed by ":"; you need/have/will need to;
#     please run, approve, confirm, review, merge, log in, sign in,
#     authenticate, decide, choose, pick, reply or check; let me know; say the
#     word; shall I; want me to; do you want; would you like; waiting on or for
#     you; need(s) you; up to you. Negated or generic: no, not, nothing,
#     never, none, neither, without, anything, everything, whatever, n't
#     ("nothing needs your decision", "anything that needs you waits").
#     Hypothetical: I'll, I will, if ("I'll tell you if you need to sign in").
#
# Covered: the ask passes when this turn ran a Bash command that holds a card
# (fm-captain-hold.sh ... hold), or when the final message names an open
# captain call's task id, any URL that call carries, or any MR, PR, or issue
# number it names ("MR 821", "PR #975", ".../merge_requests/821" all read as
# the same reference), read from bin/fm-captain-calls.sh with PR lookups off. Holding a card for an ask is
# the session's own judgement; this hook only refuses to let it be forgotten.
#
# Loop guard: at most one block per turn. The blocked turn's key (the prompt
# entry's uuid, or a checksum of the message when no transcript is readable)
# is stored per session in state/.chat-ask-guard.json; a later stop with the
# same key passes, whatever the final message says, so a session that judges
# the ask already covered just ends its turn again. stop_hook_active is not
# used, because Claude sets it on every stop after any hook continuation.
#
# The hook prints one Claude block decision, or nothing. Missing jq, an
# unreadable payload or transcript, or a state-write failure exits 0 and
# prints nothing, so a Stop is never stuck on this hook.
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CALLS="${FM_CHAT_ASK_CALLS_CMD:-$SCRIPT_DIR/fm-captain-calls.sh}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh" || exit 0
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh" || exit 0

usage() {
  cat <<'EOF'
usage: fm-chat-ask-guard.sh

Claude Stop hook. Reads the hook payload on stdin.
On by default in a primary home; config/chat-ask-guard "off" disables it.
See the script header for the ask heuristic and the loop guard.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

if [ -n "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ]; then
  exit 0
fi
if [ -t 0 ]; then
  usage
  exit 0
fi

payload=$(cat || true)
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0
fm_hook_payload_is_foreign_host "$payload" && exit 0

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_root_is_secondmate_home "$FM_ROOT" && exit 0

if [ -f "$CONFIG/chat-ask-guard" ]; then
  setting=$(sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/[[:space:]]//g; p; q' "$CONFIG/chat-ask-guard" 2>/dev/null || true)
  [ "$setting" != off ] || exit 0
fi

sid=$(jq -r '.session_id // .sessionId // "session"' <<<"$payload" 2>/dev/null || echo session)
transcript=$(jq -r '.transcript_path // .transcriptPath // empty' <<<"$payload" 2>/dev/null || true)
last_message=$(jq -r 'if (.last_assistant_message | type) == "string" then .last_assistant_message else empty end' <<<"$payload" 2>/dev/null || true)

# One pass over the transcript tail: the turn key, whether this turn held a
# card, and the turn's last assistant text.
turn='{"key":"","covered":false,"text":""}'
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  turn=$(tail -c 2000000 "$transcript" | jq -R -n -c '
    def text_of: if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join("\n")) end;
    def genuine_prompt:
      .type == "user" and (.isMeta != true)
      and ((.message.content | type) == "string"
           or ([.message.content[]? | .type] | (index("tool_result") == null) and (index("text") != null)))
      and ((.message.content | text_of | ltrimstr(" ") | startswith("Stop hook feedback")) | not);
    [inputs | fromjson? | select(type == "object")] as $e
    | ([range(0; $e | length) | select($e[.] | genuine_prompt)] | last) as $start
    | (if $start == null then $e else $e[$start + 1:] end) as $after
    | {
        key: (if $start == null then "" else ($e[$start].uuid // $e[$start].promptId // "") end),
        covered: any($after[] | select(.type == "assistant") | .message.content[]?
          | select(.type == "tool_use" and .name == "Bash") | (.input.command // "");
          test("fm-captain-hold\\.sh[\"'"'"']?\\s+hold\\s")),
        text: ([$after[] | select(.type == "assistant") | .message.content | text_of | select(length > 0)] | last // "")
      }' 2>/dev/null) || turn='{"key":"","covered":false,"text":""}'
fi

if [ -z "$last_message" ]; then
  last_message=$(jq -r '.text' <<<"$turn" 2>/dev/null || true)
fi
[ -n "$last_message" ] || exit 0

ask=$(jq -R -s -r '
  def clean: gsub("```[\\s\\S]*?```"; " ") | gsub("`[^`\\n]*`"; " ") | gsub("https?://[^\\s)>\\]]+"; " ");
  def question_cue: test("\\b(you|your|captain|shall (i|we)|should (i|we)|can (i|we)|may (i|we)|want me|ok|okay|go ahead|proceed|merge|approve|decision)\\b"; "i");
  def request_cue: test("\\b(your (call|go-ahead|go ahead|sign-off|ok|okay)\\b|(need|needs|needed|waiting (on|for)|awaiting|waits for|ready for|for) your (decision|approval|word|pick|choice|review|input|answer|verdict|read|go-ahead|call|ok|okay)\\b|your (decision|pick|choice) *(is\\b|:)|you (need|have|will need|.ll need) to\\b|please (run|approve|confirm|review|merge|log ?in|sign ?in|authenticate|decide|choose|pick|reply|check)\\b|let me know|say the word|shall i\\b|want me to|do you want|would you like|waiting (on|for) you\\b|needs? you\\b|up to you\\b)"; "i");
  def negated: test("\\b(no|not|nothing|never|none|neither|without|anything|everything|whatever)\\b|n.t\\b"; "i");
  def relay: test("\\b(i.ve|i have|i|it|has|have) (passed|sent|told|relayed|recorded|forwarded|handed|replaced|withdrawn|reported)\\b"; "i");
  def hypothetical: test("\\bi.ll\\b|\\bi will\\b|\\bif\\b"; "i");
  def label_re: "^\\s*(?:(?:[>*+-]|[0-9]+[.)])\\s+)*(?:#{1,6}\\s+.*\\?[\\s#]*$|\\*\\*[^*\\n]*\\?\\*\\*|__[^_\\n]*\\?__)";
  def answered_labels_dropped:
    [splits("\\n")] as $l
    | [range(0; $l | length) as $i | $l[$i]
       | if test(label_re) and ((sub(label_re; "") | test("[[:alnum:]]"))
             or any($l[$i + 1:][]; test("[[:alnum:]]")))
         then sub(label_re; "") else . end]
    | join("\n");
  if (gsub("^\\s+|\\s+$"; "") == "Captain, shipshape.") then ""
  else
    [clean | answered_labels_dropped | splits("(?<=[.!?])\\s+|\\n+") | gsub("^[\\s>*_#-]+|[\\s*_]+$"; "") | select(length > 0)
      | select((relay | not) and ((test("\\?[)\"'"'"']*$") and question_cue) or (request_cue and (negated | not) and (hypothetical | not))))]
    | first // ""
  end' <<<"$last_message" 2>/dev/null || true)
[ -n "$ask" ] || exit 0

[ "$(jq -r '.covered' <<<"$turn" 2>/dev/null)" != true ] || exit 0

# An open captain call already on the board covers the ask when the message
# names its task id, one of its URLs, or one of its MR, PR, or issue numbers.
if [ -x "$CALLS" ]; then
  calls=$(FM_HOME="$FM_HOME" FM_CAPTAIN_CALLS_PR_CHECK=0 "$CALLS" 2>/dev/null || true)
  if [ -n "$calls" ] && jq -e --arg m "$last_message" '
      def refs: ascii_downcase
        | [scan("\\b(mr|pr|issue)s?\\s*[!#]?\\s*([0-9]+)|/(merge_requests|pulls?|issues)/([0-9]+)")
           | ((.[0] // .[2]) | if . == "merge_requests" then "mr" elif startswith("pull") then "pr" elif . == "issues" then "issue" else . end)
             + " " + (.[1] // .[3])];
      ($m | refs) as $mrefs
      | [$m | splits("[^A-Za-z0-9._-]+")] as $tokens
      | any(.calls[]?;
          ((.task // "") as $t | ($t | length) > 2 and ($tokens | index([$t]) != null))
          or any([.. | strings | scan("https?://[^\\s)>\\]\"]+")][]; . as $u | $m | contains($u))
          or ([.. | strings | refs[]] - ([.. | strings | refs[]] - $mrefs) | length > 0))' \
      >/dev/null 2>&1 <<<"$calls"; then
    exit 0
  fi
fi

key=$(jq -r '.key' <<<"$turn" 2>/dev/null || true)
if [ -z "$key" ]; then
  key="msg:$(printf '%s' "$last_message" | cksum | awk '{print $1}')"
fi

state_path="$STATE/.chat-ask-guard.json"
seen='{}'
if [ -f "$state_path" ]; then
  seen=$(jq -c 'if type == "object" then . else {} end' "$state_path" 2>/dev/null || echo '{}')
fi
if [ "$(jq -r --arg sid "$sid" '.[$sid] // empty' <<<"$seen")" = "$key" ]; then
  exit 0
fi
seen=$(jq -c --arg sid "$sid" --arg key "$key" 'del(.[$sid]) | . + {($sid): $key} | to_entries | .[-20:] | from_entries' <<<"$seen") || exit 0
tmp=$(mktemp "$STATE/.chat-ask-guard.json.XXXXXX") || exit 0
if ! { printf '%s\n' "$seen" > "$tmp" && mv -f "$tmp" "$state_path"; }; then
  rm -f "$tmp"
  exit 0
fi

hold="$SCRIPT_DIR/fm-captain-hold.sh"
reason="fm-chat-ask-guard: your final message asks the captain for something, but no card was held this turn, so it will not reach the captain's board. The ask: \"${ask:0:240}\". Hold a card for it now: \`$hold hold <task-id> --reason \"<the ask, as a question>\"\` on the work item it gates, or add \`--title \"<short title>\"\` to create the task when none exists (add --option/--link as they fit). If an open card already covers this exact ask, re-run its hold with the same reason or just end the turn: this guard will not block this turn again. Then repeat your captain-facing message in full."
jq -nc --arg reason "$reason" '{decision:"block", reason:$reason}'
exit 0
