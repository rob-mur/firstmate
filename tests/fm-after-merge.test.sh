#!/usr/bin/env bash
# tests/fm-after-merge.test.sh - bin/fm-after-merge.sh runs a project's
# declared after-merge fast-forward, records its result in the task record,
# refuses a dirty, wrong-branch, or diverged checkout without changing it, and
# gates cleanup until the result is done. A relayed note is also held as
# exactly one captain card linking the PR. A project without the token is a
# no-op in every form.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (the captain card is a backlog task)"; exit 0; }

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
  fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  fm_git_init_commit "$UP"
  git clone --quiet "$UP" "$CHECKOUT"
  printf 'landed\n' > "$UP/landed.txt"
  git -C "$UP" add landed.txt
  git -C "$UP" commit -q -m landed
  TARGET=$(git -C "$UP" rev-parse HEAD)
  BEFORE=$(git -C "$CHECKOUT" rev-parse HEAD)
  META="$HOME_DIR/state/t1.meta"
  fm_write_meta "$META" kind=ship mode=direct-PR "project=$HOME_DIR/projects/dot" \
    "pr=https://github.com/example/dot/pull/62"
}
run_after() {
  FM_HOME="$HOME_DIR" "$AFTER" t1 "$@"
}
meta_value() { grep "^$1=" "$META" | tail -1 | cut -d= -f2-; }
# card_count: how many backlog rows the after-merge card for t1 has.
card_count() { grep -c 't1-after-merge' "$HOME_DIR/data/backlog.md" || true; }
# assert_one_held_card: exactly one card for t1, held for the captain, whose
# reason reads as the captain's action and links the PR.
assert_one_held_card() {
  local show
  assert_equals "1" "$(card_count)" "the relayed note did not leave exactly one card"
  show=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" show t1-after-merge) || fail "the card could not be read"
  assert_contains "$show" "Run snrs to put dot PR 62 live" "the card does not read as the captain's action"
  assert_contains "$show" "https://github.com/example/dot/pull/62" "the card does not link the PR"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-captain-hold.sh" open t1-after-merge || fail "the card is not held for the captain"
}
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
assert_one_held_card
run_after --mark-done "captain pulled by hand" >/dev/null || fail "recording by hand after a run failed"
assert_one_held_card
pass "fm-after-merge: fast-forwards the declared checkout, records done, prints the note, holds one captain card, and reruns idempotently"

# --- note without a PR --------------------------------------------------------
make_case nopr
fm_write_meta "$META" kind=ship mode=local-only "project=$HOME_DIR/projects/dot" branch=fm/t1
out=$(run_after 2>&1) || fail "the fast-forward without a PR failed: $out"
assert_equals "1" "$(card_count)" "a local landing's note did not leave exactly one card"
show=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" show t1-after-merge) || fail "the local card could not be read"
assert_contains "$show" "Run snrs to put the dot change live" "the local card does not read as the captain's action"
assert_contains "$show" "fm/t1" "the local card does not name the landed branch"
pass "fm-after-merge: a local landing's note holds one card naming its branch"

# --- action without a note ---------------------------------------------------
make_case nonote
sed -i.bak 's/ after-merge-note=run%20snrs//' "$HOME_DIR/data/projects.md"
out=$(run_after 2>&1) || fail "the fast-forward without a note failed: $out"
assert_equals "done" "$(meta_value after_merge)" "the action without a note was not recorded done"
assert_not_contains "$out" "relay to the captain" "an action without a note relayed something"
assert_equals "0" "$(card_count)" "an action without a note held a card"
pass "fm-after-merge: an action without a note holds no card"

# --- card cannot be held ------------------------------------------------------
make_case nobacklog
rm "$HOME_DIR/data/backlog.md"
mkdir "$HOME_DIR/data/backlog.md"
out=$(run_after 2>&1) || fail "a failed card hold failed the after-merge step: $out"
assert_equals "done" "$(meta_value after_merge)" "a failed card hold lost the done record"
assert_contains "$out" "relay to the captain: run snrs" "a failed card hold dropped the chat relay"
assert_contains "$out" "actionable: could not hold the after-merge note" "a failed card hold was not reported"
assert_contains "$out" "fm-captain-hold.sh hold t1-after-merge" "a failed card hold did not name the hand command"
pass "fm-after-merge: a card that cannot be held is reported without undoing the action"

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
assert_equals "0" "$(card_count)" "a refused action held a card"
run_after --mark-done "" >/dev/null 2>&1 && fail "recording by hand accepted an empty reason"
out=$(run_after --mark-done "captain pulled by hand") || fail "recording by hand failed"
assert_contains "$out" "relay to the captain: run snrs" "recording by hand did not print the note"
assert_equals "done" "$(meta_value after_merge)" "recording by hand did not record done"
assert_equals "recorded by hand: captain pulled by hand" "$(meta_value after_merge_reason)" "recording by hand lost its reason"
run_after --require-done || fail "the cleanup gate refused after recording by hand"
assert_one_held_card
pass "fm-after-merge: --mark-done records done by hand, holds the captain card, and opens the cleanup gate"

# --- project without the token ----------------------------------------------
make_case plain
fm_write_meta "$META" kind=ship mode=direct-PR "project=$HOME_DIR/projects/plain"
cp "$META" "$CASE/meta.before"
out=$(run_after 2>&1) || fail "a project without the token failed: $out"
assert_equals "" "$out" "a project without the token printed output"
run_after --require-done || fail "the cleanup gate refused a project without the token"
cmp -s "$META" "$CASE/meta.before" || fail "a project without the token had its task record changed"
assert_equals "0" "$(card_count)" "a project without the token held a card"
assert_equals "$BEFORE" "$(git -C "$CHECKOUT" rev-parse HEAD)" "a project without the token moved some checkout"
pass "fm-after-merge: a project without the token is a no-op in every form"

echo "# fm-after-merge.test.sh: all assertions passed"
