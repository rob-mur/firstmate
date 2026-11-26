#!/usr/bin/env bash
# fm-unowned-work.sh - list the captain's forgotten Draft MRs/PRs and paused work.
#
# Read-only on every forge and every home. One sweep:
#   1. reads the captain's open Draft MRs with ONE GitLab GraphQL call
#      (glab api graphql; archived projects are left out by GitLab) and the
#      captain's open Draft PRs with ONE Forgejo issues search (curl with the
#      token forgejo-cli stores), each only when config/unowned-work enables it;
#   2. joins each Draft to the captain's held cards (bin/fm-captain-calls.sh of
#      this home, calls[] and skipped[]), to the task records of this home and of
#      every local secondmate home in data/secondmates.md (state/<task>.meta,
#      state/<task>.status, open data/backlog.md rows), and to each owning task's
#      current state (bin/fm-crew-state.sh);
#   3. writes the result to state/unowned-work.json under FM_HOME.
#
# A finding is work firstmate must act on - raise a card or close it. This
# script never raises a card, steers a worker, or writes to a forge.
#
# Rules, in order, for each Draft (a Draft updated less than 30 minutes ago is
# skipped this sweep, as its worker may not have recorded it yet):
#   - waits on someone else: a reviewer who is not the captain (GitLab), or a
#     repo listed reviewer-owned in config/unowned-work. Never a finding, and
#     not counted toward the cap.
#   - held card: a call or deferred hold of bin/fm-captain-calls.sh names the
#     Draft's web address (trailing punctuation removed). Not a finding.
#   - task record: a task that has not finished names the Draft - its meta
#     pr= or pr_extra=, its status log, or its open backlog row - or its meta
#     branch= is the Draft's source branch and its meta project= is the same
#     repo. A standing babysit-mrs-* sweep never owns a Draft. The owning task
#     is a finding only when its current state is done (a Draft cannot merge,
#     so it waits on nobody) or paused with a last state line that waits on the
#     captain (WAITS_ON_CAPTAIN below); any other state is moving it. An open
#     backlog row with no worker yet also owns it.
#   - otherwise: "no task, no worker and no card".
# A prototype Draft (source branch prototype/... or "prototype" in its title)
# follows the same rules but is not counted toward the cap.
# Paused work with no Draft: every live task of each local home whose last
# state line is paused on the captain, whose current state is paused, and
# that no held card covers (by task or by a link of that line) is a finding.
# Draft cap: more than <cap> (default 5) of the captain's open non-prototype
# Drafts that do not wait on someone else give one finding listing them,
# even when each one is owned.
#
# state/unowned-work.json:
#   {"checked_at": <epoch of the last good sweep, 0 if none>,
#    "read_failed_at": <epoch the current run of failed sweeps began|null>,
#    "failed_sweeps": <failed sweeps in a row>,
#    "findings": [{"key", "kind": "draft|paused|cap", "repo", "ref", "url",
#                  "reason", "since": <epoch of the first sweep that saw key>}]}
# key is "<MR web URL or task id or cap>+<reason>"; since is kept across sweeps.
# A failed forge or card read keeps the last good findings and checked_at and
# only advances read_failed_at and failed_sweeps.
#
# --check is the watcher check mode: it sweeps, then prints one line for each
# finding key it has not printed before (state/unowned-work.announced holds
# the printed keys; a key that leaves the findings is forgotten, so it prints
# again if it comes back), and prints "unowned-work: forge unreadable since
# HH:MMZ" once, on the third failed sweep in a row. Otherwise it prints
# nothing. --print-check prints the 3-line state/unowned-work.check.sh that
# runs it; register it with bin/fm-check-register.sh unowned-work.
#
# config/unowned-work (optional; absent means no forge reads, so only paused
# work is listed). One setting per line, # starts a comment:
#   gitlab                         read GitLab Drafts with glab's default host
#   forgejo <host> <login>...      read Forgejo PRs on <host> authored by <login>s
#   reviewer-owned <repo>...       repos another reviewer merges
#   cap <n>                        the Draft cap (default 5)
#
# Environment (tests and tuning):
#   FM_UNOWNED_GRACE                seconds of grace after a Draft update (1800)
#   FM_UNOWNED_FORGEJO_KEYS         forgejo-cli keys.json path
#   FM_UNOWNED_CALLS_CMD            command printing the captain-calls JSON
#   FM_UNOWNED_CREW_STATE_CMD       command printing "state: <s> ..." for a task
#   FM_UNOWNED_NOW                  the sweep's epoch
#
# Exit 0 after a sweep (good or failed); 2 on usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
OUT="$STATE/unowned-work.json"
ANNOUNCED="$STATE/unowned-work.announced"
GRACE=${FM_UNOWNED_GRACE:-1800}
case "$GRACE" in ''|*[!0-9]*) GRACE=1800 ;; esac
NOW=${FM_UNOWNED_NOW:-$(date +%s)}
KEYS_FILE=${FM_UNOWNED_FORGEJO_KEYS:-$HOME/.local/share/forgejo-cli/keys.json}
CALLS_CMD=${FM_UNOWNED_CALLS_CMD:-$SCRIPT_DIR/fm-captain-calls.sh}
CREW_STATE_CMD=${FM_UNOWNED_CREW_STATE_CMD:-$SCRIPT_DIR/fm-crew-state.sh}

