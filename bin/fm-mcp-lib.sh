#!/usr/bin/env bash
# fm-mcp-lib.sh - the single owner of resolving MCP server names against a
# home's config/mcp-servers.json, and of the per-secondmate MCP pin file.
#
# docs/configuration.md "Per-spawn MCP servers" owns the operator-facing
# contract. Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# Two sources name servers, and both resolve through fm_mcp_resolve:
# - a ship or scout's repeatable `fm-spawn.sh --mcp <name>`, recorded as mcp=
#   in its task record and replayed by every relaunch;
# - a local secondmate's durable pin, config/secondmate-accounts/<id>/mcp in
#   the launching (primary) home, re-read by every spawn, relaunch, and
#   automatic recovery of that mate, never replayed from a previous record.
# The pin is opt-in: an absent file is no servers and the launch is unchanged.
# A present file lists one server name per line (blank lines ignored); a file
# naming no server, a malformed name, or an unreadable file refuses rather than
# launching the mate without the servers it was promised.

# fm_mcp_name_valid <name>
fm_mcp_name_valid() {
  case "${1:-}" in
  '' | *[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  return 0
}

# fm_secondmate_mcp_pin_file <config-dir> <secondmate-id>
fm_secondmate_mcp_pin_file() {
  printf '%s/secondmate-accounts/%s/mcp\n' "$1" "$2"
}

# fm_secondmate_mcp_names <config-dir> <secondmate-id>
# Prints the pinned server names, one per line, or nothing when no pin file
# exists or the id is empty (a ship or scout). On refusal prints one error
# naming the file and returns 1.
fm_secondmate_mcp_names() {
  local config=$1 mate=${2:-} cfg line
  local names=()
  [ -n "$mate" ] || return 0
  cfg=$(fm_secondmate_mcp_pin_file "$config" "$mate")
  [ -e "$cfg" ] || [ -L "$cfg" ] || return 0
  if [ ! -f "$cfg" ] || [ ! -r "$cfg" ]; then
    echo "error: $cfg must be a readable regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if ! fm_mcp_name_valid "$line"; then
      echo "error: $cfg must list one MCP server name per line, each of letters, digits, '.', '_' or '-'; got '$line'" >&2
      return 1
    fi
    names+=("$line")
  done <"$cfg"
  if [ "${#names[@]}" -eq 0 ]; then
    echo "error: $cfg names no MCP server; list at least one config/mcp-servers.json name, or remove the file" >&2
    return 1
  fi
  printf '%s\n' "${names[@]}"
}

# fm_mcp_resolve <config-dir> <source-label> <name>...
# Prints the compact {"mcpServers":{...}} JSON holding only the named entries
# of <config-dir>/mcp-servers.json. <source-label> names where the request came
# from in refusals (`--mcp` or the pin file). On refusal prints one error and
# returns 1.
fm_mcp_resolve() {
  local config=$1 label=$2 file names_json out
  shift 2
  file="$config/mcp-servers.json"
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $label $* needs $file, a readable JSON file of {\"mcpServers\":{\"<name>\":{...}}}" >&2
    return 1
  fi
  if ! jq -e '(.mcpServers | type) == "object"' "$file" >/dev/null 2>&1; then
    echo "error: $file must be a JSON object with an mcpServers object" >&2
    return 1
  fi
  names_json=$(printf '%s\n' "$@" | jq -R . | jq -cs 'unique')
  if ! out=$(jq -c --argjson names "$names_json" \
      'if ($names - (.mcpServers | keys)) == [] then {mcpServers: (.mcpServers | with_entries(select(.key as $k | $names | index($k))))} else error("missing") end' \
      "$file" 2>/dev/null); then
    echo "error: $label names a server $file does not define (asked: $*; defined: $(jq -r '.mcpServers | keys | join(", ")' "$file"))" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# fm_mcp_launch_check <harness> <raw-launch-note> <backend> <source-label>
# The launch-form limits every MCP request shares: only a claude launch built
# by firstmate can carry --mcp-config (a non-empty <raw-launch-note> means a
# raw launch command), and backend=t3code starts the agent itself.
fm_mcp_launch_check() {
  local harness=$1 raw=$2 backend=$3 label=$4
  if [ "$harness" != claude ] || [ -n "$raw" ]; then
    echo "error: $label is supported only for a claude harness launch built by firstmate (harness=$harness${raw:+, raw launch command}); it cannot be applied here" >&2
    return 1
  fi
  if [ "$backend" = t3code ]; then
    echo "error: backend=t3code starts the agent itself and cannot pass --mcp-config; choose another backend or drop $label" >&2
    return 1
  fi
}
