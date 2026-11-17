#!/usr/bin/env bash
# fm-lavish-watchdog.sh - restart the Lavish board server before its heap runs out
#
# Usage:
#   fm-lavish-watchdog.sh check
#
# One pass over the Lavish board server on this host. The watcher
# (bin/fm-watch.sh) runs it on its reconcile cadence when the home-local
# config/lavish-heap-watchdog file exists; without that file `check` prints
# nothing and touches nothing, so only the home that opts in watches the server.
#
# Config (config/lavish-heap-watchdog, one key=value per line, # comments):
#   rss_mb=<MB>       restart threshold on the server's resident memory.
#                     Default 2560, well under the server's 4 GB V8 heap limit.
#   quiet_secs=<s>    a page counts as in use when the server's state.json
#                     changed within this many seconds. Default 120.
#   round_secs=<s>    a session's open feedback round counts as mid-answer
#                     only while that session was updated within this many
#                     seconds, so one abandoned round cannot hold the restart
#                     off until the heap runs out. Default 1800.
# An empty file means both defaults. A malformed value or unknown key is
# refused (exit 2) without touching the server.
#
# Each pass:
#   1. Finds the one process listening on LAVISH_AXI_PORT (default 4387, the
#      same default lavish-axi uses) with `ss` (or `lsof`), and acts only when
#      its argv names lavish-axi and has a `server` argument.
#   2. Sets that process's core-file limit to 0 (soft and hard, via prlimit)
#      when it is not 0 already, so a heap-limit abort never writes a core dump.
#      This covers a server any lavish-axi command started on demand.
#   3. Under rss_mb, stops there.
#   4. Over rss_mb, defers the restart while a page may be mid-answer:
#      - a session in the server's state.json has status "feedback" or holds
#        prompts the agent has not received yet, and was updated within
#        round_secs (or has no readable updated_at); an older round is logged
#        and ignored, and its saved prompts survive the restart in state.json;
#      - state.json changed within quiet_secs (opening a page, submitting, and
#        answering all write it; typing a draft does not, but a restart never
#        reloads the page, so a draft survives);
#      - state.json is present but unreadable;
#      - this home has a captured Lavish result that is not handled yet.
#   5. Otherwise restarts it: records the exact argv, environment, working
#      directory, and executable from /proc, sends SIGTERM to that exact pid,
#      waits for it to exit and free the port, then starts the same command
#      line with the same environment in a new session with `ulimit -c 0`,
#      appending to <state-dir>/server.log as lavish-axi does. It never sends
#      SIGKILL: a server still running after FM_LAVISH_WATCHDOG_STOP_WAIT
#      seconds (default 15) is reported and left alone. Open pages keep their
#      tab, their draft, and their live connection, which reconnects by itself.
#      Nothing posts to the server's /shutdown route, which would show every
#      page a sticky "reload" banner.
#
# Output: one line on stdout naming the outcome (ok, deferred, restarted, no
# server, skipped, unsupported). Every action, deferral, and failure is also
# appended to state/lavish-watchdog.log.
#
# Exit codes: 0 = pass completed (including deferral and no-op), 1 = a restart
# or limit change failed, 2 = usage or config error.
#
# Linux only (it reads /proc). Elsewhere `check` prints "unsupported" and does
# nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONF_FILE="$CONFIG/lavish-heap-watchdog"
LOG="$STATE/lavish-watchdog.log"
PORT="${LAVISH_AXI_PORT:-4387}"
STOP_WAIT="${FM_LAVISH_WATCHDOG_STOP_WAIT:-15}"
START_WAIT="${FM_LAVISH_WATCHDOG_START_WAIT:-20}"
LOG_MAX_BYTES=262144

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit "${1:-2}"; }

log() {
  [ -d "$STATE" ] || return 0
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null
  fi
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

# report <line>: the outcome line, also logged.
report() { printf '%s\n' "$1"; log "$1"; }

die_config() { printf 'error: %s\n' "$1" >&2; log "error: $1"; exit 2; }

RSS_MB=2560
QUIET_SECS=120
ROUND_SECS=1800

read_config() {
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] || continue
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) die_config "config/lavish-heap-watchdog: expected key=value, got '$line'" ;;
    esac
    case "$value" in
      ''|*[!0-9]*|0) die_config "config/lavish-heap-watchdog: $key must be a positive whole number, got '$value'" ;;
    esac
    case "$key" in
      rss_mb) RSS_MB=$value ;;
      quiet_secs) QUIET_SECS=$value ;;
      round_secs) ROUND_SECS=$value ;;
      *) die_config "config/lavish-heap-watchdog: unknown key '$key' (known: rss_mb, quiet_secs, round_secs)" ;;
    esac
  done < "$CONF_FILE"
}

# Every pid listening on PORT, one per line.
listener_pids() {
  if command -v ss >/dev/null 2>&1; then
    ss -Hltnp "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
  elif command -v lsof >/dev/null 2>&1; then
    lsof -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sort -u
  fi
}

