#!/usr/bin/env bash
# Stable PreToolUse transport for the scan-guard command policy.
#
# A recursive grep or find rooted at /, ~ or a home directory walks every project
# clone, worktree, and cache on the machine. In the recorded primary session five
# such scans hit the 120 s tool timeout and returned nothing, while the answer
# sat in a durable record firstmate already keeps. This seatbelt denies such a
# command before it runs and names the record to read instead.
# bin/fm-scan-command-policy.mjs is the sole owner of the block/allow decision;
# it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs. This
# wrapper only scopes the guard to the real primary checkout, acquires the
# harness payload, invokes that policy, and renders the established harness
# responses. It never executes, sources, evaluates, or expands the command.
# See docs/scan-guard.md for the complete contract.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-scan-pretool-check.sh --claude
#   bin/fm-scan-pretool-check.sh --command '<cmd>'
#
# The transport, exit/output contract, and rendering are identical to
# bin/fm-cd-pretool-check.sh (--claude, --cursor, --agy, --command).
#   INERT - not the real primary checkout (a crewmate/scout task worktree or a
#           non-firstmate repo): exit 0 with no output, exactly like ALLOW.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
# FM_ALLOW_BROAD_SCAN=1 in the pane's environment turns the guard off.
set -u
CMD=""
CMD_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0
AGY_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-scan-pretool-check.sh [--command <cmd>] [--claude|--cursor|--agy]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, Antigravity toolCall.args.CommandLine/command, or
Claude/Codex tool_input.command).
Fires only in the real primary firstmate checkout; it is a silent no-op in a
crewmate/scout task worktree or any non-firstmate repo.
Exits 0 to allow and 2 to deny a recursive grep or find rooted at /, ~ or a
home directory; searches scoped to a repo or directory are allowed.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0,
because Cursor reads the returned object rather than the exit status.
With --agy, a deny is Antigravity's decision object on stdout and exit 0.
Malformed transport and an unavailable classifier runtime fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    --cursor)
      CURSOR_MODE=1
      shift
      ;;
    --agy)
      AGY_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"
  # Cursor's own registration passes --cursor. Without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads, already
  # evaluated by that registration, so this copy allows without re-classifying.
  if [ "$CURSOR_MODE" -eq 0 ] && [ "$AGY_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolCall.args.CommandLine // .toolCall.args.command // .toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification
# semantics). The command must mention a searching tool and a root marker (a
# slash, a tilde, or HOME) before the policy owner is consulted. Quotes,
# backslashes and newlines are stripped first so an ordinary quoted fragment
# cannot hide a tool name; an ANSI-C or locale quoting marker delegates, as in
# bin/fm-cd-pretool-check.sh, whose decoder coupling applies here too.
[ "${FM_ALLOW_BROAD_SCAN:-0}" != "1" ] || exit 0
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *grep*|*find*|*rg*|*ag*|*ack*) ;;
      *) exit 0 ;;
    esac
    case "$PREFILTER" in
      */*|*~*|*HOME*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0

# Scope to a plain, non-worktree firstmate checkout, where git-dir equals
# git-common-dir. A crewmate/scout task worktree - the shape bin/fm-spawn.sh
# always hands out - is a linked git worktree where the two differ. This guard
# does not inspect .fm-secondmate-home, so it applies in a git-cloned secondmate
# home but remains inert when the secondmate home is itself a treehouse-leased
# linked worktree. docs/scan-guard.md owns this scope; docs/turnend-guard.md owns
# the turn-end guard's separate marker-aware scope. Any failure to confirm the
# checkout is inert (exit 0), never a block, so a broken environment never
# denies a shell command.
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0

POLICY="$FM_ROOT/bin/fm-scan-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi
if [ "$AGY_MODE" -eq 1 ]; then
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$DETAIL" '{decision:"deny",reason:$r}'
  else
    printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
  fi
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
