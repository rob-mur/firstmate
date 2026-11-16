#!/usr/bin/env bash
# fm-board-refresh.sh - keep an open bearings board in step with fleet state.
#
# Usage:
#   fm-board-refresh.sh [--force]
#   fm-board-refresh.sh --kick
#
# Regenerates the board payload (bin/fm-bearings-board-payload.sh, which applies
# the captain's stored priority) and, only when it differs from the last one
# built, rebuilds the existing board through `bin/fm-bearings-board.sh build
# --no-reopen`, so the open Lavish session shows the new fleet state at the same
# URL and a refresh never opens a browser tab or revives a session the captain
# ended. A rebuild never forces a reload of the open page or touches what the
# captain is typing; new board code reaches it once they stop working in it
# (bin/fm-bearings-board.sh owns how).
#
# --kick records a refresh request and starts this script detached, returning at
# once. In a secondmate home with no board it forwards the request once to the
# parent home named by a local-route .fm-secondmate-parent record, because the
# parent board shows that home's decisions; any other home without a board makes
# it a no-op. It is the hook for every fleet state change: each wake appended to
# the queue (bin/fm-wake-lib.sh: worker status, PR and MR state, checks,
# heartbeats), each captain hold placed, answered, or reconciled, and each board
# reconcile request recorded (bin/fm-captain-hold.sh), each steer recorded in a
# task inbox (bin/fm-send.sh), each task cleanup (bin/fm-teardown.sh), and each
# main wake drain (bin/fm-wake-drain.sh).
#
# A board is built only by its own home's code. When $FM_HOME carries its own
# bin/fm-board-refresh.sh and that is not this file, this script runs that one
# in its place, before anything else. A kick forwarded from a secondmate on
# another release, or any caller from another code root, therefore never
# rewrites the board page with another template: Lavish reloads the board, and
# every page frame in it, each time that page file changes. A refresher loop an
# older code root already started keeps the lock, and serves every later request
# with its own code, for as long as requests keep coming. So when this is the
# home's own code and the lock is held, it looks (Linux, through /proc) for a
# refresher of this same home, by its state directory, that runs another file;
# it waits until that one is between passes (its only child a sleep, at most
# FM_BOARD_REFRESH_LOCK_TTL seconds), stops it and that sleep with SIGTERM (its
# exit trap frees the lock), and carries on in its place. A refresher of another
# home, one running this same file, or a kick is never touched.
#
# Requests are never dropped, only coalesced:
#   - each request marks state/.board-refresh.pending; a mkdir lock under state/
#     lets one refresher run at a time, and it keeps rebuilding until no request
#     is left, so a request that lands while a rebuild runs gets its own pass.
#   - a pass starts FM_BOARD_REFRESH_DEBOUNCE seconds (default 3) after the
#     request it serves and at least FM_BOARD_REFRESH_MIN_INTERVAL seconds
#     (default 60) after the previous pass, so a burst of events causes one
#     rebuild. --force skips both waits and both change checks below.
#   - a stale lock older than FM_BOARD_REFRESH_LOCK_TTL seconds (default 300) is
#     reclaimed; a running refresher refreshes the lock while it waits.
#
# A pass costs a full fleet snapshot, so it is skipped when nobody can see it or
# nothing it reads has moved. Each skip leaves the request consumed:
#   - no viewer: while Lavish records the board's session as ended
#     (`fm-bearings-board.sh ended`, a file read that never calls the server)
#     there is no pass at all, even with --force. A rebuild could not reach an
#     ended session anyway, and reopening it (`fm-bearings-board.sh url`, or a
#     /bearings build) brings the board current: `url` kicks a refresh after it
#     reopens, and the inputs check below sees everything that moved meanwhile.
#   - no lavish-axi: a refresher started by a caller whose PATH lacks lavish-axi
#     appends the directory where an earlier refresher found it (recorded in
#     state/.board-refresh.lavish-dir); with neither, it logs and stops before
#     building the payload, recording nothing, so the next request retries.
#   - no input changed: the pass first takes a signature of every local file the
#     payload reads (this home's task records, statuses, steering inboxes,
#     reconcile requests, board answers, merge authorities, away-mode records,
#     backlog, stored priority, secondmate registry, reports, contribution
#     records and their config, the board code and template, and each local
#     secondmate home's task records, statuses, inboxes, reconcile requests,
#     and summary less its generation, observation and expiry stamps), by
#     path, size, and mtime, so a deleted file counts as a change. The payload
#     also reads live inputs no file shows (worker liveness, PR and MR state on
#     the forge, and the date), so a matching signature skips the pass only
#     while it is younger than FM_BOARD_REFRESH_MAX_AGE seconds (default 300);
#     state/.board-refresh.inputs holds it.
#   - the fingerprint covers the payload, less its `generated` stamp, and the
#     board template, so updated board code is installed on the next pass even
#     when fleet state has not moved; an attempt, even a failed one, records it
#     and the input signature, so a refused payload is not retried until fleet
#     state or the template changes again or the signature ages out.
# A failed build is logged to state/.board-refresh.log (last 20 lines kept, a
# repeated skip logged once) and never changes the caller's exit status beyond
# this script's own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
if [ -x "$FM_HOME/bin/fm-board-refresh.sh" ] && [ ! "$FM_HOME/bin/fm-board-refresh.sh" -ef "${BASH_SOURCE[0]}" ]; then
  exec "$FM_HOME/bin/fm-board-refresh.sh" "$@"
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BOARD="$FM_HOME/.lavish/bearings-board.html"
LOCK="$STATE/.board-refresh.lock"
PENDING="$STATE/.board-refresh.pending"
STAMP="$STATE/.board-refresh.last"
SUM="$STATE/.board-refresh.sum"
INPUTS="$STATE/.board-refresh.inputs"
LAVISH_DIR="$STATE/.board-refresh.lavish-dir"
LOG="$STATE/.board-refresh.log"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DEBOUNCE="${FM_BOARD_REFRESH_DEBOUNCE:-3}"
MIN_INTERVAL="${FM_BOARD_REFRESH_MIN_INTERVAL:-60}"
MAX_AGE="${FM_BOARD_REFRESH_MAX_AGE:-300}"
LOCK_TTL="${FM_BOARD_REFRESH_LOCK_TTL:-300}"
TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
# FM_BOARD_REFRESH_PAYLOAD replaces the payload command (tests only).
PAYLOAD="${FM_BOARD_REFRESH_PAYLOAD:-$SCRIPT_DIR/fm-bearings-board-payload.sh}"

