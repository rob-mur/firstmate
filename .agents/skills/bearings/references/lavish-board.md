# bearings: Lavish board mode, board wakes, and the merge-click ruling

## Lavish board mode

`/bearings lavish` adds one deliverable beside the unchanged chat digest: the interactive fleet board, a myfirstmate-styled Lavish page where the captain answers Captain's Call items directly instead of replying in chat.
`bin/fm-bearings-board.sh` owns every board mechanic - the stable board path, fm-bearings-board.v1 payload validation, the board data file beside the page, live Lavish session verification and ended-session reopening, the any-origin answer binding, and listener registration - so the per-invocation work is generating the payload and running its `build`.

`bin/fm-bearings-board-payload.sh` owns the payload's shape, so the board is identical every session.
It maps the fleet snapshot to the fm-bearings-board.v1 payload deterministically: one decision card per captain-held task id (keyed by the task id, titled and described from the held task's own record), every non-done in-flight row as Underway with its projected `name`, landed rows, and the gates and warnings as Charted Next with `kind`, `dispatchable`, `filed`, `repo` and the omitted-row counts derived from structured fields.
Run `bin/fm-bearings-board-payload.sh > <payload.json>` (add `--include-prs` when the digest used live PRs), then `bin/fm-bearings-board.sh build <payload.json>`.
Add nothing for a plain board.
The board opens on step 1, one priority list of every Captain's Call decision, which the captain reorders (drag or arrows), most important first.
Repeated down presses on any row walk the list below it, leaving the rows above alone: each brings up the next decision into that row while the ones already passed over drop just below it as a block in their original order, and a press after the last decision restores the original order.
Clicking a decision row opens its card; "Start answering" deals the cards in the list's order.
A task under way is not a decision, so the board never lists it unless it is blocked or needs a decision, in which case it is a question card; a sent priority carries the tasks under way after the decisions in their recorded order, so their stored rank survives.
"Reorder" returns from the cards to the list at any time, including after answers are queued or sent.
The "bearings" header returns to the board's home view in place from anywhere on the board - a shown page, full screen, or the cards - and to the priority list when there is one.
The list's order survives a refresh and rebuild like a queued answer, and a row added since asks to be placed again.
`bin/fm-bearings-board-payload.sh` already sorts cards and tasks by the stored priority, so a rebuilt board starts in the captain's order.
Every question card carries real default answer choices derived from its question, and the standard reconcile choice stays secondary.
A yes/no question gets yes and no, numbered sub-questions become one choice each, a plain two-way "A or B" question gets both sides, a request that the captain do something in person (dismiss, merge, run, re-run, log in) gets done and not done (say why), and any other request gets approve and decline.
Authored overlay options still replace the derived ones.
`bin/fm-bearings-question-lib.sh` owns that derivation and the question-versus-wait rule for the payload and the snapshot.
URLs in a question lift into the card's links (https or a Lavish page, at most eight), each labelled by what it points at (`PR 837`, `MR 872`, `Understand page`, `Review page`), and the question text shows that label in place of the URL; everything else stays escaped text.

Every question the wake drain lists as an open decision reaches the board without `--all-decisions`.
That covers a needs-decision or blocked status on a task under way and on a secondmate's task, and a captain hold whose reason asks a question even when the snapshot buckets it as blocked or aged.
Each becomes a card, or a waiting row when it is a wait; a resolved key never shows.
Only open calls stay cards: a hold deferred to a later date, from any home, is charted next with its date; a card whose PR or MR merged or closed, read live from the forge and kept when the read fails, drops; a round a newer round of the same work superseded drops; and a status line that only announces a page or PR is live folds its link into that work's card, or drops when there is none.
The generator's header owns those rules.
Status-sourced cards carry the key `status.[<mate>.]<task>.<key>`, and the snapshot row keeps `task`, `decision_key` and `mate`.
The board's keyed-answer intake announces such a key as skipped, because no main-backlog hold owns it.
Route the answer from the skipped row: run `FM_HOME=<home of the mate, or this home for a main task> bin/fm-send.sh <task> --resolve-key <decision_key> '<answer>'`, so the answer closes the question on the worker's side as well.
A secondmate question the parent's own status log shows is read from the parent task, so it reaches the board even when the mate's home summary is invalid or empty; it is skipped only when the home is valid with no active work, or already lists the same key.
Its row has `mate: null` and `task` set to the mate id, so run that send under this home with the mate id as the task.
A finished task whose last event names a live review page (a `/session/<id>` link) becomes a `review.<task>` card with the verb `review-ready` and the choices "Reviewed, carry on" and "Not yet, keep it on the board".
The tailnet review-page origin lifts into card links alongside https URLs.
Card links each sit on their own line and wrap instead of clipping, and the card title and about text are base size and never truncated.

Decision cards otherwise arrive with those choices and a freeform box; the optional `--copy <overlay.json>` carries only the judgment the snapshot cannot supply, and the generator's header owns its schema:

- A card's authored options, `recommend_value`, `decide` and `about` copy, and a `close: "release"` when the card's task is a captain-gated WORK item (the answer should free it to proceed rather than complete it); question-shaped items omit it.
- A merge or credential card under `captains_call_extra`: a merge card's key is `merge.<task-id>`, carries `risk`, and puts the one PR it waits on in `pr_url`.
- Captain's Call shows everything waiting on the captain, including items firstmate never held. Add each such item under `captains_call_extra` with a slug `key` of its own (it need not be a task id); `build` keeps a card whose key is not an open captain-held task.
- A hold whose reason is a wait or park on a condition or date, not a question, goes to the payload's `waiting` group, shown below the decisions as a row with nothing to answer.
- A released hold, one marked `held: no` or dated today or earlier, is dropped from the payload and never shown as a card or a waiting row.
- The generator tells a wait from a question this way: a reason whose first sentence records that the captain parked, deferred, or paused it is a wait, otherwise a reason with a question mark is a question, a hold with an until date or a reason that parks, pauses, resumes, holds until, waits for or on, or says until or re-runs is a wait, and anything else is a question.
- Each decision card leads with its hold reason as `question` and shows the task title as the subject line.
- A status question is titled from its decision, never the bare home name, and a status question about a captain-held task in the same home merges into that one card with every choice kept.
- Any card may carry `links`, one or more `{url, label}` or `{page, label}` pointers to the page the captain acts on, such as a Lavish page, a board page id, a merge request, or a credential console. A link is https, or http only on the tailnet Lavish origin the board contract names; the validator refuses every other http link.
- A hold whose subject has already landed is dropped by `build` when its task or PR appears among the payload's landed rows; for a published version put the artifact and numeric three-part version in the card's structured `subject`, and verify any subject without one of these identities against current reality before carding it.
- Never author a `reconcile` option: `build` gives every decision card that standard choice and the generator refuses it.
- The dispatch picker's key `dispatch.charted` comes from the template; a payload never authors it.

Run `build` once per board.
Its serve-first sequence publishes the board, establishes and verifies its Lavish session with `lavish-axi`, reopens an ended session when necessary, and only then binds the answer source and proves a live polling listener; use the session URL it prints in the chat digest.
Never bind or arm the board before its session is listed open.
When the captain asks for the board link, run `bin/fm-bearings-board.sh url` and send the one link it prints; that link is stable, and the command reopens and re-arms a board the captain closed without rebuilding it or opening a browser.
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
A `priority` annotation (context schema `fm-bearings-priority.v1`, `keys` highest first, tasks by their id and decisions by their card key) is the captain's durable task priority and needs no answer routing.
Record it with `bin/fm-board-priority.sh set --from-ctx <file>` (the script header owns the store, `data/board-priority.txt`), and echo the recorded order in chat.
The session digest and wake drain print the ranking as CAPTAIN PRIORITY; read it with `bin/fm-board-priority.sh show` whenever you choose which queued task to dispatch, which wake to handle, or which decision to raise or answer next: a higher-ranked task goes first unless a dependency, blocker, time gate or capacity limit makes it unsafe, and say so when you skip one.
The board refreshes itself on every fleet state change - each queued wake, captain hold, answer or reconcile, task cleanup, and main wake drain kicks `bin/fm-board-refresh.sh` in the background whenever a board exists - and a burst becomes one rebuild of the same Lavish session, only while the session is not ended, its inputs moved, and the generated payload changed, and never reopening a session the captain ended (the script header owns its triggers, input check, debounce, lock and failure handling), so the stored priority and the board's own order store carry the captain's ranking across each rebuild.
A rebuild never reloads the captain's open page: the page patches only the cards that changed and leaves alone a card the captain is answering.
Rebuild by hand with the payload generator and `build` when you need the board current at once.

### Pages shown in place

The board is the captain's one Lavish tab.
Any other page - an understand page, an MR review page, or a page a skill from another repository builds - registers through `bin/fm-board-page.sh`, the one entry point whose header owns the page contract and paths, and shows inside the board instead of opening a tab.
A skill from another repository finds it as the `fm-board-page` command that `bin/fm-board-page.sh install` writes, and runs its page standalone until that command exists.
Each live page gets a tab in the board header; the captain opens it in place and returns with "Back to board" or the bearings header.
"Full screen" fills the window below the board header with the open page without reloading it, and the same button or Esc leaves it.
A card link to a Lavish page opens the matching registered page in place too, and a card whose page is not registered says it is not in the board yet; the board never links out to a Lavish session, and the `build` header owns how a link finds its page.
A decision answered on a page the board does not have shows its question, says its choices are on that page, and takes a free-text answer, so it is still answered from the board; the `build` header owns that fallback.
"End this page" ends only that page; ending the board's Lavish session ends every page.
One refresh policy covers the whole app: no frame ever reloads, and the board and each page poll their own data file and patch in place.
A page's actions ride the board's Lavish session as rows tagged `page`, and the process-event runner routes them to that page's agent before publishing the result, so a board result holding only routed page actions raises no wake.
A board wake that still lists `page` rows means their page was not registered or the route failed: check `bin/fm-board-page.sh list`, and never answer a page's action as a board decision.
Each answer carries the captain's priority, as `[priority N of M]` in its label and as `order` and `order_total` in its context data.
When a result holds several answers, handle them lowest `order` first, and echo that sequence in chat.
Route the non-decision keys yourself:

- `merge.<task-id>` is the captain's explicit merge order; follow the merge ruling below.
- `dispatch.charted` carries comma-separated task ids the captain picked to start now; verify each id against the current backlog - still queued, blocker and time gate actually clear - then dispatch through the normal lifecycle, and report any id that no longer qualifies instead of forcing it.

After handling, rebuild the board from a fresh snapshot so acted-on items leave Captain's Call, and echo every action taken in chat so the board and chat never diverge silently.

### The merge-click ruling (captain-decided)

A board "Merge now" answer IS the captain's explicit merge word for that one exact PR; ask no second confirmation.
The safeguards are mandatory, not optional: resolve the PR from the task's own `state/<task-id>.meta` `pr=` record, never from board bytes; re-verify at wake time that the PR is still open and CI-green; refuse and report a red or changed PR rather than merging it; record the exact `merge` answer through `bin/fm-captain-hold.sh answer <task-id> --decision-file <file> --release` before invoking the merge; proceed only when that release succeeds; merge only through `bin/fm-pr-merge.sh`; and echo every merge in chat with the full PR URL.
Only the exact answer value `merge` authorizes a merge; an answer carrying a freeform note is the captain's instruction text to read and act on with judgment, never an auto-merge.
