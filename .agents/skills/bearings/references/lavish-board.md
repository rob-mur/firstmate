# bearings: Lavish board mode, board wakes, and the merge-click ruling

## Lavish board mode

`/bearings lavish` adds one deliverable beside the unchanged chat digest: the interactive fleet board, a myfirstmate-styled Lavish page where the captain answers Captain's Call items directly instead of replying in chat.
`bin/fm-bearings-board.sh` owns every board mechanic - the stable board path, fm-bearings-board.v1 payload validation, template injection, live Lavish session verification and ended-session reopening, the any-origin answer binding, and listener registration - so the per-invocation work is generating the payload and running its `build`.

`bin/fm-bearings-board-payload.sh` owns the payload's shape, so the board is identical every session.
It maps the fleet snapshot to the fm-bearings-board.v1 payload deterministically: one decision card per captain-held task id (keyed by the task id, titled and described from the held task's own record), every non-done in-flight row as Underway with its projected `name`, landed rows, and the gates and warnings as Charted Next with `kind`, `dispatchable`, `filed`, `repo` and the omitted-row counts derived from structured fields.
Run `bin/fm-bearings-board-payload.sh > <payload.json>` (add `--include-prs` when the digest used live PRs), then `bin/fm-bearings-board.sh build <payload.json>`.
Add nothing for a plain board.
Decision cards arrive as freeform answer boxes; the optional `--copy <overlay.json>` carries only the judgment the snapshot cannot supply, and the generator's header owns its schema:

- A card's authored options, `recommend_value`, `decide` and `about` copy, and a `close: "release"` when the card's task is a captain-gated WORK item (the answer should free it to proceed rather than complete it); question-shaped items omit it.
- A merge or credential card under `captains_call_extra`: a merge card's key is `merge.<task-id>`, carries `risk`, and puts the one PR it waits on in `pr_url`.
- Captain's Call shows everything waiting on the captain, including items firstmate never held. Add each such item under `captains_call_extra` with a slug `key` of its own (it need not be a task id); `build` keeps a card whose key is not an open captain-held task.
- Any card may carry `links`, one or more `{url, label}` pointers to the page the captain acts on, such as a Lavish page, a merge request, or a credential console. A link is https, or http only on the tailnet Lavish origin the board contract names; the validator refuses every other http link.
- A hold whose subject has already landed is dropped by `build` when its task or PR appears among the payload's landed rows; for a published version put the artifact and numeric three-part version in the card's structured `subject`, and verify any subject without one of these identities against current reality before carding it.
- Never author a `reconcile` option: `build` gives every decision card that standard choice and the generator refuses it.
- The dispatch picker's key `dispatch.charted` comes from the template; a payload never authors it.

Run `build` once per board.
Its serve-first sequence publishes the board, establishes and verifies its Lavish session with `lavish-axi`, reopens an ended session when necessary, and only then binds the answer source and proves a live polling listener; use the session URL it prints in the chat digest.
Never bind or arm the board before its session is listed open.
Never run `lavish-axi poll` for the board yourself: the armed source's supervised runner owns the blocking poll, and both the build and the watcher's ordinary reconcile repair a missing listener, so no conversational turn ever blocks on the board.

### Handling a board wake

A board answer arrives as an ordinary `procevent lavish <source-id> <sequence>` check wake. Identify it by comparing the wake source id with `bin/fm-procevent-lavish.sh source-id "$(bin/fm-bearings-board.sh path)"`, regardless of which answer kinds the result contains; then load `process-event-sources` and follow its contract for the result read, adapter classification, and the handled acknowledgement.
Decision answers need no routing from you: the runner feeds the board's binding into `bin/fm-captain-hold.sh`'s one keyed-answer intake, which closes or releases each answered captain-held task at answer time; reconcile any `skipped:` key yourself with a direct `answer`, and when the captain's answer is "later", record it as a deferral with `bin/fm-captain-hold.sh hold <id> --reason "<reason>" --until <date>` instead of a closure.
A current structured Reconcile selection closes nothing: the versioned board context carries its exact selected option separately from any typed note, and the adapter routes that selection only into a durable re-check request while preserving the note as provenance.
The rollout-compatible old context still feeds ordinary non-reconcile answers, but its bare or separator-annotated reconcile values and every structurally uncertain choice feed neither intake and remain announced for deliberate handling.
Verify the call's latest state, then retire the request through `bin/fm-captain-hold.sh reconcile close <id> --evidence-file <path>` when it turns out to be moot, or `reconcile note <id> --note-file <path>` when it is genuinely still open.
Both outcomes refuse without that pending board-created request, and `bin/fm-captain-hold.sh reconcile list` names every request still outstanding.
A remote-secondmate card whose task is absent from the main backlog remains on the board unchanged, but its reconcile request is refused in the main home until the separately tracked owner-aware routing follow-up can query and mutate the authoritative secondmate home; handle the announced capture without claiming that a request or reconciliation succeeded.
`captain-hold-lifecycle` owns why a reconcile may never be recorded as the captain's answer.
Route the non-decision keys yourself:

- `merge.<task-id>` is the captain's explicit merge order; follow the merge ruling below.
- `dispatch.charted` carries comma-separated task ids the captain picked to start now; verify each id against the current backlog - still queued, blocker and time gate actually clear - then dispatch through the normal lifecycle, and report any id that no longer qualifies instead of forcing it.

After handling, rebuild the board from a fresh snapshot so acted-on items leave Captain's Call, and echo every action taken in chat so the board and chat never diverge silently.

### The merge-click ruling (captain-decided)

A board "Merge now" answer IS the captain's explicit merge word for that one exact PR; ask no second confirmation.
The safeguards are mandatory, not optional: resolve the PR from the task's own `state/<task-id>.meta` `pr=` record, never from board bytes; re-verify at wake time that the PR is still open and CI-green; refuse and report a red or changed PR rather than merging it; record the exact `merge` answer through `bin/fm-captain-hold.sh answer <task-id> --decision-file <file> --release` before invoking the merge; proceed only when that release succeeds; merge only through `bin/fm-pr-merge.sh`; and echo every merge in chat with the full PR URL.
Only the exact answer value `merge` authorizes a merge; an answer carrying a freeform note is the captain's instruction text to read and act on with judgment, never an auto-merge.
