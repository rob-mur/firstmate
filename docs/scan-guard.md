# Scan-guard PreToolUse seatbelt

This document is the authoritative human-readable contract for the scan-guard PreToolUse seatbelt.
`bin/fm-scan-command-policy.mjs` is the single decision owner.
`bin/fm-scan-pretool-check.sh` is the stable harness transport, primary-checkout scope, and output renderer.
It is a sibling of the cd-guard (`docs/cd-guard.md`) and reuses the same shell classifier and transport shape.

## Purpose and boundary

A recursive `grep` or a `find` rooted at `/`, `~`, `$HOME` or a user's home directory walks every project clone, worktree, `node_modules` and cache on the machine.
In the recorded primary session five such scans ran into the 120 s tool timeout and returned nothing, while each answer sat in a durable record firstmate already keeps.
The seatbelt denies exactly that command shape before it runs and names the record to read instead.

The deny text points at `data/projects.md` (which clones exist and where), `data/backlog.md` and `bin/fm-crew-state.sh` (work and its current state), `state/<id>.status` and `data/<id>/report.md` (a task's events and findings), and `data/learnings.md` and `data/captain.md` (notes and preferences).
It also says to scope the search to one directory, such as `grep -r <pattern> projects/<clone>`.

This guard is not a general sandbox.
It classifies shell command positions only and never evaluates, expands, sources or runs any byte of the submitted command.
Its threat model is agent mistakes, so `bash -c` payloads, `xargs` indirection and deliberate obfuscation are out of scope and allowed.

## Block vs allow

The guard **blocks**, in any command position including pipeline stages and behind `timeout`, `env`, `sudo`, `nohup`, `exec` and `command`:

- `grep`, `egrep`, `fgrep` with a recursive flag (`-r`, `-R`, a short cluster containing either, `--recursive`, `--dereference-recursive`, `-d recurse`), and `rgrep`, when a path operand is a broad root.
- `rg`, `ag` and `ack`, which recurse by default, when a path operand is a broad root.
- `find` whose starting points include a broad root, unless `-maxdepth` is 2 or less.

A broad root is `/`, `~`, `$HOME`, `${HOME}`, the invoking user's home directory, `/home`, `/Users`, or `/home/<name>` and `/Users/<name>`, after collapsing repeated slashes and a trailing `/`, `/.` or `/*`.
The first non-option operand of a search is its pattern, so `grep -r / projects/firstmate` is allowed; `-e` and `-f` make every operand a path.

The guard **allows** everything else, including a search scoped inside a repo or under the home (`grep -rn foo ~/repos/firstmate`, `find . -name x`), a non-recursive `grep` of any path, `git grep`, and a shallow `find ~ -maxdepth 1`.
An unparseable command is allowed.

## Scope: the pane, not the workers

The guard fires only in the real primary firstmate checkout, where git-dir equals git-common-dir, with the same scope rule and fail-open behavior as the cd-guard.
A crewmate or scout task worktree is a linked worktree, so the guard is inert there.
It therefore covers the captain-facing pane and does not cover workers.
That is deliberate: the deny text names firstmate's own durable records, which are the wrong advice for a worker that legitimately searches a repository.

`FM_ALLOW_BROAD_SCAN=1` in the pane's environment turns the guard off.
Any failure to confirm the primary, missing `jq` for stdin transport, missing Node, a missing policy file or malformed input allows the command.

## Registration

Claude is registered in `.claude/settings.json` as a second Bash PreToolUse hook next to the cd-guard.
The transport already renders the Cursor (`--cursor`), Antigravity (`--agy`) and Grok or OpenCode or Pi (`--command`) shapes, so another harness adds the guard with a registration that mirrors its cd-guard one.

## Verification

`tests/fm-scan-pretool-check.test.sh` proves the decision matrix, the deny text, the harness output shapes, the inert scope outside the primary, the override, the fail-open cases and the Claude registration.
No harness is spawned by that suite.
