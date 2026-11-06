#!/usr/bin/env bash
# fm-phone-channel.sh - the one owner of the optional home-local phone channel:
# its config format, the reach sentence an away entry records, and the bounded,
# best-effort send.
#
# CONFIG (config/phone-channel; local, gitignored; absent means no phone
# channel). One directive per non-empty, non-comment line, in the form
# config/wedge-alarm uses for its command channel:
#   command:<cmd>   required, exactly once. A single word, such as
#                   command:/abs/path/notify.sh, runs that executable with the
#                   text as its one argument; anything longer runs via `sh -c`
#                   with the text as $1. Either way the text is also on stdin.
#                   Use an absolute path, because the away session's PATH need
#                   not match an interactive shell's.
#   name:<label>    optional, at most once: what announcements call the channel
#                   (default: the command's first word without its directory).
# Any other line, a repeated directive, an empty value, or an unreadable file is
# malformed: `status` says why, nothing is sent, and an away entry keeps its
# hold-for-return announcement and prints the problem (bin/fm-afk-contract.sh).
#
# AWAY USE. bin/fm-afk-contract.sh records `reach_channels: phone` and the
# `reach` sentence below only when an away entry finds the channel configured,
# so what the captain was told at entry is what happens. While that away record
# stands, bin/fm-branch-outcome.sh calls `away-outcome` after it stores each
# non-silent captain-verdict outcome: the outcome is stored first, so a failed
# or slow send never loses it, and the return brief still lists it.
#
# WHAT IS SENT. One line: newlines collapsed, likely credentials (token
# prefixes, key=value secrets, URL user info, private-key blocks) redacted, and
# cut to FM_PHONE_CHANNEL_MAX_CHARS (default 300) while keeping the first
# https:// URL. The command runs under FM_PHONE_CHANNEL_TIMEOUT_SECS (default
# 15) and is then killed. Each failure appends one line to
# state/phone-channel.log; the command itself is never logged or printed.
#
# Usage:
#   fm-phone-channel.sh status
#     Print `configured<TAB><label>` (exit 0), `absent` (exit 1), or
#     `malformed<TAB><why>` (exit 3).
#   fm-phone-channel.sh reach
#     Print the one-sentence reach announcement for a configured channel
#     (exit 0); exit 1 when absent and 3 when malformed, printing nothing.
#   fm-phone-channel.sh send <text>
#     Send one line. Exit 0 sent, 1 the command failed or timed out, 3 absent
#     or malformed.
#   fm-phone-channel.sh away-outcome --summary <text>
#     Send `Firstmate needs you: <summary>` only while an away record with
#     `reach_channels: phone` stands; otherwise do nothing and exit 0. Exit as
#     `send` does when it sends.
set -u

FM_PHONE_CHANNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_PHONE_CHANNEL_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_PHONE_CHANNEL_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/phone-channel"
FM_PHONE_CHANNEL_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_PHONE_CHANNEL_MAX_CHARS_DEFAULT=300
FM_PHONE_CHANNEL_TIMEOUT_SECS_DEFAULT=15

