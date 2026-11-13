#!/usr/bin/env bash
# Behavior tests for bin/fm-board-page.sh, the one entry point for pages shown
# inside the bearings board: registering a page, routing the board's page
# actions to that page's agent once, ending one page without touching the
# others, ending every page when the board's session ends, and the adapter's
# silence check that keeps a routed action from waking firstmate.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PAGE="$ROOT/bin/fm-board-page.sh"
TMP_ROOT=$(fm_test_tmproot fm-board-page)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A home with a board file, a refresh recorder, and a fake lavish-axi that
# records its arguments and never opens anything.
make_home() {  # <name> [--no-board]
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state"
  [ "${2-}" = --no-board ] || { mkdir -p "$home/.lavish"; printf '<html></html>\n' > "$home/.lavish/bearings-board.html"; }
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/lavish-calls"
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

in_home() {  # <home> <command...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_BOARD_PAGE_REFRESH="touch $home/refreshed" "$@"
}

# Write the page the way a skill does: ask for the folder, write page.html, open.
show() {  # <home> <page-id> [open args...]
  local home=$1 id=$2 dir
  shift 2
  dir=$(in_home "$home" "$PAGE" dir "$id") || return
  printf '<html>%s</html>\n' "$id" > "$dir/page.html"
  in_home "$home" "$PAGE" open "$id" "$@"
}

action() {  # <page> <key> [tag] [text]
  jq -cn --arg page "$1" --arg key "$2" --arg tag "${3:-answer}" --arg text "${4:-hello}" \
    '{key: $key, page: $page, tag: $tag, text: $text, prompt: $text, data: {n: 1}}'
}

test_open_registers_a_page_and_refreshes_the_board() {
  local home dir
  home=$(make_home open)
  dir=$(in_home "$home" "$PAGE" dir understand-mr-12) || fail "dir failed"
  assert_equals "$home/.lavish/pages/understand-mr-12" "$dir" "dir did not print the page folder"
  [ -s "$dir/lavish-relay.js" ] || fail "dir did not copy the page relay"
  [ -z "$(in_home "$home" "$PAGE" list)" ] || fail "dir registered the page"
  [ ! -e "$home/refreshed" ] || fail "dir asked the board to refresh"
  in_home "$home" "$PAGE" open understand-mr-12 --title "Understand MR 12" >/dev/null 2>&1 \
    && fail "open accepted a page with no page.html"
  [ -z "$(in_home "$home" "$PAGE" list)" ] || fail "a refused open registered the page"
  printf '<html></html>\n' > "$dir/page.html"
  assert_equals "$dir" "$(in_home "$home" "$PAGE" open understand-mr-12 --title "Understand MR 12")" "open did not print the page folder"
  [ -e "$home/refreshed" ] || fail "open did not ask the board to refresh"
  assert_equals "$(printf 'understand-mr-12\tlive\tUnderstand MR 12')" "$(in_home "$home" "$PAGE" list)" "list did not show the live page"
  rm -f "$home/refreshed"
  in_home "$home" "$PAGE" open understand-mr-12 --title "Understand MR 12 again" >/dev/null || fail "reopen failed"
  assert_equals "$(printf 'understand-mr-12\tlive\tUnderstand MR 12 again')" "$(in_home "$home" "$PAGE" list)" "reopen did not keep one record with the new title"
  [ ! -e "$home/lavish-calls" ] || fail "open ran lavish-axi: $(cat "$home/lavish-calls")"
  pass "dir gives the folder, open registers the written page and refreshes the board, and neither runs lavish-axi"
}

test_open_without_a_board_exits_3() {
  local home rc
  home=$(make_home noboard --no-board)
  in_home "$home" "$PAGE" dir p1 >/dev/null 2>&1
  rc=$?
  assert_equals 3 "$rc" "dir without a board did not exit 3"
  show "$home" p1 --title "P1" >/dev/null 2>&1
  rc=$?
  assert_equals 3 "$rc" "open without a board did not exit 3"
  [ -z "$(in_home "$home" "$PAGE" list)" ] || fail "open without a board registered the page"
  pass "dir and open without a board exit 3 so the caller runs its page standalone"
}

test_bad_page_ids_are_refused() {
  local home
  home=$(make_home badid)
  in_home "$home" "$PAGE" dir "../x" >/dev/null 2>&1 && fail "dir accepted a path id"
  in_home "$home" "$PAGE" dir "Upper" >/dev/null 2>&1 && fail "dir accepted an uppercase id"
  show "$home" ok-id >/dev/null 2>&1 && fail "open accepted a page without a title"
  pass "dir and open refuse ids that are not slugs and pages without a title"
}

test_route_delivers_each_action_once_and_wait_prints_it() {
  local home out
  home=$(make_home route)
  show "$home" p1 --title P1 >/dev/null || fail "open failed"
  { action p1 r1-1; action p1 r1-2 answer "second"; } | in_home "$home" "$PAGE" route || fail "route failed"
  action p1 r1-1 | in_home "$home" "$PAGE" route || fail "a repeated route failed"
  out=$(in_home "$home" "$PAGE" wait p1 --timeout-s 0) || fail "wait failed"
  assert_equals "page: p1" "$(sed -n 1p <<<"$out")" "wait did not name the page"
  assert_equals "status: feedback" "$(sed -n 2p <<<"$out")" "wait did not report feedback"
  assert_equals "r1-1 r1-2" "$(sed -n '3,$p' <<<"$out" | jq -r .key | tr '\n' ' ' | sed 's/ $//')" "wait did not print each action once, oldest first"
  assert_equals 1 "$(sed -n 3p <<<"$out" | jq -r .data.n)" "wait dropped the action data"
  action p1 r1-1 | in_home "$home" "$PAGE" route || fail "routing a handled action failed"
  out=$(in_home "$home" "$PAGE" wait p1 --timeout-s 0)
  assert_equals "status: timeout" "$(sed -n 2p <<<"$out")" "a handled action was delivered again"
  pass "route delivers each action to its page once and wait prints it once"
}

test_routed_reports_only_fully_delivered_lines() {
  local home
  home=$(make_home routed)
  show "$home" p1 --title P1 >/dev/null || fail "open failed"
  action p1 k1 | in_home "$home" "$PAGE" routed && fail "routed passed an undelivered action"
  action p1 k1 | in_home "$home" "$PAGE" route || fail "route failed"
  action p1 k1 | in_home "$home" "$PAGE" routed || fail "routed refused a delivered action"
  action nobody k2 | in_home "$home" "$PAGE" route 2>/dev/null && fail "route accepted an unregistered page"
  action nobody k2 | in_home "$home" "$PAGE" routed && fail "routed passed an action for an unregistered page"
  printf '%s\n' '{"app_ended":true}' | in_home "$home" "$PAGE" routed && fail "routed passed app_ended with a live page"
  pass "routed passes only lines that already reached a page agent"
}

test_ending_one_page_leaves_the_others_live() {
  local home out
  home=$(make_home endone)
  show "$home" p1 --title P1 >/dev/null || fail "open p1 failed"
  show "$home" p2 --title P2 >/dev/null || fail "open p2 failed"
  action p1 e1 page-end | in_home "$home" "$PAGE" route || fail "routing page-end failed"
  assert_equals "$(printf 'p1\tended\tP1\np2\tlive\tP2')" "$(in_home "$home" "$PAGE" list)" "page-end changed another page"
  out=$(in_home "$home" "$PAGE" wait p1 --timeout-s 0)
  assert_equals "status: ended" "$(sed -n 2p <<<"$out")" "wait did not report the ended page"
  action p1 e1 page-end | in_home "$home" "$PAGE" routed || fail "routed refused an ended page's page-end"
  in_home "$home" "$PAGE" end p2 || fail "end failed"
  assert_equals "$(printf 'p1\tended\tP1\np2\tended\tP2')" "$(in_home "$home" "$PAGE" list)" "end did not end its page"
  [ -d "$home/.lavish/pages/p2" ] || fail "end removed the page's files"
  pass "ending one page leaves the other pages live and keeps its files"
}

test_wait_delivers_pending_actions_before_ended() {
  local home out
  home=$(make_home pending)
  show "$home" p1 --title P1 >/dev/null || fail "open failed"
  { action p1 a1; action p1 a2 page-end; } | in_home "$home" "$PAGE" route || fail "route failed"
  out=$(in_home "$home" "$PAGE" wait p1 --timeout-s 0)
  assert_equals "status: feedback" "$(sed -n 2p <<<"$out")" "a pending action was dropped for the ended status"
  out=$(in_home "$home" "$PAGE" wait p1 --timeout-s 0)
  assert_equals "status: ended" "$(sed -n 2p <<<"$out")" "the ended status did not follow the pending action"
  pass "wait delivers actions already waiting before it reports the page ended"
}

test_app_ended_ends_every_live_page() {
  local home
  home=$(make_home appended)
  show "$home" p1 --title P1 >/dev/null || fail "open p1 failed"
  show "$home" p2 --title P2 >/dev/null || fail "open p2 failed"
  printf '%s\n' '{"app_ended":true}' | in_home "$home" "$PAGE" route || fail "routing app_ended failed"
  assert_equals "$(printf 'p1\tended\tP1\np2\tended\tP2')" "$(in_home "$home" "$PAGE" list)" "app_ended left a page live"
  printf '%s\n' '{"app_ended":true}' | in_home "$home" "$PAGE" routed || fail "routed refused app_ended after every page ended"
  pass "the board's session ending ends every live page"
}

test_reply_posts_through_lavish_reply_with_the_page_title() {
  local home
  home=$(make_home reply)
  show "$home" p1 --title "Review MR 9" >/dev/null || fail "open failed"
  in_home "$home" "$PAGE" reply p1 "checked your answer" || fail "reply failed"
  assert_equals "reply $home/.lavish/bearings-board.html --agent-reply Review MR 9: checked your answer" \
    "$(cat "$home/lavish-calls")" "reply did not post one titled lavish-axi reply"
  pass "reply posts one lavish-axi reply prefixed with the page title"
}

test_install_writes_a_command_bound_to_this_home() {
  local home bin out
  home=$(make_home install)
  bin="$home/bin"
  out=$(in_home "$home" "$PAGE" install --bin-dir "$bin") || fail "install failed"
  assert_equals "$bin/fm-board-page" "$out" "install did not print the command path"
  [ -x "$bin/fm-board-page" ] || fail "install did not write an executable"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME=/nonexistent FM_STATE_OVERRIDE="$home/state" \
    FM_BOARD_PAGE_REFRESH=true "$bin/fm-board-page" dir p9) \
    || fail "the installed command did not run for its own home"
  assert_equals "$home/.lavish/pages/p9" "$out" "the installed command did not use its own home"
  [ -f "$out/lavish-relay.js" ] || fail "the installed command did not install the relay"
  pass "install writes a command that runs the entry point for its own home"
}

fm_test_run \
  test_open_registers_a_page_and_refreshes_the_board \
  test_open_without_a_board_exits_3 \
  test_bad_page_ids_are_refused \
  test_route_delivers_each_action_once_and_wait_prints_it \
  test_routed_reports_only_fully_delivered_lines \
  test_ending_one_page_leaves_the_others_live \
  test_wait_delivers_pending_actions_before_ended \
  test_app_ended_ends_every_live_page \
  test_reply_posts_through_lavish_reply_with_the_page_title \
  test_install_writes_a_command_bound_to_this_home