usage() {
  cat <<'EOF'
Usage: fm-unowned-work.sh [--check | --print-check]

Sweep the captain's open Draft MRs/PRs and paused work that no task, worker
or held card moves, and write state/unowned-work.json under FM_HOME.
  (no option)    sweep and print the JSON
  --check        sweep; print one line per new finding, and one line on the
                 third failed forge read in a row; else print nothing
  --print-check  print the 3-line state/unowned-work.check.sh

The script header owns the rules, the JSON shape and config/unowned-work.
EOF
}

MODE=json
case "${1:-}" in
  '') ;;
  --check) MODE=check ;;
  --print-check)
    printf '#!/usr/bin/env bash\n# Watcher check: list unowned Drafts and paused work (bin/fm-unowned-work.sh).\nexec %q --check\n' "$SCRIPT_DIR/fm-unowned-work.sh"
    exit 0 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-unowned-work: jq is required" >&2; exit 1; }
[ -d "$STATE" ] || { echo "fm-unowned-work: no state directory" >&2; exit 1; }

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-unowned-work.XXXXXX") || exit 1
trap 'rm -rf -- "$WORK"' EXIT
umask 077

# Copied from bearings `run` WAITS_ON_CAPTAIN (the paused-worker rule, about
# run:540): a paused line waits on the captain only when it says so, not when
# it names the captain in a later step or says no captain call is needed.
# Oniguruma (jq) reads the same extended pattern.
WAITS_ON_CAPTAIN='
    \b(?:wait\w*|idl\w*|await\w*|needs?|open)(?:\ only)?\ (?:(?:on|for)\ )?(?:the\ )?captain\b
  | \bfor\ the\ captain\ to\b
  | \b(?:ready\ for|without)\ the\ captain\b
  | \bthe\ captain\ must\b
  | \bwhen\ the\ captain\ (?:has|saves|answers|decides|says)\b
  | (?<!no\ )\bcaptain(?:'"'"'s)?\ (?:\S+\ )?(?:word|call|decision|answer|review|approval|ok|acknowledgement|dismissal)s?\b
  | \bnext:\ (?:the\ )?captain\b
  | \bwait\w*\ for\ the\ next\ save\b
'

# --- config -----------------------------------------------------------------
GITLAB=0
FORGEJO_HOST=
FORGEJO_LOGINS=
REVIEWER_OWNED=' '
CAP=5
if [ -f "$CONFIG/unowned-work" ]; then
  while read -r k rest || [ -n "$k" ]; do
    rest=${rest%%#*}
    case "$k" in
      ''|'#'*) ;;
      gitlab) GITLAB=1 ;;
      forgejo) FORGEJO_HOST=${rest%% *}; FORGEJO_LOGINS=${rest#"$FORGEJO_HOST"} ;;
      reviewer-owned) REVIEWER_OWNED="$REVIEWER_OWNED$rest " ;;
      cap) case "$rest" in *[!0-9\ ]*|'') ;; *) CAP=${rest// /} ;; esac ;;
    esac
  done < "$CONFIG/unowned-work"
fi

# --- helpers ----------------------------------------------------------------
# Web addresses in text, one per line, without trailing punctuation.
urls_in() {
  grep -oE 'https?://[^][:space:]<>"()`]+' | sed -E 's/[.,;:?!)]+$//; s#/$##'
}

# The last state line of a status log, or nothing.
last_state_line() {
  [ -f "$1" ] || return 0
  awk '{ w = $1; sub(/\[.*/, "", w); sub(/:$/, "", w)
         if (w ~ /^(working|paused|done|blocked|failed|needs-decision)$/) last = $0 }
       END { if (last != "") print last }' "$1"
}

# True when a status line is paused and waits on the captain.
paused_on_captain() {
  case "$1" in paused*) ;; *) return 1 ;; esac
  jq -en --arg t "${1#* }" --arg re "$WAITS_ON_CAPTAIN" '$t | test($re; "ix")' >/dev/null 2>&1
}

