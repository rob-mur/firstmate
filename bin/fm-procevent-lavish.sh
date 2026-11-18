#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html> [--for <task-id>] [--agent-reply-file <path>]
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh silent <result-file>
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh reconciles <result-file>
#   fm-procevent-lavish.sh pages <result-file>
#   fm-procevent-lavish.sh priority <result-file>
#   fm-procevent-lavish.sh read <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#   fm-procevent-lavish.sh finished <source-id> -- <listener argv>...
#   fm-procevent-lavish.sh poll <artifact.html> [--agent-reply-file <path>]
#   fm-procevent-lavish.sh deliver-reply poll <artifact.html> --agent-reply-file <path>
#
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, disconnected, missing, or unknown.
# read       Print a structured presentation of one already-captured result so a
#            handler consumes every queued item without grepping the raw file.
#            It is read-only over the capture: it does not arm, poll, or change
#            what Lavish delivered. The freeform message (tag=message) is its
#            own labeled field, printed first and distinct from per-element
#            annotations; it is labeled SESSION-ENDING MESSAGE, and counted as
#            session_ending_message_count, only when the session ended, and is
#            otherwise CAPTAIN MESSAGE and captain_message_count. Declared and
#            presented item counts,
#            plus a completeness verdict, follow before all annotations so a
#            partial read is obvious. Each annotation retains its element uid,
#            selector, tag, and text. A non-choice freeform comment (`prompt`)
#            is printed as its own field even when a selector is also present
#            and even when that comment matches the element text, so typed
#            words are never dropped. Choice Context data is not a comment;
#            a board answer row prints its question, selection, and typed note
#            instead, flagged when the note is only a comment on an option card.
#            Captain-supplied body lines are visibly prefixed so they cannot
#            forge structural labels. Empty message and annotation sections
#            are reported explicitly.
#            Both table-form and list-form captures are supported; nested
#            targets and attachments are skipped while the item's own scalar
#            fields are retained. The shared parser below owns the wire format.
#            Malformed content or a declared/presented count mismatch yields
#            complete: no; inspect that verdict, not just the command's exit
#            status. A declared nonempty block parsed as empty is incomplete.
# poll       The registered listener command `arm` publishes, not a command to
#            run in a conversational turn. It runs the published blocking poll
#            and prints its response verbatim, absorbing only the one exact
#            transient interruption described below. A staged reply still
#            present when it starts is posted before the long-poll: through
#            `lavish-axi reply` when supported, otherwise through the legacy
#            best-effort `poll --agent-reply` path.
# deliver-reply
#            Run by `fm-procevent.sh register-task` under the source lock, only
#            after the task is eligible to own the board, with the listener argv
#            it is about to publish. Exit 0 once Lavish accepts the staged reply,
#            3 when the installed Lavish is a confirmed older release without
#            synchronous reply so the listener keeps the legacy path, and any
#            other status when the reply failed or the version is unknown.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
# silent     Exit 0 when the captured result is a routine no-op the runner should
#            record and never announce; any other exit publishes the wake. This
#            is the generic no-op contract bin/fm-procevent.sh calls, and the
#            only place Lavish's notion of "nothing was said" is decided.
#            Task-owned terminal rounds bypass generic silence so their owner
#            receives the stop-and-conclude instruction.
# finished   Exit 0 when a firstmate-owned decision page is finished, so the
#            runner's reconcile may retire its listener; any other exit keeps
#            it armed. This is the generic `finished` adapter contract
#            bin/fm-procevent.sh calls with the registration's own argv, and
#            the only place Lavish's notion of a finished page is decided. A
#            page is finished when its saved Lavish session has ended, or when
#            every `data-lavish-question` key it carries is either answered on
#            the page in a capture firstmate has already handled, or names a
#            captain call `fm-captain-hold.sh settled` reports finished. A
#            comment on an option card, a `reconcile` request, and an
#            unhandled capture are not answers. The bearings board, a page
#            with no question keys, and anything this command cannot read are
#            never finished. It reads only; it never closes, reloads, or ends
#            the page or its session.
#
# AN EMPTY BOARD CLOSE IS NOT NEWS, and that is what `silent` exists to say.
# Closing a review surface that carried nothing is the single most common Lavish
# result: the captain reads a board, says nothing, and closes it. Announcing that
# put a wake in front of the handler whose entire content was that nothing
# happened. `silent` therefore holds two narrow, positively-determined shapes -
# a session this adapter classifies `ended` that carries no queued content block
# at all, or `browser_disconnected`, which carries no answer while the session
# remains open - and every other result stays announced. The page-prompt
# shape described under `pages` below and the server restart below are the
# only additions.
#
# Deliberately narrow, in both directions. A `Send & End` close carrying the
# captain's actual answer arrives as `status: feedback` with `session_ended`, so
# it classifies `feedback`, never `ended`, and is announced exactly as before; so
# is any `ended` result that still carries a `prompts` or `feedback` block, which
# the published poll is not expected to produce but which must never be dropped
# on that expectation. A `waiting` session, a `missing` one, an `unknown` or
# unreadable result, and every error except the transport errors below stay
# announced, because none of them positively proves nothing was said. Silence
# is only ever an absence this adapter can see in the result, never an absence
# it assumes.
#
# A SERVER RESTART IS NOT NEWS EITHER. While the shared board server is down or
# restarting, every armed listener's poll ends in a bare transport error -
# `Lavish Editor server did not start`, `... poll response was interrupted`, or
# `... server connection failed`, under `code: SERVER_ERROR` with only `help[N]:`
# lines after it - and captured that way, each one woke the handler with
# nothing in it. `silent` holds a result that is exactly that and nothing else,
# so the runner records it handled and the same listener polls again. A result
# carrying any other line, session block, prompt, or feedback is announced. So
# the outage cannot go unseen, the capture that takes a source's unbroken run of
# transport errors past TRANSPORT_OUTAGE_ANNOUNCE_SECONDS is announced, once per
# run per source; captures before and after it stay quiet.
#
# OUTAGE BACK-OFF. A poll against a down server fails at once, so without a
# pause each relaunched listener would poll again on the next supervision cycle
# and a fleet of boards would spin. Before its first poll, `poll` therefore
# counts its source's unbroken run of transport-error captures, newest first,
# and waits the retry delay (POLL_RETRY_DELAY_DEFAULT, or its test override)
# doubled for each capture after the first, capped at POLL_RETRY_DELAY_MAX and
# measured from the newest capture. A capture that is not a transport error
# ends the run, so the first poll after a real answer never waits.
#
# This adapter is deliberately thin. It owns only what is specific to Lavish:
# canonical source identity, the argv for the currently published poll command,
# and how to read a completed result. Ownership, durable capture, publication,
# and restart recovery all belong to bin/fm-procevent.sh.
#
# The published poll vocabulary includes feedback, ended, waiting, and
# browser_disconnected. A waiting result from this no-timeout poll means a
# second poller was present; it is not a normal idle round. browser_disconnected
# means the session remains open and is handled as a silent reconnect wait.
# Before each poll attempt, resolve the artifact's saved URL from Lavish's own
# session store (LAVISH_AXI_STATE_DIR/state.json, default ~/.lavish-axi/state.json)
# and use its host and port. Opening the board writes that URL; polling does not.
# This is a routing lookup before the blocking call, not presence polling or a
# second route record. Ambient/configured addresses must not retarget a reply.
# An unreadable or missing session stops before the staged reply is consumed.
#
# `answers` is this adapter's half of the generic keyed-answer contract in
# bin/fm-procevent.sh. It reports what the captain actually chose, as
# `<task-id>\t<answer>\t<label>` lines, and stops there. It maps nothing to a
# task, records no decision, and closes nothing: a captain answer is not special
# to Lavish, so every rule about what a keyed answer DOES belongs to the one
# intake in bin/fm-captain-hold.sh, which the runner feeds. A Lavish review is
# just an ephemeral discussion format that happens to carry answers.
#
# Only rows tagged `choice` are read. A freeform captain message is prose that may
# contain anything, and must never be able to forge a decision key.
# `answers` and `reconciles` use the same parser as `read` for either emission
# form. Malformed content or a declared/parsed count mismatch prints a diagnostic
# to stderr and exits 3, even if valid choices were already printed to stdout;
# callers must not treat that output as a complete extraction.
#
# `read` is the presentation command summarized above; keyed intake remains
# the separate `answers` contract described here.
#
# `pages` is this adapter's half of the page-prompt seam in bin/fm-procevent.sh.
# A page shown in place inside the bearings board queues its prompts on the
# board's own session tagged `page`, with an `fm-board-page.v1` Context data
# block naming the page (bin/fm-board-page.sh's header owns that contract).
# `pages` prints one JSON line per such prompt -
# `{key, page, tag, text, prompt, data}`, where `prompt` is the page's own words
# with the page's own data appended as Lavish would have, and `key` is unique to
# the capture and the prompt's place in it - plus `{"app_ended":true}` when the
# board session itself ended. It routes nothing; bin/fm-board-page.sh route
# owns delivery. It exits 3 like `answers` when the result is not fully
# accounted for. `silent` also holds a result whose every queued item is a page
# prompt, once `fm-board-page.sh routed` confirms each one reached its page and
# a live owning task was told, so a page's answer goes to the page's agent and
# never wakes the handler; that header owns what counts as routed.
#
# `priority` is this adapter's half of the board-priority seam in
# bin/fm-procevent.sh. It prints, as one compact JSON line, the
# `fm-bearings-priority.v1` Context data of the last prompt tagged `priority`
# in the result - the most recent ranking the board sent - and nothing when no
# such prompt carries a valid one. It records nothing; bin/fm-board-priority.sh
# `record` owns that. It exits 3 like `answers` when the result is not fully
# accounted for.
#
# It wraps the published `lavish-axi poll` and `lavish-axi reply` interfaces,
# verified against 0.1.80. `poll` long-polls indefinitely; `reply` exits only
# after the server confirms acceptance. Older compatible versions retain the
# legacy poll-with-reply path, without the synchronous handoff guarantee.
#
# BOUNDED QUIET RETRY, owned here and nowhere else. A live listener can be cut
# short by the server with exactly this two-line response while the session's
# marks remain available:
#
#   error: Lavish Editor poll response was interrupted
#   code: SERVER_ERROR
#
# That is an internal retry, not news, so registering the raw poll made the
# generic runner capture it and wake the whole fleet. `poll` therefore re-runs
# the published poll up to POLL_RETRY_LIMIT times for that exact response, with
# attempt starts at least POLL_RETRY_DELAY_DEFAULT seconds apart. The match is exact and
# deliberately narrow: real feedback, ended and missing sessions, any other
# SERVER_ERROR, and the same interruption still standing after the bound is
# spent are all printed straight through and captured normally, where `silent`
# then treats a bare interruption as the server restart above. The retry is a
# Lavish fact, so the generic runner in bin/fm-procevent.sh stays
# adapter-agnostic and learns nothing about it.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

