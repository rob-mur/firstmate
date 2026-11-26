#!/usr/bin/env bash
# Block until the CI for one pull request, merge request, commit, or Forgejo
# Actions run finishes, then print one verdict and exit, so a worker spends one tool call on a CI wait
# instead of a polling loop, sleep, or a scheduled wake-up.
#
# Usage:
#   fm-ci-wait.sh [--timeout <secs>] [--tail <lines>] <pr-url>
#   fm-ci-wait.sh [--timeout <secs>] [--tail <lines>] --commit <sha> <repo-url>
#   fm-ci-wait.sh [--timeout <secs>] [--tail <lines>] <forgejo-run-url>
#   fm-ci-wait.sh [--timeout <secs>] [--tail <lines>] [--workflow <file>] --run <sha|branch> <repo-url>
#
# <pr-url> is a canonical GitHub pull request, Forgejo/Gitea pull request, or
# GitLab merge request URL, parsed by fm_pr_url_parse in bin/fm-pr-lib.sh.
# <repo-url> is https://<host>/<owner>/<repo> on GitHub (github.com or a host
# named in config/github-hosts) or on a Forgejo host with exactly one tea login;
# GitLab commits are not supported because the delegated script waits on merge
# requests only.
#
# Forgejo Actions runs (Forgejo only): <forgejo-run-url> is the run page
# https://<host>/<owner>/<repo>/actions/runs/<n> and waits on that one run.
# --run waits on every Actions run of a commit: a 7-40 character hex sha, or a
# branch name whose head is re-read on every poll so a push during the wait is
# followed; --workflow (for example release.yml) keeps only that workflow's
# runs. A run mode also covers workflow_dispatch runs, such as a release or a
# promotion, which post no commit status and so are invisible to --commit.
# --run counts every run of the commit, including finished ones from an earlier
# dispatch, so to wait on a fresh dispatch of an already-run commit pass the
# new run's URL instead.
#
# --timeout defaults to 540 seconds, under the ten-minute cap most agent shells
# put on one command; on a timeout run the same command again. --tail (default
# 40) bounds how many log lines each failed job prints.
#
# Output: the first line is the verdict, one of
#   passed: <target> (<n> checks)
#   failed: <target> (<k> of <n> checks failed)
#   timed out: <target> after <secs>s (<what is still pending>)
#   error: <target>: <why>
# and a failed verdict is followed, per failed job, by "--- <name> <link>" and,
# for the first five jobs whose forge serves a log, the last --tail lines of it.
#
# Exit codes: 0 passed, 1 failed, 2 usage, 3 timed out (including no CI having
# started yet), 4 the CI state could not be read three polls in a row or the
# forge tooling is missing.
#
# Per forge:
#   - GitHub: `gh pr checks` for a PR (its buckets pass, fail, pending,
#     skipping, cancel; cancel counts as failed), the commit's check runs and
#     combined status for a commit. A failed GitHub Actions job's log comes from
#     `gh run view --job <id> --log-failed`.
#   - Forgejo: the commit's combined status through `tea api`, so the credential
#     never leaves tea; a PR re-reads its head commit on every poll so a push
#     during the wait is followed. A failed Actions job's log comes from the
#     Actions jobs API. A warning status counts as passed.
#   - Forgejo runs: the Actions runs API; a run counts as one check, and a failed
#     run prints each of its failed jobs with a log tail.
#   - GitLab: delegated to the forge-gitlab skill's ci-wait script
#     (FM_CI_WAIT_GITLAB, else ~/.agents/skills or ~/.claude/skills), which owns
#     the wait; this script adds only the failed-job log tails.
# Cloud Build and other GCP-run pipelines are not supported.
#
# Polling backs off from FM_CI_WAIT_POLL_MIN (default 10) seconds, doubling to
# FM_CI_WAIT_POLL_MAX (default 60), and never sleeps past the deadline.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '6,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,3\}//' >&2
  exit 2
}

