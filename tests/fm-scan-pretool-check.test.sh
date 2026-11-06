#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the scan-guard PreToolUse seatbelt (docs/scan-guard.md).
#
# bin/fm-scan-command-policy.mjs owns the block/allow decision and
# bin/fm-scan-pretool-check.sh is the transport that scopes it to the real
# primary checkout and shapes the harness output. No harness is spawned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-scan-pretool-check)

install_scan_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-scan-pretool-check.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-scan-command-policy.mjs" "$dir/bin/"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/"
  chmod +x "$dir/bin/fm-scan-pretool-check.sh" "$dir/bin/fm-scan-command-policy.mjs"
}

PRIMARY="$TMP_ROOT/primary"
git init -q "$PRIMARY"
git -C "$PRIMARY" commit -q --allow-empty -m init
: > "$PRIMARY/AGENTS.md"
install_scan_scripts "$PRIMARY"
CHECK="$PRIMARY/bin/fm-scan-pretool-check.sh"

WORKTREE="$TMP_ROOT/worktree"
fm_git_worktree "$PRIMARY" "$WORKTREE" fm/scan-guard-test-branch
: > "$WORKTREE/AGENTS.md"
install_scan_scripts "$WORKTREE"

claude_payload() {
  jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
}

# run_check <script> <command>: sets RC, OUT, ERR.
run_check() {
  local script=$1 command=$2 out err
  out=$(mktemp "$TMP_ROOT/out.XXXXXX")
  err=$(mktemp "$TMP_ROOT/err.XXXXXX")
  claude_payload "$command" | "$script" --claude >"$out" 2>"$err"
  RC=$?
  OUT=$(cat "$out")
  ERR=$(cat "$err")
}

expect_deny() {
  run_check "$CHECK" "$2"
  [ "$RC" -eq 2 ] && [ -z "$OUT" ] && [[ "$ERR" == *broad-scan* ]] \
    || fail "$1 (rc=$RC out=$OUT err=$ERR)"
}

expect_allow() {
  run_check "$CHECK" "$2"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] \
    || fail "$1 (rc=$RC out=$OUT err=$ERR)"
}

test_blocked_scans() {
expect_deny "recursive grep of the home tilde" 'grep -rn "foo" ~'
expect_deny "recursive grep of a tilde slash" 'grep -rn foo ~/'
expect_deny "recursive grep of HOME" 'grep -r foo $HOME'
expect_deny "recursive grep of the slash root" 'grep -R foo /'
expect_deny "recursive grep of an absolute home directory" 'grep -rl foo /home/rob'
expect_deny "grep with the long recursive flag" 'grep --recursive foo /home/rob/'
expect_deny "grep with -e naming the pattern" 'grep -r -e foo /'
expect_deny "grep option values are not mistaken for roots" 'grep -rn -A 3 foo /'
expect_deny "find rooted at slash" 'find / -name "*.md"'
expect_deny "find rooted at the home tilde" 'find ~ -name x -type f'
expect_deny "find rooted at an absolute home directory" 'find /home/rob -name x'
expect_deny "ripgrep rooted at the home tilde" 'rg foo ~'
expect_deny "scan inside a pipeline" 'cat x | grep -ri foo ~'
expect_deny "scan behind timeout" 'timeout 100 find / -name x'
expect_deny "scan after a list separator" 'cd /tmp && grep -r foo /'

  pass "whole-filesystem scans are denied across grep, find, ripgrep, pipelines, timeout and lists"
}

test_allowed_searches() {
expect_allow "grep scoped to a repo directory" 'grep -rn foo projects/firstmate'
expect_allow "grep scoped under the home" 'grep -rn foo ~/repos/firstmate'
expect_allow "grep of the current directory" 'grep -r foo .'
expect_allow "non-recursive grep of a file under slash" 'grep foo /etc/hosts'
expect_allow "non-recursive grep of slash is not a scan" 'grep foo /'
expect_allow "find scoped to a directory" 'find /home/rob/repos/firstmate -name x'
expect_allow "find of the current directory" 'find . -name x'
expect_allow "shallow find of the home is a listing" 'find ~ -maxdepth 1 -name x'
expect_allow "ripgrep scoped to a repo" 'rg foo ~/repos/firstmate/bin'
expect_allow "the pattern is not a root" 'grep -r / projects/firstmate'
expect_allow "a command without a search tool" 'ls / ~'
expect_allow "git grep is not a filesystem walk" 'git grep -n foo'

  pass "scoped searches and non-recursive forms are allowed"
}

