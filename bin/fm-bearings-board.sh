#!/usr/bin/env bash
# fm-bearings-board.sh - build and arm the /bearings lavish fleet board.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# fm-bearings-board.v1 JSON payload in a data file beside it.
# bin/fm-bearings-board-payload.sh
# generates that payload from the fleet snapshot, so its shape is the same every
# session, and this script owns the mechanics so the invoking agent's per-run
# work stays "generate the JSON, run build" - the agent never authors board UI
# at invocation time.
#
# Usage:
#   fm-bearings-board.sh build [--no-reopen] <data.json>
#   fm-bearings-board.sh path
#   fm-bearings-board.sh url
#   fm-bearings-board.sh ended
#
# build      Validate the payload, drop the Captain's Call cards whose subject
#            already landed, give every surviving decision card the standard
#            reconcile choice, and write the result to the board data file
#            beside the stable board path, installing the shipped template's
#            code file and page beside it only when each differs (see A
#            REBUILD NEVER RELOADS THE OPEN PAGE below). Establish the Lavish
#            session on that board and PROVE it is live BEFORE binding and
#            arming its answer source, so a registered poll can never race a
#            session that does not exist or attach to one that has ended.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm, so the board can never produce an answer that has
#            nowhere to go (captain-hold-lifecycle's ordering rule, enforced
#            here rather than left to agent memory). Output starts with
#            `board: <path>` and `data: <path>`, then includes lavish-axi's
#            session output and
#            the remaining status:
#              session: live | reopened
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
#              listening: <owner>            (only when a replacement was needed)
#            Every dropped card is named on stderr as a `dropped-landed-card:`
#            line, so a rebuild states what it removed instead of quietly
#            shrinking Captain's Call.
#            --no-reopen is the automatic refresh's form
#            (bin/fm-board-refresh.sh): the board data is still rewritten, but
#            a session the captain ended is left ended and the build refuses
#            instead of reopening it, because reopening opens a browser tab
#            nobody asked for.
# path       Print the stable board path for this home.
# url        Print the board's current Lavish session URL as the only stdout
#            line, after making it reachable: the same serve sequence as build
#            (prove the session live, reopen it if it ended, bind, arm, prove a
#            listener) runs against the already-built board, without rebuilding
#            it and with LAVISH_AXI_NO_OPEN=1 so no browser is ever opened.
#            Prints `reopened: yes` on stderr when it had to reopen, and then
#            starts an automatic refresh (bin/fm-board-refresh.sh --kick), so a
#            board left behind while its session was ended catches up in place
#            rather than by a reload. Refuses when no board has been built in
#            this home yet.
# ended      Exit 0 only when Lavish's own saved state names this home's board
#            and every session it records for it has ended; exit 1 otherwise.
#            It reads $LAVISH_AXI_STATE_DIR/state.json (default
#            ~/.lavish-axi/state.json) and never calls the Lavish server, so the
#            automatic refresh can ask it before every pass. A missing,
#            unreadable, or unfamiliar state file, or no record of the board,
#            answers not ended, so the refresh keeps working if Lavish changes
#            that file. Verified against lavish-axi 0.1.96, whose session
#            statuses are open, feedback, ended, and user-ended.
#
# THE URL IS STABLE BUT NOT ALWAYS SERVED. Lavish names a session by the first
# 16 hex digits of sha256(realpath of the board file), so the stable board path
# yields the same /session/<id> through rebuilds, Lavish server restarts, and
# reopening after the captain ends the session; the host and port come from
# the server's link host (its Tailscale MagicDNS name when bound) and
# LAVISH_AXI_PORT. That bookmark only answers while the session is open: once
# the captain ends the last session the server stops, and Lavish offers no
# alias route that could reopen it. `url` is what brings the bookmark back.
#
# A LIVE SESSION IS PROVED, NEVER ASSUMED. `lavish-axi <file>` exits 0 even
# when it refuses to reopen a session the captain ended from the browser,
# reporting `status: user-ended` with the same session id, so exit status alone
# cannot tell a live board from a dead one. build requires the server's fresh
# session listing to show the canonical board open and refuses rather than
# arming an ended session. After a reopen it retires the pre-reopen source
# generation through the guarded adapter path, arms a fresh registration, and
# accepts only the replacement listener as live. A registered board with no
# live owner also gets a replacement before build returns, because
# `already-armed` is not the same fact as `listening`.
#
# CAPTAIN'S CALL HYGIENE. A decision card is dropped when its work item, PR, or
# structured artifact/version subject appears among the payload's own landed
# rows, or when `bin/fm-captain-hold.sh open` reports the task is no longer an
# open captain call. A newer published version also supersedes a version card.
# A task whose state cannot be established is kept, because a call wrongly
# hidden is worse than a card wrongly shown. Cleanup is therefore a normal
# rebuild effect rather than a committed migration or direct state mutation.
#
# THE RECONCILE CHOICE. Every decision card carries the standard `reconcile`
# option, injected here so the guarantee does not depend on the composer's
# memory, and the payload validator reserves that value across every card type.
# The board labels it "Already settled? Re-check and close it" and shows it
# apart from the decision's own choices. Because build always adds it, a
# page-backed decision card may arrive with no options and no free-text answer
# (a decision answered on its page shows only that page link).
#
# EVERY CARD STATES ITS DECISION. After the hygiene drop above and before the
# board is touched, build checks that each Captain's Call card says
# what the captain is deciding. The rule - a prompt that asks, a way to answer,
# recorded options, a link unless the card is exempt, each link listed once,
# and no link to a PR/MR already merged or closed - and its exemptions
# are owned by bin/fm-bearings-card-check-lib.sh, the same check the watcher
# runs on a worker's needs-decision line to bounce it back (bin/fm-watch.sh).
# A card that fails is
# held back, never refused and never silently dropped: it is named on stderr as
# an `undecided-card: <key>: <problem>` line plus one summary
# line, and it moves out of `captains_call` into the payload's `cards_to_fix`
# as {key, task, title, problem}, `problem` being that <problem> text
# (the key is absent when no card was held back), so
# no consumer counts or shows it as the captain's while every other card still
# builds. The page does not render `cards_to_fix`. The build also publishes
# the list as `<task>\t<key>\t<problem>` lines at <state>/board-cards-to-fix
# (removed when empty), which bin/fm-wake-drain.sh presents to main as CARDS
# TO FIX so the owner re-posts the card as a clean keyed decision.
# `cards_to_fix` and a card's `problem` are the build's own: authored ones are
# cleared.
#
# The validator's reservation scope must equal the adapter's reconcile
# classification scope, which is all card types because the captured payload
# carries no card type. Its meaning, and the reason it can never reach the
# keyed-answer intake as a blind close, are owned by
# docs/captain-hold-lifecycle.md.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below. Every fleet row and
# Captain's Call item explicitly carries `repo`; the payload generator fills it
# from the snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched. The refusal names the first failing item (its
# section, index, and key or id) with each missing or invalid field, and counts
# any further failing items.
#
# Every Underway row likewise carries a non-empty `name`: the durable task name
# when known, otherwise its durable identifier.
# A Charted Next row MAY carry `filed`, the durable filed date (YYYY-MM-DD, or
# that date with a UTC timestamp) the template orders the section by, newest
# first; a row with no comparable date keeps its payload order after every dated
# row. Anything else in that field refuses rather than sorting on garbage.
#
# CAPTAIN'S CALL SHOWS EVERYTHING WAITING ON THE CAPTAIN, including items
# firstmate never held. Any card (decision, merge, credential) MAY carry `links`,
# up to 24 pointers to what the captain acts on: `{url, label}`,
# `{page, label}`, where page is a board page id (the slug bin/fm-board-page.sh
# registers), or `{path, label}`, an absolute file path the card cites, shown as
# text because the board cannot open a local file. A link url is https, or http only on the tailnet Lavish origin
# http://dev-1.tailf848b0.ts.net:4387 (exact host and port, then `/`, `?`, `#`
# or the end); every other http url refuses. A card whose key is not a captain-
# held task id is kept, because hygiene only drops a decision card it can
# positively show is landed or no longer an open captain call.
#
# A PAGE LINK OPENS IN PLACE, NEVER IN ANOTHER TAB. build rewrites every card
# link to a Lavish page before writing the board data, so the board never links
# out to a Lavish session. A Lavish-origin url resolves through the server's
# session listing to the file that session shows; when that file sits in a live
# registered page's folder ($FM_HOME/.lavish/pages/<id>/), or in a folder named
# for a live registered page id (a page skill's standalone folder), the link
# becomes `{page: <id>, label}` and the board opens that page in place. A
# `{page, label}` link naming a live page stays as it is. Any other Lavish-
# origin url or page link becomes `{label, not_in_board: true}`, which the board
# shows as a plain note; a link to the board's own session is dropped. A
# session the listing no longer shows (an ended standalone page) resolves only
# when a live page record names it in `replaces` (bin/fm-board-page.sh open
# --replaces), which maps that old session URL to the registered page.
# A card that links a live page does not also show its raw `page:<id>` token:
# the token in its question or about reads "the linked page", or the "<label>"
# page when the card links more than one.
# A live page also links itself to the work it is about: before the decision
# check, a card whose key or `context.task` the page record names in `task`
# (bin/fm-board-page.sh open --task), whose key is the page id, or whose text
# (title, question, about, context reason or notes) names the page id as a
# whole word, or names the page title whole when that title is 12 characters
# or more ("Architecture page: board tab 'Architecture: MR 887 net-only
# claims'"), gains a `{page, label}` link to it, and a Waiting or Charted row
# matched the same way gains `context.page` ({id, title}). A card whose task's
# own status log (state/<task>.status) names the page as `page:<id>` links it
# too when its text speaks of a "<word> page" whose word (4 letters or more)
# is a word of the page id or title ("open on the understand page" for
# understand-mr821).
#
# EVERY BOARD ITEM MAY CARRY `context`, what it expands to show in place: an
# object of `task`, `reason` and `report` (strings), `answers` (an array of
# {at, mode, text}, each recorded captain answer with its date and words) and
# `notes` (an array of strings), plus `page` added by build as above.
# A decision card MAY carry `off_board`, an object of `question`, `about`,
# `freeform_hint`, `malformed` (strings) and `allow_freeform` (boolean): what
# the card shows when the page it is answered on is not in the board. When a
# card link resolves to a board page, build drops `off_board` so the page
# answers it; otherwise build merges those fields into the card, so the
# question still reaches the captain and the answer the asking home.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation keeps the same Lavish session URL and the same canonical
# process-event source id.
#
# A REBUILD NEVER RELOADS THE OPEN PAGE. Lavish reloads the whole open page
# whenever the page file changes, and watches no other file, so a forced reload
# would wipe text the captain is typing. So build installs four files:
#   - bearings-board.data.js holds the payload as one
#     `window.FM_BEARINGS_BOARD_DATA = <json>;` assignment, stamped with
#     `board_code`, the checksum of the template that built it, and
#     `data_stamp`, the checksum of the payload itself. The data is the
#     compact JSON with every `<` escaped as the \u003c string escape, so a
#     payload string containing "</script>" stays inert.
#   - bearings-board.stamp.js holds only that data stamp, as
#     `window.FM_BEARINGS_BOARD_STAMP = "<stamp>";`, so the open page can poll
#     one short line and read the data only when it changed.
#   - bearings-board.app.js holds the template's one inline script, stamped
#     with the same checksum as window.FM_BEARINGS_BOARD_CODE.
#   - bearings-board.html, the page, is the template with that inline script
#     swapped for a load of the code file.
# The template must load the data file through exactly one
# `<script src="bearings-board.data.js"></script>` line, followed by exactly
# one `<script>` line and one `</script>` line around its code. Each file is
# rewritten only when its bytes change, so the page file changes only with the
# template's markup or styles, and that is the only rebuild that reloads the
# page at once. The open page re-reads the data file and patches only the cards
# that changed; when the data names a newer `board_code` than the code it is
# running, it reloads itself into the new code only once the reader is not
# working in it, and keeps the shown card across that reload (the template
# owns that test). Files are written code, then data, then stamp, then page,
# each replaced whole by a rename of a file staged beside it, so a reader never
# sees one missing or half written, a page that reloads finds code at least as
# new as the data that asked for it, and a stamp never names data that is not
# there yet. A fetch already under way can still be cut short
# by the rename, because Lavish streams a file by path, so the page treats a
# data load that fails or breaks as a reason to wait and re-read, never as a
# dead board (the template's waitForData).
#
# A HOME WITH ITS OWN CODE KEEPS ITS OWN TEMPLATE. When $FM_HOME carries its
# own bin/fm-bearings-board.sh and that is not this file, build installs only a
# template byte-identical to that home's own; otherwise it writes nothing (no
# page, code, or data, so the open page does not reload), logs the refusal,
# naming both roots, to state/.board-refresh.log, and exits non-zero. A home
# with no code of its own takes the build from whichever code root serves it.
#
# PAGES SHOWN IN PLACE. build adds `pages` to the board data: one
# {id, title, href} row per live page registered through bin/fm-board-page.sh
# (its header owns registration, the page folders, and the one refresh policy of
# the board app), read from state/pages/*/page.json at build time. The board
# lists them and shows each in place inside its own tab. A payload never
# authors `pages`; the validator refuses one that does.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
# FM_BEARINGS_BOARD_REFRESH replaces the refresh command `url` starts after a reopen (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-bearings-card-check-lib.sh
. "$SCRIPT_DIR/fm-bearings-card-check-lib.sh"  # the shared card check

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
DATA_SCRIPT='<script src="bearings-board.data.js"></script>'
DATA_PREFIX='window.FM_BEARINGS_BOARD_DATA = '
BOARD_SCHEMA=fm-bearings-board.v1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }
board_data_path() { printf '%s.data.js\n' "${1%.html}"; }
board_app_path() { printf '%s.app.js\n' "${1%.html}"; }
board_stamp_path() { printf '%s.stamp.js\n' "${1%.html}"; }
APP_SCRIPT='<script src="bearings-board.app.js"></script>'