# A secondmate home has no board of its own, but its decisions show on the
# main board, so its kick goes to the parent home it is bound to over a local
# route (bin/fm-secondmate-parent-lib.sh), once and never further up.
forward_kick_to_parent() {
  local record="$FM_HOME/.fm-secondmate-parent"
  [ -z "${FM_BOARD_REFRESH_FORWARDED:-}" ] || return 0
  [ -f "$record" ] || return 0
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-parent-lib.sh" 2>/dev/null || return 0
  fm_secondmate_parent_record_parse "$record" 2>/dev/null || return 0
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 0
  [ "$FM_SECONDMATE_PARENT_HOME" != "$FM_HOME" ] || return 0
  [ -f "$FM_SECONDMATE_PARENT_HOME/.lavish/bearings-board.html" ] || return 0
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$FM_SECONDMATE_PARENT_HOME" FM_BOARD_REFRESH_FORWARDED=1 \
    "$0" --kick >/dev/null 2>&1 || true
}

FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  --kick)
    if [ ! -f "$BOARD" ]; then
      forward_kick_to_parent
      exit 0
    fi
    mkdir -p "$STATE" 2>/dev/null && : >"$PENDING" 2>/dev/null || exit 0
    ( nohup "$0" >/dev/null 2>&1 </dev/null & ) 2>/dev/null || true
    exit 0
    ;;
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  '') ;;
  *) echo "fm-board-refresh: unknown argument: $1" >&2; exit 2 ;;
esac

[ -f "$BOARD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
mkdir -p "$STATE" || exit 0
: >"$PENDING" || exit 0

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

take_lock() {
  mkdir "$LOCK" 2>/dev/null && return 0
  [ $(($(date +%s) - $(mtime "$LOCK"))) -gt "$LOCK_TTL" ] || return 1
  rmdir "$LOCK" 2>/dev/null || return 1
  mkdir "$LOCK" 2>/dev/null
}

log() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"
  tail -n 20 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
}

# A skip repeats on every request, so it is logged only when it is news.
log_once() {
  local last
  last=$(tail -n 1 "$LOG" 2>/dev/null)
  [ "${last#* }" != "$*" ] || return 0
  log "$@"
}

# Make lavish-axi reachable for the build, or say it is not. A detached
# refresher inherits the PATH of whatever kicked it, which may lack the tool.
# shellcheck source=bin/fm-lavish-path-lib.sh
. "$SCRIPT_DIR/fm-lavish-path-lib.sh"
lavish_reachable() { fm_lavish_reachable "$LAVISH_DIR"; }