test_deny_text_names_records() {
  run_check "$CHECK" 'grep -r foo ~'
  case "$ERR" in
    *data/projects.md*data/backlog.md*bin/fm-crew-state.sh*data/learnings.md*) pass "deny text names the durable records to read" ;;
    *) fail "deny text must name the durable records: $ERR" ;;
  esac
}

test_harness_output_shapes() {
  local grok_out cursor_out cursor_rc cmd_rc
  grok_out=$(claude_payload 'grep -r foo /' | "$CHECK" 2>/dev/null)
  case "$grok_out" in *'"decision":"deny"'*) ;; *) fail "non-Claude deny must print a decision object: $grok_out" ;; esac
  cursor_out=$(claude_payload 'grep -r foo /' | "$CHECK" --cursor 2>/dev/null)
  cursor_rc=$?
  case "$cursor_out" in *'"permission":"deny"'*) ;; *) fail "cursor deny must print its decision object: $cursor_out" ;; esac
  [ "$cursor_rc" -eq 0 ] || fail "cursor deny must exit 0, got $cursor_rc"
  "$CHECK" --claude --command 'grep -r foo /' >/dev/null 2>&1
  cmd_rc=$?
  [ "$cmd_rc" -eq 2 ] || fail "--command mode must deny with exit 2, got $cmd_rc"
  pass "harness output shapes: Claude stderr, non-Claude stdout, Cursor exit 0, --command"
}

test_inert_outside_primary() {
  local nonfm="$TMP_ROOT/plain"
  run_check "$WORKTREE/bin/fm-scan-pretool-check.sh" 'grep -r foo /'
  { [ "$RC" -eq 0 ] && [ -z "$ERR" ]; } || fail "a crew worktree must be inert (rc=$RC err=$ERR)"
  git init -q "$nonfm"
  install_scan_scripts "$nonfm"
  run_check "$nonfm/bin/fm-scan-pretool-check.sh" 'grep -r foo /'
  [ "$RC" -eq 0 ] || fail "a non-firstmate repo must be inert (rc=$RC)"
  pass "a crew worktree and a non-firstmate repo are inert: the guard covers the pane, not workers"
}

test_override_and_fail_open() {
  FM_ALLOW_BROAD_SCAN=1 run_check "$CHECK" 'grep -r foo /'
  [ "$RC" -eq 0 ] || fail "FM_ALLOW_BROAD_SCAN=1 must allow (rc=$RC)"
  printf 'not json' | "$CHECK" --claude >/dev/null 2>&1 || fail "malformed stdin must fail open"
  printf '' | "$CHECK" --claude >/dev/null 2>&1 || fail "empty stdin must fail open"
  "$CHECK" --claude --command 'grep -r "unterminated /' >/dev/null 2>&1 || fail "an unparseable command must fail open"
  mv "$PRIMARY/bin/fm-scan-command-policy.mjs" "$PRIMARY/bin/fm-scan-command-policy.mjs.off"
  "$CHECK" --claude --command 'grep -r foo /' >/dev/null 2>&1
  local rc=$?
  mv "$PRIMARY/bin/fm-scan-command-policy.mjs.off" "$PRIMARY/bin/fm-scan-command-policy.mjs"
  [ "$rc" -eq 0 ] || fail "a missing policy owner must fail open"
  pass "the override, malformed or empty input, an unparseable command and a missing policy all fail open"
}

test_claude_registration() {
  jq -e '[.hooks.PreToolUse[].hooks[].command | select(test("fm-scan-pretool-check.sh --claude"))] | length == 1' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "the Claude settings must register the scan-guard exactly once"
  pass "the Claude Bash PreToolUse hook is registered"
}

test_scripts_are_lint_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-scan-pretool-check.sh" 2>&1) || fail "the transport is not lint-clean: $out"
  pass "bin/fm-scan-pretool-check.sh is clean under bin/fm-lint.sh"
}

fm_test_run test_blocked_scans test_allowed_searches test_deny_text_names_records test_harness_output_shapes \
  test_inert_outside_primary test_override_and_fail_open test_claude_registration test_scripts_are_lint_clean
