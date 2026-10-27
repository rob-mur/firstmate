#!/usr/bin/env bash
# Live: same-id Herdr recovery reuses the leased slot, then aborts after record
# publication (fault: launch-file home hash fails). The task's slot and work must survive.
set -u
ROOT=$1 EV=$2
. "$ROOT/tests/herdr-test-safety.sh"; herdr_forget_inherited_pane
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
S=$("$ROOT/bin/fm-herdr-lab.sh" name reuse-abort); export HERDR_SESSION="$S"
T="$EV/transcript.txt"; : > "$T"; log() { printf '%s\n' "$*" | tee -a "$T"; }
cleanup() {
  "$ROOT/bin/fm-herdr-lab.sh" teardown "$S" >/dev/null 2>&1 || true
  (cd "$P" 2>/dev/null && treehouse status --json 2>/dev/null) | jq -r '.[] | select(.lease_holder=="bt") | .path' | while read -r w; do (cd "$P" && treehouse return --force "$w" >/dev/null 2>&1); done
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB" "$SHIM"
}
trap cleanup EXIT
P="$LAB/projects/demo"; mkdir -p "$P"
git -C "$P" init -q; echo '# demo' > "$P/README.md"; git -C "$P" add .; git -C "$P" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$P" "$LAB/demo.origin.git"; git -C "$P" remote add origin "file://$LAB/demo.origin.git"
mkdir -p "$LAB/data/bt"; printf '# Task\n## Captain'"'"'s intent\nLab fixture.\n\n## Firstmate spec\nNothing.\n' > "$LAB/data/bt/brief.md"
snap() {
  local wt; wt=$(grep '^worktree=' "$LAB/state/bt.meta" 2>/dev/null | cut -d= -f2-)
  log "[$1] meta present=$([ -f "$LAB/state/bt.meta" ] && echo yes || echo no) worktree=${wt:-<none>}"
  log "[$1] work.txt in $W1: $(cat "$W1/work.txt" 2>&1)"
  log "[$1] slot claim: $(tr '\n' ' ' < "$(dirname "$W1")/.fm-slot-owner" 2>&1)"
  log "[$1] leases held by bt: $(cd "$P" && treehouse status --json | jq -c '[.[]|select(.lease_holder=="bt")|{path,status}]')"
}
"$ROOT/bin/fm-herdr-lab.sh" provision "$S" >/dev/null || { log "provision failed"; exit 1; }
spawn() { FM_SPAWN_NO_GUARD=1 FM_HOME="$LAB" "$ROOT/bin/fm-spawn.sh" bt "$P" --harness 'sh -i' --mode local-only --yolo off --backend herdr; }
spawn >"$EV/1-spawn.out" 2>"$EV/1-spawn.err"; log "1. fresh spawn exit=$?"
W1=$(grep '^worktree=' "$LAB/state/bt.meta" | cut -d= -f2-)
echo 'uncommitted task work' > "$W1/work.txt"
snap "after fresh spawn + uncommitted work"
"$ROOT/bin/fm-herdr-lab.sh" stop "$S" >/dev/null; "$ROOT/bin/fm-herdr-lab.sh" provision "$S" >/dev/null
log "2. Herdr lab session restarted (resume_agents_on_restore off in lab config -> restored pane holds no agent)"
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-shim.XXXXXX"); MARK="$SHIM/mark"; RS=$(command -v sha256sum)
for n in sha256sum shasum; do cat > "$SHIM/$n" <<SH
#!/usr/bin/env bash
in=\$(cat)
if [ "\$in" = "\$(cd "$LAB" && pwd -P)" ] && [ "$LAB/state/bt.meta" -nt "$MARK" ]; then echo "fault-injected $n failure (after record publication)" >&2; exit 1; fi
printf '%s' "\$in" | "$RS"
SH
chmod +x "$SHIM/$n"; done
touch "$MARK"; sleep 1
PATH="$SHIM:$PATH" spawn >"$EV/3-respawn-injected-fail.out" 2>"$EV/3-respawn-injected-fail.err"; log "3. same-id re-spawn with fault after record publication exit=$?"
log "3. stderr tail: $(tail -3 "$EV/3-respawn-injected-fail.err" | tr '\n' '|')"
snap "after aborted recovery"
spawn >"$EV/4-respawn.out" 2>"$EV/4-respawn.err"; log "4. same-id re-spawn without fault exit=$? out=$(cat "$EV/4-respawn.out")"
snap "after successful recovery"
PANE=$(grep '^herdr_pane_id=' "$LAB/state/bt.meta" | cut -d= -f2-)
log "4. recovered pane cwd: $("$ROOT/bin/fm-herdr-lab.sh" run "$S" pane get "$PANE" | jq -c '.result.pane|{cwd,foreground_cwd}')"
