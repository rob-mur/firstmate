#!/usr/bin/env bash
# Live: real Claude crewmate on Herdr lab, restart with resume_agents_on_restore=true,
# verify the resumed claude runs in the worker's worktree, not the project checkout.
set -u
ROOT=$1; E=$2
cd "$ROOT"
LABH=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LABH" >/dev/null
SESSION=$(bin/fm-herdr-lab.sh name claude-cwd)
CFG="$LABH/herdr-config.toml"
sed 's/^resume_agents_on_restore = false/resume_agents_on_restore = true/' ~/.config/herdr/config.toml > "$CFG"
grep -n 'resume_agents_on_restore' "$CFG"
export HERDR_CONFIG_PATH="$CFG"
ID=cwdlive
PROJ="$LABH/projects/demo"
WT=
cleanup() {
  [ -n "$WT" ] && treehouse return --force "$WT" >/dev/null 2>&1
  bin/fm-herdr-lab.sh teardown "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$LABH" "$PROJ.origin.git"
}
trap cleanup EXIT
mkdir -p "$PROJ" "$LABH/data/$ID"
git -C "$PROJ" init -q; echo '# demo' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=T -c user.email=t@example.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
touch "$LABH/state/.last-watcher-beat"
cat > "$LABH/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Live cwd restore check. Reply with the single word READY, run no tools, change nothing.

## Firstmate spec
Reply READY only.
EOF
bin/fm-herdr-lab.sh provision "$SESSION" || exit 1
lab() { bin/fm-herdr-lab.sh run "$SESSION" "$@"; }
echo "== spawn real claude crewmate (session $SESSION, home $LABH)"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  HERDR_SESSION="$SESSION" FM_HOME="$LABH" FM_SPAWN_NO_GUARD=1 \
  bin/fm-spawn.sh "$ID" "$PROJ" --mode local-only --yolo off --harness claude --backend herdr > "$E/claude-spawn.out" 2>&1
echo "spawn exit=$?"; tail -5 "$E/claude-spawn.out"
META="$LABH/state/$ID.meta"
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
echo "recorded worktree=$WT pane=$PANE project=$PROJ"
# wait for claude to register an agent session and go idle
for i in $(seq 1 90); do
  st=$(lab pane get "$PANE" 2>/dev/null | jq -r '.result.pane.agent_status // .result.pane.state // empty')
  as=$(lab pane get "$PANE" 2>/dev/null | jq -c '.result.pane | {cwd, foreground_cwd, agent, agent_status}')
  [ $((i % 10)) -eq 0 ] && echo "t=$((i*2))s $as"
  case "$as" in *'"agent":"claude"'*'"agent_status":"idle"'*|*'"agent_status":"done"'*) break;; esac
  sleep 2
done
echo "== before restart"; lab pane get "$PANE" | jq -c '.result.pane | {pane_id, cwd, foreground_cwd, agent, agent_status}'
lab pane read "$PANE" --lines 15 2>/dev/null | tail -15 || true
bin/fm-herdr-lab.sh stop "$SESSION" >/dev/null || { echo "stop failed"; exit 1; }
SJ=$(ls -d ~/.config/herdr/sessions/"$SESSION"/session.json 2>/dev/null || true)
echo "== saved session.json ($SJ)"
[ -n "$SJ" ] && jq -c '[.. | objects | select(.agent_session? != null)] | map({cwd, agent_session})' "$SJ" | sed "s#$LABH#<home>#g"
bin/fm-herdr-lab.sh provision "$SESSION" || exit 1
echo "== after restart (resume_agents_on_restore=true)"
sleep 15
P=$(lab pane get "$PANE" 2>/dev/null | jq -c '.result.pane | {pane_id, cwd, foreground_cwd, agent, agent_status}'); echo "$P"
lab pane process-info --pane "$PANE" 2>/dev/null | tee "$E/claude-process-info.json" | jq -c '.' | cut -c1-600
for pid in $(pgrep -f "claude --resume" ); do
  c=$(readlink /proc/$pid/cwd 2>/dev/null); case "$c" in "$LABH"*|*"demo"*) echo "resumed pid=$pid cmd=$(tr '\0' ' ' < /proc/$pid/cmdline | cut -c1-80) cwd=$c";; esac
done
RC=$(printf '%s' "$P" | jq -r '.cwd')
if [ "$(cd "$RC" && pwd -P)" = "$(cd "$WT" && pwd -P)" ]; then echo "RESULT: PASS restored pane cwd is the worktree"; else echo "RESULT: FAIL restored pane cwd=$RC worktree=$WT"; fi
lab pane read "$PANE" --lines 25 2>/dev/null | tail -25 || true
echo "== teardown"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS HERDR_SESSION="$SESSION" FM_HOME="$LABH" bin/fm-teardown.sh "$ID" > "$E/claude-teardown.out" 2>&1; echo "teardown exit=$?"; tail -3 "$E/claude-teardown.out"
(cd "$PROJ" && treehouse status --json 2>/dev/null | jq -c "[.[] | select(.lease_holder == \"$ID\") | .path]") | sed 's/^/leased-to-id after teardown: /'
