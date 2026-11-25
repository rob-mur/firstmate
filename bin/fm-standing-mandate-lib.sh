#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Shared facts for a secondmate's standing mandate: its dated rest, its idle
# marker, and the parent's "stopped with standing work" test.
#
# Rest.  A mate whose posture gives it standing work (drive, or duty with a
# named trigger) may declare a dated rest with bin/fm-secondmate-rest.sh.  The
# record lives in that mate's own state directory as .mandate-rest, with
# key=value lines:
#   until_epoch=<unix seconds>
#   until=<YYYY-MM-DDTHH:MMZ>
#   reason=<one line>
#   set_epoch=<unix seconds>
# A rest is active while now < until_epoch.  A missing, unreadable, malformed,
# or expired record means no rest, so every reader treats the mate as owing
# work rather than trusting a broken record.
#
# Idle marker.  bin/fm-home-summary-refresh.sh keeps state/.idle-since, the
# first epoch this home's published summary showed no_active_work, and clears
# it when the summary shows any known other state.  The summary carries it as
# idle_since and the rest as mandate_rest, so both reach the parent for local
# and remote homes alike.
#
# Stopped test.  FM_STANDING_MANDATE_JQ defines
#   mandate_stopped_since($now; $grace)
# over an object {posture, state, valid, mandate_rest, idle_since,
# generated_epoch}.  It yields the idle_since epoch when a drive mate's summary,
# published within the last 30 minutes, has shown no_active_work for at least
# $grace seconds with no active rest, and null otherwise.  An old summary proves
# nothing about the mate now, so it never counts as stopped.  The bearings view
# and the parent watcher both use it, so one rule decides "stopped".
#
# Mate-home helpers.  A mate's own watcher and turn-end guard read its posture
# (fm_standing_mandate_posture), whether standing work needs a live watcher
# (fm_standing_mandate_needs_watch), the shared 15m/1h/4h wake back-off
# (fm_standing_mandate_wake_due and its marker), and its open offer cards
# (fm_standing_mandate_offer_cards).  docs/configuration.md "Standing-work
# wakes in the mate home" owns the wake contract.

FM_MANDATE_REST_MAX_SECONDS=86400

MANDATE_REST_UNTIL_EPOCH=
MANDATE_REST_UNTIL=
MANDATE_REST_REASON=
MANDATE_REST_SET_EPOCH=

fm_mandate_rest_path() {  # <state-dir>
  printf '%s/.mandate-rest\n' "$1"
}

# Parse the record into the MANDATE_REST_* globals.  Returns 0 only when the
# record is well formed and still active at <now>.
fm_mandate_rest_read() {  # <state-dir> <now-epoch>
  local file key value
  MANDATE_REST_UNTIL_EPOCH=
  MANDATE_REST_UNTIL=
  MANDATE_REST_REASON=
  MANDATE_REST_SET_EPOCH=
  file=$(fm_mandate_rest_path "$1")
  [ -f "$file" ] && [ -r "$file" ] || return 1
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      until_epoch) MANDATE_REST_UNTIL_EPOCH=$value ;;
      until) MANDATE_REST_UNTIL=$value ;;
      reason) MANDATE_REST_REASON=$value ;;
      set_epoch) MANDATE_REST_SET_EPOCH=$value ;;
    esac
  done < "$file"
  case "$MANDATE_REST_UNTIL_EPOCH" in ''|*[!0-9]*) return 1 ;; esac
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  [ "$MANDATE_REST_UNTIL_EPOCH" -gt "$2" ]
}

fm_mandate_rest_active() {  # <state-dir> <now-epoch>
  fm_mandate_rest_read "$1" "$2"
}

