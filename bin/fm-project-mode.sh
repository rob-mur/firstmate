#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Default usage prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# --branch-prefix instead prints one value: the project's registered ship-branch
# prefix, "fm/" when the project registers none, is unregistered, or the registry
# is absent, so every existing installation keeps its current "fm/<task-id>"
# branch names unchanged.
# With --forge it prints one word instead: the project's registered forge,
# none|gerrit|forgejo|external. The forge is asked for explicitly, so the
# default output stays the same two words for every project, bound or not.
# With --pr it prints one word: the project's registered PR-text posture,
# auto|manual, "auto" when the project registers none.
# With --after-merge it prints the project's declared after-merge action as one
# tab-separated line "ff<TAB><checkout><TAB><remote><TAB><branch><TAB><note>",
# or nothing when the project declares none (bin/fm-after-merge.sh runs it).
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode,
# yolo, and ship-branch prefix are resolved by firstmate at intake and passed
# explicitly to bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md
# section 7; bin/fm-brief.sh's own header owns the --branch-prefix flag it accepts).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh and bin/fm-remote-home-seed.sh (refuse local-only seeding,
# run no-mistakes init), bin/fm-spawn.sh's advisory registry-deviation notice,
# and --forge for bin/fm-spawn.sh's forge agreement and yolo refusal and for
# bin/fm-promote.sh, which takes the forge binding from here because it is a
# project fact rather than a task choice. --pr is read the same way by
# bin/fm-spawn.sh's PR-text agreement and by bin/fm-promote.sh.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                                 -> no-mistakes off fm/  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)                        -> <mode> off fm/
#   - <name> [<mode> +yolo] - <desc> (added <date>)                  -> <mode> on fm/
#   - <name> [<mode> +yolo branch=<prefix>] - <desc> (added <date>)  -> <mode> <yolo> <prefix>
#   - <name> [<mode> forge=gerrit] - <desc> (added <date>)           -> <mode> off, --forge gerrit
#   - <name> [<mode> forge=forgejo] - <desc> (added <date>)          -> <mode> <yolo>, --forge forgejo
#   - <name> [direct-PR forge=external] - <desc> (added <date>)      -> direct-PR off, --forge external
#   - <name> [no-mistakes pr=manual] - <desc> (added <date>)         -> no-mistakes off, --pr manual
#   - <name> [direct-PR after-merge=ff:<path>@<remote>/<branch> after-merge-note=<text>] - <desc>
#                                                                    -> --after-merge ff ...
#   <name> may contain spaces; it ends at the literal " [" or " - " that follows it.
#   Bracket tokens are order-independent: +yolo, branch=<prefix>, forge=<value>,
#   pr=<value>, after-merge=<action>, and after-merge-note=<text> are recognized by their own shape wherever they appear, and whichever token is
#   left over is the mode. <prefix> must not contain a space; an empty override
#   ("branch=") resolves to "" for a bare "<task-id>" ship branch instead of the
#   legacy "fm/<task-id>".
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
# branch=<prefix> (orthogonal) = overrides the "fm/" ship-branch prefix so a
#   project's branch and PR do not read as firstmate-authored, e.g. for a
#   third-party repo that does not use this tooling. Query it with
#   --branch-prefix; it never appears in the default "<mode> <yolo>" output, so
#   existing mechanical callers are unaffected by its presence.
# forge (orthogonal, and orthogonal to yolo too) = which forge the project's
#   remote actually is, never inferred from mode, remote name, host, or protocol.
#   `none` means a forge whose pull requests and checks no-mistakes already
#   drives, `gerrit` means a Gerrit server: no pull requests, so the worker
#   publishes a change with gerrit-axi instead, and `forgejo` means a Forgejo or
#   Gitea server, whose pull requests the worker handles with tea rather than
#   gh-axi, and `external` means the project's reviews are created by a review
#   tool that uploads its own snapshot of the worker's local commits: the
#   worker never needs to push a branch, and must never push a task branch to
#   the project's shared origin. Firstmate cannot observe, approve, or merge
#   such a review, so that rail always escalates (bin/fm-dod-lib.sh owns what
#   each changes for a worker in each publishing mode;
#   docs/forgejo-tea-integration.md holds the tea evidence and
#   docs/external-review-forge.md the external design).
#   The binding is EXPLICIT because a provider family must never be guessed;
#   bin/fm-forge-detect.sh proposes gerrit from a protocol fact at project-add
#   intake, forgejo has no such fact and is proposed from the captain's own
#   account of the host, external is never detected or proposed because no
#   protocol fact identifies a snapshot-uploading review tool, and the captain's
#   confirmation is what this record holds.
#   A forge describes what a mode publishes, so it composes with no-mistakes and
#   direct-PR and is REFUSED on local-only, which publishes nothing: that mode
#   lands by fast-forwarding local main, which on a review-server project
#   advances it with content the server has never seen
#   (docs/gerrit-forge-integration.md section 3).
#
# pr (orthogonal) = who writes the pull request's title and body. Absent means
#   `auto`, today's behavior: the no-mistakes pipeline's pr step writes and
#   refreshes them. `manual` is for a project whose PR text a person writes
#   and a maintainer reads: the worker owns the text and the pipeline's pr step
#   is skipped (bin/fm-dod-lib.sh owns what that changes for a worker). It is
#   the thin registry form of no-mistakes' own keep-text option
#   (kunchenguid/no-mistakes#1648) and maps onto it once that exists. Only a
#   no-mistakes ship takes it, because direct-PR already leaves the text to the
#   worker and local-only opens no PR, and only a project with no forge binding,
#   because the manual brief carries no PR commands for another forge. A
#   registered pr=manual on any other mode or forge, and a malformed binding (an
#   empty or unknown value), are REFUSED in the default and --pr output forms:
#   nothing on stdout, exit status 3, the token named. --branch-prefix and
#   --forge do not make these checks.
#
# after-merge (orthogonal) = a step firstmate owes after this project's task
#   lands, declared because a project's own finishing steps otherwise belong to
#   nobody: the worker's instructions end before the merge, and landing is
#   generic. The one action is `ff:<path>@<remote>/<branch>`: fast-forward the
#   local checkout at the absolute <path>, which must be on <branch>, to
#   <remote>/<branch> after a fetch, and stop without changing it when it has
#   uncommitted tracked changes, is on another branch, or has diverged (never a
#   force, reset, or stash). The optional after-merge-note=<text> is a short
#   note relayed to the captain once the action has run, such as a command
#   only they can run. Bracket tokens cannot hold a space, so both values are
#   percent-encoded: %20 is a space, %25 a percent sign, %5D a closing bracket,
#   and any %XX hex pair decodes to that byte; a backslash or control character
#   is refused. <path> is split from its target at the LAST "@", and <remote>
#   from <branch> at the first "/". A malformed action, an unknown action kind,
#   or a note without an action is REFUSED by --after-merge only: nothing on
#   stdout, exit status 3, the token named. The other output forms ignore both
#   tokens, so declaring one never changes a project's posture.
#   bin/fm-after-merge.sh runs the action and records its result, and
#   bin/fm-teardown.sh refuses cleanup until it has recorded done.
#
# A registered `forge=gerrit` project reports yolo=off with an explicit stderr
# refusal, on the captain's decision of 2026-09-15: a Gerrit Code-Review+2 is a
# positive attributed claim that a named human approved, read by colleagues and
# by any audit, and firstmate must not manufacture one. A registered
# `forge=external` project reports yolo=off the same way, because firstmate can
# neither observe nor perform the review tool's approval or merge.
#
# --raw prints the registered mode annotation unmapped, so a caller that must
# tell a conditional policy apart from a flat mode sees "no-mistakes-prod-only"
# itself. Not combined with --branch-prefix, which has no conditional-policy leg.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" (or
# "fm/" under --branch-prefix) and warns to stderr, so a typo never silently
# drops the gate. Other annotation tokens are ignored, as they always were, keyed
# ones included: a `<key>=<value>` token whose key is none of `forge`, `branch`, and
# `pr` resolves as it did before the forge existed, and in the mode slot it
# is read as an unknown mode. A key one or two edits from `forge` (such as
# `forg=` or `Forge=`) is still ignored, with one stderr warning naming the token
# and the forge=gerrit, forge=forgejo, and forge=external spellings. The one
# refusal is a malformed forge binding - a `forge=` token whose value is empty or outside the
# closed set - which is REFUSED in the default and --forge output forms: nothing
# on stdout, exit status 3, the token named. Resolving it to "no registered
# forge" would hand a Gerrit project the pull-request contract the binding
# exists to prevent.
# local-only with a forge is refused the same way. --branch-prefix does not make
# that check: it answers only the registered prefix, and a prefix is orthogonal
# to the forge binding, so it prints even when the forge token is malformed;
# every path that reads the forge binding (default, --forge, and spawn's
# forge-agreement check) still refuses.
# Usage: fm-project-mode.sh [--raw|--branch-prefix|--forge|--pr|--after-merge] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
BRANCH_PREFIX_QUERY=0
WANT_FORGE=0
WANT_PR=0
WANT_AFTER_MERGE=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --branch-prefix) BRANCH_PREFIX_QUERY=1; shift ;;
  --forge) WANT_FORGE=1; shift ;;
  --pr) WANT_PR=1; shift ;;
  --after-merge) WANT_AFTER_MERGE=1; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw|--branch-prefix|--forge|--pr|--after-merge] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  if [ "$WANT_AFTER_MERGE" -eq 1 ]; then :
  elif [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
    echo "fm/"
  elif [ "$WANT_FORGE" -eq 1 ]; then echo none
  elif [ "$WANT_PR" -eq 1 ]; then echo auto; else echo "no-mistakes off"; fi
  exit 0
fi

# awk emits one "near <token>" line per keyed token whose key is a near miss of
# `forge`, then "posture <mode> <yolo> <forge> <pr> <branch-prefix>" (branch-prefix
# is the raw prefix, defaulting to "fm/"; forge is `none` or the whole
# `forge=<value>` token and pr is `auto` or the whole `pr=<value>` token, so an
# empty value survives the split), or nothing if the project is
# absent. Every other token beside the mode is ignored, exactly as before either
# annotation existed.
parsed=$(awk -v n="$NAME" '
  function dist(x, y,   i, j, lx, ly, d, c, v) {
    lx = length(x); ly = length(y);
    for (i=0; i<=lx; i++) d[i,0] = i;
    for (j=0; j<=ly; j++) d[0,j] = j;
    for (i=1; i<=lx; i++) for (j=1; j<=ly; j++) {
      c = (substr(x,i,1) == substr(y,j,1)) ? 0 : 1;
      v = d[i-1,j] + 1;
      if (d[i,j-1] + 1 < v) v = d[i,j-1] + 1;
      if (d[i-1,j-1] + c < v) v = d[i-1,j-1] + c;
      d[i,j] = v;
    }
    return d[lx,ly];
  }
  {
    # Exact whole-name match on the raw line text (never a regex, so a name
    # containing dots or brackets is compared literally): the line must start
    # with "- " n, and the text right after the name must be empty, or start
    # with " [" or " - ", so a name that is a leading prefix of a longer
    # registered name does not match that longer row.
    prefix = "- " n; plen = length(prefix);
    if (substr($0, 1, plen) != prefix) next
    after = substr($0, plen + 1);
    if (after != "" && substr(after, 1, 2) != " [" && substr(after, 1, 3) != " - ") next
    mode="no-mistakes"; yolo="off"; branch="fm/"; forge="none"; pr="auto";
    if (substr(after, 1, 2) == " [") {
      s="";
      nk = split(after, rest, " ");
      for (i=1; i<=nk; i++) { s = s (s==""?"":" ") rest[i]; if (rest[i] ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      # Tokens are order-independent: +yolo, branch=<prefix>, forge=<value>, and
      # pr=<value> are recognized by their own shape wherever they appear, keyed tokens
      # that are neither are ignored (with a near-miss warning for the forge
      # spelling), and the first token left over is the mode.
      mode_set = 0
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") { yolo="on"; continue }
        if (a[j] ~ /^branch=/) { branch = substr(a[j], 8); continue }
        if (a[j] ~ /^forge=/) { forge = a[j]; continue }
        if (a[j] ~ /^pr=/) { pr = a[j]; continue }
        if (a[j] ~ /^after-merge=/) { print "aftermerge", a[j]; continue }
        if (a[j] ~ /^after-merge-note=/) { print "amnote", a[j]; continue }
        if (a[j] ~ /^[^=]+=/) {
          key = substr(a[j], 1, index(a[j], "=") - 1);
          e = dist(key, "forge");
          if (e >= 1 && e <= 2) print "near", a[j];
          if (mode_set == 0) { mode = a[j]; mode_set = 1 }
          continue
        }
        if (a[j] != "" && mode_set == 0) { mode = a[j]; mode_set = 1 }
      }
    }
    # branch is printed LAST: an empty branch= override must survive as an
    # empty final field, which only holds when nothing follows it.
    print "posture", mode, yolo, forge, pr, branch; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  if [ "$WANT_AFTER_MERGE" -eq 1 ]; then :
  elif [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
    echo "fm/"
  elif [ "$WANT_FORGE" -eq 1 ]; then echo none
  elif [ "$WANT_PR" -eq 1 ]; then echo auto; else echo "no-mistakes off"; fi
  exit 0
fi

posture=
after_merge=
after_merge_note=
while IFS=' ' read -r kind rest; do
  case "$kind" in
    aftermerge) after_merge=$rest ;;
    amnote) after_merge_note=$rest ;;
    near) echo "warn: ignoring \"$rest\" registered for $NAME in $REG; it is not a forge binding, and the forge binding is spelled forge=gerrit, forge=forgejo, or forge=external" >&2 ;;
    posture) posture=$rest ;;
  esac
done <<EOF
$parsed
EOF
while IFS=' ' read -r m y f p b; do
  mode=$m; yolo=$y; rest_forge=$f; rest_pr=$p; branch=$b
done <<EOF
$posture
EOF
forge=${rest_forge:-none}
pr=${rest_pr:-auto}
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off; branch=fm/ ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac

# Decode one percent-encoded after-merge value (see the header). Prints the
# decoded text, or fails on a backslash, a stray "%", or a control character.
after_merge_decode() {  # <value>
  local v=$1 out
  case "$v" in *\\*) return 1 ;; esac
  if printf '%s' "$v" | LC_ALL=C grep -Eq '%($|.$|[^0-9A-Fa-f]|.[^0-9A-Fa-f])'; then
    return 1
  fi
  out=$(printf '%b' "${v//%/\\x}") || return 1
  case "$out" in *[[:cntrl:]]*) return 1 ;; esac
  printf '%s' "$out"
}
after_merge_refuse() {  # <token> <why>
  echo "refused: after-merge token \"$1\" registered for $NAME in $REG $2; the accepted form is after-merge=ff:<absolute-path>@<remote>/<branch> with an optional after-merge-note=<text>, both percent-encoded (%20 is a space); correct the registry entry" >&2
  exit 3
}
if [ "$WANT_AFTER_MERGE" -eq 1 ]; then
  if [ -z "$after_merge" ]; then
    [ -z "$after_merge_note" ] || after_merge_refuse "$after_merge_note" "is a note without an after-merge action"
    exit 0
  fi
  am_value=${after_merge#after-merge=}
  case "$am_value" in
    ff:*) am_value=${am_value#ff:} ;;
    *) after_merge_refuse "$after_merge" "names an unknown action; the only action is ff" ;;
  esac
  case "$am_value" in *@*/*) ;; *) after_merge_refuse "$after_merge" "has no @<remote>/<branch> target" ;; esac
  am_path=${am_value%@*}
  am_target=${am_value##*@}
  am_remote=${am_target%%/*}
  am_branch=${am_target#*/}
  am_path=$(after_merge_decode "$am_path") || after_merge_refuse "$after_merge" "has a malformed encoding"
  case "$am_path" in /*) ;; *) after_merge_refuse "$after_merge" "names a checkout that is not an absolute path" ;; esac
  [ -n "$am_remote" ] && [ -n "$am_branch" ] || after_merge_refuse "$after_merge" "has an empty remote or branch"
  git check-ref-format --branch "$am_branch" >/dev/null 2>&1 \
    || after_merge_refuse "$after_merge" "names an invalid branch"
  case "$am_remote" in *[!A-Za-z0-9._-]*) after_merge_refuse "$after_merge" "names an invalid remote" ;; esac
  am_note=
  if [ -n "$after_merge_note" ]; then
    am_note=$(after_merge_decode "${after_merge_note#after-merge-note=}") \
      || after_merge_refuse "$after_merge_note" "has a malformed encoding"
  fi
  printf 'ff\t%s\t%s\t%s\t%s\n' "$am_path" "$am_remote" "$am_branch" "$am_note"
  exit 0
fi
if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
  echo "$branch"
  exit 0
fi

case "$forge" in
  none|forge=gerrit|forge=forgejo|forge=external) forge=${forge#forge=} ;;
  forge=)
    echo "refused: empty forge binding \"forge=\" registered for $NAME in $REG; the accepted values are forge=gerrit, forge=forgejo, and forge=external, or no forge token at all for a forge whose pull requests no-mistakes already drives; correct the registry entry" >&2
    exit 3 ;;
  *)
    echo "refused: unknown forge \"${forge#forge=}\" registered for $NAME in $REG; the accepted values are forge=gerrit, forge=forgejo, and forge=external, or no forge token at all for a forge whose pull requests no-mistakes already drives; correct the registry entry" >&2
    exit 3 ;;
esac
if [ "$forge" != none ] && [ "$mode" = local-only ]; then
  echo "refused: $NAME is registered local-only with forge=$forge in $REG; local-only publishes nothing, so a forge has no meaning there, and its landing would fast-forward local main with content the review server has never seen; register no-mistakes or direct-PR to publish through the forge, or drop the forge token to keep the project local" >&2
  exit 3
fi
if [ "$WANT_FORGE" -eq 1 ]; then
  echo "$forge"
  exit 0
fi

case "$pr" in
  auto|pr=manual) pr=${pr#pr=} ;;
  pr=)
    echo "refused: empty PR-text binding \"pr=\" registered for $NAME in $REG; the only accepted value is pr=manual, or no pr token at all for the pipeline's own PR text; correct the registry entry" >&2
    exit 3 ;;
  *)
    echo "refused: unknown PR-text binding \"$pr\" registered for $NAME in $REG; the only accepted value is pr=manual, or no pr token at all for the pipeline's own PR text; correct the registry entry" >&2
    exit 3 ;;
esac
if [ "$pr" = manual ]; then
  case "$mode" in
    no-mistakes|no-mistakes-prod-only) ;;
    *)
      echo "refused: $NAME is registered $mode with pr=manual in $REG; only a no-mistakes ship takes it, because direct-PR already leaves the PR text to the worker and local-only opens no PR; register no-mistakes, or drop the pr token" >&2
      exit 3 ;;
  esac
  if [ "$forge" != none ]; then
    echo "refused: $NAME is registered with pr=manual and forge=$forge in $REG; pr=manual ships a project with no forge binding only; drop the pr token" >&2
    exit 3
  fi
fi
if [ "$WANT_PR" -eq 1 ]; then
  echo "$pr"
  exit 0
fi
if [ "$forge" = gerrit ] && [ "$yolo" = on ]; then
  echo "refused: +yolo is registered for $NAME but yolo is inactive for forge=gerrit, so this reports yolo=off: a Gerrit Code-Review+2 is a positive attributed claim that a named human approved, and firstmate must not manufacture one (captain's decision 2026-09-15)" >&2
  yolo=off
fi
if [ "$forge" = external ] && [ "$yolo" = on ]; then
  echo "refused: +yolo is registered for $NAME but yolo is inactive for forge=external, so this reports yolo=off: firstmate can neither observe nor perform the review tool's approval or merge, so every review escalates" >&2
  yolo=off
fi
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