# NUL-separated /proc file into the named array (bash 3.2 compatible).
read_nul_array() {  # <file> <array-name>
  local item
  eval "$2=()"
  # shellcheck disable=SC2034 # item is appended through the eval below
  while IFS= read -r -d '' item; do
    eval "$2+=(\"\$item\")"
  done < "$1"
}

is_lavish_server() {  # <pid>
  local a lav=0 srv=0 i=0
  local -a args=()
  read_nul_array "/proc/$1/cmdline" args 2>/dev/null || return 1
  for a in "${args[@]}"; do
    i=$((i + 1))
    [ "$i" -gt 1 ] || continue
    case "$a" in
      *lavish-axi*) lav=1 ;;
      server) srv=1 ;;
    esac
  done
  [ "$lav" = 1 ] && [ "$srv" = 1 ]
}

core_limits() {  # <pid> -> "<soft> <hard>"
  awk '/^Max core file size/ { print $5, $6 }' "/proc/$1/limits" 2>/dev/null
}

# Make sure <pid> cannot write a core file. 0 = already off or now off.
disable_core() {  # <pid>
  local limits
  limits=$(core_limits "$1")
  [ "$limits" != "0 0" ] || return 0
  if ! command -v prlimit >/dev/null 2>&1; then
    log "failed: prlimit not found; core dumps stay enabled for lavish server pid $1"
    return 1
  fi
  if prlimit --pid "$1" --core=0:0 2>/dev/null; then
    log "core dumps disabled for lavish server pid $1 (was $limits)"
    return 0
  fi
  log "failed: could not disable core dumps for lavish server pid $1"
  return 1
}

environ_value() {  # <pid> <name>
  local entry
  while IFS= read -r -d '' entry; do
    case "$entry" in "$2="*) printf '%s\n' "${entry#*=}"; return 0 ;; esac
  done < "/proc/$1/environ"
  return 1
}