# Render the installed page and code file from the template into <page> and
# <app>; the template must carry exactly one inline <script> line and one
# </script> line, after its data-file load.
render_board_files() {  # <code> <page> <app>
  awk -v code="$1" -v page="$2" -v app="$3" -v data="$DATA_SCRIPT" -v appload="$APP_SCRIPT" '
    $0 == data { seen_data = 1 }
    $0 == "<script>" { if (!seen_data || opened) bad = 1; opened++; in_app = 1
                       print appload > page
                       printf "window.FM_BEARINGS_BOARD_CODE = \"%s\";\n", code > app
                       next }
    $0 == "</script>" { if (!in_app) bad = 1; closed++; in_app = 0; next }
    in_app { print > app; next }
    { print > page }
    END { exit (bad || opened != 1 || closed != 1) ? 1 : 0 }
  ' "$TEMPLATE"
}

# Publish <staged> at <dest> unless <dest> already has the same bytes.
publish_if_changed() {  # <staged> <dest> <what>
  if cmp -s -- "$1" "$2"; then rm -f -- "$1"; return 0; fi
  if ! { chmod 0600 "$1" && mv -f -- "$1" "$2"; }; then
    rm -f -- "$1"
    printf 'fm-bearings-board: cannot publish the %s\n' "$3" >&2
    return 1
  fi
}

