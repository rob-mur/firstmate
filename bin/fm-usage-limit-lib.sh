#!/usr/bin/env bash
# fm-usage-limit-lib.sh - read a worker pane's subscription usage-limit wait.
#
# A worker that hits its plan's usage limit mid-turn cannot write a `paused:`
# status line, so its pane goes stale with nothing declared. Every verified
# rendering of that wait names when it ends, and this library is the single
# owner of reading it:
#
#   fm_usage_limit_read <screen> [now-epoch]
#     prints `limited <reset-epoch>` while the pane shows a usage-limit wait
#     with a parseable reset, `reset <reset-epoch-or-0>` once the pane says the
#     limit has reset or the parsed reset time has passed, and returns 1 with
#     no output when the bottom of the pane shows no such wait or its reset
#     cannot be parsed (the caller keeps its ordinary stale handling).
#   fm_usage_limit_menu <screen>
#     returns 0 when the bottom of the pane is the harness's interactive
#     rate-limit options menu, where typed input would answer the menu.
#
# Only the last FM_USAGE_LIMIT_TAIL_LINES non-blank lines are read, so the same
# words quoted in a diff or a note higher on the pane do not count.
# Recorded wording (Claude Code, 2026-11):
#   You've hit your 5-hour limit · resets 3:40pm (Europe/Paris)
#   You've hit your weekly limit · resets Nov 28, 3pm (Europe/Paris)
#   Usage limit reached · continuing automatically at 7:10pm · esc to cancel
#   2. Wait here, then continue automatically at Nov 28, 3pm
#   Usage limit has reset · Press enter to continue
# A time with no date is the occurrence of that wall-clock time nearest to now
# (5-hour windows never span 12 hours); a date with no year is the nearest year.
# A missing zone is the host's local zone, which is where the harness renders.
# Date math runs in python3 only after the cheap shell match, so panes that show
# no limit wording never start an interpreter.

FM_USAGE_LIMIT_TAIL_LINES=${FM_USAGE_LIMIT_TAIL_LINES:-15}

_fm_usage_limit_tail() {  # <screen>
  printf '%s\n' "$1" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' \
    | awk 'NF' | tail -n "$FM_USAGE_LIMIT_TAIL_LINES"
}

fm_usage_limit_menu() {  # <screen>
  local tail
  tail=$(_fm_usage_limit_tail "${1-}")
  case "$tail" in
    *'Stop and wait for limit to reset'*'continue automatically at'*) return 0 ;;
  esac
  return 1
}

fm_usage_limit_read() {  # <screen> [now-epoch]
  local tail now=${2:-} out
  [ -n "$now" ] || now=$(date +%s)
  tail=$(_fm_usage_limit_tail "${1-}")
  case "$tail" in
    *'limit has reset'*) ;;
    *'hit your '*' limit'*'resets '*|*'imit reached'*'continuing automatically at '*|*'continue automatically at '*) ;;
    *) return 1 ;;
  esac
  out=$(printf '%s\n' "$tail" | python3 -I -c '
import re, sys, datetime as dt
try:
    from zoneinfo import ZoneInfo
except ImportError:
    sys.exit(1)
now = int(sys.argv[1])
lines = sys.stdin.read().splitlines()
WHEN = (r"(?:([A-Z][a-z]{2}) (\d{1,2})(?:st|nd|rd|th)?,? (?:(\d{4}),? )?)?"
        r"(\d{1,2})(?::(\d{2}))?\s*([ap]m)(?:\s*\(([^)]+)\))?")
LIM = re.compile(r"(?:hit your [^\n]*?limit[^\n]*?resets |continu(?:ing|e) automatically at )" + WHEN, re.I)
MON = {m: i + 1 for i, m in enumerate("jan feb mar apr may jun jul aug sep oct nov dec".split())}
hit = None
reset_seen = False
for line in lines:
    if "limit has reset" in line:
        reset_seen = True
    m = LIM.search(line)
    if m:
        hit = m
if hit is None:
    print("reset 0" if reset_seen else "")
    sys.exit(0)
mon, day, year, hh, mm, ap, tz = hit.groups()
try:
    zone = ZoneInfo(tz) if tz else dt.datetime.now().astimezone().tzinfo
except Exception:
    sys.exit(1)
h = int(hh) % 12 + (12 if ap.lower() == "pm" else 0)
m = int(mm or 0)
ref = dt.datetime.fromtimestamp(now, zone)
cands = []
if mon:
    mo = MON.get(mon.lower())
    if mo is None:
        sys.exit(1)
    years = [int(year)] if year else [ref.year - 1, ref.year, ref.year + 1]
    for y in years:
        try:
            cands.append(dt.datetime(y, mo, int(day), h, m, tzinfo=zone))
        except ValueError:
            pass
else:
    for d in (-1, 0, 1):
        base = (ref + dt.timedelta(days=d)).date()
        cands.append(dt.datetime(base.year, base.month, base.day, h, m, tzinfo=zone))
if not cands:
    sys.exit(1)
reset = int(min(cands, key=lambda c: abs(c.timestamp() - now)).timestamp())
print(("reset %d" if reset_seen or reset <= now else "limited %d") % reset)
' "$now" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
