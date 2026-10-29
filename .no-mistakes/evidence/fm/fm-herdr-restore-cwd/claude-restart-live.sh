#!/usr/bin/env bash
# Live check: real Claude crewmate spawned via fm-spawn --backend herdr into a lab
# home, Herdr lab session restarted with resume_agents_on_restore=true, then the
# restored pane cwd and the resumed claude process cwd are read.
set -u
ROOT=$PWD
H=$ROOT/bin/fm-herdr-lab.sh
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_ENV NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
CFGDIR=$(mktemp -d /tmp/fm-lab-cfg.XXXXXX)
sed 's/^resume_agents_on_restore = false/resume_agents_on_restore = true/' ~/.config/herdr/config.toml > "$CFGDIR/config.toml"
grep -n resume_agents "$CFGDIR/config.toml"
export HERDR_CONFIG_PATH="$CFGDIR/config.toml"
S=$("$H" name claude-cwd); export HERDR_SESSION=$S
echo "lab session=$S home=$LAB"
cleanup() {
  [ -n "${WT:-}" ] && treehouse return --force "$WT" >/dev/null 2>&1
  "$H" teardown "$S" >/dev/null 2>&1; echo "teardown rc=$?"
  rm -rf "$LAB" "$CFGDIR"
}
trap cleanup EXIT
"$H" provision "$S" || exit 1
P=$LAB/projects/demo; mkdir -p "$P"
git -C "$P" init -q -b main; echo demo > "$P/README.md"; git -C "$P" add .; git -C "$P" -c user.name=t -c user.email=t@e commit -qm init
git clone -q --bare "$P" "$P.origin.git"; git -C "$P" remote add origin "file://$P.origin.git"
ID=democwd
mkdir -p "$LAB/data/$ID"
cat > "$LAB/data/$ID/brief.md" <<B
# Task
## Captain's intent
Reply with the single word READY and then stop. Do not edit any files.

## Firstmate spec
Reply READY. Make no changes.
B
FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" $ID "$P" --mode local-only --yolo off --harness claude --backend herdr 2>&1 | tail -15
echo "--- meta"; cat "$LAB/state/$ID.meta" | grep -E '^(worktree|herdr_pane_id|herdr_session|backend)='
WT=$(grep '^worktree=' "$LAB/state/$ID.meta" | cut -d= -f2-)
PANE=$(grep '^herdr_pane_id=' "$LAB/state/$ID.meta" | cut -d= -f2-)
for i in $(seq 1 60); do
  st=$("$H" run "$S" pane get "$PANE" | jq -r '.result.pane.agent_status // .result.pane.agent_state // empty'); [ "$st" = idle ] && break; sleep 3; done
echo "--- before restart (agent status: $st)"
"$H" run "$S" pane get "$PANE" | jq -c '.result.pane | {cwd, foreground_cwd}'
echo "worktree=$WT"
"$H" stop "$S" >/dev/null || echo STOPFAIL
SJ=$(ls -d ~/.config/herdr/sessions/"$S"/session.json "$CFGDIR"/sessions/"$S"/session.json 2>/dev/null | head -1)
echo "--- saved session.json ($SJ)"
[ -n "$SJ" ] && jq -c '[.. | objects | select(.agent_session? != null)] | map({cwd, agent_session})' "$SJ"
"$H" provision "$S" >/dev/null || echo PROVFAIL
sleep 15
echo "--- after restart"
"$H" run "$S" pane get "$PANE" | jq -c '.result.pane | {cwd, foreground_cwd, agent_status}'
"$H" run "$S" pane process-info --pane "$PANE" | jq -c '.' | head -c 1500; echo
for pid in $(pgrep -f 'claude --resume'); do
  c=$(readlink /proc/$pid/cwd); case "$c" in "$LAB"*|*treehouse*demo*) echo "resumed pid=$pid cmd=$(tr '\0' ' ' < /proc/$pid/cmdline) cwd=$c";; esac
done
echo "--- teardown task"
FM_HOME="$LAB" "$ROOT/bin/fm-teardown.sh" $ID --force 2>&1 | tail -5; echo "teardown task rc=${PIPESTATUS[0]}"
echo "--- leases held by $ID after teardown"
(cd "$P" && treehouse status --json | jq -r --arg id $ID '[.[] | select(.lease_holder == $id) | .path] | length')