# Current state word of a task in a home.
crew_state() {
  local out
  out=$(FM_HOME="$1" FM_CREW_STATE_NO_FORGE=1 "$CREW_STATE_CMD" "$2" 2>/dev/null) || true
  out=${out#state: }
  printf '%s\n' "${out%% *}"
}

meta_field() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# --- forge reads ------------------------------------------------------------
FAILED=0
: > "$WORK/drafts.jsonl"
# shellcheck disable=SC2016 # jq program, not shell
EPOCH_JQ='def epoch: try ((sub("\\.[0-9]+"; "")) as $s
  | if ($s | test("Z$")) then ($s | fromdateiso8601)
    else ($s | capture("^(?<d>.{19})(?<sg>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})$") as $c
      | (($c.d + "Z") | fromdateiso8601)
        - (if $c.sg == "+" then 1 else -1 end) * (($c.h | tonumber) * 3600 + ($c.m | tonumber) * 60))
    end) catch 0;'

if [ "$GITLAB" = 1 ]; then
  q='query { currentUser { username authoredMergeRequests(state: opened, draft: true, first: 50) { nodes { webUrl iid title sourceBranch updatedAt reviewers { nodes { username } } headPipeline { status } } } } }'
  if glab api graphql -f query="$q" > "$WORK/gitlab.json" 2>/dev/null \
    && jq -e '.data.currentUser.authoredMergeRequests.nodes | type == "array"' "$WORK/gitlab.json" >/dev/null 2>&1; then
    jq -c --arg owned "$REVIEWER_OWNED" "$EPOCH_JQ"'
      .data.currentUser as $u | $u.authoredMergeRequests.nodes[]
      | (.webUrl | sub("/-/merge_requests/.*$"; "") | sub("^.*/"; "")) as $repo
      | {url: (.webUrl | sub("/$"; "")), repo: $repo, ref: ("!" + (.iid | tostring)),
         branch: (.sourceBranch // ""), updated: ((.updatedAt // "") | epoch),
         pipeline: (.headPipeline.status // ""),
         other: (([.reviewers.nodes[]?.username] | map(select(. != $u.username)) | length > 0)
                 or ($owned | contains(" " + $repo + " "))),
         prototype: (((.sourceBranch // "") | test("^prototype[/-]"; "i"))
                     or ((.title // "") | test("\\bprototype\\b"; "i")))}' \
      "$WORK/gitlab.json" >> "$WORK/drafts.jsonl" || FAILED=1
  else
    FAILED=1
  fi
fi

if [ -n "$FORGEJO_HOST" ]; then
  tok=$(jq -r --arg h "$FORGEJO_HOST" '.hosts[$h].token // empty' "$KEYS_FILE" 2>/dev/null)
  if [ -n "$tok" ]; then
    printf 'Authorization: token %s\n' "$tok" > "$WORK/hdr"
    if curl -fsS --max-time 10 -H @"$WORK/hdr" \
        "https://$FORGEJO_HOST/api/v1/repos/issues/search?type=pulls&state=open&limit=50" \
        > "$WORK/forgejo.json" 2>/dev/null \
      && jq -e 'type == "array"' "$WORK/forgejo.json" >/dev/null 2>&1; then
      jq -c --arg logins " $FORGEJO_LOGINS " --arg owned "$REVIEWER_OWNED" "$EPOCH_JQ"'
        .[] | select(.pull_request.draft == true)
        | select((" " + (.user.login // "") + " ") as $l | $logins | contains($l))
        | (.repository.name // "") as $repo
        | {url: ((.html_url // .pull_request.html_url // "") | sub("/$"; "")), repo: $repo,
           ref: ("#" + (.number | tostring)), branch: "", updated: ((.updated_at // "") | epoch),
           pipeline: "", other: ($owned | contains(" " + $repo + " ")),
           prototype: ((.title // "") | test("\\bprototype\\b"; "i"))}' \
        "$WORK/forgejo.json" >> "$WORK/drafts.jsonl" || FAILED=1
    else
      FAILED=1
    fi
    rm -f "$WORK/hdr"
  else
    FAILED=1
  fi
fi

# --- held cards -------------------------------------------------------------
if [ "$FAILED" = 0 ]; then
  if FM_HOME="$FM_HOME" FM_CAPTAIN_CALLS_PR_CHECK=0 "$CALLS_CMD" > "$WORK/calls.json" 2>/dev/null \
    && jq -e '.calls | type == "array"' "$WORK/calls.json" >/dev/null 2>&1; then
    jq -r '[.calls[]?, .skipped[]?] | tostring' "$WORK/calls.json" | urls_in | sort -u > "$WORK/card-links"
    jq -r '[.calls[]?, .skipped[]?][] | .task // empty' "$WORK/calls.json" | sort -u > "$WORK/card-tasks"
  else
    FAILED=1
  fi
fi

# --- write ------------------------------------------------------------------
prev='{"checked_at":0,"read_failed_at":null,"failed_sweeps":0,"findings":[]}'
if [ -f "$OUT" ] && p=$(jq -ce 'select(type == "object")' "$OUT" 2>/dev/null); then prev=$p; fi

write_out() {  # <json>
  printf '%s\n' "$1" > "$WORK/out.json" && mv -f -- "$WORK/out.json" "$OUT"
}

if [ "$FAILED" = 1 ]; then
  next=$(jq -c --argjson now "$NOW" \
    '.read_failed_at = (.read_failed_at // $now) | .failed_sweeps = ((.failed_sweeps // 0) + 1)' <<<"$prev")
  write_out "$next" || exit 1
  if [ "$MODE" = check ]; then
    if [ "$(jq -r '.failed_sweeps' <<<"$next")" = 3 ]; then
      printf 'unowned-work: forge unreadable since %s\n' \
        "$(date -u -d "@$(jq -r '.read_failed_at' <<<"$next")" +%H:%MZ 2>/dev/null \
          || date -u -r "$(jq -r '.read_failed_at' <<<"$next")" +%H:%MZ)"
    fi
  else
    printf '%s\n' "$next"
  fi
  exit 0
fi

# --- task records of every local home ---------------------------------------
HOMES=$FM_HOME
MATES=' '
if [ -f "$DATA/secondmates.md" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    MATES="$MATES$SECONDMATE_REGISTRY_ID "
    [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] && continue
    [ -d "$SECONDMATE_REGISTRY_HOME/state" ] && HOMES="$HOMES"$'\n'"$SECONDMATE_REGISTRY_HOME"
  done < "$DATA/secondmates.md"
fi

# tasks.tsv: n, home, task, has-meta (1/0), branch, repo, split by \037 (a
# non-whitespace separator, so an empty branch keeps its field); task-<n>.links: its links.
: > "$WORK/tasks.tsv"
n=0
while IFS= read -r h; do
  [ -n "$h" ] || continue
  b="$h/data/backlog.md"
  if [ -f "$b" ]; then
    # One "<task>\t<text>" line per line of each open row (not in Done).
    awk '
      /^##[[:space:]]/ { done = ($0 ~ /^##[[:space:]]+Done[[:space:]]*$/); id = ""; next }
      done { next }
      /^[-*][[:space:]]+\[[ ]\][[:space:]]+[^[:space:]]+[[:space:]]+-/ { id = $3; print id "\t" $0; next }
      /^[-*][[:space:]]/ { id = ""; next }
      id != "" && /^[[:space:]]/ { print id "\t" $0 }
    ' "$b" > "$WORK/rows.tsv"
  else
    : > "$WORK/rows.tsv"
  fi
  for id in $( { cut -f1 "$WORK/rows.tsv"; for m in "$h"/state/*.meta; do [ -f "$m" ] && basename "$m" .meta; done; } | sort -u); do
    case "$id" in babysit-mrs-*) continue ;; esac
    case "$MATES" in *" $id "*) continue ;; esac
    n=$((n + 1))
    m="$h/state/$id.meta"
    if [ -f "$m" ]; then
      has=1
      branch=$(meta_field "$m" branch)
      proj=$(meta_field "$m" project)
      proj=${proj%/}
      proj=${proj##*/}
    else
      has=0 branch='' proj=''
    fi
    {
      [ "$has" = 1 ] && { meta_field "$m" pr; meta_field "$m" pr_extra; }
      [ -f "$h/state/$id.status" ] && cat "$h/state/$id.status"
      awk -F'\t' -v id="$id" '$1 == id { sub(/^[^\t]*\t/, ""); print }' "$WORK/rows.tsv"
    } | urls_in | sort -u > "$WORK/task-$n.links"
    printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$n" "$h" "$id" "$has" "$branch" "$proj" >> "$WORK/tasks.tsv"
  done
done <<<"$HOMES"

# --- join -------------------------------------------------------------------
: > "$WORK/findings.jsonl"
REPORTED_TASKS=' '
add_finding() {  # <key> <kind> <repo> <ref> <url> <reason>
  jq -cn --arg key "$1" --arg kind "$2" --arg repo "$3" --arg ref "$4" --arg url "$5" --arg reason "$6" \
    '{key: $key, kind: $kind, repo: $repo, ref: $ref, url: $url, reason: $reason}' >> "$WORK/findings.jsonl"
}

capped=
capn=0
while IFS= read -r d; do
  [ -n "$d" ] || continue
  url=$(jq -r .url <<<"$d"); repo=$(jq -r .repo <<<"$d"); ref=$(jq -r .ref <<<"$d")
  branch=$(jq -r .branch <<<"$d"); updated=$(jq -r .updated <<<"$d")
  other=$(jq -r .other <<<"$d"); proto=$(jq -r .prototype <<<"$d")
  [ "$other" = true ] && continue
  if [ "$proto" != true ]; then
    capn=$((capn + 1))
    capped="$capped${capped:+, }$repo $ref"
  fi
  [ $((NOW - updated)) -lt "$GRACE" ] && continue
  grep -qxF -- "$url" "$WORK/card-links" && continue
  case "$(jq -r .pipeline <<<"$d")" in SUCCESS) adj='green ' ;; FAILED) adj='red ' ;; *) adj= ;; esac
  [ "$proto" = true ] && adj="${adj}prototype "
  owner='' owner_home='' owner_has=''
  while IFS=$'\037' read -r tn th tid thas tbranch tproj; do
    if grep -qxF -- "$url" "$WORK/task-$tn.links" \
      || { [ -n "$branch" ] && [ "$tbranch" = "$branch" ] && [ "$tproj" = "$repo" ]; }; then
      owner=$tid owner_home=$th owner_has=$thas
      break
    fi
  done < "$WORK/tasks.tsv"
  if [ -z "$owner" ]; then
    add_finding "$url+${adj}Draft, no task, no worker and no card" draft "$repo" "$ref" "$url" \
      "${adj}Draft, no task, no worker and no card"
    continue
  fi
  [ "$owner_has" = 1 ] || continue
  grep -qxF -- "$owner" "$WORK/card-tasks" && continue
  st=$(crew_state "$owner_home" "$owner")
  reason=
  if [ "$st" = 'done' ]; then
    reason="${adj}Draft, task $owner done, no card"
  elif [ "$st" = paused ] && paused_on_captain "$(last_state_line "$owner_home/state/$owner.status")"; then
    reason="${adj}Draft, task $owner paused on you, no card"
  fi
  if [ -n "$reason" ]; then
    add_finding "$url+$reason" draft "$repo" "$ref" "$url" "$reason"
    REPORTED_TASKS="$REPORTED_TASKS$owner "
  fi
done < "$WORK/drafts.jsonl"

if [ "$capn" -gt "$CAP" ]; then
  add_finding "cap+Drafts over cap $CAP" cap "" "$capn Drafts" "" "$capn Drafts open, cap $CAP: $capped"
fi

# Paused work on the captain that no card covers.
while IFS=$'\037' read -r tn th tid thas tbranch tproj; do
  [ "$thas" = 1 ] || continue
  case "$REPORTED_TASKS" in *" $tid "*) continue ;; esac
  grep -qxF -- "$tid" "$WORK/card-tasks" && continue
  last=$(last_state_line "$th/state/$tid.status")
  paused_on_captain "$last" || continue
  if printf '%s\n' "$last" | urls_in | grep -qxF -f "$WORK/card-links" 2>/dev/null; then continue; fi
  [ "$(crew_state "$th" "$tid")" = paused ] || continue
  link=$(printf '%s\n' "$last" | urls_in | head -1)
  add_finding "$tid+paused on you, no card" paused "$tproj" "$tid" "$link" "paused on you, no card"
done < "$WORK/tasks.tsv"

next=$(jq -cs --argjson prev "$prev" --argjson now "$NOW" '
  ($prev.findings // [] | map({(.key): .since}) | add // {}) as $since
  | {checked_at: $now, read_failed_at: null, failed_sweeps: 0,
     findings: (unique_by(.key) | map(. + {since: ($since[.key] // $now)}))}' "$WORK/findings.jsonl") || exit 1
write_out "$next" || exit 1

if [ "$MODE" = check ]; then
  touch "$ANNOUNCED"
  jq -r '.findings[] | [.key, .repo, .ref, .reason, .url] | @tsv' <<<"$next" \
    | while IFS=$'\t' read -r key repo ref reason url; do
      grep -qxF -- "$key" "$ANNOUNCED" && continue
      printf 'unowned-work: %s: %s%s\n' "${repo:+$repo }$ref" "$reason" "${url:+  $url}"
    done
  jq -r '.findings[].key' <<<"$next" > "$WORK/announced" && mv -f -- "$WORK/announced" "$ANNOUNCED"
else
  printf '%s\n' "$next"
fi
