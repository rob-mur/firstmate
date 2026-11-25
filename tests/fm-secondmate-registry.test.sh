#!/usr/bin/env bash
# Behavior of the shared secondmate registry parser, including the optional
# continuation posture field and its routed default.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$ROOT/bin/fm-secondmate-registry-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-registry)
REG="$TMP_ROOT/secondmates.md"
cat > "$REG" <<'EOF'
# Secondmates

- legacy - Legacy mate (keeps; punctuation) (home: /homes/legacy; scope: work (a; b); projects: alpha,beta; added 2026-01-02)
- driver - Driving mate (home: /homes/driver; scope: alpha delivery; projects: alpha; posture: drive; added 2026-02-03)
- weekly - Weekly mate (home: /homes/weekly; scope: reviews; projects: ; posture:  scheduled   weekly ; added 2026-03-04)
- watcher - Duty mate (home: /homes/watcher; scope: upstream PRs; projects: beta; posture: duty; added 2026-04-05)
- taker - Intake mate (home: /homes/taker; scope: intake; projects: ; posture: duty  offered-item-taken; added 2026-05-07)
- quiet - Routed mate (home: /homes/quiet; scope: intake; projects: alpha; posture: routed; added 2026-05-06)
- far - Remote mate (host: box1; root: /srv/fm; home: /srv/homes/far; scope: far work; projects: gamma; posture: drive; added 2026-06-07)
- farlegacy - Remote legacy mate (host: box1; root: /srv/fm; home: /srv/homes/farlegacy; scope: far work; projects: gamma; added 2026-06-08)
EOF

test_posture_field_parses() {
  assert_equals "$(secondmate_registry_posture "$REG" legacy)" routed "missing posture field defaults to routed"
  assert_equals "$(secondmate_registry_field "$REG" legacy scope)" "work (a; b)" "legacy scope keeps its punctuation"
  assert_equals "$(secondmate_registry_field "$REG" legacy projects)" "alpha,beta" "legacy projects unchanged"
  assert_equals "$(secondmate_registry_posture "$REG" driver)" drive "drive posture parses"
  assert_equals "$(secondmate_registry_field "$REG" driver projects)" alpha "projects before posture parse"
  assert_equals "$(secondmate_registry_field "$REG" driver home)" /homes/driver "home with posture parses"
  assert_equals "$(secondmate_registry_posture "$REG" weekly)" "scheduled weekly" "scheduled cadence is normalized"
  assert_equals "$(secondmate_registry_posture "$REG" watcher)" duty "duty posture parses"
  assert_equals "$(secondmate_registry_posture "$REG" taker)" "duty offered-item-taken" "duty posture carries its named trigger"
  assert_equals "$(secondmate_posture_duty_trigger "duty offered-item-taken")" offered-item-taken "duty trigger is readable"
  assert_equals "$(secondmate_posture_duty_trigger duty)" "" "plain duty has no watched trigger"
  assert_equals "$(secondmate_registry_posture "$REG" quiet)" routed "explicit routed posture parses"
  assert_equals "$(secondmate_registry_posture "$REG" far)" drive "remote record carries posture"
  assert_equals "$(secondmate_registry_field "$REG" far remote)" 1 "remote record with posture stays remote"
  assert_equals "$(secondmate_registry_field "$REG" far root)" /srv/fm "remote root with posture parses"
  assert_equals "$(secondmate_registry_posture "$REG" farlegacy)" routed "remote record without posture is routed"
  pass "registry posture field parses with a routed default"
}

test_malformed_posture_refused() {
  secondmate_registry_parse_line "- driver - Driving mate (home: /homes/driver; scope: alpha; projects: alpha; posture: drive; added 2026-02-03)"
  assert_equals "$SECONDMATE_REGISTRY_ADDED" 2026-02-03 "added date survives the posture field"

  for bad in "posture: bogus" "posture: drive now" "posture: scheduled" "posture: routed weekly" "posture: scheduled we/ekly" "posture: duty whenever" "posture: drive offered-item-taken" "posture: "; do
    line="- bad - Bad mate (home: /homes/bad; scope: s; projects: p; $bad; added 2026-01-01)"
    if secondmate_registry_parse_line "$line"; then
      fail "malformed $bad was accepted"
    fi
  done
  pass "unknown or malformed posture values make the record malformed"
}

test_validation_refuses_unknown_posture() {
  BAD_REG="$TMP_ROOT/bad.md"
  printf '%s\n' "- bad - Bad mate (home: /homes/bad; scope: s; projects: p; posture: forever; added 2026-01-01)" > "$BAD_REG"
  if secondmate_registry_validate_bindings "$BAD_REG" "" >/dev/null 2>&1; then
    fail "registry validation accepted an unknown posture"
  fi
  assert_contains "$SECONDMATE_REGISTRY_ERROR" "malformed secondmate registry entry" "validation names the malformed entry"
  pass "registry validation refuses an unknown posture"
}

fm_test_run test_posture_field_parses test_malformed_posture_refused test_validation_refuses_unknown_posture