apply_session_host() {  # <artifact>
  local endpoint
  endpoint=$(perl -MJSON::PP -MCwd=realpath -MEncode=decode,FB_CROAK -e '
    use strict;
    use warnings;
    my ($path, $artifact) = @ARGV;
    my $real = realpath($artifact) // die "cannot resolve board artifact\n";
    $real = decode("UTF-8", $real, FB_CROAK);
    open my $file, "<", $path or die "cannot read Lavish session store\n";
    -f $file or die "Lavish session store is not a regular file\n";
    local $/;
    my $state = eval { decode_json(<$file>) };
    !$@ or die "invalid Lavish session store\n";
    ref($state) eq "HASH" && ref($state->{sessions}) eq "HASH"
      or die "invalid Lavish session store\n";
    my @sessions = grep {
      ref($_) eq "HASH" && defined($_->{file}) && $_->{file} eq $real
    } values %{$state->{sessions}};
    @sessions == 1 or die "board must have one saved Lavish session\n";
    my $url = $sessions[0]->{url} // "";
    $url =~ m{\Ahttp://(\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+):([0-9]+)/session/[0-9a-f]{16}(?:\?[^\s#]*)?\z}
      or die "invalid saved Lavish session URL\n";
    my ($host, $port) = ($1, $2);
    $host =~ s/^\[|\]$//g;
    $host ne "0.0.0.0" && $host ne "::" && $port >= 1 && $port <= 65535
      or die "invalid saved Lavish server address\n";
    print "$host\n$port\n";
  ' "${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json" "$1") \
    || die "cannot resolve the board server from its Lavish session: $1"
  LAVISH_AXI_HOST=${endpoint%$'\n'*}
  LAVISH_AXI_PORT=${endpoint##*$'\n'}
  export LAVISH_AXI_HOST LAVISH_AXI_PORT
}

lavish_reply_compatible() {
  local status=0
  "$FM_ROOT/bin/fm-bootstrap.sh" lavish-reply-compatible >/dev/null 2>&1 || status=$?
  case "$status" in
    0|1) return "$status" ;;
  esac
  die "cannot confirm a supported lavish-axi version, so the staged reply was not posted; retry once \`lavish-axi --version\` reports a supported release"
}

post_lavish_reply() {  # <artifact> <reply-file>
  local output
  if ! output=$(lavish-axi reply "$1" --agent-reply-file "$2" 2>&1); then
    [ -n "$output" ] || output="lavish-axi reply exited nonzero"
    die "Lavish did not accept the staged reply: $output"
  fi
}

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact, so two names for one file are one
# source and must never become two owners.
cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

cmd_arm() {
  local artifact='' task='' reply_file='' id real owner listening
  local -a listener=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for)
        [ "$#" -ge 2 ] || usage
        task=$2
        shift 2
        ;;
      --agent-reply-file)
        [ "$#" -ge 2 ] || usage
        reply_file=$2
        shift 2
        ;;
      --*) usage ;;
      *)
        [ -z "$artifact" ] || usage
        artifact=$1
        shift
        ;;
    esac
  done
  [ -n "$artifact" ] || usage
  [ -z "$reply_file" ] || [ -n "$task" ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  poll_retry_delay >/dev/null
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  listener=("$SCRIPT_DIR/fm-procevent-lavish.sh" poll "$real")
  [ -z "$reply_file" ] || listener+=(--agent-reply-file "$reply_file")
  if [ -n "$task" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" register-task lavish "$id" "$task" -- \
      "${listener[@]}" || exit 1
  else
    # This adapter's own listener command, which runs the plain blocking form
    # with no --timeout-ms so completion is a server event, and absorbs only
    # the exact transient interruption.
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" \
      -- "${listener[@]}" || exit 1
  fi
  # Registration is not a running listener. Readiness is the process-event
  # owner's evidence for this generation; a miss retires a source that never
  # started so arm does not leave it registered.
  listening=0
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" ensure-listening "$id" || listening=$?
  if [ "$listening" -eq 3 ]; then
    printf 'still-listening: %s\n' "$id"
    printf 'artifact: %s\n' "$real"
    [ -z "$task" ] || printf 'owner-task: %s\n' "$task"
    printf 'note: an earlier listener is still live and serving this board; this registration takes effect only after the source is retired and armed again\n'
    exit 0
  fi
  if [ "$listening" -ne 0 ]; then
    owner=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
      | awk -v id="$id" '$1 == id { print $3; exit }')
    case "$owner" in
      live|orphaned|task:*/listening|task:*/round-open) ;;
      *) FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" retire "$id" >/dev/null 2>&1 || true ;;
    esac
    exit 1
  fi
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
  [ -z "$task" ] || printf 'owner-task: %s\n' "$task"
}

