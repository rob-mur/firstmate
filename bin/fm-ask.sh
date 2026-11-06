#!/usr/bin/env bash
# fm-ask.sh - the `ask` verb of the seam between the captain-facing session
# and the work behind it: answer a question from the home's durable records
# without the asking session running the lookup itself.
#
# The question goes to a headless Claude print-mode engine (the supervision
# host's engine runner, bin/fm-supervision-engine-lib.sh) whose tools are
# narrowed to reading: the answer comes back on stdout and in a durable
# record. docs/supervision-host.md "Ask" owns the design, the read-only
# boundary, and the measured latency.
#
# Usage:
#   FM_HOME=<home> fm-ask.sh [--model <name>] [--timeout <seconds>] [--async] <question...>
#   FM_HOME=<home> fm-ask.sh outcome <id>
#   fm-ask.sh --print-prompt
#
# FM_HOME must be set explicitly, as for bin/fm-send.sh, so an ask can never
# silently read another home's records.
#
# Records (state/ask/<id>/): request (the question), answer (the engine's
# answer text), result (the engine's JSON result), errors, and meta (key=value
# lines: status=running|answered|failed, model, started, finished, seconds,
# cost, turns). `--async` prints the id at once and answers in the background;
# `outcome <id>` prints the answer (exit 0), or "running" (exit 3), or the
# failure (exit 1).
#
# Read-only boundary: the engine's tool allowlist is Read plus a fixed set of
# read commands (below). It is a guardrail against a model drifting into a
# write, NOT a security boundary: a permitted command such as `find` or `sed`
# has write-capable options, and the allowlist does not inspect arguments. Do
# not point ask at a home whose records you would not let the engine read.
#
# PREFIX-STABILITY: --print-prompt emits the engine's system prompt, a pure
# function of this file (no clock, no home paths, no fleet state), so the
# provider's prompt cache keeps hitting across asks. The home path and the
# question reach the engine as the user message at the tail.
#
# Environment: FM_ASK_MODEL (default: the supervision engine's default model),
# FM_ASK_TIMEOUT (default 120 seconds), FM_SUPERVISION_ENGINE_CLAUDE_BIN (the
# engine executable, a test seam shared with the supervision host).
# Exit: 0 answered, 1 failed, 2 usage, 3 running (outcome only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ask_prompt() {
  cat <<'PROMPT'
You are the ASK desk of firstmate: a read-only lookup over one firstmate home's durable records.
A message gives you the home's path and a captain's question.
Answer from the records, quickly and truthfully, in plain prose the captain can read at a glance.

# Where the records are
Everything is under the home path the message names.
- data/backlog.md - the work queue: items, their state (queued, in flight, held, done), and notes.
- data/captain.md, data/captain-shared.md, data/learnings.md - the captain's preferences and curated knowledge.
- data/secondmates.md - the registered second mates and their scopes.
- data/<task-id>/report.md - a scout's findings; data/<task-id>/ also holds that task's brief.
- state/<task-id>.status - append-only wake events for a task, one line each: `<state> [at=<epoch>]: <text>`.
  A status line is the last EVENT, not the current state.
- state/<task-id>.meta - the task's recorded project, branch, kind, PR url (pr=), and endpoint.
- state/<task-id>.brief or data/<task-id>/brief.md - what the worker was told to do.
- config/ - local operating choices.
For a task's current state of a live fleet, `bin/fm-crew-state.sh <task-id>` reads it; it needs the live worker, so on a copied home it can only report what the records say.

# How to work
- Search before you read: `grep -ril <term> data state` finds the task or report that mentions a thing; read only the lines you need.
- Prefer few tool calls. Batch several reads into one command; one `grep -r` beats five `cat`s.
- Never read a whole large file when `grep -n` plus a short `head`/`tail` window will do.
- You are read-only. Never write, move, delete, or run anything that changes state, and never run a state-changing firstmate script.
- Do not browse the web or call a forge; the records are the only source.

# How to answer
- Lead with the answer itself, in the first sentence.
- Then the supporting facts: the task id, the PR url or report path that holds it, the date or state if it matters.
- If the records do not hold the answer, say exactly that and name what you looked at; never guess and never invent a task, number, or URL.
- If the records disagree, say so and prefer the newer durable record (a report, backlog, or meta line) over an older status line.
- Keep it short: a few sentences, a short list at most.
PROMPT
}

usage() {
  sed -n '/^# Usage:/,/^# FM_HOME must/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# The read-only tool set (see the header's boundary note).
