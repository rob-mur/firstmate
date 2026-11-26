#!/usr/bin/env bash
# Behavior tests for bin/fm-ci-wait.sh with stubbed gh, tea, glab, and the
# forge-gitlab ci-wait script. Each stub serves the fixture for the current
# poll, so a test can script how CI moves from one poll to the next.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-ci-wait.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-wait)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
trap 'rm -rf "$TMP_ROOT"' EXIT

# A stub answers from $FIX/<name>.<poll>, falling back to the highest earlier
# poll's fixture, where <poll> counts the stub's calls for <name>.
cat > "$FAKEBIN/fixture" <<'EOF'
#!/usr/bin/env bash
name=$1 n=1 f=
[ -f "$FIX/$name.count" ] && n=$(( $(cat "$FIX/$name.count") + 1 ))
printf '%s\n' "$n" > "$FIX/$name.count"
while [ "$n" -gt 0 ]; do
  f="$FIX/$name.$n"
  [ -f "$f" ] && { cat "$f"; exit 0; }
  [ -f "$f.err" ] && { cat "$f.err" >&2; exit 1; }
  n=$((n - 1))
done
exit 1
EOF

# gh applies --jq to the JSON it serves, like the real CLI.
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
expr= key=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = --jq ] && expr=${args[$((i + 1))]}
done
case "$*" in
  "pr checks "*) key=checks ;;
  "api repos/"*"/check-runs"*) key=check-runs ;;
  "api repos/"*"/status"*) key=status ;;
  "run view --job "*) printf '%s\n' "$4" >> "$FIX/logged-jobs"; seq -f 'log line %g' 1 50; exit 0 ;;
  *) echo "unexpected gh $*" >&2; exit 9 ;;
esac
json=$(fixture "$key") || exit 1
printf '%s\n' "$json" | jq -r "$expr"
EOF

cat > "$FAKEBIN/tea" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "login list --output json") echo '[{"name":"fj","url":"https://forgejo.example"}]' ;;
  *"/pulls/5") echo '{"head":{"sha":"abc1234"}}' ;;
  *"/commits/abc1234/status") fixture fj-status ;;
  *"/actions/runs?run_number=7") echo '{"total_count":1,"workflow_runs":[{"id":70,"index_in_repo":7}]}' ;;
  *"/actions/runs?run_number=9") fixture fj-run ;;
  *"/actions/runs?run_number="*) echo '{"total_count":0,"workflow_runs":[]}' ;;
  *"/actions/runs?head_sha="*) a="$*"; a=${a##*head_sha=}; printf '%s\n' "${a%%&*}" >> "$FIX/head-shas"; fixture fj-runs ;;
  *"/git/commits/abc1234") echo '{"sha":"abc1234000000000000000000000000000000000"}' ;;
  *"/branches/main") fixture fj-branch ;;
  *"/actions/runs/70/jobs") echo '[{"id":99,"name":"test","status":"failure"},{"id":98,"name":"lint","status":"success"}]' ;;
  *"/actions/runs/90/jobs") echo '{"jobs":[{"id":91,"name":"build","status":"success"},{"id":92,"name":"publish","status":"failure"},{"id":93,"name":"notify","status":"cancelled"}]}' ;;
  *"/actions/jobs/99/logs") seq -f 'fj log %g' 1 20 ;;
  *"/actions/jobs/92/logs") seq -f 'publish log %g' 1 20 ;;
  *"/actions/jobs/"*"/logs") echo '{"message":"job has not been executed yet"}' ;;
  *) echo "unexpected tea $*" >&2; exit 9 ;;
esac
EOF

cat > "$FAKEBIN/glab" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "api projects/g%2Fp/merge_requests/3/pipelines") echo '[{"id":55}]' ;;
  "api projects/g%2Fp/pipelines/55/jobs?scope[]=failed&per_page=100") echo '[{"id":61,"name":"unit","web_url":"https://gitlab.example/g/p/-/jobs/61"}]' ;;
  "api projects/g%2Fp/jobs/61/trace") seq -f 'gl log %g' 1 30 ;;
  *) echo "unexpected glab $*" >&2; exit 9 ;;
esac
EOF