cmd_deliver_reply() {
  [ "$#" -eq 4 ] && [ "$1" = poll ] && [ "$3" = --agent-reply-file ] || usage
  lavish_reply_compatible || exit 3
  apply_session_host "$2"
  post_lavish_reply "$2" "$4"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# Whether a firstmate-owned decision page is finished, as the header's
# `finished` describes. Exit 0 is the only "finished"; every doubt is a 1.
cmd_finished() {  # <source-id> -- <listener argv>...
  local id=${1-} artifact real board key
  local -a keys=() answered=()
  [ "$#" -ge 4 ] && [ "$2" = -- ] || usage
  shift 2
  [ "${1##*/}" = fm-procevent-lavish.sh ] && [ "${2-}" = poll ] || return 1
  artifact=${3-}
  [ "$(cmd_source_id "$artifact" 2>/dev/null)" = "$id" ] || return 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || return 1
  board="$FM_HOME/.lavish/bearings-board.html"
  if [ -e "$board" ] && [ "$(cmd_source_id "$board" 2>/dev/null)" = "$id" ]; then
    return 1
  fi
  # A session that has ended will never deliver to this listener again.
  if perl -MJSON::PP -MEncode=decode,FB_CROAK -e '
    my ($path, $real) = @ARGV;
    $real = decode("UTF-8", $real, FB_CROAK);
    open my $file, "<", $path or exit 1;
    local $/;
    my $state = eval { decode_json(<$file>) };
    ref($state) eq "HASH" && ref($state->{sessions}) eq "HASH" or exit 1;
    my @sessions = grep {
      ref($_) eq "HASH" && defined($_->{file}) && $_->{file} eq $real
    } values %{$state->{sessions}};
    @sessions or exit 1;
    for (@sessions) { defined($_->{status}) && $_->{status} eq "ended" or exit 1 }
    exit 0;
  ' "${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json" "$real" 2>/dev/null; then
    return 0
  fi
  mapfile -t keys < <(perl -ne '
    print "$1\n" while /data-lavish-question="([^"]*)"/g;
  ' "$real" 2>/dev/null | sort -u)
  [ "${#keys[@]}" -gt 0 ] || return 1
  for key in "${keys[@]}"; do
    [[ "$key" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || return 1
  done
  mapfile -t answered < <(perl -MJSON::PP -e "$(lavish_result_parser)"'
    use strict; use warnings;
    my ($inbox, $id, @keys) = @ARGV;
    my %want = map { $_ => 1 } @keys;
    my %answered;
    sub truthy { my ($v) = @_; return JSON::PP::is_bool($v) ? ($v ? 1 : 0) : 0 }
    opendir(my $dh, $inbox) or exit 0;
    for my $name (readdir $dh) {
      next unless $name =~ /\A\Q$id\E\.([0-9]+)\.result\z/;
      my $path = "$inbox/$name";
      my $mark = "$inbox/$id.$1.handled";
      next if -l $path || !-f $path || -l $mark || !-f $mark;
      my ($form, $want, $items, $malformed) = eval { lavish_result($path, "prompts") };
      next if !defined($form) || $malformed || @$items != $want;
      for my $item (@$items) {
        next unless defined $item->{tag} && $item->{tag} eq "choice";
        my $prompt = $item->{prompt};
        next unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
        my $data = eval { decode_json($1) };
        next unless ref($data) eq "HASH";
        my $key = $data->{question};
        next if !defined($key) || ref($key) || !$want{$key};
        if (defined($data->{schema}) && !ref($data->{schema})
            && $data->{schema} eq "fm-bearings-answer.v1") {
          my ($selected, $note) = ($data->{selection}, $data->{note});
          next if !defined($selected) || ref($selected) || !defined($note) || ref($note);
          next if $selected eq "reconcile";
          if (!length($selected)) {
            next unless length($note);
            next if truthy($data->{has_options}) && !truthy($data->{free_text});
          }
        } elsif (!exists($data->{schema}) && !exists($data->{selection})
            && !exists($data->{note})) {
          my $answer = $data->{answer};
          next if !defined($answer) || ref($answer) || !length($answer);
          next if $answer eq "reconcile" || index($answer, "reconcile - ") == 0;
        } else {
          next;
        }
        $answered{$key} = 1;
      }
    }
    print "$_\n" for sort keys %answered;
  ' "$(fm_procevent_inbox_dir "${FM_STATE_OVERRIDE:-$FM_HOME/state}")" "$id" "${keys[@]}" 2>/dev/null)
  for key in "${keys[@]}"; do
    case $'\n'"$(printf '%s\n' "${answered[@]}")"$'\n' in
      *$'\n'"$key"$'\n'*) continue ;;
    esac
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" settled "$key" >/dev/null 2>&1 || return 1
  done
  return 0
}

# The bounded quiet retry described in the header. The bound is a constant
# because it is a property of the transient response, not an operator choice;
# only the delay takes an override, so a test can exercise the real bound
# without waiting it out.
POLL_RETRY_LIMIT=12
TRANSPORT_OUTAGE_ANNOUNCE_SECONDS=300
POLL_RETRY_DELAY_DEFAULT=5
POLL_RETRY_DELAY_MIN=1
POLL_RETRY_DELAY_MAX=60

# Exit 0 only for the exact two-line interruption, and nothing else. The whole
# response must be those two lines with those exact bytes: whitespace variants,
# a longer response that merely opens with them, and any other SERVER_ERROR are
# genuine errors this adapter must never swallow.
poll_response_filter() {  # <response-file>
  perl -e '
    use strict;
    use warnings;
    my ($stage) = @ARGV;
    my $expected = "error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n";
    open my $staged, ">", $stage or exit 2;
    binmode STDIN;
    binmode STDOUT;
    binmode $staged;
    my ($candidate, $streaming) = ("", 0);
    sub write_all {
      my ($handle, $bytes) = @_;
      my $offset = 0;
      while ($offset < length $bytes) {
        my $written = syswrite $handle, $bytes, length($bytes) - $offset, $offset;
        exit 2 unless defined $written;
        $offset += $written;
      }
    }
    while (1) {
      my $count = sysread STDIN, my $chunk, 65536;
      exit 2 unless defined $count;
      last if $count == 0;
      if ($streaming) {
        write_all(*STDOUT, $chunk);
        next;
      }
      my $room = length($expected) + 1 - length($candidate);
      my $take = length($chunk) < $room ? length($chunk) : $room;
      my $prefix = substr($chunk, 0, $take);
      $candidate .= $prefix;
      write_all($staged, $prefix);
      my $matches_prefix = length($candidate) <= length($expected)
        && substr($expected, 0, length($candidate)) eq $candidate;
      if (!$matches_prefix) {
        write_all(*STDOUT, $candidate);
        write_all(*STDOUT, substr($chunk, $take));
        $streaming = 1;
      }
    }
    exit 10 if !$streaming && $candidate eq $expected;
    write_all(*STDOUT, $candidate) unless $streaming;
  ' "$1"
}

# Minimum seconds between retry attempt starts. FM_LAVISH_POLL_RETRY_DELAY is a
# bounded test override; a malformed or out-of-range value is refused rather than quietly
# rounded, because silently changing a retry cadence is how a bound stops
# meaning anything.
poll_retry_delay() {
  local delay=${FM_LAVISH_POLL_RETRY_DELAY-}
  if [ -z "$delay" ]; then
    printf '%s\n' "$POLL_RETRY_DELAY_DEFAULT"
    return 0
  fi
  case "$delay" in
    *[!0-9]*) die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from $POLL_RETRY_DELAY_MIN to $POLL_RETRY_DELAY_MAX: $delay" ;;
  esac
  [ "$delay" -ge "$POLL_RETRY_DELAY_MIN" ] && [ "$delay" -le "$POLL_RETRY_DELAY_MAX" ] \
    || die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from $POLL_RETRY_DELAY_MIN to $POLL_RETRY_DELAY_MAX: $delay"
  printf '%s\n' "$delay"
}

poll_iteration_started() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
    'printf "%.6f\\n", clock_gettime(CLOCK_MONOTONIC)'
}