TIMEOUT=540
TAIL=40
COMMIT=
RUN_REF=
WORKFLOW=
while [ $# -gt 0 ]; do
  case $1 in
    --timeout) [ $# -ge 2 ] || usage; TIMEOUT=$2; shift 2 ;;
    --tail) [ $# -ge 2 ] || usage; TAIL=$2; shift 2 ;;
    --commit) [ $# -ge 2 ] || usage; COMMIT=$2; shift 2 ;;
    --run) [ $# -ge 2 ] || usage; RUN_REF=$2; shift 2 ;;
    --workflow) [ $# -ge 2 ] || usage; WORKFLOW=$2; shift 2 ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) echo "fm-ci-wait: unknown option $1" >&2; usage ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || usage
TARGET=$1
case $TIMEOUT in ''|*[!0-9]*) echo "fm-ci-wait: --timeout must be whole seconds" >&2; exit 2 ;; esac
case $TAIL in ''|*[!0-9]*) echo "fm-ci-wait: --tail must be a line count" >&2; exit 2 ;; esac
POLL_MIN=${FM_CI_WAIT_POLL_MIN:-10}
POLL_MAX=${FM_CI_WAIT_POLL_MAX:-60}

die_error() {  # <why>
  printf 'error: %s: %s\n' "$TARGET" "$1"
  exit 4
}

command -v jq >/dev/null 2>&1 || die_error "jq is not installed"

PROVIDER='' HOST='' NUMBER='' RPATH='' RUN_INDEX='' ROWS=''
[ -z "$COMMIT" ] || [ -z "$RUN_REF" ] || { echo "fm-ci-wait: --commit and --run are exclusive" >&2; exit 2; }
[ -z "$WORKFLOW" ] || [ -n "$RUN_REF" ] || { echo "fm-ci-wait: --workflow needs --run" >&2; exit 2; }
[[ $WORKFLOW =~ ^[A-Za-z0-9._-]*$ ]] || { echo "fm-ci-wait: --workflow needs a workflow file name such as release.yml" >&2; exit 2; }
run_re='^https://([a-z0-9.-]+)/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/actions/runs/([0-9]+)/?$'
repo_re='^https://([a-z0-9.-]+)/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/?$'
forgejo_host_or_usage() {
  fm_pr_forgejo_login "$HOST" >/dev/null && return 0
  echo "fm-ci-wait: Actions run waits need a Forgejo host with exactly one tea login; $HOST is not one" >&2
  exit 2
}
if [ -n "$RUN_REF" ]; then
  [[ $RUN_REF =~ ^[A-Za-z0-9._/-]+$ ]] && [[ $RUN_REF != -* ]] || { echo "fm-ci-wait: --run needs a commit sha or a branch name" >&2; exit 2; }
  [[ $TARGET =~ $repo_re ]] || { echo "fm-ci-wait: --run needs a repository URL https://<host>/<owner>/<repo>" >&2; exit 2; }
  HOST=${BASH_REMATCH[1]}
  RPATH=${BASH_REMATCH[2]}/${BASH_REMATCH[3]%.git}
  forgejo_host_or_usage
  PROVIDER=forgejo ROWS=forgejo_run_rows
  TARGET="${TARGET%/}@$RUN_REF${WORKFLOW:+ ($WORKFLOW)}"
elif [[ $TARGET =~ $run_re ]]; then
  HOST=${BASH_REMATCH[1]}
  RPATH=${BASH_REMATCH[2]}/${BASH_REMATCH[3]}
  RUN_INDEX=${BASH_REMATCH[4]}
  forgejo_host_or_usage
  PROVIDER=forgejo ROWS=forgejo_run_rows
elif [ -n "$COMMIT" ]; then
  [[ $COMMIT =~ ^[0-9a-f]{7,64}$ ]] || { echo "fm-ci-wait: --commit needs a hex commit sha" >&2; exit 2; }
  [[ $TARGET =~ $repo_re ]] || { echo "fm-ci-wait: --commit needs a repository URL https://<host>/<owner>/<repo>" >&2; exit 2; }
  HOST=${BASH_REMATCH[1]}
  RPATH=${BASH_REMATCH[2]}/${BASH_REMATCH[3]%.git}
  if fm_github_host_allowed "$HOST"; then
    PROVIDER=github
  elif fm_pr_forgejo_login "$HOST" >/dev/null; then
    PROVIDER=forgejo
  else
    echo "fm-ci-wait: $HOST is neither a GitHub host this home names nor a Forgejo host with exactly one tea login" >&2
    exit 2
  fi
  TARGET="$TARGET@${COMMIT:0:12}"
