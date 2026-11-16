#!/usr/bin/env bash
# fm-lavish-path-lib.sh - make lavish-axi reachable for a caller whose PATH may
# lack it, with no source-time side effects.
#
# fm_lavish_reachable <record-file>
#   Returns 0 when lavish-axi can run. When it is on PATH, its directory is
#   written to <record-file> (only when that changes). When it is not, the
#   directory recorded there earlier is appended to PATH and exported, if it
#   still holds an executable lavish-axi. Returns 1 when neither finds it.
#   The home's record file is state/.board-refresh.lavish-dir: a detached board
#   refresh or an agent shell can inherit a PATH without the tool.

fm_lavish_reachable() {  # <record-file>
  local record=$1 found dir
  if found=$(command -v lavish-axi 2>/dev/null) && [ -n "$found" ]; then
    dir=$(dirname "$found")
    [ "$(cat "$record" 2>/dev/null)" = "$dir" ] || printf '%s\n' "$dir" >"$record"
    return 0
  fi
  dir=$(cat "$record" 2>/dev/null) || return 1
  [ -n "$dir" ] && [ -x "$dir/lavish-axi" ] || return 1
  PATH="$PATH:$dir"
  export PATH
}