poll_iteration_floor_wait() {
  perl -MTime::HiRes=clock_gettime,sleep,CLOCK_MONOTONIC -e '
    my ($started, $floor) = @ARGV;
    my $remaining = $floor - (clock_gettime(CLOCK_MONOTONIC) - $started);
    sleep($remaining) if $remaining > 0;
  ' "$1" "$2"
}

# The outage back-off described in the header. The run is counted from this
# source's latest capture backwards and stops at the first capture that is not
# a transport error, so a real answer resets it at once; the walk also stops as
# soon as the delay reaches its cap, which bounds its cost. The wait is measured
# from the latest capture, so time the listener already spent relaunching
# counts, and it never exceeds the computed delay even if that capture's time
# reads as being in the future.
transport_backoff_wait() {  # <artifact> <base-delay>
  local artifact=$1 delay=$2 id inbox latest='' f seq run=0 captured now wait
  id=$(cmd_source_id "$artifact" 2>/dev/null) || return 0
  inbox=$(fm_procevent_inbox_dir "${FM_STATE_OVERRIDE:-$FM_HOME/state}")
  for f in "$inbox/$id".*.result; do
    seq=${f##*/"$id".}
    seq=${seq%.result}
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$latest" ] || [ "$((10#$seq))" -gt "$((10#$latest))" ]; then
      latest=$seq
    fi
  done
  [ -n "$latest" ] || return 0
  seq=$((10#$latest))
  while [ "$seq" -ge 1 ]; do
    f="$inbox/$id.$seq.result"
    if ! { [ -f "$f" ] && [ ! -L "$f" ] && result_is_transport_error "$f"; }; then
      break
    fi
    run=$((run + 1))
    [ "$run" -eq 1 ] || delay=$((delay * 2))
    if [ "$delay" -ge "$POLL_RETRY_DELAY_MAX" ]; then
      delay=$POLL_RETRY_DELAY_MAX
      break
    fi
    seq=$((seq - 1))
  done
  [ "$run" -gt 0 ] || return 0
  wait=$delay
  if captured=$(fm_path_mtime "$inbox/$id.$latest.result") \
    && case "$captured" in ''|*[!0-9]*) false ;; esac; then
    now=$(date +%s)
    [ "$now" -lt "$captured" ] || wait=$((delay - (now - captured)))
  fi
  [ "$wait" -le 0 ] || sleep "$wait"
}

cmd_poll() {
  local artifact=${1-} delay attempt=0 response cleanup_command rc filter_rc iteration_started
  local pipeline_status reply_file=''
  local reply_text='' reply_pending=0
  [ -n "$artifact" ] || usage
  if [ "$#" -eq 3 ] && [ "${2-}" = --agent-reply-file ]; then
    reply_file=$3
  elif [ "$#" -ne 1 ]; then
    usage
  fi
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  delay=$(poll_retry_delay) || exit 1
  transport_backoff_wait "$artifact" "$delay"
  response=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-poll.XXXXXX") || die "cannot stage the poll response"
  printf -v cleanup_command 'rm -f -- %q' "$response"
  # shellcheck disable=SC2064 # $cleanup_command must expand now, while the staged path is still set.
  trap "$cleanup_command" EXIT
  # Retirement stops this listener by signalling its process group, and bash runs
  # no EXIT trap for an uncaught signal, so each one cleans up the staged
  # response and then re-raises itself with the default disposition, leaving the
  # process dying exactly as the runner expects.
  local signal
  for signal in INT TERM HUP; do
    # shellcheck disable=SC2064 # Same reason: expand now, while both are set.
    trap "$cleanup_command; trap - $signal; kill -$signal $$" "$signal"
  done
  while :; do
    iteration_started=$(poll_iteration_started) || die "cannot start the poll rate governor"
    [ -f "$artifact" ] && [ ! -L "$artifact" ] && [ -r "$artifact" ] \
      || die "artifact is no longer a readable file: $artifact"
    apply_session_host "$artifact"
    # Newer Lavish builds expose a one-shot reply command whose success is the
    # server's acceptance receipt. Consume the staged file only after that
    # confirmation; older compatible builds retain the published poll reply
    # behavior and its best-effort delivery boundary.
    if [ -f "$reply_file" ] && [ ! -L "$reply_file" ]; then
      if lavish_reply_compatible; then
        post_lavish_reply "$artifact" "$reply_file"
        rm -f -- "$reply_file" || die "cannot consume agent reply file: $reply_file"
      else
        reply_text=$(cat -- "$reply_file") \
          || die "cannot read agent reply file: $reply_file"
        rm -f -- "$reply_file" || die "cannot consume agent reply file: $reply_file"
        reply_pending=1
      fi
    fi
    if [ "$reply_pending" -eq 1 ]; then
      lavish-axi poll "$artifact" --agent-reply "$reply_text" | poll_response_filter "$response"
    else
      lavish-axi poll "$artifact" | poll_response_filter "$response"
    fi
    pipeline_status=("${PIPESTATUS[@]}")
    reply_pending=0
    rc=${pipeline_status[0]}
    filter_rc=${pipeline_status[1]}
    case "$filter_rc" in
      0) break ;;
      10)
        if [ "$attempt" -lt "$POLL_RETRY_LIMIT" ]; then
          attempt=$((attempt + 1))
          poll_iteration_floor_wait "$iteration_started" "$delay" \
            || die "cannot enforce the poll rate governor"
        else
          cat -- "$response"
          break
        fi
        ;;
      *) die "cannot classify the poll response" ;;
    esac
  done
  return "$rc"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback)            printf 'feedback\n'; return 0 ;;
    ended)               printf 'ended\n'; return 0 ;;
    waiting)             printf 'waiting\n'; return 0 ;;
    browser_disconnected) printf 'disconnected\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result - keeps the source armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

