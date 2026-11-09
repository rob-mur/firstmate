#!/usr/bin/env bash
# fm-board-priority.sh - the captain's durable task priority from the bearings board.
#
# The board's step 1 list ranks every Captain's Call item and every task under
# way. The board sends that ranking as a `priority` annotation (context schema
# fm-bearings-priority.v1, `keys` highest first); firstmate records it here, and
# reads it back whenever it chooses which task to work on or which decision to
# answer next. A task or card the ranking does not name sorts after the ranked
# ones.
#
# Usage:
#   fm-board-priority.sh set <id> [<id>...]   replace the ranking, highest first
#   fm-board-priority.sh set --from-ctx <file> replace it from a fm-bearings-priority.v1 JSON object
#   fm-board-priority.sh show                 print the ranking, one id per line
#   fm-board-priority.sh rank <id>            print the 1-based rank, or `-` when unranked
#   fm-board-priority.sh digest               print a bounded one-block ranking for the session digest and wake drain; nothing when no ranking is stored
#
# Storage: one id per line in $FM_HOME/data/board-priority.txt (FM_DATA_OVERRIDE
# relocates data/). The file is captain-private durable state, written atomically.
# `fm-bearings-board-payload.sh` reads it, so every rebuilt board lists and deals
# cards in the captain's order.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FILE="$DATA/board-priority.txt"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-board-priority: %s\n' "$*" >&2
  exit 1
}

valid_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._:@/-]*) return 1 ;;
  esac
  return 0
}

cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 2; }
shift

case "$cmd" in
  -h|--help) usage ;;
  show)
    [ -f "$FILE" ] && cat "$FILE"
    exit 0
    ;;
  digest)
    [ -s "$FILE" ] || exit 0
    printf 'CAPTAIN PRIORITY (set on the board, highest first; when choosing what to dispatch, handle or answer next, take a higher-ranked task first unless a dependency, blocker, time gate or capacity limit makes it unsafe; full list: bin/fm-board-priority.sh show):\n'
    awk 'NR <= 12 { printf "  %d. %s\n", NR, $0 } END { if (NR > 12) printf "  (%d more ranked - bin/fm-board-priority.sh show)\n", NR - 12 }' "$FILE"
    exit 0
    ;;
  rank)
    [ "$#" -eq 1 ] || fail "rank needs one id"
    n=0
    if [ -f "$FILE" ]; then
      while IFS= read -r line; do
        n=$((n + 1))
        if [ "$line" = "$1" ]; then printf '%s\n' "$n"; exit 0; fi
      done <"$FILE"
    fi
    printf -- '-\n'
    ;;
  set)
    ids=()
    if [ "${1:-}" = "--from-ctx" ]; then
      [ "$#" -eq 2 ] || fail "--from-ctx needs one file"
      command -v jq >/dev/null 2>&1 || fail "jq is required"
      jq -e '.schema == "fm-bearings-priority.v1" and (.keys | type == "array") and all(.keys[]; type == "string")' "$2" >/dev/null \
        || fail "not an fm-bearings-priority.v1 object: $2"
      while IFS= read -r k; do ids+=("$k"); done < <(jq -r '.keys[]' "$2")
    else
      ids=("$@")
    fi
    [ "${#ids[@]}" -gt 0 ] || fail "set needs at least one id"
    mkdir -p "$DATA"
    tmp=$(mktemp "$DATA/.board-priority.XXXXXX")
    seen=" "
    for id in "${ids[@]}"; do
      valid_id "$id" || { rm -f "$tmp"; fail "invalid id: $id"; }
      case "$seen" in *" $id "*) continue ;; esac
      seen="$seen$id "
      printf '%s\n' "$id" >>"$tmp"
    done
    mv "$tmp" "$FILE"
    ;;
  *) fail "unknown command: $cmd" ;;
esac