# Print the active rest as one JSON object, or `null` when no rest is active.
fm_mandate_rest_json() {  # <state-dir> <now-epoch>
  if fm_mandate_rest_read "$1" "$2"; then
    jq -cn --argjson until_epoch "$MANDATE_REST_UNTIL_EPOCH" \
      --arg until "$MANDATE_REST_UNTIL" --arg reason "$MANDATE_REST_REASON" \
      '{until_epoch:$until_epoch, until:$until, reason:($reason | .[:240])}'
  else
    printf 'null\n'
  fi
}

# Atomically write a rest record.  Callers validate the bound and the reason.
fm_mandate_rest_write() {  # <state-dir> <until-epoch> <until-iso> <reason> <now-epoch>
  local file tmp
  file=$(fm_mandate_rest_path "$1")
  mkdir -p "${file%/*}" || return 1
  tmp="$file.tmp.$$"
  {
    printf 'until_epoch=%s\n' "$2"
    printf 'until=%s\n' "$3"
    printf 'reason=%s\n' "$4"
    printf 'set_epoch=%s\n' "$5"
  } > "$tmp" && mv -f "$tmp" "$file"
}

FM_STANDING_MANDATE_STOPPED_GRACE=${FM_STANDING_MANDATE_STOPPED_GRACE:-900}
case "$FM_STANDING_MANDATE_STOPPED_GRACE" in ''|*[!0-9]*) FM_STANDING_MANDATE_STOPPED_GRACE=900 ;; esac

