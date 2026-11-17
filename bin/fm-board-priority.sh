#!/usr/bin/env bash
# fm-board-priority.sh - the captain's durable task priority from the bearings board.
#
# The board's step 1 list ranks every Captain's Call decision. The board sends
# that ranking, followed by the tasks under way in their recorded order, as a
# `priority` annotation (context schema fm-bearings-priority.v1, `keys` highest
# first, `order` the decisions among them). The process-to-event runner records
# it here through `record` as soon as it captures the board's result
# (bin/fm-procevent.sh owns that seam), and firstmate reads it back whenever it
# chooses which task to work on or which decision to answer next. A task or
# card the ranking does not name sorts after the ranked ones.
#
# A board priority names only what that board showed, so `set --from-ctx`
# merges it per section instead of replacing the ranking. Its decisions
# (`order`) and its other keys (the tasks under way) are two sections. Each
# section's stored ids are re-ranked among the places that section already
# held, so every id the priority does not name - a queued task, a decision the
# board did not show, or a whole section the priority left empty - keeps its
# stored rank. A newly named id goes just above the next id of its section
# already stored, or just below the previous one, or last when its section has
# none stored.
#
# `record` is the runner's intake: it reads one fm-bearings-priority.v1 object
# on stdin and merges it exactly like `set --from-ctx`, but only when
# `--source-id` is the bearings board's own process-to-event source
# (`fm-procevent-lavish.sh source-id` of `fm-bearings-board.sh path`) and
# `--result` is that source's captured `<source-id>.<seq>.result`. It records
# each result at most once and never an older one over a newer one: the last
# recorded source, sequence and result digest are kept in
# $FM_HOME/state/board-priority.recorded, and a result whose sequence is not
# above the recorded one is skipped while the recorded result still exists
# unchanged (a cleared capture inbox restarts its numbering, so its first new
# result records). Exit 0 recorded, 3 skipped, 1 refused.
#
# Both board-priority writes (`set --from-ctx` and `record`) then drop ids that
# name only closed work, so the ranking does not fill with finished tasks and
# answered decisions. An id is dropped only on positive evidence from this
# home: a task id whose backlog row is Done or whose row is archived in
# data/done-archive.md, and which no registered second mate's backlog lists; a
# `review.<task>` card whose task is archived and gone from the backlog; or a
# `status.<task>.<key>` card of exactly one known task of this home whose
# readable status file no longer holds that decision open (a closed task with
# no status file counts as answered too). Everything else is kept: open, queued
# and held tasks, ids carrying a second mate's name or a `/`, other card kinds,
# ids nothing knows, and every id when the backlog cannot be read in full.
# Plain `set <id>...` stores exactly what it is given.
#
# Usage:
#   fm-board-priority.sh set <id> [<id>...]   replace the whole ranking, highest first
#   fm-board-priority.sh set --from-ctx <file> merge a fm-bearings-priority.v1 JSON object into it, as above
#   fm-board-priority.sh record --source-id <id> --result <file>  merge the object on stdin, as above
#   fm-board-priority.sh show                 print the ranking, one id per line
#   fm-board-priority.sh rank <id>            print the 1-based rank, or `-` when unranked
#   fm-board-priority.sh digest               print a bounded one-block ranking for the session digest and wake drain; nothing when no ranking is stored
#
# Storage: one id per line in $FM_HOME/data/board-priority.txt (FM_DATA_OVERRIDE
# relocates data/; FM_STATE_OVERRIDE relocates state/). The file is
# captain-private durable state, written atomically.
# `fm-bearings-board-payload.sh` reads it, so every rebuilt board lists and deals
# cards in the captain's order.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FILE="$DATA/board-priority.txt"
MARKER="$STATE/board-priority.recorded"

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

sha256_of() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