# A home that carries its own board code (its own bin/fm-bearings-board.sh) has
# its board installed only from its own template. A build from another code
# root whose template differs stops here, before writing anything, and says so
# in the home's refresh log.
refuse_foreign_template() {
  local own="$FM_HOME/bin/fm-bearings-board.sh" own_template code_root msg
  [ -f "$own" ] || return 0
  [ ! "$own" -ef "${BASH_SOURCE[0]}" ] || return 0
  own_template="$FM_HOME/.agents/skills/bearings/assets/board-template.html"
  ! cmp -s -- "$TEMPLATE" "$own_template" || return 0
  code_root=$(cd "$SCRIPT_DIR/.." && pwd)
  msg="refused a board build from code root $code_root: home $FM_HOME carries its own board code and its template differs, so the installed board is left unchanged"
  if [ -d "$STATE" ]; then
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$msg" >>"$STATE/.board-refresh.log"
    tail -n 20 "$STATE/.board-refresh.log" >"$STATE/.board-refresh.log.tmp" 2>/dev/null \
      && mv "$STATE/.board-refresh.log.tmp" "$STATE/.board-refresh.log"
  fi
  fail "$msg"
}

# Print one line per payload item, or for the payload itself, that breaks
# fm-bearings-board.v1, naming the item (its section index, and its key or id)
# and every missing or invalid field; print nothing for a valid payload.
payload_errors() {  # <data.json>
  jq -r --arg schema "$BOARD_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def valid_filed:
      . as $filed
      | type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$")
      and (if test("T")
        then try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $filed) catch false
        else try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $filed) catch false
        end);
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def https_url:
      type == "string"
      and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$");
    def link_url:
      https_url or (type == "string"
        and test("^http://dev-1\\.tailf848b0\\.ts\\.net:4387(?:[/?#][^[:space:]]*)?$"));
    def page_id: type == "string" and test("^[a-z0-9][a-z0-9-]{0,63}$");
    def opt_str: . == null or type == "string";
    def count: type == "number" and . >= 0 and (floor == .);
    def context:
      type == "object"
        and optional_string("task") and optional_string("reason") and optional_string("report")
        and ((has("answers") | not)
          or (.answers | type == "array"
            and ([.[] | type == "object" and (.at | opt_str) and (.mode | opt_str)
                  and (.text | type == "string")] | all)))
        and ((has("notes") | not) or (.notes | type == "array" and all(.[]; type == "string")))
        and ((has("page") | not)
          or (.page | type == "object" and (.id | page_id) and (.title | type == "string")));
    def links:
      type == "array"
        and length <= 24
        and ([.[]
          | type == "object"
            and ((((keys - ["url", "label"]) | length == 0) and (.url | link_url))
              or (((keys - ["page", "label"]) | length == 0) and (.page | page_id))
              or (((keys - ["path", "label"]) | length == 0)
                and (.path | type == "string" and test("^/[^[:space:]]+$"))))
            and optional_string("label")] | all);
    def version: type == "string" and test("^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})$");
    def subject:
      type == "object"
        and (keys | sort) == ["artifact", "version"]
        and (.artifact | slug(128))
        and (.version | version);
    def options:
      type == "array"
        and ([.[]
          | type == "object"
            and (.value | slug(128))
            and (.label | nonempty_string)
            and optional_string("hint")] | all);
    def off_board:
      type == "object"
        and ((keys - ["question", "about", "freeform_hint", "malformed", "allow_freeform"]) | length == 0)
        and optional_string("question") and optional_string("about")
        and optional_string("freeform_hint") and optional_string("malformed")
        and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"));
    # Each rule is one check that yields its failure message, or nothing.
    def holds(f): [try (if f then true else false end) catch false] | length > 0 and all;
    def rule(f; $msg): if holds(f) then empty else $msg end;
    def req($name; f):
      if has($name) | not then "missing required field \"\($name)\""
      else rule(.[$name] | f; "invalid field \"\($name)\"") end;
    def opt($name; f): if has($name) then req($name; f) else empty end;
    def repo_marker: req("repo"; . == null or type == "string");
    def call_item:
      req("key"; slug(128)),
      req("type"; . == "decision" or . == "merge" or . == "credential"),
      repo_marker,
      req("title"; nonempty_string),
      req("options"; options),

      (("about", "question", "malformed", "problem", "decide", "detail", "freeform_hint") as $f
        | opt($f; type == "string")),
      opt("pr_url"; https_url),
      opt("links"; links),
      opt("subject"; subject),
      (select(holds(.type == "merge" or .type == "credential") and has("subject"))
        | "field \"subject\" on a card that is not a decision"),
      (("free_text", "no_link", "options_inferred", "from_status", "allow_freeform") as $f
        | opt($f; type == "boolean")),
      opt("context"; context),
      opt("close"; . == "done" or . == "release"),
      opt("recommend_value"; slug(128)),
      # Rules across fields speak only once the fields they read are valid,
      # since the field rule above already refuses the card.
      (select(holds(.options | options))
        | rule((.options | length) > 0 or .allow_freeform == true or .type == "decision";
            "empty options on a card that is not a decision and does not allow free text"),
          rule((has("recommend_value") | not)
            or (.recommend_value as $recommend | [.options[].value] | index($recommend) != null);
            "field \"recommend_value\" names no option"),
          rule([.options[].value] | index("reconcile") == null;
            "option value \"reconcile\" is reserved")),
      opt("off_board"; off_board),
      (if .type == "merge" then req("risk"; nonempty_string) else empty end);
    def underway_item:
      repo_marker, req("name"; nonempty_string),
      (("id", "state", "doing", "kind") as $f | req($f; nonempty_string));
    def landed_item:
      repo_marker,
      (("id", "what", "owner") as $f | req($f; nonempty_string)),
      opt("pr_url"; https_url),
      opt("subject"; subject);
    def waiting_item:
      repo_marker, req("key"; slug(128)),
      req("title"; nonempty_string), req("reason"; type == "string"),
      opt("context"; context);
    def open_mr_item:
      ((keys - ["key", "repo", "title", "url", "state"])[] | "unexpected field \"\(.)\""),
      repo_marker, req("key"; slug(128)),
      req("title"; nonempty_string), req("state"; nonempty_string),
      req("url"; https_url);
    def charted_item:
      repo_marker, req("id"; slug(128)),
      req("title"; nonempty_string), req("reason"; type == "string"),
      req("dispatchable"; type == "boolean"),
      opt("kind"; . == "queued" or . == "warning"),
      opt("filed"; . == null or valid_filed),
      opt("context"; context),
      rule(if .kind == "warning" then .dispatchable == false else true end;
        "a warning row with \"dispatchable\" not false");
    def name_of:
      if type == "object" and (.key | type) == "string" then " (key \"\(.key)\")"
      elif type == "object" and (.id | type) == "string" then " (id \"\(.id)\")"
      else "" end;
    def section($name; item):
      if (.[$name] | type) == "array" then
        .[$name] | to_entries[] | .key as $index | .value
        | [if type == "object" then item else "not an object" end] as $failed
        | select($failed | length > 0)
        | "\($name)[\($index)]\(name_of): \($failed | join("; "))"
      else empty end;
    if type != "object" then "the payload is not a JSON object"
    else
      ([req("schema"; . == $schema),
        req("home"; nonempty_string),
        req("generated"; nonempty_string),
        req("prs_live"; type == "boolean"),
        (("captains_call", "underway", "landed", "charted") as $f | req($f; type == "array")),
        (("waiting", "open_mrs") as $f | opt($f; type == "array")),
        (("charted_more", "charted_warning_more") as $f | opt($f; count)),
        rule(has("pages") | not; "field \"pages\", which only build may write")]
        | select(length > 0) | "payload: \(join("; "))"),
      section("captains_call"; call_item),
      section("underway"; underway_item),
      section("waiting"; waiting_item),
      section("open_mrs"; open_mr_item),
      section("landed"; landed_item),
      section("charted"; charted_item)
    end
  ' "$1"
}

