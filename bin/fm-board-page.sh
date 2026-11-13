#!/usr/bin/env bash
# fm-board-page.sh - show a page inside the open bearings board, in place.
#
# Usage:
#   fm-board-page.sh dir <page-id>
#   fm-board-page.sh open <page-id> --title <title>
#   fm-board-page.sh wait <page-id> [--timeout-s <seconds>]
#   fm-board-page.sh reply <page-id> <text>
#   fm-board-page.sh end <page-id>
#   fm-board-page.sh list
#   fm-board-page.sh install [--bin-dir <dir>]
#   fm-board-page.sh route  < page-prompt lines   (the process-event runner's feed)
#   fm-board-page.sh routed < page-prompt lines   (the Lavish adapter's silence check)
#
# This is the ONE entry point for any page that wants to live in the captain's
# single board tab instead of a Lavish tab of its own, including pages built by
# skills that run from other repositories. A page registers here and nowhere
# else; nothing writes the paths below by hand.
#
# dir      Print the folder the page's files go in,
#          $FM_HOME/.lavish/pages/<page-id>/, as the only stdout line, and copy
#          the page relay into it. Write the page's entry file there as
#          page.html, with `<script src="lavish-relay.js"></script>` before the
#          page's own script, then run open. dir registers nothing.
#          <page-id> is a slug: lowercase letters, digits and dashes, starting
#          with a letter or digit, at most 64 characters.
#          Exit 3 when this home has no board ($FM_HOME/.lavish/bearings-board.html);
#          the caller then runs its page standalone.
# open     Register the page and ask the board to refresh, which lists it and
#          shows it in place. Refused while the folder has no page.html, because
#          the board loads each page frame once and never reloads it. Prints the
#          folder like dir. Opening an already registered page keeps its folder
#          and answers, sets the new title, and makes it live again. Exit 3 when
#          this home has no board.
# wait     Block until the page has something for its agent, then print
#            page: <page-id>
#            status: feedback | ended | timeout
#          followed, for feedback, by one JSON line per page action, oldest
#          first: {"key","page","tag","text","prompt","data"}, where tag, text
#          and data are what the page passed to window.lavish.queuePrompt and
#          prompt is the page's message with its data appended as Lavish would.
#          Printed actions are moved to the page's handled folder, so each is
#          delivered once. Actions already waiting are delivered before an
#          ended status. Without --timeout-s it waits until one arrives.
# reply    Post <text> to the board's Lavish chat, prefixed with the page title,
#          through `lavish-axi reply`; it never opens a tab.
# end      Mark the page ended; the board removes it on its next refresh, which
#          end requests at once. The page's folder and answers are kept. Ending
#          a page never ends the board or any other page.
# list     Print `<page-id><TAB><live|ended><TAB><title>` for every registered page.
# install  Write a `fm-board-page` command into <dir> (default
#          ${XDG_BIN_HOME:-$HOME/.local/bin}) that runs this script for this
#          home, so a skill can find the entry point with `command -v`.
#
# route and routed are the board side of the seam and are not for page agents.
# Each stdin line is one JSON object from `fm-procevent-lavish.sh pages`:
# {"key","page","tag","text","prompt","data"} for a page action, or
# {"app_ended":true} when the board's Lavish session ended.
# route    Deliver each action to its page's inbox, once (an already delivered
#          key is skipped). Tag `page-end` ends that page instead, and
#          app_ended ends every live page. Exit 1 if any line names no
#          registered page or cannot be read; every other line is still routed.
# routed   Exit 0 only when every line is already delivered: each action sits
#          in its page's inbox or handled folder, each page-end page is ended,
#          and app_ended left no live page. The adapter stays silent about a
#          board result only then, so an action that reached no page agent
#          still wakes firstmate.
#
# Where things live: the page's served files under $FM_HOME/.lavish/pages/<id>/
# (inside the board's Lavish artifact folder, so the board can frame them, and
# outside the board file Lavish watches, so writing them never reloads the
# board), and its record under state/pages/<id>/: page.json
# ({id,title,opened,state}) plus inbox/ and inbox/handled/.
#
# One refresh policy covers the whole board app: no frame ever reloads. The
# board and each page poll their own data file and patch in place; the board
# never re-points or reloads a page frame. A page therefore follows the
# data-file pattern its own skill documents: page.html is written once and only
# its data file changes.
#
# FM_BOARD_PAGE_REFRESH overrides the refresh command (tests only); the default
# is a detached `bin/fm-board-refresh.sh --force`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BOARD="$FM_HOME/.lavish/bearings-board.html"
SERVED="$FM_HOME/.lavish/pages"
RECORDS="$STATE/pages"
RELAY="$SCRIPT_DIR/../.agents/skills/bearings/assets/lavish-relay.js"

