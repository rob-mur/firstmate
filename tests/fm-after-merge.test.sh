#!/usr/bin/env bash
# tests/fm-after-merge.test.sh - bin/fm-after-merge.sh runs a project's
# declared after-merge fast-forward, records its result in the task record,
# refuses a dirty, wrong-branch, or diverged checkout without changing it, and
# gates cleanup until the result is done. A project without the token is a
# no-op in every form.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AFTER="$ROOT/bin/fm-after-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-after-merge-tests)
fm_git_identity fmtest fmtest@example.invalid

# make_case <name>: a home whose registry declares an after-merge action for
# project "dot", a local checkout of "dot" on main, and an upstream that is one
# commit ahead of that checkout.
make_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  CHECKOUT="$CASE/dot checkout"
  UP="$CASE/upstream"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects/dot"
  enc=${CHECKOUT// /%20}
  {
    echo "## Projects"
    echo "- dot [direct-PR +yolo after-merge=ff:$enc@origin/main after-merge-note=run%20snrs] - declares the action (added 2026-01-01)"
    echo "- plain [direct-PR +yolo] - declares nothing (added 2026-01-01)"
  } > "$HOME_DIR/data/projects.md"
  fm_git_init_commit "$UP"
  git clone --quiet "$UP" "$CHECKOUT"
  printf 'landed\n' > "$UP/landed.txt"
  git -C "$UP" add landed.txt
  git -C "$UP" commit -q -m landed
  TARGET=$(git -C "$UP" rev-parse HEAD)
  BEFORE=$(git -C "$CHECKOUT" rev-parse HEAD)
  META="$HOME_DIR/state/t1.meta"
  fm_write_meta "$META" kind=ship mode=direct-PR "project=$HOME_DIR/projects/dot"
}
run_after() {
  FM_HOME="$HOME_DIR" "$AFTER" t1 "$@"
}
meta_value() { grep "^$1=" "$META" | tail -1 | cut -d= -f2-; }
# checkout_snapshot: HEAD, branch, and porcelain status, to prove a refusal
# left the checkout exactly as it was.
checkout_snapshot() {
  printf '%s %s\n' "$(git -C "$CHECKOUT" rev-parse HEAD)" "$(git -C "$CHECKOUT" symbolic-ref --short HEAD 2>/dev/null)"
  git -C "$CHECKOUT" status --porcelain
  cat "$CHECKOUT/README.md"
}

# --- success ----------------------------------------------------------------
make_case ff
FM_HOME="$HOME_DIR" "$AFTER" t1 --require-done 2>/dev/null && fail "cleanup gate passed before the action ran"
out=$(run_after 2>&1) || fail "the fast-forward failed: $out"
assert_equals "$TARGET" "$(git -C "$CHECKOUT" rev-parse HEAD)" "the checkout was not fast-forwarded to origin/main"
assert_contains "$out" "relay to the captain: run snrs" "the decoded note was not printed for the captain"
assert_equals "done" "$(meta_value after_merge)" "the success was not recorded"
assert_contains "$(meta_value after_merge_reason)" "fast-forwarded $CHECKOUT" "the recorded reason does not say what happened"
assert_equals "kind=ship" "$(head -1 "$META")" "recording the result disturbed the rest of the task record"
run_after --require-done || fail "the cleanup gate refused after a recorded success"
out=$(run_after 2>&1) || fail "a rerun on an up-to-date checkout failed: $out"
assert_contains "$out" "already at origin/main" "a rerun did not report an up-to-date checkout"
assert_equals "1" "$(grep -c '^after_merge=' "$META")" "a rerun left more than one after_merge record"
pass "fm-after-merge: fast-forwards the declared checkout, records done, prints the note, and reruns idempotently"

