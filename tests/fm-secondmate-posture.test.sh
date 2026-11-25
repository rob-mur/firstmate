#!/usr/bin/env bash
# Behavior of secondmate continuation posture delivery: the primary's registry
# posture reaches each registered home as config/secondmate-posture through the
# inherited-material push, and a change rides the live reread nudge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-posture)

fm_git_identity fmtest fmtest@example.invalid

# A primary home plus one gitignored secondmate home on a firstmate-shaped repo.
# Sets WORLD_ROOT, WORLD_HOME, and WORLD_SM.
new_posture_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  WORLD_ROOT="$w/root"
  WORLD_HOME="$w/home"
  WORLD_SM="$w/sm"
  mkdir -p "$WORLD_HOME/state" "$WORLD_HOME/data" "$WORLD_HOME/config" "$WORLD_HOME/projects"
  git init -q -b main "$WORLD_ROOT"
  printf '%s\n' '.fm-secondmate-home' 'data/' 'state/' 'config/' 'projects/' > "$WORLD_ROOT/.gitignore"
  printf '%s\n' "instructions" > "$WORLD_ROOT/AGENTS.md"
  mkdir -p "$WORLD_ROOT/bin" "$WORLD_ROOT/.agents/skills"
  printf '%s\n' "echo spawn" > "$WORLD_ROOT/bin/fm-spawn.sh"
  printf '%s\n' "skill" > "$WORLD_ROOT/.agents/skills/example.md"
  touch "$WORLD_HOME/state/.last-watcher-beat"
  git -C "$WORLD_ROOT" add -A
  git -C "$WORLD_ROOT" commit -qm initial
  git -C "$WORLD_ROOT" worktree add -q --detach "$WORLD_SM" HEAD
  printf '%s\n' sm > "$WORLD_SM/.fm-secondmate-home"
  mkdir -p "$WORLD_SM/data" "$WORLD_SM/state" "$WORLD_SM/config" "$WORLD_SM/projects"
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$WORLD_SM"
  } > "$WORLD_HOME/state/sm.meta"
}

write_registry() {  # <posture-field-or-empty>
  printf -- '- sm - fixture mate (home: %s; scope: fixture work; projects: %s; added 2026-11-01)\n' \
    "$WORLD_SM" "${1:-}" > "$WORLD_HOME/data/secondmates.md"
}

push() {
  FM_HOME="$WORLD_HOME" FM_ROOT_OVERRIDE="$WORLD_ROOT" "$ROOT/bin/fm-config-push.sh" 2>&1
}

test_config_push_delivers_registered_posture() {
  local out
  new_posture_world deliver
  write_registry "; posture: drive"
  out=$(push)
  [ "$(cat "$WORLD_SM/config/secondmate-posture" 2>/dev/null)" = drive ] \
    || fail "push did not deliver the drive posture: $out"
  assert_contains "$out" "secondmate-posture: pushed" "push should report the delivered posture"

  out=$(push)
  assert_not_contains "$out" "secondmate-posture: pushed" "an unchanged posture should not be pushed again"

  write_registry ""
  out=$(push)
  [ "$(cat "$WORLD_SM/config/secondmate-posture" 2>/dev/null)" = routed ] \
    || fail "a cleared registry posture did not converge to routed: $out"
  pass "config push delivers, keeps, and clears each home's registered posture"
}

test_config_push_leaves_unregistered_home_alone() {
  local out
  new_posture_world unregistered
  printf -- '- other - other mate (home: %s; scope: other; projects: ; posture: drive; added 2026-11-01)\n' \
    "$TMP_ROOT/elsewhere" > "$WORLD_HOME/data/secondmates.md"
  out=$(push)
  assert_absent "$WORLD_SM/config/secondmate-posture" "an unregistered home received a posture: $out"
  pass "config push writes no posture into a home the registry does not name"
}

fm_test_run test_config_push_delivers_registered_posture test_config_push_leaves_unregistered_home_alone