cat > "$FAKEBIN/ci-wait" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FIX/ci-wait.args"
echo "polling"
cat "$FIX/gitlab-verdict"
EOF
chmod +x "$FAKEBIN"/*

PR=https://github.com/o/r/pull/7
OUT=

# run_wait <fixture-dir> <args...>: sets OUT and RC.
run_wait() {
  local fix=$1
  shift
  OUT=$(FIX="$fix" FM_HOME="$TMP_ROOT/home" PATH="$FAKEBIN:$PATH" \
    FM_CI_WAIT_POLL_MIN=1 FM_CI_WAIT_POLL_MAX=1 FM_CI_WAIT_GITLAB="$FAKEBIN/ci-wait" \
    bash "$SCRIPT" "$@" 2>&1)
  RC=$?
}

new_fix() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

mkdir -p "$TMP_ROOT/home"

test_pass() {
  local fix
  fix=$(new_fix pass)
  echo '[{"name":"build","bucket":"pass","link":"https://github.com/o/r/actions/runs/1/job/2"},{"name":"docs","bucket":"skipping","link":""}]' > "$fix/checks.1"
  run_wait "$fix" "$PR"
  assert_equals 0 "$RC" "a green PR must exit 0"
  assert_equals "passed: $PR (2 checks)" "$OUT" "a green PR must print one passed verdict"
  pass "fm-ci-wait: green checks print one passed verdict and exit 0"
}

test_fail_with_log_tail() {
  local fix
  fix=$(new_fix fail)
  echo '[{"name":"build","bucket":"pending","link":""}]' > "$fix/checks.1"
  echo '[{"name":"build","bucket":"fail","link":"https://github.com/o/r/actions/runs/1/job/42"},{"name":"deploy","bucket":"cancel","link":""},{"name":"lint","bucket":"pass","link":""}]' > "$fix/checks.2"
  run_wait "$fix" --tail 3 "$PR"
  assert_equals 1 "$RC" "a red PR must exit 1"
  assert_equals "failed: $PR (2 of 3 checks failed)" "$(printf '%s\n' "$OUT" | head -n 1)" \
    "the first line must be the failed verdict counting failed and cancelled checks"
  printf '%s\n' "$OUT" > "$fix/out"
  assert_grep "--- build https://github.com/o/r/actions/runs/1/job/42" "$fix/out" "the failed job must be named with its link"
  assert_grep "--- deploy " "$fix/out" "a cancelled job must be listed as failed"
  assert_grep "log line 48" "$fix/out" "the failed job's log tail must be printed"
  assert_grep "log line 50" "$fix/out" "the failed job's log tail must reach the last line"
  assert_no_grep "log line 47" "$fix/out" "--tail must bound the log lines"
  assert_equals 42 "$(cat "$fix/logged-jobs")" "the log must be read for the failed job's id"
  pass "fm-ci-wait: red checks print the failed jobs with a bounded log tail and exit 1"
}

test_log_tails_capped() {
  local fix rows='' i
  fix=$(new_fix many)
  for i in 1 2 3 4 5 6 7; do
    rows="$rows{\"name\":\"job$i\",\"bucket\":\"fail\",\"link\":\"https://github.com/o/r/actions/runs/1/job/$i\"},"
  done
  echo "[${rows%,}]" > "$fix/checks.1"
  run_wait "$fix" --tail 1 "$PR"
  assert_equals 1 "$RC" "a red PR must exit 1"
  printf '%s\n' "$OUT" > "$fix/out"
  assert_grep "--- job7 " "$fix/out" "every failed job must still be named"
  assert_equals 5 "$(grep -c '^log line' "$fix/out")" "only the first five failed jobs may print log tails"
  pass "fm-ci-wait: log tails stop after five failed jobs while every failed job is still named"
}

test_timeout() {
  local fix
  fix=$(new_fix timeout)
  echo '[{"name":"build","bucket":"pending","link":""},{"name":"lint","bucket":"pass","link":""}]' > "$fix/checks.1"
  run_wait "$fix" --timeout 2 "$PR"
  assert_equals 3 "$RC" "a wait that outlives --timeout must exit 3"
  assert_equals "timed out: $PR after 2s (still pending: build)" "$OUT" "a timeout must name what is still pending"
  pass "fm-ci-wait: a timeout names the pending checks and exits 3"
}

test_not_yet_started() {
  local fix
  fix=$(new_fix late)
  echo "no checks reported on the 'fm/x' branch" > "$fix/checks.1.err"
  echo "no checks reported on the 'fm/x' branch" > "$fix/checks.2.err"
  echo '[{"name":"build","bucket":"pass","link":""}]' > "$fix/checks.3"
  run_wait "$fix" --timeout 30 "$PR"
  assert_equals 0 "$RC" "checks that start after the first poll must still be waited for"
  assert_equals "passed: $PR (1 checks)" "$OUT" "a late-starting green run must print passed"

  fix=$(new_fix never)
  echo "no checks reported on the 'fm/x' branch" > "$fix/checks.1.err"
  run_wait "$fix" --timeout 2 "$PR"
  assert_equals 3 "$RC" "CI that never starts must time out, not pass"
  assert_equals "timed out: $PR after 2s (no CI has reported yet)" "$OUT" "a never-started run must say no CI reported"
  pass "fm-ci-wait: a not-yet-started pipeline is waited for, and one that never starts times out"
}

test_read_error() {
  local fix
  fix=$(new_fix broken)
  echo "HTTP 502: bad gateway" > "$fix/checks.1.err"
  run_wait "$fix" --timeout 30 "$PR"
  assert_equals 4 "$RC" "an unreadable CI state must exit 4"
  case $OUT in "error: $PR: the CI state could not be read: HTTP 502"*) ;; *) fail "the read error must be reported (got '$OUT')" ;; esac
  pass "fm-ci-wait: three unreadable polls in a row report an error and exit 4"
}

test_github_commit() {
  local fix
  fix=$(new_fix commit)
  echo '{"check_runs":[{"name":"build","status":"in_progress","conclusion":null,"html_url":""}]}' > "$fix/check-runs.1"
  echo '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","html_url":""}]}' > "$fix/check-runs.2"
  echo '{"statuses":[{"context":"ci/ext","state":"success","target_url":""}]}' > "$fix/status.1"
  run_wait "$fix" --commit abc1234def https://github.com/o/r
  assert_equals 0 "$RC" "a green commit must exit 0"
  assert_equals "passed: https://github.com/o/r@abc1234def (2 checks)" "$OUT" "a commit verdict must name the commit"
  pass "fm-ci-wait: a GitHub commit waits on its check runs and statuses"
}

test_forgejo() {
  local fix url=https://forgejo.example/o/r/pulls/5
  fix=$(new_fix fj)
  echo '{"state":"","total_count":0,"statuses":null}' > "$fix/fj-status.1"
  echo '{"state":"failure","statuses":[{"context":"ci / test","status":"failure","target_url":"/o/r/actions/runs/7/jobs/1"},{"context":"ci / lint","status":"success","target_url":"/o/r/actions/runs/7/jobs/0"}]}' > "$fix/fj-status.2"
  run_wait "$fix" --tail 2 "$url"
  assert_equals 1 "$RC" "a red Forgejo PR must exit 1"
  printf '%s\n' "$OUT" > "$fix/out"
  assert_equals "failed: $url (1 of 2 checks failed)" "$(head -n 1 "$fix/out")" "the Forgejo verdict must count the failed status"
  assert_grep "--- ci / test https://forgejo.example/o/r/actions/runs/7/jobs/1" "$fix/out" "a relative Forgejo link must be made absolute"
  assert_grep "fj log 20" "$fix/out" "the job at the link's index, ordered by id, must supply the log"
  assert_no_grep "fj log 18" "$fix/out" "--tail must bound the Forgejo log"

  fix=$(new_fix fj-none)
  echo '{"state":"","total_count":0,"statuses":null}' > "$fix/fj-status.1"
  run_wait "$fix" --timeout 2 "$url"
  assert_equals 3 "$RC" "a Forgejo commit with no CI must time out, not error"
  assert_equals "timed out: $url after 2s (no CI has reported yet)" "$OUT" "an empty Forgejo status must read as not started"
  pass "fm-ci-wait: Forgejo reads the PR head's combined status through tea and tails the failed Actions job"
}

# fj_run <id> <index> <workflow> <status>: one Actions run as the runs API lists it.
fj_run() {
  printf '{"id":%s,"index_in_repo":%s,"workflow_id":"%s","status":"%s","html_url":"https://forgejo.example/o/r/actions/runs/%s"}' "$1" "$2" "$3" "$4" "$2"
}

test_forgejo_run_url() {
  local fix url=https://forgejo.example/o/r/actions/runs/9
  fix=$(new_fix fj-run-url)
  echo "{\"total_count\":1,\"workflow_runs\":[$(fj_run 90 9 release.yml running)]}" > "$fix/fj-run.1"
  echo "{\"total_count\":1,\"workflow_runs\":[$(fj_run 90 9 release.yml failure)]}" > "$fix/fj-run.2"
  run_wait "$fix" --tail 2 "$url"
  assert_equals 1 "$RC" "a failed Actions run must exit 1"
  printf '%s\n' "$OUT" > "$fix/out"
  assert_equals "failed: $url (1 of 1 checks failed)" "$(head -n 1 "$fix/out")" "the run verdict must name the run URL"
  assert_grep "--- release.yml #9 $url" "$fix/out" "the failed run must be named by workflow and number"
  assert_grep "--- job publish" "$fix/out" "the run's failed job must be named"
  assert_grep "publish log 20" "$fix/out" "the failed job's log tail must be printed"
  assert_no_grep "publish log 18" "$fix/out" "--tail must bound the run's job log"
  assert_no_grep "job notify" "$fix/out" "a cancelled job that never ran must not be listed as a failed job"
  assert_no_grep "message" "$fix/out" "an API error body must never print as a log"

  fix=$(new_fix fj-run-pass)
  echo "{\"total_count\":1,\"workflow_runs\":[$(fj_run 90 9 release.yml waiting)]}" > "$fix/fj-run.1"
  echo "{\"total_count\":1,\"workflow_runs\":[$(fj_run 90 9 release.yml success)]}" > "$fix/fj-run.3"
  run_wait "$fix" --timeout 30 "$url"
  assert_equals 0 "$RC" "a succeeded Actions run must exit 0"
  assert_equals "passed: $url (1 checks)" "$OUT" "the run must be waited for until it succeeds"

  fix=$(new_fix fj-run-missing)
  run_wait "$fix" --timeout 30 https://forgejo.example/o/r/actions/runs/404
  assert_equals 4 "$RC" "a run number the repository does not have must be an error"
  case $OUT in "error: https://forgejo.example/o/r/actions/runs/404: the CI state could not be read: no Actions run 404 in o/r"*) ;;
    *) fail "a missing run must be reported (got '$OUT')" ;; esac
  pass "fm-ci-wait: a Forgejo Actions run URL waits on that run and tails its failed jobs"
}

test_forgejo_run_ref() {
  local fix repo=https://forgejo.example/o/r
  fix=$(new_fix fj-run-sha)
  echo '{"total_count":0,"workflow_runs":[]}' > "$fix/fj-runs.1"
  echo "{\"total_count\":2,\"workflow_runs\":[$(fj_run 80 8 ci.yml success),$(fj_run 81 9 release.yml running)]}" > "$fix/fj-runs.2"
  echo "{\"total_count\":2,\"workflow_runs\":[$(fj_run 80 8 ci.yml success),$(fj_run 81 9 release.yml skipped)]}" > "$fix/fj-runs.3"
  run_wait "$fix" --timeout 30 --run abc1234 "$repo"
  assert_equals 0 "$RC" "a commit whose runs all succeed or skip must exit 0"
  assert_equals "passed: $repo@abc1234 (2 checks)" "$OUT" "the --run verdict must name the repository and ref"
  assert_equals abc1234000000000000000000000000000000000 "$(sort -u "$fix/head-shas")" "a short sha must be resolved to the full sha the runs filter needs"

  fix=$(new_fix fj-run-workflow)
  echo "{\"total_count\":2,\"workflow_runs\":[$(fj_run 80 8 ci.yml failure),$(fj_run 81 9 release.yml running)]}" > "$fix/fj-runs.1"
  run_wait "$fix" --timeout 2 --workflow release.yml --run abc1234 "$repo"
  assert_equals 3 "$RC" "--workflow must ignore another workflow's failed run"
  assert_equals "timed out: $repo@abc1234 (release.yml) after 2s (still pending: release.yml #9)" "$OUT" "the timeout must name the pending run"

  fix=$(new_fix fj-run-branch)
  echo '{"commit":{"id":"1111111111111111111111111111111111111111"}}' > "$fix/fj-branch.1"
  echo '{"commit":{"id":"2222222222222222222222222222222222222222"}}' > "$fix/fj-branch.2"
  echo '{"total_count":0,"workflow_runs":[]}' > "$fix/fj-runs.1"
  echo "{\"total_count\":1,\"workflow_runs\":[$(fj_run 82 10 ci.yml success)]}" > "$fix/fj-runs.2"
  run_wait "$fix" --timeout 30 --run main "$repo"
  assert_equals 0 "$RC" "a branch's runs must be waited for"
  assert_equals "$(printf '%s\n' 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222)" "$(cat "$fix/head-shas")" \
    "a branch must be re-read on every poll so a push during the wait is followed"

  fix=$(new_fix fj-run-none)
  echo '{"total_count":0,"workflow_runs":[]}' > "$fix/fj-runs.1"
  run_wait "$fix" --timeout 2 --run abc1234 "$repo"
  assert_equals 3 "$RC" "a commit with no runs yet must time out, not pass"
  assert_equals "timed out: $repo@abc1234 after 2s (no CI has reported yet)" "$OUT" "no runs must read as not started"
  pass "fm-ci-wait: --run waits on a commit's or branch's Forgejo Actions runs, optionally one workflow"
}

test_gitlab_delegation() {
  local fix url=https://gitlab.example/g/p/-/merge_requests/3
  fix=$(new_fix gl)
  echo success > "$fix/gitlab-verdict"
  run_wait "$fix" --timeout 120 "$url"
  assert_equals 0 "$RC" "a succeeded GitLab pipeline must exit 0"
  assert_equals "passed: $url (pipeline succeeded)" "$OUT" "the GitLab pass verdict"
  assert_equals "g/p 3 120 1" "$(cat "$fix/ci-wait.args")" "ci-wait must get the project, MR, timeout, and interval"

  echo failed > "$fix/gitlab-verdict"
  run_wait "$fix" --tail 2 "$url"
  assert_equals 1 "$RC" "a failed GitLab pipeline must exit 1"
  printf '%s\n' "$OUT" > "$fix/out"
  assert_equals "failed: $url (pipeline failed)" "$(head -n 1 "$fix/out")" "the GitLab fail verdict"
  assert_grep "--- unit https://gitlab.example/g/p/-/jobs/61" "$fix/out" "the failed GitLab job must be named"
  assert_grep "gl log 30" "$fix/out" "the failed GitLab job's trace tail must be printed"
  assert_no_grep "gl log 28" "$fix/out" "--tail must bound the GitLab trace"

  echo timeout > "$fix/gitlab-verdict"
  run_wait "$fix" --timeout 5 "$url"
  assert_equals 3 "$RC" "a GitLab timeout must exit 3"
  pass "fm-ci-wait: GitLab waits through the forge-gitlab ci-wait script and adds failed-job traces"
}

test_usage() {
  run_wait "$TMP_ROOT" https://example.com/not-a-pr
  assert_equals 2 "$RC" "an unsupported URL must be a usage error"
  run_wait "$TMP_ROOT" --timeout soon "$PR"
  assert_equals 2 "$RC" "a non-numeric timeout must be a usage error"
  run_wait "$TMP_ROOT" --run main https://github.com/o/r
  assert_equals 2 "$RC" "--run on a host that is not Forgejo must be a usage error"
  run_wait "$TMP_ROOT" https://github.com/o/r/actions/runs/9
  assert_equals 2 "$RC" "a run URL on a host that is not Forgejo must be a usage error"
  run_wait "$TMP_ROOT" --run main --commit abc1234 https://forgejo.example/o/r
  assert_equals 2 "$RC" "--run and --commit together must be a usage error"
  run_wait "$TMP_ROOT" --workflow ci.yml "$PR"
  assert_equals 2 "$RC" "--workflow without --run must be a usage error"
  run_wait "$TMP_ROOT" --run 'main;x' https://forgejo.example/o/r
  assert_equals 2 "$RC" "a --run ref with shell or URL characters must be a usage error"
  pass "fm-ci-wait: unsupported targets and bad options exit 2"
}

test_pass
test_fail_with_log_tail
test_log_tails_capped
test_timeout
test_not_yet_started
test_read_error
test_github_commit
test_forgejo
test_forgejo_run_url
test_forgejo_run_ref
test_gitlab_delegation
test_usage