# Print the shared result parser described in its own leading comment, for
# prepending to a command's perl program.
lavish_result_parser() {
  cat <<'PERL'
use strict; use warnings;
# The one reader of a captured result's queued-content block, shared by `read`,
# `answers`, and `reconciles` so the two emission forms are parsed in exactly one
# place. lavish-axi encodes its response as TOON and picks the form itself:
#
#   table form, when every item carries the same scalar fields:
#     prompts[N]{uid,prompt,selector,tag,text}:
#       "1","a comment",div#a,div,"Element text"
#   list form, when items differ, for example when some carry a nested
#   `target` object or an `attachments` table:
#     prompts[N]:
#       - uid: "1"
#         prompt: "a comment"
#         target:
#           type: table-cell
#
# Only a column-zero header opens a block, and the block is the indented lines
# that follow it. Every captain-supplied value is a single encoded line, so an
# item or field boundary is only ever an indentation the encoder wrote: in list
# form an item starts at the first item's hyphen indent, its own fields sit one
# indent deeper, and anything deeper still is skipped only beneath a field that
# opened a nested object or array. Only an item's own scalar fields are
# returned. A line or item the parser cannot fully account for is counted as
# malformed rather than dropped, and a column-zero line that names the block
# but is not a recognized header makes the whole result malformed, so a form
# this reader does not know can never look like a complete, empty result.
#
# lavish_result(<path>, <block-name-regex>) returns
# (form, declared, [item hashes], malformed), with form one of none, table,
# list, or unrecognized.
sub lavish_unescape {
  my ($v) = @_;
  $v =~ s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge;
  return $v;
}
sub lavish_table_rows {
  my ($fields, $rows) = @_;
  my (@items, $malformed);
  $malformed = 0;
  for my $row (@$rows) {
    $row =~ s/^\s+//;
    my @vals;
    while (length $row) {
      if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
        push @vals, $1;
      } else {
        $row =~ s/^([^,]*)//;
        push @vals, $1;
      }
      last unless $row =~ s/^,//;
    }
    # An unquoted prompt or text value may carry commas; rejoin the surplus
    # into that one field rather than shifting every later column.
    if (@vals > @$fields) {
      my ($preserve) = grep { $fields->[$_] eq "prompt" } 0 .. $#$fields;
      ($preserve) = grep { $fields->[$_] eq "text" } 0 .. $#$fields unless defined $preserve;
      if (defined $preserve) {
        my $count = @vals - @$fields + 1;
        my @parts = splice @vals, $preserve, $count;
        splice @vals, $preserve, 0, join(",", @parts);
      }
    }
    if (@vals != @$fields) {
      $malformed++;
      next;
    }
    my %f;
    $f{$fields->[$_]} = lavish_unescape($vals[$_]) for 0 .. $#$fields;
    push @items, \%f;
  }
  return (\@items, $malformed);
}
sub lavish_list_items {
  my ($lines) = @_;
  my (@items, $unit, $cur, $bad, $nested, %keys);
  my ($malformed, $stray) = (0, 0);
  my $finish = sub {
    return unless $cur;
    if ($bad || !%$cur) { $malformed++ } else { push @items, $cur }
    ($cur, $bad, $nested) = (undef, 0, 0);
  };
  my $field = sub {
    my ($s) = @_;
    my $key;
    if ($s =~ s/^"((?:[^"\\]|\\.)*)"//) {
      $key = lavish_unescape($1);
    } elsif ($s =~ s/^([A-Za-z_][A-Za-z0-9_.]*)//) {
      $key = $1;
    } else {
      $bad = 1;
      return;
    }
    $bad = 1 if $keys{$key}++;
    $nested = 0;
    if ($s =~ /^(?::|\[\d+\](?:\{[^}]*\})?:)\s*$/) {
      $nested = 1;
    } elsif ($s =~ /^\[\d+\]: /) {
      # An inline primitive array is not an item field this adapter reads.
    } elsif ($s =~ /^: (.*)$/) {
      my $v = $1;
      if ($v =~ /^"/) {
        if ($v =~ /^"((?:[^"\\]|\\.)*)"\s*$/) {
          $cur->{$key} = lavish_unescape($1);
        } else {
          $bad = 1;
        }
      } else {
        $v =~ s/\s+$//;
        $cur->{$key} = $v;
      }
    } else {
      $bad = 1;
    }
  };
  for my $line (@$lines) {
    $line =~ /^( *)(.*)$/s;
    my ($ind, $rest) = (length $1, $2);
    $unit = $ind if !defined($unit) && $ind > 0 && $rest =~ /^-(?: |$)/;
    if (defined($unit) && $ind == $unit && $rest =~ /^-(?: (.*))?$/s) {
      my $first = $1;
      $finish->();
      ($cur, $bad, $nested) = ({}, 0, 0);
      %keys = ();
      if (defined $first) { $field->($first) } else { $bad = 1 }
    } elsif ($cur && $ind == 2 * $unit) {
      $field->($rest);
    } elsif ($cur && $nested && $ind > 2 * $unit) {
      next;
    } elsif ($cur) {
      $bad = 1;
    } else {
      $stray = 1;
    }
  }
  $finish->();
  return (\@items, $malformed + $stray);
}
sub lavish_result {
  my ($path, $names) = @_;
  open my $fh, "<", $path or return;
  my ($form, $want, @fields, @body) = ("none", 0);
  while (my $line = <$fh>) {
    chomp $line;
    if ($form eq "none") {
      next unless $line =~ /^(?:$names)/;
      if ($line =~ /^(?:$names)\[(\d+)\]\{([^}]*)\}:\s*$/) {
        ($form, $want, @fields) = ("table", $1, split /,/, $2);
      } elsif ($line =~ /^(?:$names)\[(\d+)\]:\s*$/) {
        ($form, $want) = ("list", $1);
      } else {
        $form = "unrecognized";
        $want = $1 if $line =~ /^(?:$names)\[(\d+)\]/;
        last;
      }
      next;
    }
    last unless $line =~ /^\s/;
    last if $form eq "table" && @body >= $want;
    push @body, $line;
  }
  close $fh;
  return ($form, $want, [], 1) if $form eq "unrecognized";
  return ($form, $want, [], 0) if $form eq "none";
  my ($items, $malformed) = $form eq "table"
    ? lavish_table_rows(\@fields, \@body)
    : lavish_list_items(\@body);
  return ($form, $want, $items, $malformed);
}
PERL
}