die() { printf 'fm-board-page: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit "${1:-2}"; }

command -v jq >/dev/null 2>&1 || die "jq is required"

valid_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; }
need_id() { [ -n "${1-}" ] || usage; valid_id "$1" || die "invalid page id: $1"; }
record() { printf '%s/%s/page.json\n' "$RECORDS" "$1"; }
inbox() { printf '%s/%s/inbox\n' "$RECORDS" "$1"; }
field() { jq -r --arg f "$2" '.[$f] // empty' "$(record "$1")" 2>/dev/null; }

write_json() {  # <path> <jq-filter> [jq args...] - atomic rewrite of a record
  local path=$1 filter=$2 tmp
  shift 2
  tmp=$(mktemp "$path.XXXXXX") || return 1
  if [ -f "$path" ]; then
    jq "$@" "$filter" "$path" >"$tmp"
  else
    jq -n "$@" "$filter" >"$tmp"
  fi || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

refresh_board() {
  if [ -n "${FM_BOARD_PAGE_REFRESH:-}" ]; then
    $FM_BOARD_PAGE_REFRESH >/dev/null 2>&1 </dev/null || true
    return 0
  fi
  ( nohup "$SCRIPT_DIR/fm-board-refresh.sh" --force >/dev/null 2>&1 </dev/null & ) 2>/dev/null || true
}

set_state() {  # <page-id> <live|ended>
  # shellcheck disable=SC2016 # jq program text, not shell expansion.
  write_json "$(record "$1")" '.state = $s' --arg s "$2"
}

page_dir() {  # <page-id> - make the served folder, install the relay, print the folder
  local dir="$SERVED/$1"
  [ -f "$BOARD" ] || die "no bearings board in this home; open the board first or run the page standalone" 3
  [ -f "$RELAY" ] || die "the page relay is missing: $RELAY"
  mkdir -p "$dir" || die "cannot create the page folder for $1"
  cp -f "$RELAY" "$dir/lavish-relay.js" || die "cannot install the page relay for $1"
  printf '%s\n' "$dir"
}

cmd_dir() {
  need_id "${1-}"
  [ $# -eq 1 ] || usage
  page_dir "$1"
}

cmd_open() {
  local id=${1-} title='' dir
  need_id "$id"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) [ $# -ge 2 ] || usage; title=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$title" ] || die "open needs --title"
  dir=$(page_dir "$id") || exit
  [ -f "$dir/page.html" ] || die "write $dir/page.html before open; the board loads a page frame once"
  mkdir -p "$(inbox "$id")/handled" || die "cannot create the inbox for $id"
  # shellcheck disable=SC2016 # jq program text, not shell expansion.
  write_json "$(record "$id")" \
    '{id: $id, title: $title, opened: (.opened // $now), state: "live"}' \
    --arg id "$id" --arg title "$title" --arg now "$(date -u +%FT%TZ)" \
    || die "cannot record page $id"
  refresh_board
  printf '%s\n' "$dir"
}

pending() {  # <page-id> - undelivered action files, oldest first
  find "$(inbox "$1")" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort -V
}

cmd_wait() {
  local id=${1-} timeout='' deadline=0 files f
  need_id "$id"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout-s) [ $# -ge 2 ] || usage; timeout=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$timeout" in ''|*[!0-9]*) [ -z "$timeout" ] || die "--timeout-s needs whole seconds" ;; esac
  [ -f "$(record "$id")" ] || die "no registered page: $id"
  [ -z "$timeout" ] || deadline=$(( $(date +%s) + timeout ))
  while :; do
    files=$(pending "$id")
    if [ -n "$files" ]; then
      printf 'page: %s\nstatus: feedback\n' "$id"
      while IFS= read -r f; do
        jq -c . "$f" && mv -f "$f" "$(inbox "$id")/handled/"
      done <<<"$files"
      return 0
    fi
    if [ "$(field "$id" state)" = ended ]; then
      printf 'page: %s\nstatus: ended\n' "$id"
      return 0
    fi
    if [ -n "$timeout" ] && [ "$(date +%s)" -ge "$deadline" ]; then
      printf 'page: %s\nstatus: timeout\n' "$id"
      return 0
    fi
    sleep 1
  done
}

cmd_reply() {
  local id=${1-} text=${2-} title
  need_id "$id"
  [ -n "$text" ] || usage
  [ -f "$(record "$id")" ] || die "no registered page: $id"
  [ -f "$BOARD" ] || die "no bearings board in this home"
  title=$(field "$id" title)
  lavish-axi reply "$BOARD" --agent-reply "$title: $text" >/dev/null \
    || die "Lavish did not accept the reply for page $id"
}

cmd_end() {
  local id=${1-}
  need_id "$id"
  [ -f "$(record "$id")" ] || die "no registered page: $id"
  set_state "$id" ended || die "cannot end page $id"
  refresh_board
}

cmd_list() {
  local f
  for f in "$RECORDS"/*/page.json; do
    [ -f "$f" ] || continue
    jq -r '[.id, .state, .title] | @tsv' "$f" 2>/dev/null
  done
}

cmd_install() {
  local bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}" home self
  while [ $# -gt 0 ]; do
    case "$1" in
      --bin-dir) [ $# -ge 2 ] || usage; bin_dir=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  home=$(cd "$FM_HOME" && pwd -P) || die "cannot resolve FM_HOME: $FM_HOME"
  self="$(cd "$SCRIPT_DIR" && pwd -P)/fm-board-page.sh"
  mkdir -p "$bin_dir" || die "cannot create $bin_dir"
  if ! { printf '#!/usr/bin/env bash\n# Written by fm-board-page.sh install; shows pages inside the bearings board of this home.\nexec env FM_HOME=%q %q "$@"\n' \
            "$home" "$self" >"$bin_dir/fm-board-page.tmp" \
          && chmod +x "$bin_dir/fm-board-page.tmp" \
          && mv -f "$bin_dir/fm-board-page.tmp" "$bin_dir/fm-board-page"; }; then
    die "cannot write $bin_dir/fm-board-page"
  fi
  printf '%s\n' "$bin_dir/fm-board-page"
}

# One stdin line -> kind, page, key and tag joined by the unit separator (a
# non-blank IFS character, so an empty field is never skipped), or nothing when
# the line is unreadable.
US=$'\037'
line_fields() {
  jq -r 'if .app_ended == true then ["app_ended", "", "", ""]
         else ["action", (.page // "" | tostring), (.key // "" | tostring), (.tag // "" | tostring)] end
         | map(gsub("[\u0000-\u001f]"; "")) | join("\u001f")' 2>/dev/null <<<"$1"
}

delivered() {  # <page-id> <key>
  [ -f "$(inbox "$1")/$2.json" ] || [ -f "$(inbox "$1")/handled/$2.json" ]
}

live_pages() {
  local f
  for f in "$RECORDS"/*/page.json; do
    [ -f "$f" ] || continue
    jq -r 'select(.state == "live") | .id' "$f" 2>/dev/null
  done
}

cmd_route() {
  local line kind page key tag rc=0 changed=0 tmp p
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    IFS=$US read -r kind page key tag <<<"$(line_fields "$line")"
    if [ "$kind" = app_ended ]; then
      for p in $(live_pages); do set_state "$p" ended && changed=1; done
      continue
    fi
    if [ "$kind" != action ] || ! valid_id "$page" || [ ! -f "$(record "$page")" ]; then
      printf 'fm-board-page: no registered page for: %s\n' "$line" >&2
      rc=1
      continue
    fi
    if [ "$tag" = page-end ]; then
      [ "$(field "$page" state)" = ended ] || { set_state "$page" ended && changed=1; }
      continue
    fi
    [[ "$key" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || { printf 'fm-board-page: bad action key: %s\n' "$line" >&2; rc=1; continue; }
    delivered "$page" "$key" && continue
    mkdir -p "$(inbox "$page")/handled"
    tmp=$(mktemp "$(inbox "$page")/.$key.XXXXXX") || { rc=1; continue; }
    if jq -c . <<<"$line" >"$tmp"; then
      mv -f "$tmp" "$(inbox "$page")/$key.json"
    else
      rm -f "$tmp"
      rc=1
    fi
  done
  [ "$changed" -eq 0 ] || refresh_board
  return "$rc"
}

cmd_routed() {
  local line kind page key tag
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    IFS=$US read -r kind page key tag <<<"$(line_fields "$line")"
    case "$kind" in
      app_ended) [ -z "$(live_pages)" ] || return 1 ;;
      action)
        valid_id "$page" && [ -f "$(record "$page")" ] || return 1
        if [ "$tag" = page-end ]; then
          [ "$(field "$page" state)" = ended ] || return 1
        else
          [[ "$key" =~ ^[A-Za-z0-9._-]{1,128}$ ]] && delivered "$page" "$key" || return 1
        fi
        ;;
      *) return 1 ;;
    esac
  done
  return 0
}

case "${1-}" in
  dir)     shift; cmd_dir "$@" ;;
  open)    shift; cmd_open "$@" ;;
  wait)    shift; cmd_wait "$@" ;;
  reply)   shift; cmd_reply "$@" ;;
  end)     shift; cmd_end "$@" ;;
  list)    shift; cmd_list ;;
  install) shift; cmd_install "$@" ;;
  route)   shift; cmd_route ;;
  routed)  shift; cmd_routed ;;
  -h|--help|help) usage 0 ;;
  *) usage ;;
esac