fm_phone_channel_usage() {
  sed -n '/^# Usage:/,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

fm_phone_channel_trim() {  # <text>
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# Parse the config into FM_PHONE_CHANNEL_CMD and FM_PHONE_CHANNEL_LABEL.
# Returns 0 configured, 1 absent, 3 malformed with FM_PHONE_CHANNEL_WHY set.
fm_phone_channel_load() {
  local line value cmd='' label='' n=0
  FM_PHONE_CHANNEL_CMD=; FM_PHONE_CHANNEL_LABEL=; FM_PHONE_CHANNEL_WHY=
  [ -e "$FM_PHONE_CHANNEL_CONFIG" ] || return 1
  if [ ! -f "$FM_PHONE_CHANNEL_CONFIG" ] || [ ! -r "$FM_PHONE_CHANNEL_CONFIG" ]; then
    FM_PHONE_CHANNEL_WHY='config/phone-channel is not a readable file'
    return 3
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=$(fm_phone_channel_trim "$line")
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
      command:*)
        value=$(fm_phone_channel_trim "${line#command:}")
        [ -z "$cmd" ] || { FM_PHONE_CHANNEL_WHY="line $n repeats command:"; return 3; }
        [ -n "$value" ] || { FM_PHONE_CHANNEL_WHY="line $n has an empty command:"; return 3; }
        cmd=$value ;;
      name:*)
        value=$(fm_phone_channel_trim "${line#name:}")
        [ -z "$label" ] || { FM_PHONE_CHANNEL_WHY="line $n repeats name:"; return 3; }
        [ -n "$value" ] || { FM_PHONE_CHANNEL_WHY="line $n has an empty name:"; return 3; }
        label=$value ;;
      *) FM_PHONE_CHANNEL_WHY="line $n is not a command: or name: directive"; return 3 ;;
    esac
  done < "$FM_PHONE_CHANNEL_CONFIG"
  [ -n "$cmd" ] || { FM_PHONE_CHANNEL_WHY='config/phone-channel has no command: line'; return 3; }
  if [ -z "$label" ]; then
    label=${cmd%%[[:space:]]*}
    label=${label##*/}
  fi
  FM_PHONE_CHANNEL_CMD=$cmd
  FM_PHONE_CHANNEL_LABEL=$(printf '%s' "$label" | tr -d '\000-\037')
  return 0
}

# The sentence an away record stores as reach_announced when the channel is
# configured. It names the channel and what reaches it; the outcome still
# waits for the captain's return to be acted on.
fm_phone_channel_reach_sentence() {  # <label>
  printf 'Each outcome that needs your verdict - a decision, a PR ready for review, a blocker, or a credential need - is also sent to your phone channel (%s) as one short line, with its link when there is one; it still waits for your return to be acted on.' "$1"
}

# Best-effort credential redaction for one line of text (stdin to stdout).
fm_phone_channel_redact() {
  sed -E \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----.*/[redacted]/' \
    -e 's#(https?://)[^/@ ]+@#\1[redacted]@#g' \
    -e 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]{16,}/[redacted]/g' \
    -e 's/glpat-[A-Za-z0-9_-]{16,}/[redacted]/g' \
    -e 's/xox[abprs]-[A-Za-z0-9-]{10,}/[redacted]/g' \
    -e 's/sk-[A-Za-z0-9_-]{16,}/[redacted]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[redacted]/g' \
    -e 's/[0-9]{8,10}:[A-Za-z0-9_-]{35}/[redacted]/g' \
    -e 's/([Bb]earer) +[^ ]+/\1 [redacted]/g' \
    -e 's/([Tt]oken|[Pp]assword|[Pp]asswd|[Ss]ecret|[Aa][Pp][Ii][_-]?[Kk]ey)([=:]) *[^ ]+/\1\2[redacted]/g'
}

# The one line that is sent: collapsed, redacted, and bounded, keeping the
# first https:// URL when the cut would drop it.
fm_phone_channel_line() {  # <text>
  local text max url keep
  max=${FM_PHONE_CHANNEL_MAX_CHARS:-$FM_PHONE_CHANNEL_MAX_CHARS_DEFAULT}
  case "$max" in ''|*[!0-9]*) max=$FM_PHONE_CHANNEL_MAX_CHARS_DEFAULT ;; esac
  [ "$max" -ge 80 ] || max=80
  text=$(printf '%s' "$1" | tr '\n\r\t' '   ' | tr -s ' ' | tr -d '\000-\010\013\014\016-\037' | fm_phone_channel_redact)
  text=$(fm_phone_channel_trim "$text")
  [ "${#text}" -gt "$max" ] || { printf '%s' "$text"; return 0; }
  url=$(printf '%s\n' "$text" | grep -oE 'https://[^ ]+' | head -n 1 | sed -E 's/[).,;:]+$//')
  if [ -n "$url" ] && [ "${#url}" -lt $((max - 20)) ]; then
    keep=$((max - ${#url} - 5))
    case "${text:0:$keep}" in
      *"$url"*) printf '%s...' "${text:0:$((max - 3))}" ;;
      *) printf '%s ... %s' "$(fm_phone_channel_trim "${text:0:$keep}")" "$url" ;;
    esac
  else
    printf '%s...' "${text:0:$((max - 3))}"
  fi
}