# shellcheck disable=SC2016 # jq program text, not shell expansion.
FM_STANDING_MANDATE_JQ='
def mandate_stopped_since($now; $grace):
  if (.posture // "routed") == "drive"
     and .valid == true
     and .state == "no_active_work"
     and ((.generated_epoch // null) | type) == "number"
     and ($now - .generated_epoch) <= 1800
     and ((.mandate_rest // null) == null
          or ((.mandate_rest.until_epoch // 0) | type) != "number"
          or (.mandate_rest.until_epoch // 0) <= $now)
     and ((.idle_since // null) | type) == "number"
     and ($now - .idle_since) >= $grace
  then .idle_since else null end;
'

# Keep state/.idle-since in step with a just-published summary.
fm_standing_mandate_idle_update() {  # <state-dir> <summary-file>
  local state=$1 summary=$2 line tmp
  line=$(jq -r '[(.state // ""), ((.idle_since // "") | tostring)] | @tsv' "$summary" 2>/dev/null) || return 0
  case "$line" in
    no_active_work$'\t'[0-9]*)
      tmp="$state/.idle-since.tmp.$$"
      printf '%s\n' "${line#*$'\t'}" > "$tmp" && mv -f "$tmp" "$state/.idle-since"
      ;;
    unknown$'\t'*|$'\t'*|'') ;;
    *) rm -f -- "$state/.idle-since" ;;
  esac
}

# Mate-home posture.  config/secondmate-posture holds this home's canonical
# registered posture (bin/fm-config-inherit-lib.sh writes it).  Prints it only
# for a marked secondmate home; prints nothing otherwise, and a missing or empty
# file means routed.
fm_standing_mandate_posture() {  # <home>
  local home=$1 line=
  [ -n "$home" ] && [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || return 0
  if [ -f "$home/config/secondmate-posture" ] && [ -r "$home/config/secondmate-posture" ]; then
    IFS= read -r line < "$home/config/secondmate-posture" || true
  fi
  line=$(printf '%s' "$line" | tr -s '[:space:]' ' ')
  line=${line# }
  line=${line% }
  printf '%s\n' "${line:-routed}"
}

# True when this home's posture keeps its own watcher on duty with nothing in
# flight: drive, or duty with a watched trigger, and no active rest.  A drive
# home whose last summary shows anything other than no_active_work (a captain
# question, an external hold, live children) is covered by that state instead.
# bin/fm-supervision-lib.sh reads this as a supervision need.
fm_standing_mandate_needs_watch() {  # <home> <state-dir> <now-epoch>
  local posture state=
  posture=$(fm_standing_mandate_posture "$1")
  case "$posture" in
    drive|'duty offered-item-taken') ;;
    *) return 1 ;;
  esac
  fm_mandate_rest_active "$2" "$3" && return 1
  if [ "$posture" = drive ] && [ -f "$2/home-summary.json" ]; then
    state=$(jq -r '.state // ""' "$2/home-summary.json" 2>/dev/null || true)
    case "$state" in
      ''|no_active_work|unknown) ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# Back-off for a mate's own standing-mandate wakes: the first wake once the
# episode is FM_STANDING_MANDATE_FIRST_WAKE seconds old (15 minutes), the second
# 1 hour after it, then every 4 hours.  Succeeds when a wake is due.
FM_STANDING_MANDATE_FIRST_WAKE=${FM_STANDING_MANDATE_FIRST_WAKE:-900}
case "$FM_STANDING_MANDATE_FIRST_WAKE" in ''|*[!0-9]*) FM_STANDING_MANDATE_FIRST_WAKE=900 ;; esac
fm_standing_mandate_wake_due() {  # <episode-start> <wakes-so-far> <last-wake-epoch> <now>
  local start=$1 count=$2 last=$3 now=$4 gap v
  for v in "$start" "$count" "$last" "$now"; do
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done
  if [ "$count" -eq 0 ]; then
    [ $(( now - start )) -ge "$FM_STANDING_MANDATE_FIRST_WAKE" ]
    return
  fi
  if [ "$count" -eq 1 ]; then gap=3600; else gap=14400; fi
  [ $(( now - last )) -ge "$gap" ]
}

# Read a "<episode> <count> <last>" back-off marker into MANDATE_WAKE_* globals;
# a missing or malformed marker reads as no episode.
fm_standing_mandate_marker_read() {  # <file>
  MANDATE_WAKE_EPISODE=
  MANDATE_WAKE_COUNT=0
  MANDATE_WAKE_LAST=0
  [ -f "$1" ] || return 1
  local v
  read -r MANDATE_WAKE_EPISODE MANDATE_WAKE_COUNT MANDATE_WAKE_LAST < "$1" 2>/dev/null || true
  for v in "$MANDATE_WAKE_EPISODE" "$MANDATE_WAKE_COUNT" "$MANDATE_WAKE_LAST"; do
    case "$v" in
      ''|*[!0-9]*) MANDATE_WAKE_EPISODE=; MANDATE_WAKE_COUNT=0; MANDATE_WAKE_LAST=0; return 1 ;;
    esac
  done
}

fm_standing_mandate_marker_write() {  # <file> <episode> <count> <last>
  local tmp="$1.tmp.$$"
  printf '%s %s %s\n' "$2" "$3" "$4" > "$tmp" && mv -f "$tmp" "$1"
}

# Offer cards.  An offer card is a captain hold in this home's backlog that
# carries `Captain hold option:` lines (bin/fm-captain-hold.sh hold --option).
# Prints the ids of the open offer cards in this home's published summary, one
# per line, after a first line that is `complete` when the summary lists every
# hold and `partial` when it omitted some.  Fails when the summary is missing,
# invalid, or older than 30 minutes, since it then proves nothing.
fm_standing_mandate_offer_cards() {  # <summary-file> <now-epoch>
  [ -f "$1" ] || return 1
  jq -er --argjson now "$2" '
    select(.valid == true
           and ((.generated_epoch // null) | type) == "number"
           and ($now - .generated_epoch) <= 1800)
    | (if any((.omitted // [])[]; .surface == "decisions_open" or .surface == "queued")
       then "partial" else "complete" end),
      ([(.decisions_open // [])[]
        | select(.verb == "captain-hold" and (((.choices // {}).options // []) | length) > 0) | .id]
       + [(.queued // [])[]
          | select(.hold_kind == "captain" and (((.choices // {}).options // []) | length) > 0) | .id]
       | map(select(type == "string")) | unique | .[])' "$1" 2>/dev/null
}