valid_ctx() {  # <file>
  jq -e '.schema == "fm-bearings-priority.v1" and (.keys | type == "array") and all(.keys[]; type == "string")
    and ((.order // []) | type == "array" and all(.[]; type == "string"))' "$1" >/dev/null 2>&1
}

# Write the ranking for <ids...> into <tmp>, merging per section with the stored
# ranking when <ctx> is a board priority, as the header describes.
compose() {  # <tmp> <ctx-or-empty> <id>...
  local tmp=$1 ctx=$2 seen=" " id merged
  shift 2
  for id in "$@"; do
    valid_id "$id" || { rm -f "$tmp"; fail "invalid id: $id"; }
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    printf '%s\n' "$id" >>"$tmp"
  done
  if [ -n "$ctx" ] && [ -s "$FILE" ]; then
    # Per-section merge, as the header describes: fill each section's stored
    # places with its ids in the board's order, then place its new ids.
    merged=$(jq -rn --rawfile named "$tmp" --rawfile stored "$FILE" --slurpfile ctx "$ctx" '
      def lines: split("\n") | map(select(length > 0));
      def set: map({key: ., value: true}) | from_entries;
      def at($k): index([$k]);
      def section($x):
        ($x | set) as $inx
        | (. | set) as $ins
        | [$x[] | select($ins[.])] as $known
        | (reduce .[] as $id ({out: [], i: 0};
            if $inx[$id] then .out += [$known[.i]] | .i += 1 else .out += [$id] end) | .out)
        | reduce range(0; $x | length) as $j (.;
            . as $cur | $x[$j] as $k
            | if $ins[$k] then .
              else
                ([$x[$j + 1:][] | select(. as $n | $cur | at($n) != null)] | first // null) as $next
                | ([$x[:$j][] | select(. as $n | $cur | at($n) != null)] | last // null) as $prev
                | if $next != null then ($cur | at($next)) as $p | $cur[:$p] + [$k] + $cur[$p:]
                  elif $prev != null then ($cur | at($prev) + 1) as $p | $cur[:$p] + [$k] + $cur[$p:]
                  else $cur + [$k] end
              end);
      ($named | lines) as $keys
      | (($ctx[0].order // []) | set) as $dec
      | ($stored | lines | reduce .[] as $s ([]; if index([$s]) then . else . + [$s] end))
      | section([$keys[] | select($dec[.])])
      | section([$keys[] | select($dec[.] | not)])
      | .[]') || { rm -f "$tmp"; fail "could not merge the board priority: $ctx"; }
    printf '%s\n' "$merged" >"$tmp"
  fi
}

# The board's card-key character rule (bin/fm-bearings-snapshot.sh owns it).
sanitize() {
  case "$1" in
    *[!A-Za-z0-9._-]*) printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Print `<id> open|closed|archived` for each backlog row and archived row of
# this home; fail when the backlog cannot be read in full, so nothing is
# dropped.
task_states() {
  local list
  list=$("$SCRIPT_DIR/fm-tasks-axi.sh" list --limit 1000000 2>/dev/null) || return 1
  printf '%s\n' "$list" | awk '
    NR == 1 { if ($0 !~ /^count: [0-9]+$/) exit 1; want = $2; next }
    /^tasks\[[0-9]+\]\{/ { rows = 1; next }
    rows && /^  / {
      line = substr($0, 3)
      n = split(line, f, ",")
      id = f[1]; st = f[2]
      gsub(/^"|"$/, "", id); gsub(/^"|"$/, "", st)
      print id, (st == "done" ? "closed" : "open")
      got++
      next
    }
    { rows = 0 }
    END { if (got != want) exit 1 }
  ' || return 1
  if [ -f "$DATA/done-archive.md" ] && [ -r "$DATA/done-archive.md" ]; then
    awk '/^- \[x\] / { print $3, "archived" }' "$DATA/done-archive.md"
  fi
}

# Drop from <file> every id the header names as closed. Best-effort: any
# missing evidence keeps the id.
prune_closed() {  # <file>
  local file=$1 ranked states mates mate_homes open closed archived known out id n cands cand cand_key sf key keep line name home
  states=$(task_states) || return 0
  open=" " closed=" " archived=" " known=" "
  while read -r id st; do
    [ -n "$id" ] || continue
    case "$st" in
      open) open="$open$id " ;;
      closed) closed="$closed$id " ;;
      archived) archived="$archived$id " ;;
    esac
    known="$known$id "
  done <<EOF
$states
EOF
  mates=" " mate_homes=""
  if [ -f "$DATA/secondmates.md" ] && [ -r "$DATA/secondmates.md" ]; then
    while IFS= read -r line; do
      case "$line" in "- "*" - "*) ;; *) continue ;; esac
      name=${line#- }; name=${name%% *}
      mates="$mates$name "
      case "$line" in
        *"(home: "*)
          home=${line#*"(home: "}; home=${home%%;*}; home=${home%%)*}
          [ -n "$home" ] && mate_homes="$mate_homes$home
"
          ;;
      esac
    done <"$DATA/secondmates.md"
  fi
  ranked=$(cat "$file")
  out=$(mktemp "$DATA/.board-priority.XXXXXX")
  : >"$out"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    keep=1
    case "$id" in
      */*) ;;
      status.*)
        cands=""; n=0
        set -f
        for cand in $known $mates; do
          case "$cand" in *[!A-Za-z0-9._-]*) cand_key=$(sanitize "$cand") ;; *) cand_key=$cand ;; esac
          case "$id" in "status.$cand_key."*)
            case " $cands " in *" $cand "*) continue ;; esac
            cands="$cands $cand"; n=$((n + 1)) ;;
          esac
        done
        set +f
        cand=${cands# }
        if [ "$n" -eq 1 ] && [ "${#id}" -lt 128 ] && ! case "$mates" in *" $cand "*) true ;; *) false ;; esac; then
          sf="$STATE/$cand.status"
          if [ -e "$sf" ] && { [ ! -r "$sf" ] || [ -L "$sf" ]; }; then
            :
          else
            keep=0
            if [ -f "$sf" ]; then
              # shellcheck source=bin/fm-classify-lib.sh
              [ -n "${_FM_CLASSIFY_LIB_DIR:-}" ] || . "$SCRIPT_DIR/fm-classify-lib.sh"
              while IFS="$(printf '\t')" read -r key _; do
                [ -n "$key" ] || continue
                if [ "$(sanitize "status.$cand.$key" | cut -c1-128)" = "$id" ]; then keep=1; break; fi
              done <<EOF
$(status_open_decisions "$sf")
EOF
            else
              case "$open" in *" $cand "*) keep=1 ;; esac
            fi
          fi
        fi
        ;;
      review.*)
        cand=${id#review.}
        case "$archived" in *" $cand "*)
          case "$open$closed" in *" $cand "*) ;; *) keep=0 ;; esac ;;
        esac
        ;;
      *)
        case "$mates" in *" $id "*) ;; *)
          case "$open" in *" $id "*) ;; *)
            case "$closed$archived" in *" $id "*)
              keep=0
              while IFS= read -r home; do
                [ -n "$home" ] && [ -f "$home/data/backlog.md" ] || continue
                if grep -Eq "^- \[.\] $(printf '%s' "$id" | sed 's/[.]/[.]/g')( |\$)" "$home/data/backlog.md" 2>/dev/null; then
                  keep=1; break
                fi
              done <<EOF
$mate_homes
EOF
              ;;
            esac ;;
          esac ;;
        esac
        ;;
    esac
    [ "$keep" -eq 0 ] || printf '%s\n' "$id" >>"$out"
  done <<EOF
$ranked
EOF
  mv "$out" "$file"
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
    ctx=''
    if [ "${1:-}" = "--from-ctx" ]; then
      [ "$#" -eq 2 ] || fail "--from-ctx needs one file"
      command -v jq >/dev/null 2>&1 || fail "jq is required"
      valid_ctx "$2" || fail "not an fm-bearings-priority.v1 object: $2"
      ctx=$2
      while IFS= read -r k; do ids+=("$k"); done < <(jq -r '.keys[]' "$ctx")
    else
      ids=("$@")
    fi
    [ "${#ids[@]}" -gt 0 ] || fail "set needs at least one id"
    mkdir -p "$DATA"
    tmp=$(mktemp "$DATA/.board-priority.XXXXXX")
    compose "$tmp" "$ctx" "${ids[@]}"
    [ -z "$ctx" ] || prune_closed "$tmp"
    mv "$tmp" "$FILE"
    ;;
  record)
    sid='' result=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --source-id) [ "$#" -ge 2 ] || fail "--source-id needs a value"; sid=$2; shift 2 ;;
        --result) [ "$#" -ge 2 ] || fail "--result needs a value"; result=$2; shift 2 ;;
        *) fail "unknown record argument: $1" ;;
      esac
    done
    [ -n "$sid" ] && [ -n "$result" ] || fail "record needs --source-id and --result"
    command -v jq >/dev/null 2>&1 || fail "jq is required"
    board=$("$SCRIPT_DIR/fm-bearings-board.sh" path) || fail "cannot locate the bearings board"
    [ -f "$board" ] || fail "no bearings board in this home"
    want=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board" 2>/dev/null) \
      || fail "cannot identify the bearings board's source"
    [ "$sid" = "$want" ] || fail "not the bearings board's source: $sid"
    [ -f "$result" ] && [ ! -L "$result" ] || fail "no captured result: $result"
    base=$(basename -- "$result")
    seq=${base#"$sid".}
    seq=${seq%.result}
    case "$seq" in ''|*[!0-9]*) fail "not a captured result of $sid: $result" ;; esac
    [ "$base" = "$sid.$seq.result" ] || fail "not a captured result of $sid: $result"
    digest=$(sha256_of "$result") || fail "cannot digest $result"
    if [ -f "$MARKER" ] && read -r rsid rseq rdigest <"$MARKER" \
      && [ "$rsid" = "$sid" ] && case "$rseq" in ''|*[!0-9]*) false ;; *) true ;; esac \
      && [ "$seq" -le "$rseq" ]; then
      prev="$(dirname -- "$result")/$sid.$rseq.result"
      if [ -f "$prev" ] && [ ! -L "$prev" ] && [ "$(sha256_of "$prev")" = "$rdigest" ]; then
        exit 3
      fi
    fi
    mkdir -p "$DATA" "$STATE"
    ctx=$(mktemp "$DATA/.board-priority-ctx.XXXXXX")
    trap 'rm -f "$ctx"' EXIT
    cat >"$ctx"
    valid_ctx "$ctx" || fail "not an fm-bearings-priority.v1 object on stdin"
    ids=()
    while IFS= read -r k; do ids+=("$k"); done < <(jq -r '.keys[]' "$ctx")
    [ "${#ids[@]}" -gt 0 ] || fail "the board priority names no id"
    tmp=$(mktemp "$DATA/.board-priority.XXXXXX")
    compose "$tmp" "$ctx" "${ids[@]}"
    prune_closed "$tmp"
    mv "$tmp" "$FILE"
    mtmp=$(mktemp "$STATE/.board-priority-recorded.XXXXXX")
    printf '%s %s %s\n' "$sid" "$seq" "$digest" >"$mtmp"
    mv "$mtmp" "$MARKER"
    ;;
  *) fail "unknown command: $cmd" ;;
esac
