#!/usr/bin/env bash
# Live scenario: real Claude crewmate through fm-spawn --backend herdr, lab restart, check resumed cwd.
set -u
ROOT=$1 EV=$2
. "$ROOT/tests/herdr-test-safety.sh"; herdr_forget_inherited_pane
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
S=$("$ROOT/bin/fm-herdr-lab.sh" name claude-cwd)
sed 's/^resume_agents_on_restore = false/resume_agents_on_restore = true/' "$HOME/.config/herdr/config.toml" > "$LAB/herdr-config.toml"
export HERDR_CONFIG_PATH="$LAB/herdr-config.toml"
EV="$EV/${TAG:-branch}"; mkdir -p "$EV"
log() { printf '%s\n' "$*" | tee -a "$EV/claude-restart-transcript.txt"; }
: > "$EV/claude-restart-transcript.txt"
cleanup() {
  [ -n "${WT:-}" ] && (FM_HOME="$LAB" HERDR_SESSION="$S" "$ROOT/bin/fm-teardown.sh" cwdtask >>"$EV/claude-restart-transcript.txt" 2>&1 || true)
  "$ROOT/bin/fm-herdr-lab.sh" teardown "$S" >/dev/null 2>&1 || true
  [ -n "${WT:-}" ] && treehouse return --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT
lab() { "$ROOT/bin/fm-herdr-lab.sh" run "$S" "$@"; }
P="$LAB/projects/demo"; mkdir -p "$P"
git -C "$P" init -q; echo '# demo' > "$P/README.md"; git -C "$P" add .; git -C "$P" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$P" "$LAB/demo.origin.git"; git -C "$P" remote add origin "file://$LAB/demo.origin.git"
mkdir -p "$LAB/data/cwdtask"; printf '# Task\n## Captain'"'"'s intent\nLab fixture. Reply only with the single word READY and then stop. Do not run any tools.\n\n## Firstmate spec\nReply READY.\n' > "$LAB/data/cwdtask/brief.md"
"$ROOT/bin/fm-herdr-lab.sh" provision "$S" || { log "provision failed"; exit 1; }
log "lab home=$LAB session=$S project=$P resume=$(grep ^resume_agents_on_restore $HERDR_CONFIG_PATH)"
export HERDR_SESSION="$S"
FM_SPAWN_NO_GUARD=1 FM_HOME="$LAB" "$ROOT/bin/fm-spawn.sh" cwdtask "$P" --harness claude --mode local-only --yolo off --backend herdr >"$EV/claude-spawn.out" 2>"$EV/claude-spawn.err"
log "spawn exit=$?"
META="$LAB/state/cwdtask.meta"; [ -f "$META" ] || { log "no meta"; cat "$EV/claude-spawn.err"; exit 1; }
WT=$(grep '^worktree=' "$META" | cut -d= -f2-); PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
log "recorded worktree=$WT pane=$PANE"
for i in $(seq 1 90); do st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.. | .status? // empty' | head -1); case "$st" in idle|done|waiting) break;; esac; sleep 2; done
log "agent status before restart: $st"; lab agent get "$PANE" > "$EV/claude-before-agent.json" 2>&1; lab pane read "$PANE" --source recent --lines 60 > "$EV/claude-before-restart-screen.txt" 2>&1
lab pane get "$PANE" | jq -c '.result.pane | {cwd, foreground_cwd}' | sed 's/^/before restart pane: /' | tee -a "$EV/claude-restart-transcript.txt"
SJ="$HOME/.config/herdr/sessions/$S/session.json"
"$ROOT/bin/fm-herdr-lab.sh" stop "$S" >/dev/null || { log "stop failed"; exit 1; }
jq -c '[.. | objects | select(.agent_session? != null)] | map({cwd, agent_session})' "$SJ" | sed 's/^/saved panes: /' | tee -a "$EV/claude-restart-transcript.txt"
"$ROOT/bin/fm-herdr-lab.sh" provision "$S" || { log "reprovision failed"; exit 1; }
for i in $(seq 1 30); do lab pane process-info --pane "$PANE" 2>/dev/null | grep -q claude && break; sleep 2; done
cp -r "$HOME/.config/herdr/sessions/$S" "$EV/lab-session-after-restart" 2>/dev/null
lab pane get "$PANE" | jq -c '.result.pane | {cwd, foreground_cwd}' | sed 's/^/after restart pane: /' | tee -a "$EV/claude-restart-transcript.txt"
PI=$(lab pane process-info --pane "$PANE" 2>/dev/null); echo "$PI" > "$EV/claude-after-process-info.json"
for pid in $(echo "$PI" | jq -r '.. | .pid? // empty' | sort -u); do
  c=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null); case "$c" in *claude*) log "resumed agent pid=$pid cmd=$c"; log "resumed agent cwd=$(readlink /proc/$pid/cwd)";; esac
done
for i in $(seq 1 30); do st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.status // empty'); [ -n "$st" ] && break; sleep 2; done
lab agent get "$PANE" > "$EV/claude-after-agent.json" 2>&1
lab pane read "$PANE" --source recent --lines 80 > "$EV/claude-after-restart-screen.txt" 2>&1 || lab pane read "$PANE" > "$EV/claude-after-restart-screen.txt" 2>&1
if grep -qiE "external CLAUDE.md|\.envrc is blocked" "$EV/claude-after-restart-screen.txt"; then log "SCREEN: import/direnv prompt present"; else log "SCREEN: no external-import or direnv prompt"; fi