# Whether a completed result carries any queued content block at all. The
# published response frames content as a top-level `prompts[N]{...}:` or
# `feedback[N]{...}:` table header, or a `prompts[N]:` list header, whose items
# are INDENTED, so this anchors on column zero: an indented payload line is captain-supplied text and must never be able
# to forge - or, here, to hide behind - a content header. Any recognized block
# is content regardless of its declared count, while a malformed top-level
# prompts or feedback header makes the result indeterminate.
#
# 0 = content present, 1 = provably no content, anything else = the check did
# not complete. The caller must distinguish those three, because "the check
# failed" is never proof that nothing was said.
result_has_queued_content() {  # <result-file>
  awk '
    /^(prompts|feedback)\[[0-9]+\](\{[^}]*\})?:[[:space:]]*$/ {
      verdict = "present"
      exit
    }
    /^(prompts|feedback)/ {
      verdict = "indeterminate"
      exit
    }
    END {
      if (verdict == "present") exit 0
      if (verdict == "indeterminate") exit 2
      exit 1
    }
  ' "$1"
}

# Whether a captured result is nothing but one of the transport errors the
# published poll prints while the board server is down or restarting: the whole
# result is the error line, `code: SERVER_ERROR`, and only `help[N]:` lines. Any
# other line, a session block, or a near-match message is not one.
result_is_transport_error() {  # <result-file>
  awk '
    NR == 1 {
      if ($0 !~ /^error: Lavish Editor (server did not start|poll response was interrupted|server connection failed)$/) { bad = 1; exit }
      next
    }
    NR == 2 {
      if ($0 != "code: SERVER_ERROR") { bad = 1; exit }
      next
    }
    /^help\[[0-9]+\]: / { next }
    { bad = 1; exit }
    END { exit (bad || NR < 2) ? 1 : 0 }
  ' "$1" 2>/dev/null
}

# Whether this transport-error capture is the one that takes its source's
# unbroken run of transport-error captures (this sequence and the consecutive
# earlier sequences beside it) past TRANSPORT_OUTAGE_ANNOUNCE_SECONDS, measured
# between capture times. Exactly one capture per run qualifies, and the verdict
# reads only captures that already exist, so it is the same on every re-read.
# The walk stops as soon as the previous capture alone is past the bound, so its
# cost is bounded by the captures in that window, not by the outage's length. A
# capture time that cannot be read counts as sustained, so doubt announces.
transport_outage_sustained_at() {  # <transport-error-result-file>
  local file=$1 dir id seq now start prev='' earlier at
  dir=$(dirname -- "$file")
  id=$(fm_procevent_result_source_id "$file")
  seq=$(fm_procevent_result_sequence "$file")
  now=$(fm_path_mtime "$file") || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  start=$now
  earlier=$((10#$seq - 1))
  while [ "$earlier" -ge 1 ]; do
    at="$dir/$id.$earlier.result"
    if ! { [ -f "$at" ] && [ ! -L "$at" ] && result_is_transport_error "$at"; }; then break; fi
    start=$(fm_path_mtime "$at") || return 0
    case "$start" in ''|*[!0-9]*) return 0 ;; esac
    [ -n "$prev" ] || prev=$start
    [ $((prev - start)) -lt "$TRANSPORT_OUTAGE_ANNOUNCE_SECONDS" ] || return 1
    earlier=$((earlier - 1))
  done
  [ $((now - start)) -ge "$TRANSPORT_OUTAGE_ANNOUNCE_SECONDS" ] || return 1
  [ -n "$prev" ] || return 0
  [ $((prev - start)) -lt "$TRANSPORT_OUTAGE_ANNOUNCE_SECONDS" ]
}

# Whether a captured result is a routine no-op the runner should record without
# announcing, for the generic runner's silence seam. Lavish's notion of "nothing
# was said" lives here and nowhere else: an ended session carrying no queued
# content block is a board the captain closed without saying anything, and the
# handler learns nothing from being told. Anything else - a real answer, a
# missing or waiting session, an unreadable result - is announced.
cmd_silent() {
  local file=${1-} content_rc lines
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = disconnected ] && return 0
  if result_is_transport_error "$file"; then
    transport_outage_sustained_at "$file" && return 1
    return 0
  fi
  # Every queued item is a page prompt and each one already reached its page.
  if lines=$(page_rows only "$file" 2>/dev/null) && [ -n "$lines" ]; then
    printf '%s\n' "$lines" | FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-board-page.sh" routed >/dev/null 2>&1 && return 0
  fi
  [ "$(cmd_classify "$file")" = ended ] || return 1
  result_has_queued_content "$file"
  content_rc=$?
  # Only a completed check that proved the result carries nothing declares
  # silence; a check that could not complete announces, like every other
  # uncertainty here.
  [ "$content_rc" -eq 1 ]
}