# --- dirty checkout ---------------------------------------------------------
make_case dirty
printf 'local edit\n' >> "$CHECKOUT/README.md"
before=$(checkout_snapshot)
out=$(run_after 2>&1) && fail "a dirty checkout was not refused"
assert_equals "$before" "$(checkout_snapshot)" "a dirty refusal changed the checkout"
assert_equals "$BEFORE" "$(git -C "$CHECKOUT" rev-parse HEAD)" "a dirty refusal moved HEAD"
assert_contains "$out" "uncommitted changes" "the dirty refusal did not say why"
assert_contains "$out" "--mark-done" "the dirty refusal did not offer recording by hand"
assert_equals "failed" "$(meta_value after_merge)" "the dirty refusal was not recorded as failed"
[ -z "$(git -C "$CHECKOUT" stash list)" ] || fail "the dirty refusal stashed the local edit"
err=$(run_after --require-done 2>&1) && fail "the cleanup gate passed after a failed action"
assert_contains "$err" "uncommitted changes" "the cleanup refusal did not carry the last failure"
assert_contains "$err" "$AFTER t1" "the cleanup refusal did not name the retry command"
pass "fm-after-merge: refuses a dirty checkout without changing it, records failed, and keeps the cleanup gate shut"

# --- diverged checkout ------------------------------------------------------
make_case diverged
printf 'local commit\n' > "$CHECKOUT/local.txt"
git -C "$CHECKOUT" add local.txt
git -C "$CHECKOUT" commit -q -m local
before=$(checkout_snapshot)
out=$(run_after 2>&1) && fail "a diverged checkout was not refused"
assert_equals "$before" "$(checkout_snapshot)" "a diverged refusal changed the checkout"
assert_contains "$out" "diverged" "the diverged refusal did not say why"
assert_equals "failed" "$(meta_value after_merge)" "the diverged refusal was not recorded as failed"
pass "fm-after-merge: refuses a diverged checkout without changing it"

# --- wrong branch -----------------------------------------------------------
make_case branch
git -C "$CHECKOUT" switch -q -c topic
before=$(checkout_snapshot)
out=$(run_after 2>&1) && fail "a checkout on another branch was not refused"
assert_equals "$before" "$(checkout_snapshot)" "a wrong-branch refusal changed the checkout"
assert_contains "$out" "not main" "the wrong-branch refusal did not say why"
pass "fm-after-merge: refuses a checkout on another branch without changing it"

# --- record by hand ---------------------------------------------------------
make_case byhand
printf 'local edit\n' >> "$CHECKOUT/README.md"
run_after >/dev/null 2>&1 && fail "the dirty fixture did not refuse"
run_after --mark-done "" >/dev/null 2>&1 && fail "recording by hand accepted an empty reason"
out=$(run_after --mark-done "captain pulled by hand") || fail "recording by hand failed"
assert_contains "$out" "relay to the captain: run snrs" "recording by hand did not print the note"
assert_equals "done" "$(meta_value after_merge)" "recording by hand did not record done"
assert_equals "recorded by hand: captain pulled by hand" "$(meta_value after_merge_reason)" "recording by hand lost its reason"
run_after --require-done || fail "the cleanup gate refused after recording by hand"
pass "fm-after-merge: --mark-done records done by hand and opens the cleanup gate"

# --- project without the token ----------------------------------------------
make_case plain
fm_write_meta "$META" kind=ship mode=direct-PR "project=$HOME_DIR/projects/plain"
cp "$META" "$CASE/meta.before"
out=$(run_after 2>&1) || fail "a project without the token failed: $out"
assert_equals "" "$out" "a project without the token printed output"
run_after --require-done || fail "the cleanup gate refused a project without the token"
cmp -s "$META" "$CASE/meta.before" || fail "a project without the token had its task record changed"
assert_equals "$BEFORE" "$(git -C "$CHECKOUT" rev-parse HEAD)" "a project without the token moved some checkout"
pass "fm-after-merge: a project without the token is a no-op in every form"

echo "# fm-after-merge.test.sh: all assertions passed"