ASK_TOOLS='Read,Bash'
ASK_ALLOWED='Read Bash(cat:*) Bash(grep:*) Bash(rg:*) Bash(ls:*) Bash(head:*) Bash(tail:*) Bash(wc:*) Bash(sort:*) Bash(jq:*) Bash(find:*) Bash(sed:-n*) Bash(bin/fm-crew-state.sh:*)'

meta_get() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

case "${1:-}" in
  --print-prompt) ask_prompt; exit 0 ;;
  -h|--help) usage ;;
esac

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME must be set explicitly so an ask cannot read another home's records" >&2
  exit 2
fi
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ASK_DIR="$STATE/ask"

if [ "${1:-}" = outcome ]; then
  id="${2:-}"
  case "$id" in ''|*[!A-Za-z0-9_-]*) echo "usage: fm-ask.sh outcome <id>" >&2; exit 2 ;; esac
  meta="$ASK_DIR/$id/meta"
  [ -f "$meta" ] || { echo "error: no ask $id" >&2; exit 1; }
  case "$(meta_get "$meta" status)" in
    answered) cat "$ASK_DIR/$id/answer"; exit 0 ;;
    running) echo running; exit 3 ;;
    *) echo "failed: $(head -c 400 "$ASK_DIR/$id/errors" 2>/dev/null)" >&2; exit 1 ;;
  esac
fi

model="${FM_ASK_MODEL:-}"
timeout="${FM_ASK_TIMEOUT:-120}"
async=0
while [ $# -gt 0 ]; do
  case "$1" in
    --model) [ $# -ge 2 ] || usage; model=$2; shift 2 ;;
    --timeout) [ $# -ge 2 ] || usage; timeout=$2; shift 2 ;;
    --async) async=1; shift ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
question="$*"
[ -n "$(printf '%s' "$question" | tr -d '[:space:]')" ] || usage
[ -d "$FM_HOME" ] || { echo "error: FM_HOME $FM_HOME is not a directory" >&2; exit 2; }

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

[ -n "$model" ] || model=$(fm_supervision_engine_default_model claude)
mkdir -p "$ASK_DIR" || { echo "error: cannot create $ASK_DIR" >&2; exit 1; }
id="$(date +%s)-$$-$RANDOM"
dir="$ASK_DIR/$id"
mkdir "$dir" || { echo "error: cannot create $dir" >&2; exit 1; }
printf '%s\n' "$question" > "$dir/request"
ask_prompt > "$dir/prompt"
home_abs=$(cd "$FM_HOME" && pwd -P)
printf 'Home: %s\n\nQuestion: %s\n' "$home_abs" "$question" > "$dir/message"
now() { date +%s.%N; }
started=$(now)
printf 'status=running\nmodel=%s\nstarted=%s\n' "$model" "$started" > "$dir/meta"

run_ask() {
  local rc line cost turns finished status
  export FM_SUPERVISION_ENGINE_TOOLS="$ASK_TOOLS" FM_SUPERVISION_ENGINE_ALLOWED="$ASK_ALLOWED"
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
  fm_supervision_engine_turn claude "$model" "$dir/prompt" "$dir/message" "$uuid" new "$timeout" "$dir/result" "$dir/errors"
  rc=$?
  finished=$(now)
  status=failed
  cost=0 turns=0
  if [ "$rc" -eq 0 ]; then
    line=$(fm_supervision_engine_result claude "$dir/result" 2>/dev/null) || line='error=1'
    case "$line" in
      *"error=0 "*)
        status=answered
        cost=${line#*cost=}; cost=${cost%% *}
        turns=${line#*turns=}; turns=${turns%% *}
        node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(j.result??""))' "$dir/result" > "$dir/answer" 2>/dev/null || status=failed
        [ -s "$dir/answer" ] || status=failed
        ;;
    esac
  fi
  [ "$status" = failed ] && [ ! -s "$dir/errors" ] && printf 'engine exit %s, no usable result\n' "$rc" > "$dir/errors"
  printf 'status=%s\nmodel=%s\nstarted=%s\nfinished=%s\nseconds=%s\ncost=%s\nturns=%s\n' \
    "$status" "$model" "$started" "$finished" "$(awk -v a="$started" -v b="$finished" 'BEGIN{printf "%.2f", b-a}')" "$cost" "$turns" > "$dir/meta"
  [ "$status" = answered ]
}

if [ "$async" -eq 1 ]; then
  ( run_ask >/dev/null 2>&1 ) </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$id"
  exit 0
fi

if run_ask; then
  cat "$dir/answer"
  printf '\n'
  exit 0
fi
echo "failed: $(head -c 400 "$dir/errors" 2>/dev/null)" >&2
exit 1