# Print one `<key>: <problem>` line per Captain's Call card that does
# not state its decision (see EVERY CARD STATES ITS DECISION above;
# the check is bin/fm-bearings-card-check-lib.sh's, shared with the watcher).
# Only the build reads its cards' PR/MR links live, so a card naming one that
# already merged or closed is held back here and not by the watcher.
undecided_cards() {  # <data.json>
  local states rc=0
  states=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-links.XXXXXX") || return 1
  fm_bearings_card_link_states "$1" > "$states" || echo '{}' > "$states"
  fm_bearings_undecided_cards "$1" "$states" || rc=$?
  rm -f -- "$states"
  return "$rc"
}

# Move each undecided card out of Captain's Call into `cards_to_fix` as
# {key, task, title, problem}, its `problem` the card's problem text and
# its task the card's owning task, and leave `cards_to_fix` out when none was.
# Any other `problem` and any authored `cards_to_fix` are cleared: both are the
# build's own, never authored.
hold_back_undecided() {  # <undecided-lines>  (payload on stdin)
  jq -c --arg lines "$1" '
    ( [ $lines | split("\n")[] | select(length > 0) | index(": ") as $i
        | {key: .[:$i], value: .[($i + 2):]} ] | from_entries ) as $why
    | .cards_to_fix = [ .captains_call[] | select($why[.key] != null)
        | {key, task: (.context.task // .key), title, problem: $why[.key]} ]
    | .captains_call |= map(select($why[.key] == null) | del(.problem))
    | if .cards_to_fix == [] then del(.cards_to_fix) else . end'
}

# Publish the held-back cards as `<task>\t<key>\t<problem>` lines at
# <state>/board-cards-to-fix, which bin/fm-wake-drain.sh presents to main as
# CARDS TO FIX, or remove that file when no card was held back.
publish_cards_to_fix() {  # <state-dir>  (payload on stdin)
  local dest="$1/board-cards-to-fix" tmp lines
  lines=$(jq -r '.cards_to_fix[]? | [.task, .key, .problem] | map(gsub("[[:cntrl:]]"; " ")) | join("\t")') \
    || return 1
  if [ -z "$lines" ]; then
    rm -f -- "$dest"
    return
  fi
  mkdir -p -- "$1" || return 1
  tmp=$(umask 077; mktemp "$1/.board-cards-to-fix.XXXXXX") || return 1
  if ! { printf '%s\n' "$lines" > "$tmp" && mv -f -- "$tmp" "$dest"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Every live page registered through bin/fm-board-page.sh, oldest first, as the
# board data's `pages` array. A record that does not parse or carries a bad id
# is left out rather than failing the build.
live_pages_json() {
  local f
  for f in "$STATE"/pages/*/page.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    jq -c 'select(type == "object" and .state == "live"
             and (.id | type == "string" and test("^[a-z0-9][a-z0-9-]{0,63}$"))
             and (.title | type == "string" and length > 0))
           | {id, title, opened: (.opened // ""), href: ("pages/" + .id + "/page.html"),
              replaces: ([.replaces // [] | arrays | .[] | strings]),
              task: (.task | if type == "string" and length > 0 then . else null end)}' "$f" 2>/dev/null
  done | jq -s -c 'sort_by(.opened, .id) | map(del(.opened))' | pages_named_by_status
}

# Add `named_by` to each page in the pages JSON on stdin: the task ids whose own
# status file ($STATE/<task>.status) names the page as a whole `page:<id>` token.
pages_named_by_status() {
  local pages id named
  pages=$(cat)
  for id in $(printf '%s\n' "$pages" | jq -r '.[].id'); do
    named=$(grep -lE "(^|[^[:alnum:]-])page:$id([^[:alnum:]-]|\$)" "$STATE"/*.status 2>/dev/null \
              | sed 's#^.*/##; s#\.status$##' | jq -R -s -c 'split("\n") | map(select(length > 0))') \
      || named='[]'
    pages=$(printf '%s\n' "$pages" | jq -c --arg id "$id" --argjson named "${named:-[]}" \
              'map(if .id == $id then .named_by = $named else . end)')
  done
  printf '%s\n' "$pages"
}

# Every Lavish session the server lists, as {"<session-id>": "<page-id>"} for a
# session showing a live registered page (its file in that page's served folder,
# or in a folder named for that page id) or "" for the board's own session. A
# session showing anything else is left out, and so is everything when the
# listing cannot be read: a link nothing resolves becomes a note, never a link
# out of the board. A row is `<file>,<status>,"<url>",<pending>`, optionally
# followed by a `,<listener>` column.
lavish_session_pages() {  # <pages-json>
  local pages=$1 listing served board
  command -v lavish-axi >/dev/null 2>&1 || { printf '{}\n'; return 0; }
  listing=$(lavish-axi 2>/dev/null) || { printf '{}\n'; return 0; }
  served=$(board_realpath "$FM_HOME/.lavish/pages" || printf '%s' "$FM_HOME/.lavish/pages")
  board=$(board_realpath "$(board_path)" || board_path)
  printf '%s\n' "$listing" \
    | sed -n 's/^[[:space:]]*\(.*\),[A-Za-z-]*,"\(https\{0,1\}:[^"]*\)",[^"]*$/\1\t\2/p' \
    | jq -R -s -c --argjson pages "$pages" --arg served "$served/" --arg board "$board" '
        ([$pages[].id]) as $live
        | [ split("\n")[] | select(length > 0) | split("\t")
            | select(length == 2)
            | (.[1] | capture("/session/(?<s>[A-Za-z0-9]+)").s // empty) as $sid
            | .[0] as $file
            | (if $file == $board then ""
               elif ($file | startswith($served)) then ($file | ltrimstr($served) | split("/")[0])
               else ($file | split("/") | .[-2] // "") end) as $id
            | select($id == "" and $file == $board or ($live | index([$id])))
            | {key: $sid, value: $id} ]
        | from_entries'
}

# Link each card, Waiting row and Charted row to the live page about its work
# (see A PAGE LINK OPENS IN PLACE above). Reads the effective payload on stdin.
attach_page_links() {  # <pages-json>
  jq -c --argjson pages "$1" '
    def names($id): type == "string" and test("(^|[^a-z0-9-])" + $id + "($|[^a-z0-9-])"; "i");
    def names_title($t):
      type == "string" and ($t | type == "string" and length >= 12)
      and (ascii_downcase | contains($t | ascii_downcase));
    def task_ids($i): [$i.key, $i.id, ($i.context.task // null)] | map(strings | ., (split("/") | last)) | unique;
    def texts($i): ($i.title, $i.question, $i.about, $i.reason, $i.context.reason, ($i.context.notes // [])[]);
    def page_words($p): [($p.id, $p.title) | ascii_downcase | scan("[a-z]{4,}")] | unique;
    def names_kind($p):
      type == "string"
      and ([ascii_downcase | scan("([a-z]{4,}) page\\b") | .[0]] as $k | page_words($p) as $w
           | any($k[]; . as $x | $w | index([$x])));
    def about_page($i; $p):
      (task_ids($i) as $t
         | ($t | index([$p.id])) or ($p.task != null and ($t | index([$p.task])))
           or (any(($p.named_by // [])[]; . as $n | $t | index([$n])) and any(texts($i); names_kind($p))))
      or any(texts($i); names($p.id) or names_title($p.title));
    def pages_for($i): [ $pages[] | select(about_page($i; .)) ];
    .captains_call |= map(
      . as $c
      | [ pages_for($c)[] | {page: .id, label: .title} ] as $auto
      | if ($auto | length) == 0 then .
        else .links = ( [ (.links // [])[] | select(has("page")) ] + $auto + [ (.links // [])[] | select(has("page") | not) ]
                        | def link_key: .url // (if has("page") then "page:" + .page else "path:" + (.path // "") end);
                          reduce .[] as $l ([]; ($l | link_key) as $k
                                                | if any(.[]; link_key == $k) then . else . + [$l] end)
                        | .[:24] ) end)
    | def with_page: . as $r | (pages_for($r)[0] // null) as $p
        | if $p != null and has("context") then .context.page = {id: $p.id, title: $p.title} else . end;
      (if has("waiting") then .waiting |= map(with_page) else . end)
    | .charted |= map(with_page)'
}

# Rewrite every card link to a Lavish page as described under A PAGE LINK OPENS
# IN PLACE in the header. Reads the effective payload on stdin.
resolve_page_links() {  # <pages-json> <sessions-json>
  jq -c --argjson pages "$1" --argjson sessions "$2" '
    ([$pages[].id]) as $live
    | def lavish: type == "string" and test("^http://dev-1\\.tailf848b0\\.ts\\.net:4387(?:[/?#]|$)");
      def label_of: if (.label // "") != "" then {label} else {label: "Lavish page"} end;
      def resolve:
        if has("page") then
          (.page as $p | if ($live | index([$p])) then . else label_of + {not_in_board: true} end)
        elif (.url | lavish) then
          ((.url | capture("/session/(?<s>[A-Za-z0-9]+)").s // null) as $sid
           | ($sid | if . == null then null
                     else ($sessions[.] // ([$pages[] | select(.replaces | index([$sid])) | .id][0])) end) as $id
           | if $id == "" then empty
             elif $id != null and ($live | index([$id])) then label_of + {page: $id}
             else label_of + {not_in_board: true} end)
        else . end;
    . + {pages: ($pages | map(del(.replaces, .task, .named_by)))}
    | .captains_call |= map(
        (if has("links") then .links |= map(resolve) else . end)
        | if has("off_board") then
            (if any((.links // [])[]; has("page")) then . else . + .off_board end) | del(.off_board)
          else . end
        | [ (.links // [])[] | select(has("page")) ] as $pl
        | reduce $pl[] as $l (.;
            (if ($pl | length) == 1 then "the linked page" else "the \"" + $l.label + "\" page" end) as $say
            | reduce ("question", "about") as $f (.;
                if (.[$f] | type) == "string"
                then .[$f] |= gsub("(?<![[:alnum:]-])page:" + $l.page + "(?![[:alnum:]-])"; $say)
                else . end)))'
}

# --- Lavish session liveness -------------------------------------------------
# Verified against lavish-axi 0.1.61. `lavish-axi <file>` EXITS 0 even when it
# refuses to reopen a session the captain ended from the browser, reporting
# `status: user-ended` and the same session id, so an exit-code check alone
# cannot tell a live board from a dead one. The establish status is an initial
# signal only; the server's fresh session listing must also show the canonical
# board open before the build may bind or arm its source.

board_realpath() {  # <board>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

lavish_status_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"'
}

# The server's own listing, keyed on the canonical artifact path. Rows are
# `<file>,<status>,"<url>",<pending>`, and only a live session is listed `open`.
lavish_session_listed_open() {  # <canonical-board-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

lavish_board_live() {  # <establish output> <canonical-board-path>
  lavish_session_listed_open "$2"
}

# Establish the board session and PROVE it is live before anything arms a poll
# on it. A session the captain ended is reopened once - the captain asked for
# this board, which is exactly the attention `--reopen` exists for - and a
# session that is still not live after that refuses the build rather than
# arming a poll that can never attach.
establish_board_session() {  # <board> <reopen-0-or-1>
  local board=$1 reopen=$2 real out status version
  BOARD_SESSION_REOPENED=0
  real=$(board_realpath "$board") || fail "cannot resolve the board path: $board"
  # --no-open: a rebuild must never open another browser tab. A window that is
  # already connected re-reads the board data file itself.
  out=$(lavish-axi "$board" --no-open) || fail "cannot establish the board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    printf 'session: live\n'
    return 0
  fi
  [ "$reopen" = 1 ] \
    || fail "the board Lavish session is not live and --no-reopen leaves an ended session ended; the rewritten board shows on the next /bearings"
  out=$(lavish-axi "$board" --reopen) || fail "cannot reopen the ended board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    BOARD_SESSION_REOPENED=1
    printf 'session: reopened\n'
    return 0
  fi
  status=$(lavish_status_field "$out")
  version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  fail "the board Lavish session is not live after reopening it (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
}

# --- Captain's Call hygiene ---------------------------------------------------
# A held decision whose subject already shipped is not a live call, so it is
# dropped here instead of being carded again. All checks use exact structured
# identities; unknown subject state keeps the card.

decision_card_is_stale() {  # <task-id> <landed-0-or-1>
  local task=$1 landed=$2 rc=0
  if [ "$landed" = 1 ]; then
    printf 'structured subject already landed\n'
    return 0
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null 2>&1 || rc=$?
  # 1 is a definite "no longer an open captain call". 2 is "cannot tell", 3 is
  # absent from this backlog, and a call wrongly hidden is worse than a card
  # wrongly shown, so both uncertain and absent cards stay.
  if [ "$rc" -eq 1 ]; then
    printf 'no longer an open captain call\n'
    return 0
  fi
  return 1
}

# Drop every stale decision card, then give every surviving decision card the
# standard reconcile choice. Injecting it here is what makes "every decision
# card offers reconcile" a property of the board rather than of the composer's
# memory; the validator prevents duplicate decision options.
effective_payload() {  # <data.json> <dest.json>
  local data=$1 dest=$2 landed_keys key reason drop='' tmp landed=0
  landed_keys=$(jq -c '
    def version_parts: split(".") | map(tonumber);
    . as $payload
    | [$payload.captains_call[]
      | select(.type == "decision")
      | . as $card
      | select(
          ($payload.landed | any(.id == $card.key))
          or (($card.pr_url? != null) and ($payload.landed | any(.pr_url? == $card.pr_url)))
          or (($card.subject? != null) and ($payload.landed | any(
            (.subject? != null)
            and (.subject.artifact == $card.subject.artifact)
            and ((.subject.version | version_parts) >= ($card.subject.version | version_parts)))))
        )
      | .key]
  ' "$data") || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    landed=0
    if jq -e --arg key "$key" 'index($key) != null' <<< "$landed_keys" >/dev/null; then
      landed=1
    fi
    reason=$(decision_card_is_stale "$key" "$landed") || continue
    printf 'dropped-landed-card: %s (%s)\n' "$key" "$reason" >&2
    drop=$drop$key$'\n'
  done < <(jq -r '.captains_call[]? | select(.type == "decision") | .key' "$data")
  tmp=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  jq --argjson dropped "$tmp" '
    .captains_call = [
      .captains_call[]
      | . as $card
      | select($card.type != "decision" or (($dropped | index($card.key)) == null))
      | if .type == "decision"
        then .options += [{
          value: "reconcile",
          label: "Already settled? Re-check and close it",
          hint: "Re-check the latest state, then close this with evidence or keep it open with a note"
        }]
        else . end
    ]' "$data" > "$dest" || return 1
}

# The OWNER column bin/fm-procevent.sh already publishes: live, none,
# orphaned, or uncertain. Empty means the source is not registered at all.
source_owner() {  # <source-id>
  "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$1" 'NR > 1 && $1 == id { print $3 }'
}

# A replacement listener is started detached, so it claims the source shortly
# after reconcile returns. Wait for that claim rather than reporting the race.
await_source_owner() {  # <source-id>
  local owner i=0
  while [ "$i" -lt 50 ]; do
    owner=$(source_owner "$1")
    [ "$owner" != live ] || { printf '%s\n' "$owner"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "${owner:-none}"
}

command_build() {
  local data board board_data board_app board_stamp json tmp extracted effective pages code stamp stage undecided errors more reopen=1
  if [ "${1-}" = --no-reopen ]; then reopen=0; shift; fi
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  data=$1
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  errors=$(payload_errors "$data") || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  if [ -n "$errors" ]; then
    more=$(printf '%s\n' "$errors" | sed 1d | wc -l | tr -d ' ')
    case $more in
      0) more= ;;
      1) more=" (and 1 more failing item)" ;;
      *) more=" (and $more more failing items)" ;;
    esac
    fail "board data does not satisfy $BOARD_SCHEMA: $data: $(printf '%s\n' "$errors" | head -n 1)$more"
  fi
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$DATA_SCRIPT" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not load the board data file exactly once: $TEMPLATE"
  refuse_foreign_template
  code=$(cksum < "$TEMPLATE" | awk '{print $1 "-" $2}')
  stage=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-bearings-board.XXXXXX") \
    || fail "cannot stage the board page"
  if ! render_board_files "$code" "$stage/page.html" "$stage/app.js"; then
    rm -rf -- "$stage"
    fail "board template must carry exactly one inline <script> line and one </script> line after its data-file load: $TEMPLATE"
  fi

  effective=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-payload.XXXXXX") \
    || fail "cannot stage the board payload"
  if ! effective_payload "$data" "$effective"; then
    rm -f -- "$effective"
    fail "cannot reconcile the board payload against landed work"
  fi
  pages=$(live_pages_json)
  if ! json=$(attach_page_links "$pages" < "$effective") || ! printf '%s\n' "$json" > "$effective"; then
    rm -f -- "$effective"; rm -rf -- "$stage"; fail "cannot link the board pages: $data"
  fi
  undecided=$(undecided_cards "$effective") \
    || { rm -f -- "$effective"; rm -rf -- "$stage"; fail "cannot check the Captain's Call cards: $data"; }
  if [ -n "$undecided" ]; then
    printf '%s\n' "$undecided" | sed 's/^/undecided-card: /' >&2
    printf 'fm-bearings-board: held back Captain'"'"'s Call cards with no explicit decision - %s: %s\n' \
      "$(printf '%s' "$undecided" | paste -sd ';' - | sed 's/;/; /g')" "$data" >&2
  fi
  if ! json=$(hold_back_undecided "$undecided" < "$effective") || ! printf '%s\n' "$json" > "$effective"; then
    rm -f -- "$effective"; rm -rf -- "$stage"; fail "cannot hold back the Captain's Call cards: $data"
  fi
  # Only a card that links a Lavish page needs the server's session listing.
  sessions='{}'
  if jq -e '[.captains_call[]?.links[]?.url | strings
             | test("^http://dev-1\\.tailf848b0\\.ts\\.net:4387(?:[/?#]|$)")] | any' \
      "$effective" >/dev/null 2>&1; then
    sessions=$(lavish_session_pages "$pages")
  fi
  json=$(resolve_page_links "$pages" "$sessions" < "$effective") \
    || { rm -f -- "$effective"; fail "cannot compact the board data"; }
  rm -f -- "$effective"
  json=$(printf '%s\n' "$json" | jq -c --arg code "$code" '. + {board_code: $code}') \
    || { rm -rf -- "$stage"; fail "cannot stamp the board data"; }
  stamp=$(printf '%s\n' "$json" | cksum | awk '{print $1 "-" $2}')
  json=$(printf '%s\n' "$json" | jq -c --arg stamp "$stamp" '. + {data_stamp: $stamp}') \
    || { rm -rf -- "$stage"; fail "cannot stamp the board data"; }
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  board_data=$(board_data_path "$board")
  board_app=$(board_app_path "$board")
  board_stamp=$(board_stamp_path "$board")
  (umask 077; mkdir -p "${board%/*}") || { rm -rf -- "$stage"; fail "cannot create ${board%/*}"; }
  # The code file goes first, so the data that names its stamp never reaches
  # an open page before the code it asks that page to reload into.
  tmp=$(umask 077; mktemp "${board%/*}/.board-app.XXXXXX") \
    || { rm -rf -- "$stage"; fail "cannot stage the board code"; }
  cp -- "$stage/app.js" "$tmp" || { rm -f -- "$tmp"; rm -rf -- "$stage"; fail "cannot write the board code"; }
  publish_if_changed "$tmp" "$board_app" "board code" || { rm -rf -- "$stage"; exit 1; }
  tmp=$(umask 077; mktemp "${board%/*}/.board-data.XXXXXX") \
    || { rm -rf -- "$stage"; fail "cannot stage the board data"; }
  if ! printf '%s%s;\n' "$DATA_PREFIX" "$json" > "$tmp"; then
    rm -f -- "$tmp"; rm -rf -- "$stage"
    fail "cannot write the board data"
  fi
  # Round-trip the payload back out of the data file, so a board that would
  # fail to parse in the browser fails here instead.
  extracted=$(cat -- "$tmp")
  extracted=${extracted#"$DATA_PREFIX"}
  extracted=${extracted%;}
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"; rm -rf -- "$stage"
    fail "the built board data does not carry a readable $BOARD_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board_data"; }; then
    rm -f -- "$tmp"; rm -rf -- "$stage"
    fail "cannot publish the board data"
  fi
  tmp=$(umask 077; mktemp "${board%/*}/.board-stamp.XXXXXX") \
    || { rm -rf -- "$stage"; fail "cannot stage the board data stamp"; }
  if ! printf 'window.FM_BEARINGS_BOARD_STAMP = "%s";\n' "$stamp" > "$tmp"; then
    rm -f -- "$tmp"; rm -rf -- "$stage"
    fail "cannot write the board data stamp"
  fi
  publish_if_changed "$tmp" "$board_stamp" "board data stamp" || { rm -rf -- "$stage"; exit 1; }
  printf '%s\n' "$json" | publish_cards_to_fix "$STATE" \
    || { rm -rf -- "$stage"; fail "cannot publish the cards to fix to $STATE"; }
  # The page file changes only when the template's markup or styles do,
  # because any change to it makes Lavish reload the captain's open page.
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") \
    || { rm -rf -- "$stage"; fail "cannot stage the board"; }
  cp -- "$stage/page.html" "$tmp" || { rm -f -- "$tmp"; rm -rf -- "$stage"; fail "cannot write the board"; }
  rm -rf -- "$stage"
  publish_if_changed "$tmp" "$board" "board" || exit 1
  printf 'board: %s\n' "$board"
  printf 'data: %s\n' "$board_data"
  serve_board "$board" "$reopen"
}

# Serve the board and keep its answer source listening: establish and prove the
# Lavish session (reopening an ended one), then bind before arm, then prove a
# live listener. Shared by build and url so a reopened board can never come
# back without somewhere for its answers to go.
serve_board() {  # <board> <reopen-0-or-1>
  local board=$1 reopen=$2 sid owner version pre_reopen_owner
  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  pre_reopen_owner=$(source_owner "$sid")
  establish_board_session "$board" "$reopen"
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" retire "$board" >/dev/null \
      || fail "cannot retire the pre-reopen source generation (observed owner: ${pre_reopen_owner:-none})"
  fi
  if ! lavish_session_listed_open "$(board_realpath "$board")"; then
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the board Lavish session is not listed open immediately before arming (lavish-axi ${version:-version-unknown}); refusing to arm a poll on observed state not-open"
  fi
  printf 'served: %s\n' "$board"

  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  owner=$(source_owner "$sid")
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm a fresh board source after reopening"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  elif [ -n "$owner" ]; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  fi
  # Registered is not listening. A board whose source has no live owner gets a
  # replacement started now rather than at the next supervision cycle, which is
  # what keeps a rebuilt board from sitting silent behind `already-armed`.
  if [ "$owner" != live ]; then
    "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
    owner=$(await_source_owner "$sid")
    if [ "$owner" != live ]; then
      fail "source $sid is not listening after reconcile (observed owner: ${owner:-none})"
    fi
    printf 'listening: live\n'
  fi
}

# The board URL as the server's own listing reports it for the canonical path.
lavish_listed_url() {  # <canonical-board-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",open,\"") == 1 {
      rest = substr(line, length(path) + 8)
      url = substr(rest, 1, index(rest, "\"") - 1)
      if (url != "") { print url; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  '
}

command_url() {
  local board out url
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  board=$(board_path)
  [ -f "$board" ] || fail "no board has been built in this home yet: $board (run /bearings lavish first)"
  # Asking for the link is the captain asking for the board, so an ended
  # session is reopened here exactly as build would; no browser is ever opened.
  out=$(LAVISH_AXI_NO_OPEN=1 serve_board "$board" 1) || exit 1
  url=$(lavish_listed_url "$(board_realpath "$board")") \
    || fail "the board is live but the Lavish listing carries no URL for it"
  case "$out" in
    *"session: reopened"*)
      printf 'reopened: yes\n' >&2
      # The automatic refresh skips passes while the session is ended, so the
      # reopened board's data catches up now; the open page patches it in place.
      if [ -n "${FM_BEARINGS_BOARD_REFRESH:-}" ]; then
        $FM_BEARINGS_BOARD_REFRESH >/dev/null 2>&1 </dev/null || true
      else
        "$SCRIPT_DIR/fm-board-refresh.sh" --kick >/dev/null 2>&1 </dev/null || true
      fi
      ;;
  esac
  printf '%s\n' "$url"
}

# Lavish's saved session record, read from disk; see `ended` in the header.
command_ended() {
  local board real state
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  board=$(board_path)
  real=$(board_realpath "$board") || return 1
  state="${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json"
  [ -r "$state" ] || return 1
  jq -e --arg file "$real" '
    [.sessions | objects | .[] | objects | select(.file == $file) | .status]
    | length > 0 and all(.[]; . == "ended" or . == "user-ended")
  ' "$state" >/dev/null 2>&1
}

# Whether a failed build attempt failed because a binary was missing: exit 127,
# or its stderr names a command not found, a path bash could not execute, or
# the jq build requires.
missing_binary_failure() {  # <rc> <stderr-file>
  [ "$1" -ne 127 ] || return 0
  grep -Eq ': command not found$|bad interpreter: No such file or directory|^.*: line [0-9]+: [^:]+: No such file or directory$|^fm-bearings-board: jq is required$' "$2" 2>/dev/null
}

# A BUILD SURVIVES A BINARY THAT BRIEFLY VANISHES. A profile switch can take a
# binary such as jq off PATH for a fraction of a second. build runs as a child
# attempt; when that attempt fails because a binary was missing
# (missing_binary_failure), it waits about a second and runs one more attempt,
# whose result is final. Any other failure is final at once. Each attempt's
# stderr reaches the caller, plus one line saying the build is retrying.
# bin/fm-board-refresh.sh rebuilds through build, so it gets the same retry.
build_retrying_once() {  # <build args...>
  local err rc=0
  if ! err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-board.err.XXXXXX" 2>/dev/null); then
    command_build "$@"
    return
  fi
  FM_BEARINGS_BOARD_BUILD_ATTEMPT=1 "${BASH_SOURCE[0]}" build "$@" 2>"$err" || rc=$?
  [ ! -s "$err" ] || printf '%s\n' "$(<"$err")" >&2
  if [ "$rc" -ne 0 ] && missing_binary_failure "$rc" "$err"; then
    rm -f -- "$err"
    printf 'fm-bearings-board: a binary was missing during the build; retrying once\n' >&2
    sleep 1 2>/dev/null || :
    rc=0
    FM_BEARINGS_BOARD_BUILD_ATTEMPT=1 "${BASH_SOURCE[0]}" build "$@" || rc=$?
    return "$rc"
  fi
  rm -f -- "$err"
  return "$rc"
}

case "${1-}" in
  build)
    shift
    if [ "${FM_BEARINGS_BOARD_BUILD_ATTEMPT:-}" = 1 ]; then unset FM_BEARINGS_BOARD_BUILD_ATTEMPT; command_build "$@"
    else build_retrying_once "$@"; fi ;;
  path) board_path ;;
  url) shift; command_url "$@" ;;
  ended) shift; command_ended "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