lavish_state_dir() {  # <pid>
  local dir home
  if dir=$(environ_value "$1" LAVISH_AXI_STATE_DIR 2>/dev/null) && [ -n "$dir" ]; then
    printf '%s\n' "$dir"
    return 0
  fi
  home=$(environ_value "$1" HOME 2>/dev/null) || home=$HOME
  printf '%s\n' "$home/.lavish-axi"
}

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# Print the reason a restart must wait, or nothing when it may proceed.
defer_reason() {  # <state-dir>
  local state_file="$1/state.json" rounds busy stale mtime age pending result adapter
  if [ -e "$state_file" ]; then
    # One line per open round: "busy <key>", or "stale <key>" when the session
    # was last updated more than round_secs ago.
    if ! rounds=$(jq -r --argjson now "$(date +%s)" --argjson window "$ROUND_SECS" '
        (.sessions // {})
        | (if type == "object" then to_entries | map(.value + {key: (.value.key // .key)}) else . end)
        | .[]
        | select(.status == "feedback" or (((.prompts // []) | length) > 0))
        | ((.updated_at // "") | tostring | sub("\\.[0-9]+Z$"; "Z")
           | try fromdateiso8601 catch null) as $at
        | (if $at != null and ($now - $at) > $window then "stale" else "busy" end)
          + " " + ((.key // "?") | tostring)' "$state_file" 2>/dev/null); then
      printf 'state.json unreadable\n'
      return 0
    fi
    busy=$(printf '%s\n' "$rounds" | sed -n 's/^busy //p' | tr '\n' ' ' | sed 's/ $//')
    stale=$(printf '%s\n' "$rounds" | sed -n 's/^stale //p' | tr '\n' ' ' | sed 's/ $//')
    if [ -n "$busy" ]; then
      printf 'session awaiting delivery: %s\n' "$busy"
      return 0
    fi
    [ -z "$stale" ] || log "ignoring feedback round(s) idle longer than ${ROUND_SECS}s: $stale"
    if mtime=$(file_mtime "$state_file") && [ -n "$mtime" ]; then
      age=$(( $(date +%s) - mtime ))
      if [ "$age" -lt "$QUIET_SECS" ]; then
        printf 'recent page activity %ss ago (quiet_secs=%s)\n' "$age" "$QUIET_SECS"
        return 0
      fi
    fi
  fi
  pending=
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    adapter=$(fm_procevent_result_adapter "$result" 2>/dev/null) || continue
    [ "$adapter" = lavish ] || continue
    pending="$pending $(fm_procevent_result_source_id "$result").$(fm_procevent_result_sequence "$result")"
  done < <(fm_procevent_pending "$STATE")
  if [ -n "$pending" ]; then
    printf 'unhandled lavish capture:%s\n' "$pending"
    return 0
  fi
}

port_free() { [ -z "$(listener_pids)" ]; }

restart() {  # <pid> <rss-mb> <state-dir>
  local pid=$1 rss_mb=$2 state_dir=$3 exe cwd i new entry setsid_bin
  local -a argv=() envv=() clean_env=()
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || exe=
  case "$exe" in
    ''|*' (deleted)')
      report "failed: lavish server pid $pid runs a binary that is gone ($exe); not restarting"
      return 1 ;;
  esac
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=/
  [ -d "$cwd" ] || cwd=/
  read_nul_array "/proc/$pid/cmdline" argv || { report "failed: cannot read argv of pid $pid"; return 1; }
  read_nul_array "/proc/$pid/environ" envv || { report "failed: cannot read environment of pid $pid"; return 1; }
  [ "${#argv[@]}" -gt 1 ] || { report "failed: empty argv for pid $pid"; return 1; }
  case "${argv[1]}" in
    /*) [ -e "${argv[1]}" ] || { report "failed: lavish server script ${argv[1]} is gone; not restarting"; return 1; } ;;
  esac
  for entry in "${envv[@]}"; do
    case "$entry" in [!=]*=*) clean_env+=("$entry") ;; esac
  done
  setsid_bin=$(command -v setsid 2>/dev/null) || { report "failed: setsid not found; not restarting"; return 1; }
  mkdir -p "$state_dir" 2>/dev/null || true

  log "restarting lavish server pid $pid on port $PORT (rss ${rss_mb} MB > ${RSS_MB} MB)"
  kill -TERM "$pid" 2>/dev/null || { report "failed: could not signal lavish server pid $pid"; return 1; }
  i=0
  while kill -0 "$pid" 2>/dev/null || ! port_free; do
    i=$((i + 1))
    if [ "$i" -gt $((STOP_WAIT * 5)) ]; then
      if kill -0 "$pid" 2>/dev/null; then
        report "failed: lavish server pid $pid did not exit within ${STOP_WAIT}s of SIGTERM; left running"
      else
        report "failed: port $PORT still in use ${STOP_WAIT}s after lavish server pid $pid exited"
      fi
      return 1
    fi
    sleep 0.2
  done

  # A fresh session with core dumps off and no inherited descriptors beyond
  # stdio, then the recorded executable under its recorded argv[0].
  # shellcheck disable=SC2016 # the inner script expands its own arguments
  env -i "${clean_env[@]}" "$setsid_bin" "$BASH" -c '
    ulimit -c 0 || exit 97
    cd -- "$1" 2>/dev/null || cd / || exit 98
    for fd in /proc/$$/fd/*; do
      n=${fd##*/}
      case "$n" in 0|1|2) ;; *[!0-9]*) ;; *) eval "exec $n>&-" 2>/dev/null ;; esac
    done
    a0=$2; exe=$3; shift 3
    exec -a "$a0" "$exe" "$@"
  ' fm-lavish-watchdog "$cwd" "${argv[0]}" "$exe" "${argv[@]:1}" \
    >> "$state_dir/server.log" 2>&1 < /dev/null &

  i=0
  new=
  while [ "$i" -lt $((START_WAIT * 5)) ]; do
    new=$(listener_pids | head -n 1)
    [ -z "$new" ] || break
    i=$((i + 1))
    sleep 0.2
  done
  if [ -z "$new" ]; then
    report "failed: no lavish server listening on port $PORT ${START_WAIT}s after restarting pid $pid; see $state_dir/server.log"
    return 1
  fi
  # A lavish-axi command may have started its own server in the gap; whichever
  # server won the port gets core dumps disabled too.
  for new in $(listener_pids); do
    is_lavish_server "$new" && disable_core "$new"
  done
  report "restarted: lavish server pid $pid (rss ${rss_mb} MB > ${RSS_MB} MB) is now pid $new on port $PORT"
}

check() {
  local pids pid count rss_kb rss_mb state_dir reason rc=0
  [ -e "$CONF_FILE" ] || return 0
  read_config
  if [ ! -r /proc/self/limits ]; then
    printf 'unsupported: this platform has no /proc\n'
    return 0
  fi
  command -v jq >/dev/null 2>&1 || { report "failed: jq not found"; return 1; }
  pids=$(listener_pids)
  if [ -z "$pids" ]; then
    printf 'no server listening on port %s\n' "$PORT"
    return 0
  fi
  count=$(printf '%s\n' "$pids" | wc -l | tr -d ' ')
  if [ "$count" -ne 1 ]; then
    printf 'skipped: %s processes listen on port %s\n' "$count" "$PORT"
    return 0
  fi
  pid=$pids
  if ! is_lavish_server "$pid"; then
    printf 'skipped: pid %s on port %s is not a lavish server\n' "$pid" "$PORT"
    return 0
  fi
  disable_core "$pid" || rc=1
  rss_kb=$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)
  case "$rss_kb" in ''|*[!0-9]*) report "failed: cannot read memory of lavish server pid $pid"; return 1 ;; esac
  rss_mb=$((rss_kb / 1024))
  if [ "$rss_kb" -lt $((RSS_MB * 1024)) ]; then
    printf 'ok: lavish server pid %s rss %s MB under %s MB\n' "$pid" "$rss_mb" "$RSS_MB"
    return "$rc"
  fi
  state_dir=$(lavish_state_dir "$pid")
  reason=$(defer_reason "$state_dir")
  if [ -n "$reason" ]; then
    report "deferred: lavish server pid $pid rss $rss_mb MB > $RSS_MB MB; $reason"
    return "$rc"
  fi
  restart "$pid" "$rss_mb" "$state_dir"
}

case "${1:-}" in
  check) ;;
  -h|--help|help) usage 0 ;;
  *) usage 2 ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

check