else
  fm_pr_url_parse "$TARGET" || { echo "fm-ci-wait: not a supported PR or MR URL: $TARGET" >&2; exit 2; }
  PROVIDER=$FM_PR_PROVIDER HOST=$FM_PR_HOST RPATH=$FM_PR_PATH NUMBER=$FM_PR_NUMBER
  [ "$PROVIDER" != gerrit ] || { echo "fm-ci-wait: Gerrit changes have no forge CI to wait on" >&2; exit 2; }
fi
[ -n "$ROWS" ] || ROWS=${PROVIDER}_rows

START=$(date +%s)
DEADLINE=$((START + TIMEOUT))
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-ci-wait.XXXXXX") || die_error "could not create a temporary file"
trap 'rm -f "$ERR"' EXIT

# --- per-forge reads -------------------------------------------------------
# Each read prints one row per check, "bucket<TAB>name<TAB>link", where bucket
# is pass, fail, pending, or skip, and returns nonzero when the forge could not
# be read. No rows at all means no CI has reported yet.

github_rows() {
  fm_pr_github_host_export "$HOST"
  if [ -z "$COMMIT" ]; then
    local out
    if ! out=$(gh pr checks "$TARGET" --json name,bucket,link --jq \
        '.[] | [(if .bucket == "cancel" then "fail" elif .bucket == "skipping" then "skip" else .bucket end), .name, (.link // "")] | @tsv' 2>"$ERR"); then
      # gh reports "nothing reported" as an error, not as data (see
      # bin/fm-pr-state.sh); any other message is a real read failure.
      grep -q "^no checks reported on the '" "$ERR" && return 0
      return 1
    fi
    printf '%s\n' "$out" | sed '/^$/d'
    return 0
  fi
  gh api "repos/$RPATH/commits/$COMMIT/check-runs?per_page=100" --jq '
    .check_runs[] | [
      (if .status != "completed" then "pending"
       elif (.conclusion | IN("success", "neutral")) then "pass"
       elif .conclusion == "skipped" then "skip"
       else "fail" end),
      .name, (.html_url // "")] | @tsv' 2>"$ERR" || return 1
  gh api "repos/$RPATH/commits/$COMMIT/status" --jq '
    .statuses[] | [
      (if .state == "success" then "pass" elif .state == "pending" then "pending" else "fail" end),
      .context, (.target_url // "")] | @tsv' 2>"$ERR" || return 1
}

FORGEJO_LOGIN=
forgejo_api() {  # <api-path>; tea api prints an HTTP error body and exits 0
  [ -n "$FORGEJO_LOGIN" ] || FORGEJO_LOGIN=$(fm_pr_forgejo_login "$HOST") || return 1
  tea api --login "$FORGEJO_LOGIN" --repo "$RPATH" "$1" 2>"$ERR"
}

forgejo_rows() {
  local sha=$COMMIT json
  if [ -z "$sha" ]; then
    json=$(forgejo_api "/repos/{owner}/{repo}/pulls/$NUMBER") || return 1
    sha=$(printf '%s' "$json" | jq -er '.head.sha | strings' 2>/dev/null) || return 1
  fi
  json=$(forgejo_api "/repos/{owner}/{repo}/commits/$sha/status") || return 1
  printf '%s' "$json" | jq -r --arg base "https://$HOST" '
    if type == "object" and has("state") then
      (.statuses // [])[] | [
        (if .status == "success" or .status == "warning" then "pass"
         elif .status == "pending" then "pending" else "fail" end),
        .context,
        ((.target_url // "") | if startswith("/") then $base + . else . end)] | @tsv
    else error("not a combined status") end' 2>/dev/null
}

# --- Forgejo Actions runs --------------------------------------------------
# A run link and a status target_url carry the run's number in the repository
# (index_in_repo); the runs and jobs API wants the run's id, so resolve it with
# the run_number filter. Never list runs unfiltered: that list is unbounded.

forgejo_run_id() {  # <index_in_repo>
  forgejo_api "/repos/{owner}/{repo}/actions/runs?run_number=$1" \
    | jq -er --argjson n "$1" '[.workflow_runs[]? | select(.index_in_repo == $n)][0].id | numbers' 2>/dev/null
}

forgejo_jobs() {  # <run id>; one "id<TAB>status<TAB>name" row per job, ordered by id
  forgejo_api "/repos/{owner}/{repo}/actions/runs/$1/jobs" \
    | jq -er '(if type == "object" then .jobs else . end) | sort_by(.id)[] | [.id, .status, .name] | @tsv' 2>/dev/null
}

RUN_SHA=
forgejo_run_rows() {
  local json sha
  if [ -n "$RUN_INDEX" ]; then
    json=$(forgejo_api "/repos/{owner}/{repo}/actions/runs?run_number=$RUN_INDEX") || return 1
    json=$(printf '%s' "$json" | jq -ec --argjson n "$RUN_INDEX" '[.workflow_runs[]? | select(.index_in_repo == $n)]' 2>/dev/null) || return 1
    [ "$json" != '[]' ] || { echo "no Actions run $RUN_INDEX in $RPATH" > "$ERR"; return 1; }
  else
    if [[ $RUN_REF =~ ^[0-9a-f]{7,40}$ ]]; then
      if [ -z "$RUN_SHA" ]; then
        json=$(forgejo_api "/repos/{owner}/{repo}/git/commits/$RUN_REF") || return 1
        RUN_SHA=$(printf '%s' "$json" | jq -er '.sha | strings' 2>/dev/null) || return 1
      fi
      sha=$RUN_SHA
    else
      json=$(forgejo_api "/repos/{owner}/{repo}/branches/$RUN_REF") || return 1
      sha=$(printf '%s' "$json" | jq -er '.commit.id | strings' 2>/dev/null) || return 1
    fi
    json=$(forgejo_api "/repos/{owner}/{repo}/actions/runs?head_sha=$sha&limit=50") || return 1
    json=$(printf '%s' "$json" | jq -ec --arg wf "$WORKFLOW" '
      if type == "object" and has("workflow_runs") then
        [(.workflow_runs // [])[] | select($wf == "" or .workflow_id == $wf)]
      else error("not a run list") end' 2>/dev/null) || return 1
  fi
  printf '%s' "$json" | jq -r '.[] | [
    (if .status == "success" then "pass" elif .status == "skipped" then "skip"
     elif (.status | IN("failure", "cancelled")) then "fail" else "pending" end),
    "\(.workflow_id) #\(.index_in_repo)", (.html_url // "")] | @tsv'
}

# --- failed-job log tails --------------------------------------------------

github_log() {  # <link>
  local re='/actions/runs/[0-9]+/job/([0-9]+)'
  [[ $1 =~ $re ]] || return 1
  gh run view --job "${BASH_REMATCH[1]}" --log-failed -R "$HOST/$RPATH" 2>/dev/null | tail -n "$TAIL"
}

forgejo_job_log() {  # <job id>; tea prints an API error body (such as a job
  # that never ran) with exit 0, so a JSON message is no log
  local out
  out=$(forgejo_api "/repos/{owner}/{repo}/actions/jobs/$1/logs") || return 1
  case $out in '{"message":'*) return 1 ;; esac
  printf '%s\n' "$out" | tail -n "$TAIL"
}

forgejo_log() {  # <link>: a status's job link, or a whole run's link
  local re='/actions/runs/([0-9]+)(/jobs/([0-9]+))?/?$' run index jobs id status name
  [[ $1 =~ $re ]] || return 1
  index=${BASH_REMATCH[3]}
  run=$(forgejo_run_id "${BASH_REMATCH[1]}") || return 1
  jobs=$(forgejo_jobs "$run") || return 1
  if [ -n "$index" ]; then
    id=$(printf '%s\n' "$jobs" | sed -n "$((index + 1))p" | cut -f 1)
    [ -n "$id" ] || return 1
    forgejo_job_log "$id"
    return
  fi
  while IFS=$'\t' read -r id status name; do
    [ "$status" = failure ] || continue
    printf -- '--- job %s\n' "$name"
    forgejo_job_log "$id" || true
  done <<EOF
$jobs
EOF
}

print_failures() {  # <rows> <provider>
  local bucket name link log shown=0
  while IFS=$'\t' read -r bucket name link; do
    [ "$bucket" = fail ] || continue
    printf -- '--- %s %s\n' "$name" "$link"
    [ "$shown" -lt 5 ] || continue
    log=$("${2}_log" "$link") || log=
    [ -z "$log" ] || { printf '%s\n' "$log"; shown=$((shown + 1)); }
  done <<EOF
$1
EOF
}

# --- GitLab: delegate the wait to forge-gitlab's ci-wait --------------------

gitlab_wait() {
  local script=${FM_CI_WAIT_GITLAB:-} cand status enc pid jobs id name url
  if [ -z "$script" ]; then
    for cand in "$HOME/.agents/skills/forge-gitlab/scripts/ci-wait" "$HOME/.claude/skills/forge-gitlab/scripts/ci-wait"; do
      [ -x "$cand" ] && { script=$cand; break; }
    done
  fi
  [ -n "$script" ] && [ -x "$script" ] || die_error "the forge-gitlab skill's ci-wait script is not installed"
  status=$(GITLAB_HOST=$HOST "$script" "$RPATH" "$NUMBER" "$TIMEOUT" "$POLL_MAX" | tail -n 1)
  case $status in
    success) printf 'passed: %s (pipeline succeeded)\n' "$TARGET"; exit 0 ;;
    timeout) printf 'timed out: %s after %ss (pipeline still running or not started)\n' "$TARGET" "$TIMEOUT"; exit 3 ;;
    error|'') die_error "the GitLab pipeline could not be read" ;;
  esac
  printf 'failed: %s (pipeline %s)\n' "$TARGET" "$status"
  enc=$(jq -rn --arg p "$RPATH" '$p|@uri')
  pid=$(GITLAB_HOST=$HOST glab api "projects/$enc/merge_requests/$NUMBER/pipelines" 2>/dev/null | jq -er '.[0].id | numbers' 2>/dev/null) || exit 1
  jobs=$(GITLAB_HOST=$HOST glab api "projects/$enc/pipelines/$pid/jobs?scope[]=failed&per_page=100" 2>/dev/null \
    | jq -r '.[] | [.id, .name, .web_url] | @tsv' 2>/dev/null) || exit 1
  while IFS=$'\t' read -r id name url; do
    [ -n "$id" ] || continue
    printf -- '--- %s %s\n' "$name" "$url"
    GITLAB_HOST=$HOST glab api "projects/$enc/jobs/$id/trace" 2>/dev/null | tail -n "$TAIL"
  done <<EOF
$jobs
EOF
  exit 1
}

[ "$PROVIDER" != gitlab ] || gitlab_wait

# --- poll loop for GitHub and Forgejo --------------------------------------

interval=$POLL_MIN
fails=0
rows=
while :; do
  if rows=$("$ROWS"); then
    fails=0
    read -r total nfail npend <<COUNTS
$(printf '%s\n' "$rows" | awk -F '\t' 'NF { t++ } $1 == "fail" { f++ } $1 == "pending" { p++ } END { print t + 0, f + 0, p + 0 }')
COUNTS
    if [ "$total" -gt 0 ] && [ "$npend" -eq 0 ]; then
      if [ "$nfail" -eq 0 ]; then
        printf 'passed: %s (%s checks)\n' "$TARGET" "$total"
        exit 0
      fi
      printf 'failed: %s (%s of %s checks failed)\n' "$TARGET" "$nfail" "$total"
      print_failures "$rows" "$PROVIDER"
      exit 1
    fi
  else
    fails=$((fails + 1))
    [ "$fails" -lt 3 ] || die_error "the CI state could not be read: $(head -c 300 "$ERR" | tr '\n' ' ')"
  fi
  now=$(date +%s)
  if [ "$now" -ge "$DEADLINE" ]; then
    if [ -z "$rows" ]; then
      printf 'timed out: %s after %ss (no CI has reported yet)\n' "$TARGET" "$TIMEOUT"
    else
      printf 'timed out: %s after %ss (still pending: %s)\n' "$TARGET" "$TIMEOUT" \
        "$(printf '%s\n' "$rows" | awk -F '\t' '$1 == "pending" { printf "%s%s", sep, $2; sep = ", " }')"
    fi
    exit 3
  fi
  wait_for=$((DEADLINE - now < interval ? DEADLINE - now : interval))
  sleep "$wait_for"
  interval=$((interval * 2 > POLL_MAX ? POLL_MAX : interval * 2))
  [ "$interval" -gt 0 ] || interval=1
done