# A digest of every local file the payload reads; see the header for the list.
input_signature() {
  perl -e '
    use strict; use warnings;
    use Digest::MD5; use File::Glob qw(bsd_glob); use JSON::PP; use Time::HiRes ();
    my ($home, $state, $data, $config, $code, $template) = @ARGV;
    # A summary is rewritten on a timer with fresh observation stamps and a
    # fresh expiry; the expiry is time, which the maximum age already covers.
    my %stamp = map { $_ => 1 } qw(generated generated_epoch observed_at age_seconds valid_until);
    sub unstamped {
      my $v = shift;
      return { map { $stamp{$_} ? () : ($_ => unstamped($v->{$_})) } keys %$v } if ref $v eq "HASH";
      return [ map { unstamped($_) } @$v ] if ref $v eq "ARRAY";
      return $v;
    }
    my $md5 = Digest::MD5->new;
    sub esc { my $p = shift; $p =~ s/([\\\[\]*?{}~])/\\$1/g; $p }
    sub add_files {
      for my $f (@_) {
        my @s = Time::HiRes::stat($f) or next;
        $md5->add("$f\0$s[7]\0$s[9]\n");
      }
    }
    sub add_globs { my $base = esc(shift); add_files(sort map { bsd_glob("$base/$_") } @_) }
    sub add_tasks {
      add_globs(shift, qw(*.meta *.status *.inbox/*.msg *.inbox/handled/*.msg
                          reconcile-requests/*.request));
    }
    add_tasks($state);
    add_globs($state, qw(procevent-inbox/lavish-*.result *.merge-authority
                         .afk .afk-contract .afk-return-catchup));
    add_globs($data, qw(backlog.md board-priority.txt secondmates.md
                        */report.md */contributions.json));
    add_globs($config, "contribution-review-bots");
    add_globs($code, "*");
    add_files($template);
    my (%homes, $fh);
    if (open $fh, "<", "$data/secondmates.md") {
      while (<$fh>) { $homes{$1} = 1 while /\(home: ([^;)]+)/g }
      close $fh;
    }
    for my $meta (bsd_glob(esc($state) . "/*.meta")) {
      open $fh, "<", $meta or next;
      my %kv = map { /^([^=]+)=(.*)$/ ? ($1, $2) : () } <$fh>;
      close $fh;
      $homes{$kv{home}} = 1 if ($kv{kind} // "") eq "secondmate" && defined $kv{home};
    }
    for my $h (sort keys %homes) {
      next if $h eq $home || ! -d "$h/state";
      add_tasks("$h/state");
      if (open $fh, "<", "$h/state/home-summary.json") {
        local $/;
        my $summary = <$fh> // "";
        close $fh;
        my $json = JSON::PP->new->canonical;
        my $tree = eval { $json->decode($summary) };
        $summary = $json->encode(unstamped($tree)) if ref $tree;
        $md5->add("$h\0summary\0$summary\n");
      }
    }
    print $md5->hexdigest, "\n";
  ' "$FM_HOME" "$STATE" "$DATA" "$CONFIG" "$SCRIPT_DIR" "$TEMPLATE"
}

inputs_unchanged() {  # <signature>
  [ -n "$1" ] && [ -f "$INPUTS" ] && [ "$(cat "$INPUTS")" = "$1" ] \
    && [ $(($(date +%s) - $(mtime "$INPUTS"))) -lt "$MAX_AGE" ]
}

# Sleep until <epoch>, keeping the lock fresh so a long wait is never reclaimed.
wait_until() {  # <epoch>
  while [ "$(date +%s)" -lt "$1" ]; do
    touch "$LOCK" 2>/dev/null || true
    sleep 1
  done
}

# One pass: consume the pending request, then rebuild if the payload moved.
refresh_once() {
  local tmp sum out inputs
  if [ "$FORCE" != 1 ]; then
    wait_until $(($(mtime "$PENDING") + DEBOUNCE))
    [ ! -f "$STAMP" ] || wait_until $(($(mtime "$STAMP") + MIN_INTERVAL))
  fi
  rm -f "$PENDING"
  if "$SCRIPT_DIR/fm-bearings-board.sh" ended >/dev/null 2>&1; then
    log_once "skipped: the board session is ended"
    return 0
  fi
  if ! lavish_reachable; then
    log_once "skipped: lavish-axi is not on PATH and no earlier refresh recorded where it is"
    return 1
  fi
  inputs=$(input_signature 2>/dev/null) || inputs=
  [ "$FORCE" = 1 ] || ! inputs_unchanged "$inputs" || return 0
  : >"$STAMP"
  tmp=$(mktemp "$STATE/.board-refresh.payload.XXXXXX") || return 1
  if ! "$PAYLOAD" >"$tmp" 2>>"$LOG"; then
    rm -f "$tmp"
    [ -z "$inputs" ] || printf '%s\n' "$inputs" >"$INPUTS"
    log "payload generation failed"
    return 1
  fi
  [ -z "$inputs" ] || printf '%s\n' "$inputs" >"$INPUTS"
  sum=$( { jq -S -c 'del(.generated)' "$tmp"; cksum < "$TEMPLATE" 2>/dev/null; } \
    | cksum | awk '{print $1 "-" $2}')
  if [ "$FORCE" != 1 ] && [ -f "$SUM" ] && [ "$(cat "$SUM")" = "$sum" ]; then
    rm -f "$tmp"
    return 0
  fi
  printf '%s\n' "$sum" >"$SUM"
  if out=$("$SCRIPT_DIR/fm-bearings-board.sh" build --no-reopen "$tmp" 2>&1); then
    rm -f "$tmp"
    log "rebuilt board"
    return 0
  fi
  rm -f "$tmp"
  log "board build refused: $(printf '%s' "$out" | tail -n 1)"
  return 1
}

# The script path a process runs, when it is a refresher pass (not a kick).
refresher_script() {  # <pid>
  local arg script='' cwd
  while IFS= read -r -d '' arg; do
    case "$arg" in
      --kick) return 1 ;;
      */fm-board-refresh.sh|fm-board-refresh.sh) [ -n "$script" ] || script=$arg ;;
    esac
  done < "/proc/$1/cmdline" 2>/dev/null
  [ -n "$script" ] || return 1
  case "$script" in
    /*) ;;
    *) cwd=$(readlink "/proc/$1/cwd" 2>/dev/null) || return 1; script="$cwd/$script" ;;
  esac
  printf '%s\n' "$script"
}

# One variable from a process's starting environment.
proc_env() {  # <pid> <name>
  local kv
  while IFS= read -r -d '' kv; do
    case "$kv" in "$2="*) printf '%s\n' "${kv#*=}"; return 0 ;; esac
  done < "/proc/$1/environ" 2>/dev/null
  return 1
}

replace_foreign_refresher() {
  local pid script home state kids kid comm busy deadline
  [ -d /proc/self ] && [ -d "$LOCK" ] || return 0
  [ "$FM_HOME/bin/fm-board-refresh.sh" -ef "${BASH_SOURCE[0]}" ] || return 0
  for pid in /proc/[0-9]*; do
    pid=${pid#/proc/}
    [ "$pid" != "$$" ] || continue
    script=$(refresher_script "$pid") || continue
    [ ! "$script" -ef "${BASH_SOURCE[0]}" ] || continue
    home=$(proc_env "$pid" FM_HOME) || home=$(cd "$(dirname "$script")/.." 2>/dev/null && pwd) || continue
    state=$(proc_env "$pid" FM_STATE_OVERRIDE) || state="$home/state"
    [ "$state" -ef "$STATE" ] || continue
    deadline=$(($(date +%s) + LOCK_TTL))
    while :; do
      kids=$(pgrep -P "$pid" 2>/dev/null)
      busy=0
      for kid in $kids; do
        comm=$(cat "/proc/$kid/comm" 2>/dev/null) || continue
        [ "$comm" = sleep ] || busy=1
      done
      [ "$busy" = 1 ] || break
      if [ "$(date +%s)" -ge "$deadline" ]; then
        log "left a busy refresher from $(dirname "$(dirname "$script")") (pid $pid) running"
        return 0
      fi
      sleep 0.2
    done
    # shellcheck disable=SC2086
    kill -TERM "$pid" $kids 2>/dev/null || continue
    deadline=$(($(date +%s) + 10))
    while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 0.1; done
    log "replaced a refresher from $(dirname "$(dirname "$script")") (pid $pid)"
  done
}

replace_foreign_refresher

rc=0
# Re-check after releasing the lock: a request that arrived just as the last
# pass finished found the lock held and left its mark for this loop to serve.
while [ -f "$PENDING" ] && take_lock; do
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
  while [ -f "$PENDING" ]; do
    refresh_once || rc=1
    FORCE=0
  done
  rmdir "$LOCK" 2>/dev/null
  trap - EXIT
done
exit "$rc"