# Print `key<TAB>answer<TAB>label[<TAB>mode]` for each non-reconcile structured choice the
# captain submitted in a captured result; the optional mode column relays the
# card's declared close mode (`done` or `release`) to the keyed-answer intake.
# Items come from the shared result parser above, in either emission form, and
# only items whose `tag` field is `choice` are read.
# The header owns the partial-output and failure contract.
# A freeform `message` row is captain prose and is deliberately never a
# source of decision keys, and neither is a v1 row with an empty selection
# whose context carries `has_options: true` without `free_text: true`: that
# text is a comment on an option card, read by firstmate from the capture. A row that does not carry both a slug-shaped `question`
# and the versioned `selection` and `note` fields inside its `Context data:` block
# is skipped. A time-limited rollout branch accepts the old question/answer
# shape only for ordinary answers and rejects its bare or annotated reconcile
# values because old rows do not separate the selected option from its note.
# The question cap is 128 so any task id fits, including the long legacy
# `<origin>-decision-<key>` identities pre-collapse decks still carry; the
# security property is the slug SHAPE, which is unchanged.
cmd_choice_rows() {
  local selection=$1 file=${2-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  perl -MJSON::PP -e "$(lavish_result_parser)"'
    use strict; use warnings;
    my ($selection, $path) = @ARGV;
    my ($form, $want, $items, $malformed) = lavish_result($path, "prompts");
    defined $form or exit 1;
    my %seen;
    my @choices;
    sub truthy { my ($v) = @_; return JSON::PP::is_bool($v) ? ($v ? 1 : 0) : 0 }
    for my $item (@$items) {
      my %f = %$item;
      next unless defined $f{tag} && $f{tag} eq "choice";
      my $prompt = $f{prompt};
      next unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
      my $ctx = $1;
      my $data = eval { decode_json($ctx) };
      next unless ref($data) eq "HASH";
      my ($key, $selected, $note, $answer, $legacy);
      if (defined($data->{schema}) && !ref($data->{schema})
          && $data->{schema} eq "fm-bearings-answer.v1") {
        $key = $data->{question};
        $selected = $data->{selection};
        $note = $data->{note};
        next if !defined($key) || ref($key) || !defined($selected) || ref($selected)
          || !defined($note) || ref($note);
        next unless $selected eq "" || $selected =~ /\A[A-Za-z0-9._-]{1,128}\z/;
        next unless length($selected) || length($note);
        # Free text alone on a card that offers its own options is a comment
        # for firstmate, never an answer: only a picked option closes such a
        # call, unless the card declares itself a free-text question. The
        # captured result and its wake still carry the comment.
        next if !length($selected) && truthy($data->{has_options})
          && !truthy($data->{free_text});
        # A selection with a note keeps the whole note in the answer; the
        # label is only the 512-cut display text.
        $answer = length($selected) ? (length($note) ? "$selected - $note" : $selected) : $note;
        $legacy = 0;
      # Time-limited compatibility for captures from pre-change boards; remove
      # once no board carrying the old question/answer context can remain armed.
      } elsif (!exists($data->{schema}) && !exists($data->{selection})
          && !exists($data->{note})) {
        $key = $data->{question};
        $answer = $data->{answer};
        next if !defined($key) || ref($key) || !defined($answer) || ref($answer);
        next unless length($answer);
        next if $answer eq "reconcile" || index($answer, "reconcile - ") == 0;
        $selected = "";
        $note = "";
        $legacy = 1;
      } else {
        next;
      }
      next unless $key =~ /\A[A-Za-z0-9._-]{1,128}\z/;
      my $mode = "";
      if (exists $data->{close}) {
        next if !defined($data->{close}) || ref($data->{close})
          || ($data->{close} ne "done" && $data->{close} ne "release");
        $mode = $data->{close};
      }
      my $label = defined $f{text} ? $f{text} : "";
      s/[\x00-\x1f\x7f]/ /g for ($answer, $note, $label);
      $label = substr($label, 0, 512);
      if (defined $seen{$key}) { $choices[$seen{$key}] = undef }
      $seen{$key} = scalar @choices;
      push @choices, {
        key => $key, selection => $selected, note => $note, legacy => $legacy,
        answer => $answer, label => $label, mode => $mode
      };
    }
    for my $choice (grep { defined } @choices) {
      if ($selection eq "reconciles") {
        next if $choice->{legacy};
        # A reconcile request keeps its 512-character note bound: an
        # over-long one is dropped, exactly as before the answer cap moved.
        if ($choice->{selection} eq "reconcile" && length($choice->{note}) <= 512) {
          print length($choice->{note})
            ? "$choice->{key}\t$choice->{note}\n"
            : "$choice->{key}\n";
        }
        next;
      }
      next if $choice->{selection} eq "reconcile";
      print length $choice->{mode}
        ? "$choice->{key}\t$choice->{answer}\t$choice->{label}\t$choice->{mode}\n"
        : "$choice->{key}\t$choice->{answer}\t$choice->{label}\n";
    }
    if ($malformed || @$items != $want) {
      print STDERR "error: the result is not fully accounted for: declared $want, parsed ",
        scalar(@$items), ", malformed $malformed\n";
      exit 3;
    }
  ' "$selection" "$file"
}

cmd_answers() { cmd_choice_rows answers "$@"; }

# The `pages` lines described in the header. In `only` mode it prints nothing
# and exits 4 unless the result's every queued item is a page prompt and it
# carries no feedback block.
page_rows() {  # all|only <result-file>
  local mode=$1 file=${2-} base ended=0
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  base=$(basename -- "$file")
  base=${base%.result}
  [ "$(cmd_classify "$file")" = ended ] && ended=1
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) ended=1 ;;
  esac
  perl -MJSON::PP -e "$(lavish_result_parser)"'
    use strict; use warnings;
    my ($mode, $path, $base, $ended) = @ARGV;
    $base =~ s/[^A-Za-z0-9._-]/_/g;
    $base = substr($base, -100);
    my ($form, $want, $items, $malformed) = lavish_result($path, "prompts");
    defined $form or exit 1;
    my $mark = "\n\nContext data:\n";
    my $out = JSON::PP->new->utf8->canonical;
    my $pretty = JSON::PP->new->utf8->canonical->pretty->space_before(0)->indent_length(2);
    my (@lines, $n, $other);
    $n = 0; $other = 0;
    for my $item (@$items) {
      $n++;
      my %f = %$item;
      my $prompt = $f{prompt};
      my $at = defined $prompt ? rindex($prompt, $mark) : -1;
      my $data = $at >= 0 ? eval { decode_json(substr($prompt, $at + length($mark))) } : undef;
      unless (defined $f{tag} && $f{tag} eq "page" && ref($data) eq "HASH"
          && defined($data->{schema}) && !ref($data->{schema})
          && $data->{schema} eq "fm-board-page.v1"
          && defined($data->{page}) && !ref($data->{page})
          && $data->{page} =~ /\A[a-z0-9][a-z0-9-]{0,63}\z/) {
        $other++;
        next;
      }
      my $tag = $data->{tag};
      $tag = "prompt" unless defined $tag && !ref($tag) && length $tag;
      my $text = defined($data->{text}) && !ref($data->{text}) ? $data->{text} : "";
      my $words = substr($prompt, 0, $at);
      utf8::decode($words);
      if (defined $data->{data}) {
        my $ctx = $pretty->encode($data->{data});
        $ctx =~ s/\n\z//;
        utf8::decode($ctx);
        $words .= $mark . $ctx;
      }
      push @lines, $out->encode({ key => "$base-$n", page => $data->{page}, tag => $tag,
        text => $text, prompt => $words, data => $data->{data} });
    }
    my $incomplete = $malformed || @$items != $want;
    if ($mode eq "only") {
      my ($fform) = lavish_result($path, "feedback");
      exit 4 if $incomplete || $other || !@lines || !defined($fform) || $fform ne "none";
    }
    print "$_\n" for @lines;
    print "{\"app_ended\":true}\n" if $ended;
    if ($incomplete) {
      print STDERR "error: the result is not fully accounted for: declared $want, parsed ",
        scalar(@$items), ", malformed $malformed\n";
      exit 3;
    }
  ' "$mode" "$file" "$base" "$ended"
}
cmd_pages() { page_rows all "$@"; }