fm_phone_channel_log_failure() {  # <why>
  mkdir -p "$FM_PHONE_CHANNEL_STATE" 2>/dev/null || return 0
  printf '%s phone channel send failed: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" \
    >> "$FM_PHONE_CHANNEL_STATE/phone-channel.log" 2>/dev/null || true
}

# Run the configured command once, bounded by the timeout. Job control puts
# the command in its own process group so a timeout also stops its children.
fm_phone_channel_run() {  # <line>
  local line=$1 timeout pid start rc monitor_was_on=0
  timeout=${FM_PHONE_CHANNEL_TIMEOUT_SECS:-$FM_PHONE_CHANNEL_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in ''|*[!0-9]*|0) timeout=$FM_PHONE_CHANNEL_TIMEOUT_SECS_DEFAULT ;; esac
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  case "$FM_PHONE_CHANNEL_CMD" in
    *[[:space:]]*) sh -c "$FM_PHONE_CHANNEL_CMD" fm-phone-channel "$line" <<< "$line" >/dev/null 2>&1 & ;;
    *) "$FM_PHONE_CHANNEL_CMD" "$line" <<< "$line" >/dev/null 2>&1 & ;;
  esac
  pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -gt "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fm_phone_channel_log_failure "timed out after ${timeout}s"
      return 1
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 0 ] && return 0
  fm_phone_channel_log_failure "command exited $rc"
  return 1
}

fm_phone_channel_send() {  # <text>
  local rc line
  fm_phone_channel_load
  rc=$?
  case "$rc" in
    0) ;;
    1) return 3 ;;
    *)
      fm_phone_channel_log_failure "$FM_PHONE_CHANNEL_WHY"
      printf 'fm-phone-channel: %s; nothing sent\n' "$FM_PHONE_CHANNEL_WHY" >&2
      return 3 ;;
  esac
  line=$(fm_phone_channel_line "$1")
  [ -n "$line" ] || { printf 'fm-phone-channel: empty text; nothing sent\n' >&2; return 1; }
  fm_phone_channel_run "$line" && return 0
  printf 'fm-phone-channel: send failed (see state/phone-channel.log)\n' >&2
  return 1
}

fm_phone_channel_away_outcome() {  # <summary>
  # shellcheck source=bin/fm-afk-contract.sh
  . "$FM_PHONE_CHANNEL_DIR/fm-afk-contract.sh" || return 0
  fm_afk_contract_away_present "$FM_PHONE_CHANNEL_STATE" || return 0
  [ "$(fm_afk_contract_read_field "$(fm_afk_contract_path "$FM_PHONE_CHANNEL_STATE")" reach_channels)" = phone ] || return 0
  fm_phone_channel_send "Firstmate needs you: $1"
}

fm_phone_channel_main() {
  local cmd=${1:-} rc summary=''
  [ "$#" -eq 0 ] || shift
  case "$cmd" in
    status)
      [ "$#" -eq 0 ] || { fm_phone_channel_usage >&2; return 2; }
      fm_phone_channel_load
      rc=$?
      case "$rc" in
        0) printf 'configured\t%s\n' "$FM_PHONE_CHANNEL_LABEL" ;;
        1) printf 'absent\n' ;;
        *) printf 'malformed\t%s\n' "$FM_PHONE_CHANNEL_WHY" ;;
      esac
      return "$rc" ;;
    reach)
      [ "$#" -eq 0 ] || { fm_phone_channel_usage >&2; return 2; }
      fm_phone_channel_load || return $?
      fm_phone_channel_reach_sentence "$FM_PHONE_CHANNEL_LABEL"
      printf '\n' ;;
    send)
      [ "$#" -eq 1 ] || { fm_phone_channel_usage >&2; return 2; }
      fm_phone_channel_send "$1" ;;
    away-outcome)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --summary) [ "$#" -gt 1 ] || { fm_phone_channel_usage >&2; return 2; }; summary=$2; shift 2 ;;
          *) fm_phone_channel_usage >&2; return 2 ;;
        esac
      done
      [ -n "$summary" ] || { fm_phone_channel_usage >&2; return 2; }
      fm_phone_channel_away_outcome "$summary" ;;
    -h|--help|help) fm_phone_channel_usage ;;
    *) fm_phone_channel_usage >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_phone_channel_main "$@"
fi
