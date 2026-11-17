"""PROTOTYPE - headless text captures of the TUI board (no window opens).

Run: TUI_BOARD_SCRIPT=prototype/tui-board/shots.py prototype/tui-board/run <outdir>
Works on a COPY of the board data inside <outdir>/data (so it can simulate a
live change); picks and chat go to <outdir>/outbox.jsonl, not the real outbox.
"""
import asyncio
import io
import json
import os
import shutil
import sys
from pathlib import Path

SRC = Path("/home/rob/repos/firstmate/.lavish")
out = Path(sys.argv[1]).resolve()
(out / "data").mkdir(parents=True, exist_ok=True)
for name in ("bearings-board.data.js", "bearings-board.stamp.js"):
    shutil.copyfile(SRC / name, out / "data" / name)  # read the original, write only the copy
os.environ["TUI_BOARD_DATA"] = str(out / "data" / "bearings-board.data.js")
os.environ["TUI_BOARD_OUTBOX"] = str(out / "outbox.jsonl")
sys.path.insert(0, str(Path(__file__).resolve().parent))

from rich.console import Console  # noqa: E402
import app as board  # noqa: E402


def text_of(a) -> str:
    w, h = a.size
    con = Console(width=w, height=h, file=io.StringIO(), record=True, color_system=None, legacy_windows=False)
    con.print(a.screen._compositor.render_update(full=True))
    return "\n".join(l.rstrip() for l in con.export_text().splitlines()) + "\n"


async def main() -> None:
    a = board.TuiBoard("A")
    async with a.run_test(size=(120, 40)) as p:
        await p.pause(0.3)
        cards = a.payload["captains_call"]
        k1 = cards[0]["key"]
        opt = cards[0]["options"][0]["value"]

        async def shot(name: str) -> None:
            await p.pause(0.4)
            (out / f"{name}.txt").write_text(text_of(a))
            a.save_screenshot(filename=f"{name}.svg", path=str(out))

        def goto(tree_id: str, node_id: str) -> None:
            t = a.query_one(f"#{tree_id}")
            node = next(x for x in a.walk(t.root) if x.data and x.data.id == node_id)
            t.focus()
            t.move_cursor(node)

        await shot("1-collapsed")

        await p.press("down", "enter")           # level 1: recommendation + options
        await p.press("enter")                   # level 2: detail & links (parts still one line each)
        await p.pause(0.2)
        goto("left", f"cc/{k1}/more/why")
        await p.press("enter")                   # open the "why" sentences
        await shot("2-card-open")

        await p.pause(0.2)
        goto("left", f"cc/{k1}/more/why/1")
        await p.press("t")                       # tag one sentence of the detail
        goto("left", f"cc/{k1}/opt/{opt}")
        await p.press("t")                       # tag an option
        await p.press("c")
        await p.press(*list("is this the same mount the immich switch would use?"))
        await shot("3-tag-and-chat")

        await p.press("enter")                   # send -> local outbox only
        goto("left", f"cc/{k1}/opt/{opt}")
        await p.press("enter")                   # pick an option -> local outbox only
        # simulate the board keeper rebuilding: an under-way task changes state
        data = out / "data" / "bearings-board.data.js"
        payload = board.load_payload(data)
        payload["underway"][0]["state"] = "working"
        payload["underway"][0]["doing"] = "Rebasing on main after the review round. Tests pass locally."
        data.write_text("window.FM_BEARINGS_BOARD_DATA = " + json.dumps(payload) + ";\n")
        (out / "data" / "bearings-board.stamp.js").write_text('window.FM_BEARINGS_BOARD_STAMP = "prototype-sim";\n')
        await p.pause(board.POLL_SECONDS + 0.8)
        goto("left", "cc")
        await p.press("left")                    # fold Captain's call
        goto("left", "uw")
        await p.press("enter")                   # open Under way: the changed row carries a dot
        await shot("4-picked-and-live-change")

        await p.press("v")                       # split layout
        await p.pause(0.6)
        goto("left", f"cc/{cards[1]['key']}")
        await p.press("enter")                   # focus the detail pane
        await p.press("down", "down", "down")
        await shot("5-split")


asyncio.run(main())