# The `priority` line described in the header.
cmd_priority() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  perl -MJSON::PP -e "$(lavish_result_parser)"'
    use strict; use warnings;
    my ($path) = @ARGV;
    my ($form, $want, $items, $malformed) = lavish_result($path, "prompts");
    defined $form or exit 1;
    if ($malformed || @$items != $want) {
      print STDERR "error: the result is not fully accounted for: declared $want, parsed ",
        scalar(@$items), ", malformed $malformed\n";
      exit 3;
    }
    my $last;
    for my $item (@$items) {
      my %f = %$item;
      next unless defined $f{tag} && $f{tag} eq "priority";
      next unless defined $f{prompt} && $f{prompt} =~ /Context data:\s*(\{.*\})\s*\z/s;
      my $data = eval { decode_json($1) };
      next unless ref($data) eq "HASH" && defined($data->{schema}) && !ref($data->{schema})
        && $data->{schema} eq "fm-bearings-priority.v1"
        && ref($data->{keys}) eq "ARRAY" && !grep { !defined || ref } @{$data->{keys}};
      next if exists $data->{order} && !(ref($data->{order}) eq "ARRAY"
        && !grep { !defined || ref } @{$data->{order}});
      $last = $data;
    }
    print JSON::PP->new->utf8->canonical->encode($last), "\n" if defined $last;
  ' "$file"
}
cmd_reconciles() { cmd_choice_rows reconciles "$@"; }

# Present one already-captured result for a handler. Body lines are prefixed
# so a captain-supplied string cannot forge a section label. A freeform message
# is printed before the count line and before any annotation, because that is
# the field a truncated grep of the raw capture historically dropped.
# A non-choice annotation that carries a freeform `prompt` prints that comment
# as its own field; a selector must not hide the typed words, even when the
# comment matches the captured element text. Choice rows keep Context data
# out of that field; a board answer row instead prints its question, its
# selection, and its typed note, marked `choice_comment_only: yes` when the
# note is a comment on an option card that `answers` does not treat as an
# answer. A pure annotation has no prompt.
cmd_read() {
  local file=${1-} lifecycle session_ended
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  lifecycle=$(cmd_classify "$file")
  session_ended=$(session_field "$file" session_ended)
  perl -MJSON::PP -e "$(lavish_result_parser)"'
    use strict; use warnings;
    my ($path, $lifecycle, $session_ended) = @ARGV;
    my ($form, $want, $items, $malformed) = lavish_result($path, "prompts|feedback");
    defined $form or exit 1;
    my @parsed = @$items;
    my $presented = scalar @parsed;
    my $complete = ($presented == $want && !$malformed) ? "yes" : "no";
    my @messages;
    my @annotations;
    for my $f (@parsed) {
      my $tag = defined $f->{tag} ? $f->{tag} : "";
      if ($tag eq "message") {
        push @messages, $f;
      } else {
        push @annotations, $f;
      }
    }
    sub emit_body {
      my ($text) = @_;
      $text = "" unless defined $text;
      $text =~ s/\r\n/\n/g;
      $text =~ s/\r/\n/g;
      my @lines = split /\n/, $text, -1;
      pop @lines if @lines && $lines[-1] eq "";
      return if !@lines || (@lines == 1 && $lines[0] eq "");
      print "| $_\n" for @lines;
    }
    my $ended = $session_ended =~ /^(?:true|True|TRUE)$/;
    if (@messages) {
      my $message_label = $ended ? "SESSION-ENDING MESSAGE" : "CAPTAIN MESSAGE";
      print "$message_label\n";
      for my $i (0 .. $#messages) {
        print "$message_label PART ", ($i + 1), " of ", scalar(@messages), "\n" if @messages > 1;
        my $body = defined $messages[$i]{prompt} && length $messages[$i]{prompt}
          ? $messages[$i]{prompt}
          : (defined $messages[$i]{text} ? $messages[$i]{text} : "");
        emit_body($body);
      }
      print "END $message_label\n";
    } else {
      print "SESSION-ENDING MESSAGE: (none)\n";
    }
    print "\n";
    print "declared_items: $want\n";
    print "presented_items: $presented\n";
    print "malformed_items: $malformed\n";
    print "complete: $complete\n";
    print "lifecycle: $lifecycle\n";
    print "session_ended: ", (length $session_ended ? $session_ended : "(unset)"), "\n";
    print "annotation_count: ", scalar(@annotations), "\n";
    my $message_count_key = $ended ? "session_ending_message_count" : "captain_message_count";
    print "$message_count_key: ", scalar(@messages), "\n";
    print "\n";
    if (@annotations) {
      print "ANNOTATIONS\n";
      my $n = 0;
      for my $f (@annotations) {
        $n++;
        my $uid = defined $f->{uid} ? $f->{uid} : "";
        my $selector = defined $f->{selector} ? $f->{selector} : "";
        my $tag = defined $f->{tag} ? $f->{tag} : "";
        print "ANNOTATION $n of ", scalar(@annotations), "\n";
        print "element_uid: $uid\n";
        print "element_selector: $selector\n";
        print "tag: $tag\n";
        print "text:\n";
        my $elem = defined $f->{text} ? $f->{text} : "";
        my $comment = defined $f->{prompt} ? $f->{prompt} : "";
        my $body = length $elem ? $elem : $comment;
        emit_body($body);
        if ($tag ne "choice" && length $comment) {
          print "prompt:\n";
          emit_body($comment);
        }
        if ($tag eq "choice" && $comment =~ /Context data:\s*(\{.*\})/s) {
          my $data = eval { decode_json($1) };
          if (ref($data) eq "HASH" && defined($data->{schema}) && !ref($data->{schema})
              && $data->{schema} eq "fm-bearings-answer.v1"
              && defined($data->{selection}) && !ref($data->{selection})
              && defined($data->{note}) && !ref($data->{note})) {
            my $is_bool = sub { JSON::PP::is_bool($_[0]) && $_[0] };
            my $question = defined($data->{question}) && !ref($data->{question}) ? $data->{question} : "";
            $question =~ s/[\x00-\x1f\x7f]/ /g;
            my $selection = $data->{selection};
            $selection =~ s/[\x00-\x1f\x7f]/ /g;
            print "choice_question: $question\n";
            print "choice_selection: ", (length $selection ? $selection : "(none)"), "\n";
            if (!length($data->{selection}) && length($data->{note})
                && $is_bool->($data->{has_options}) && !$is_bool->($data->{free_text})) {
              print "choice_comment_only: yes\n";
            }
            if (length $data->{note}) {
              print "choice_note:\n";
              emit_body($data->{note});
            }
          }
        }
      }
      print "END ANNOTATIONS\n";
    } else {
      print "ANNOTATIONS: (none)\n";
    }
    print "END LAVISH RESULT ($presented of $want)\n";
  ' "$file" "$lifecycle" "$session_ended"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  finished)  shift; cmd_finished "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  deliver-reply) shift; cmd_deliver_reply "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  silent)    shift; cmd_silent "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  reconciles) shift; cmd_reconciles "$@" ;;
  pages)     shift; cmd_pages "$@" ;;
  priority)  shift; cmd_priority "$@" ;;
  read)      shift; cmd_read "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
