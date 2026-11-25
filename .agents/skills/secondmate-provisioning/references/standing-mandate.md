# Standing mandate: resume and wind-down

Read this when a `check: secondmate <id> stopped with standing work` notification arrives, when the board shows a `stopped-<id>` row, or when a standing-work mate needs to stop for a while.
[`docs/configuration.md`](../../../../docs/configuration.md#stopped-standing-work) owns the stopped rule, its thresholds, and the rest record; this file owns only the steer text.

## Resume a stopped mate

A `drive` mate is stopped when its own summary shows no work in flight, no captain question, no dated wait, and no active rest.
First read its last parent-channel line and its board row, and resolve anything it is waiting on from main.
Then send this steer through `bin/fm-send.sh`, with the mate's charter scope filled in:

```text
Your charter is a standing mandate, and your home shows nothing under way: no workers, no captain question, no dated wait.
Pick the next most valuable item in your scope (<scope>) and start it now.
If nothing in your scope can move, do exactly one of these and say which in your parent channel:
(a) hold a captain question for the specific decision that blocks you;
(b) declare a dated rest with bin/fm-secondmate-rest.sh --until <YYYY-MM-DDTHH:MMZ> --reason "<why>";
(c) say that your charter is complete and ask main to retire or re-scope you.
```

Send it once per stop episode.
If the same mate stops again without doing (a), (b), or (c), raise its charter with the captain rather than repeating the steer.

## Wind a mate down

When the captain or main wants a standing-work mate to pause, send this steer rather than editing its posture:

```text
Wind down: finish or park the item in hand, start nothing new, then declare a dated rest with
bin/fm-secondmate-rest.sh --until <YYYY-MM-DDTHH:MMZ> --reason "<why>".
A rest lasts at most 24 hours; declare a new one if the pause must continue.
```

A mate's own watcher also wakes it for standing work on a back-off, and its turn-end guard asks for (a), (b), or (c) before it stops ([`docs/configuration.md`](../../../../docs/configuration.md#standing-work-wakes-in-the-mate-home)); the steers above are for when that self-wake has not moved it.

A pause with no end date is a posture change: edit the registry route to `posture: routed` and run `bin/fm-config-push.sh`.
