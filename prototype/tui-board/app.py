"""PROTOTYPE - throwaway terminal view of the bearings board.

Question it answers: what would a keyboard-only, HTML-free bearings board look
like, with progressive disclosure instead of walls of text, and a chat line
that can tag any element on screen?

Two layouts, switched with `v`:
  A  Outline - one tree; every card opens in place.
  B  Split   - one line per item on the left; the selected item opens on the right.

Reads the board's last built data file (read only) and re-reads it when its
stamp file changes. Picks, answers and chat messages go ONLY to a local outbox
file (prototype/outbox.jsonl); nothing reaches the board, backlog or a worker.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import Footer, Input, Static, Tree

HERE = Path(__file__).resolve().parent
DATA = Path(os.environ.get("TUI_BOARD_DATA", "/home/rob/repos/firstmate/.lavish/bearings-board.data.js"))
STAMP = Path(str(DATA).replace(".data.js", ".stamp.js"))
OUTBOX = Path(os.environ.get("TUI_BOARD_OUTBOX", str(HERE.parent / "outbox.jsonl")))
POLL_SECONDS = 2.0


# ---------------------------------------------------------------- data model

def load_payload(path: Path) -> dict:
    raw = path.read_text()
    raw = raw.split("=", 1)[1].strip().rstrip(";")
    return json.loads(raw)


def sentences(text: str) -> list[str]:
    text = re.sub(r"\s+", " ", text or "").strip()
    if not text:
        return []
    parts = re.split(r"(?<=[.?!:])\s+(?=[A-Z(#\"0-9])", text)
    return [p for p in parts if p]


def recommendation(card: dict) -> str | None:
    for src in (card.get("about"), (card.get("context") or {}).get("reason")):
        for s in sentences(src or ""):
            m = re.match(r"(?i)(recommend(?:ed|ation)?|recommend)\s*:?\s*(.*)", s)
            if m and m.group(2):
                return m.group(2)
    return None


@dataclass
class Node:
    id: str                 # stable path, survives live refresh
    label: Text
    kind: str               # section card option rec freeform more group line link
    ref: dict               # what a tag points at
    children: list["Node"] = field(default_factory=list)
    action: tuple | None = None  # ("pick", key, value, label) / ("answer", key) / ("link", url)


def T(*parts) -> Text:
    t = Text(no_wrap=True, overflow="ellipsis")
    for p in parts:
        if isinstance(p, tuple):
            t.append(p[0], style=p[1])
        else:
            t.append(p)
    return t


def lines_group(prefix: str, title: str, texts: list[str], ref: dict, gid: str) -> Node:
    """A collapsed group whose children are one sentence per line."""
    kids = []
    for i, s in enumerate(texts):
        kids.append(Node(f"{gid}/{i}", T(("· ", "dim"), s), "line", {**ref, "part": title, "line": i + 1, "text": s}))
    return Node(gid, T((prefix + " ", "cyan"), (title, "bold"), (f"  {len(texts)} line{'s' if len(texts) != 1 else ''}", "dim")), "group", {**ref, "part": title}, kids)


def detail_nodes(base: str, ref: dict, ctx: dict, links: list[dict], extra: list[tuple[str, str]] | None = None) -> list[Node]:
    out = []
    for k, v in extra or []:
        if v:
            out.append(Node(f"{base}/f/{k}", T((f"{k}: ", "dim"), str(v)), "line", {**ref, "part": k, "text": str(v)}))
    if ctx.get("reason"):
        out.append(lines_group("≡", "why", sentences(ctx["reason"]), ref, f"{base}/why"))
    for i, a in enumerate(ctx.get("answers") or []):
        title = f"earlier answer {(a.get('at') or '')[:16].replace('T', ' ')} ({a.get('mode') or ''})"
        out.append(lines_group("↩", title, sentences(a.get("text") or ""), ref, f"{base}/ans{i}"))
    for i, n in enumerate(ctx.get("notes") or []):
        ss = sentences(n)
        out.append(lines_group("✎", f"note {i + 1}", ss, ref, f"{base}/note{i}"))
    if ctx.get("report"):
        out.append(Node(f"{base}/report", T(("report: ", "dim"), ctx["report"]), "line", {**ref, "part": "report", "text": ctx["report"]}))
    for i, l in enumerate(links or []):
        url = l.get("url") or f"board page {l.get('page')}"
        out.append(Node(f"{base}/link{i}", T(("↗ ", "blue"), (l.get("label") or "link", "underline"), ("  " + url, "dim")),
                        "link", {**ref, "part": "link", "text": f"{l.get('label')} {url}"}, action=("link", url)))
    return out


def build(payload: dict, picks: dict[str, str]) -> list[Node]:
    secs: list[Node] = []

    # Captain's Call: payload order is the captain's priority order.
    cards = []
    for i, c in enumerate(payload.get("captains_call") or []):
        key = c["key"]
        ref = {"section": "captains_call", "key": key, "title": c.get("title")}
        q = c.get("question") or c.get("title") or key
        label = T((f"{i + 1:>2} ", "bold yellow"), (q, "bold"))
        if c.get("title") and c.get("question") and c["title"] != c["question"]:
            label.append(f"  · {c['title']}", style="dim")
        if c.get("repo"):
            label.append(f"  [{c['repo']}]", style="magenta")
        if key in picks:
            label.append(f"  ✓ {picks[key]}", style="green")
        rec = recommendation(c)
        kids = []
        if c.get("problem"):
            kids.append(Node(f"cc/{key}/problem", T(("⚠ ", "red"), c["problem"]), "line", {**ref, "part": "problem", "text": c["problem"]}))
        if rec:
            kids.append(Node(f"cc/{key}/rec", T(("★ recommended: ", "green bold"), rec), "rec", {**ref, "part": "recommendation", "text": rec}))
        for j, o in enumerate(c.get("options") or []):
            mark = "●" if picks.get(key) == o["label"] else "○"
            style = "dim" if o["value"] == "reconcile" else ""
            kids.append(Node(f"cc/{key}/opt/{o['value']}", T((f"{mark} {j + 1}. ", "cyan"), (o["label"], style)), "option",
                             {**ref, "part": "option", "value": o["value"], "text": o["label"]}, action=("pick", key, o["value"], o["label"])))
        if c.get("allow_freeform") or c.get("free_text"):
            kids.append(Node(f"cc/{key}/free", T(("✎ ", "cyan"), (c.get("freeform_hint") or "answer in your own words", "italic dim")), "freeform",
                             {**ref, "part": "free text"}, action=("answer", key)))
        ctx = c.get("context") or {}
        more = detail_nodes(f"cc/{key}/more", ref, ctx, c.get("links") or [], [("about", c.get("about")), ("task", ctx.get("task"))])
        if more:
            n_l = len(c.get("links") or [])
            summary = f"  {len(more)} parts" + (f", {n_l} link{'s' if n_l != 1 else ''}" if n_l else "")
            kids.append(Node(f"cc/{key}/more", T(("detail & links", "bold"), (summary, "dim")), "more", {**ref, "part": "detail"}, more))
        cards.append(Node(f"cc/{key}", label, "card", {**ref, "text": q}, kids))
    secs.append(section("cc", "Captain's call", "yellow", cards))

    rows = []
    for u in payload.get("underway") or []:
        ref = {"section": "underway", "key": u["id"], "title": u.get("name")}
        st = u.get("state", "")
        stc = {"paused": "yellow", "working": "green", "blocked": "red"}.get(st, "dim")
        label = T((u.get("name") or u["id"], ""), (f"  {st}", stc))
        if u.get("repo"):
            label.append(f"  [{u['repo']}]", style="magenta")
        kids = [lines_group("≡", "doing", sentences(u.get("doing", "")), ref, f"uw/{u['id']}/doing")] if u.get("doing") else []
        kids += [Node(f"uw/{u['id']}/id", T(("id: ", "dim"), u["id"], ("  kind: ", "dim"), u.get("kind", "")), "line", {**ref, "part": "id", "text": u["id"]})]
        rows.append(Node(f"uw/{u['id']}", label, "card", {**ref, "text": u.get("name")}, kids))
    secs.append(section("uw", "Under way", "green", rows))

    rows = []
    for w in payload.get("waiting") or []:
        ref = {"section": "waiting", "key": w["key"], "title": w.get("title")}
        label = T(w.get("title") or w["key"])
        kids = [Node(f"wt/{w['key']}/who", T(("⧗ ", "dim"), w.get("reason", "")), "line", {**ref, "part": "who has it", "text": w.get("reason", "")})]
        kids += detail_nodes(f"wt/{w['key']}", ref, w.get("context") or {}, w.get("links") or [])
        rows.append(Node(f"wt/{w['key']}", label, "card", {**ref, "text": w.get("title")}, kids))
    secs.append(section("wt", "Waiting on others", "blue", rows))

    rows = []
    for m in payload.get("open_mrs") or []:
        ref = {"section": "open_mrs", "key": m["key"], "title": m.get("title")}
        label = T(m.get("title", m["key"]), (f"  {m.get('state', '')}", "dim"))
        kids = detail_nodes(f"mr/{m['key']}", ref, {}, [{"url": m.get("url"), "label": "merge request"}] if m.get("url") else [], [("state", m.get("state"))])
        rows.append(Node(f"mr/{m['key']}", label, "card", {**ref, "text": m.get("title")}, kids))
    secs.append(section("mr", "Open MRs", "magenta", rows))

    rows = []
    for l in payload.get("landed") or []:
        ref = {"section": "landed", "key": l["id"], "title": l.get("what")}
        rows.append(Node(f"ld/{l['id']}", T(("✓ ", "green"), l.get("what") or l["id"]), "card", {**ref, "text": l.get("what")},
                         detail_nodes(f"ld/{l['id']}", ref, {}, [{"url": l["pr_url"], "label": "PR"}] if l.get("pr_url") else [],
                                      [("id", l["id"]), ("owner", l.get("owner")), ("repo", l.get("repo"))])))
    secs.append(section("ld", "Landed", "green", rows))

    rows = []
    charted = sorted(payload.get("charted") or [], key=lambda r: r.get("filed") or "", reverse=True)
    for r in charted:
        ref = {"section": "charted", "key": r["id"], "title": r.get("title")}
        label = T(r.get("title") or r["id"], (f"  {r.get('kind', '')}", "dim"))
        if r.get("filed"):
            label.append(f"  {r['filed'][:10]}", style="dim")
        ctx = dict(r.get("context") or {})
        if r.get("reason"):
            ctx["reason"] = r["reason"]
        rows.append(Node(f"ch/{r['id']}", label, "card", {**ref, "text": r.get("title")}, detail_nodes(f"ch/{r['id']}", ref, ctx, r.get("links") or [])))
    secs.append(section("ch", "Charted next", "cyan", rows))
    return secs


def section(sid: str, name: str, colour: str, kids: list[Node]) -> Node:
    return Node(sid, T((name, f"bold {colour}"), (f"  {len(kids)}", "dim")), "section", {"section": name, "text": name}, kids)


def card_hashes(payload: dict) -> dict[str, str]:
    out = {}
    for sec, k in (("captains_call", "key"), ("underway", "id"), ("waiting", "key"), ("landed", "id"), ("charted", "id"), ("open_mrs", "key")):
        for r in payload.get(sec) or []:
            out[r.get(k, "")] = hashlib.sha1(json.dumps(r, sort_keys=True).encode()).hexdigest()
    return out


def short_ref(ref: dict) -> str:
    who = ref.get("key", ref.get("section", "?"))
    part = ref.get("part")
    txt = ref.get("text") or ""
    txt = txt if len(txt) <= 40 else txt[:39] + "…"
    return f"{who}" + (f" › {part}" if part else "") + (f" “{txt}”" if txt and part else "")


# ---------------------------------------------------------------- UI

class BoardTree(Tree):
    BINDINGS = [
        Binding("enter", "activate", "open / pick", show=True),
        Binding("right,l", "open", "open", show=False),
        Binding("left,h", "close", "close", show=False),
        Binding("j", "cursor_down", "down", show=False),
        Binding("k", "cursor_up", "up", show=False),
    ]

    def action_activate(self) -> None:
        self.app.activate(self)

    def action_open(self) -> None:
        n = self.cursor_node
        if n and n.allow_expand and not n.is_expanded:
            n.expand()
        elif n and n.children:
            self.move_cursor(n.children[0])

    def action_close(self) -> None:
        n = self.cursor_node
        if n and n.is_expanded:
            n.collapse()
        elif n and n.parent and n.parent is not self.root:
            self.move_cursor(n.parent)


class TuiBoard(App):
    CSS = """
    #top { height: 1; background: $boost; padding: 0 1; }
    #main { height: 1fr; }
    BoardTree { height: 1fr; scrollbar-size-vertical: 1; }
    #left.split { width: 45%; border-right: solid $primary-darken-2; }
    #right { width: 1fr; }
    #log { height: 7; border-top: solid $primary-darken-2; padding: 0 1; }
    #chips { height: auto; max-height: 3; padding: 0 1; color: $warning; }
    #chat { height: 3; }
    """
    BINDINGS = [
        Binding("t", "tag", "tag for chat"),
        Binding("T", "clear_tags", "clear tags", show=False),
        Binding("c,slash", "chat", "chat"),
        Binding("a", "answer", "free-text answer"),
        Binding("v", "variant", "layout"),
        Binding("tab", "focus_next", "switch pane", show=False),
        Binding("escape", "leave_input", "back", show=False),
        Binding("q", "quit", "quit"),
    ]

    def __init__(self, variant: str = "A") -> None:
        super().__init__()
        self.variant = variant
        self.payload: dict = {}
        self.stamp_sig = None
        self.hashes: dict[str, str] = {}
        self.changed: set[str] = set()
        self.picks: dict[str, str] = {}
        self.tags: list[dict] = []
        self.mode: tuple = ("chat",)
        self.model: list[Node] = []
        self.by_id: dict[str, Node] = {}
        self.last_check = 0.0
        self.last_change = 0.0
        self.log_lines: list[Text] = []

    # -- layout
    def compose(self) -> ComposeResult:
        yield Static(id="top")
        with Horizontal(id="main"):
            yield BoardTree("board", id="left")
            yield BoardTree("detail", id="right")
        yield Static(id="log")
        yield Static(id="chips")
        yield Input(placeholder="c to chat · t tags the line under the cursor · Enter sends to the local outbox only", id="chat")
        yield Footer()

    def on_mount(self) -> None:
        for t in self.query(BoardTree):
            t.show_root = False
            t.guide_depth = 2
        self.reload(force=True)
        self.apply_variant()
        self.set_interval(POLL_SECONDS, self.poll)
        self.set_interval(1.0, self.paint_top)
        self.say("prototype", f"board data (read only): {DATA}")
        self.say("prototype", f"picks, answers and chat go only to {OUTBOX}")

    def apply_variant(self) -> None:
        left, right = self.query_one("#left"), self.query_one("#right")
        right.display = self.variant == "B"
        left.set_class(self.variant == "B", "split")
        self.render_trees()
        left.focus()

    # -- live data
    def poll(self) -> None:
        self.last_check = time.time()
        self.reload()

    def reload(self, force: bool = False) -> None:
        try:
            st = STAMP.stat()
            sig = (st.st_mtime_ns, st.st_size, STAMP.read_text())
        except OSError:
            sig = None
        if not force and sig == self.stamp_sig:
            return
        self.stamp_sig = sig
        try:
            payload = load_payload(DATA)
        except Exception as e:  # prototype: keep the last good payload
            self.say("prototype", f"board data unreadable, keeping last view: {e}")
            self.stamp_sig = None  # try again on the next poll
            return
        new = card_hashes(payload)
        if self.hashes:
            self.changed |= {k for k, h in new.items() if self.hashes.get(k) != h}
            if self.changed:
                self.last_change = time.time()
        self.hashes = new
        self.payload = payload
        self.render_trees()

    def paint_top(self) -> None:
        p = self.payload
        age = int(time.time() - self.last_check) if self.last_check else 0
        t = Text(no_wrap=True, overflow="ellipsis")
        t.append("bearings ", style="bold")
        t.append(f"{p.get('home', '')} ", style="dim")
        t.append(f"built {p.get('generated', '')[11:16]}Z ", style="dim")
        t.append("● live ", style="green")
        t.append(f"checked {age}s ago  ", style="dim")
        t.append(f"{len(self.picks)} picked  ", style="green" if self.picks else "dim")
        if self.changed:
            t.append(f"{len(self.changed)} changed  ", style="bold yellow")
        t.append(f"{'A outline' if self.variant == 'A' else 'B split'}  ", style="cyan")
        t.append(" PROTOTYPE: local only ", style="reverse red")
        self.query_one("#top", Static).update(t)

    # -- trees
    def render_trees(self) -> None:
        self.model = build(self.payload, self.picks)
        self.by_id = {}

        def index(n: Node):
            self.by_id[n.id] = n
            for c in n.children:
                index(c)
        for s in self.model:
            index(s)
        left: BoardTree = self.query_one("#left")
        depth = None if self.variant == "A" else 2  # split: left shows sections + one-liners only
        self.fill(left, self.model, depth, default_open={"cc"})
        if self.variant == "B":
            self.fill_detail()
        self.paint_top()

    def decorate(self, n: Node) -> Text:
        label = n.label.copy()
        if n.kind == "card" and n.ref.get("key") in self.changed:
            label = T(("● ", "yellow")) + label
        idx = [i for i, t in enumerate(self.tags) if t.get("_id") == n.id]
        if idx:
            label = T((f"@{idx[0] + 1}", "reverse yellow"), " ") + label
        return label

    def fill(self, tree: BoardTree, nodes: list[Node], depth: int | None, default_open: set[str] = frozenset()) -> None:
        expanded = {getattr(x.data, "id", None) for x in self.walk(tree.root) if x.is_expanded} if tree.root.children else set(default_open)
        cur = tree.cursor_node.data.id if tree.cursor_node and tree.cursor_node.data else None
        tree.clear()
        target = None

        def add(parent, n: Node, d: int):
            nonlocal target
            leaf = not n.children or (depth is not None and d >= depth)
            tn = parent.add_leaf(self.decorate(n), data=n) if leaf else parent.add(self.decorate(n), data=n, expand=n.id in expanded)
            if n.id == cur:
                target = tn
            if not leaf:
                for c in n.children:
                    add(tn, c, d + 1)
        for n in nodes:
            add(tree.root, n, 1)
        tree.root.expand()
        if target is not None:
            self.call_after_refresh(tree.move_cursor, target)

    def fill_detail(self) -> None:
        right: BoardTree = self.query_one("#right")
        left: BoardTree = self.query_one("#left")
        n = left.cursor_node.data if left.cursor_node and left.cursor_node.data else None
        if n is None or n.kind == "section":
            right.clear()
            right.root.add_leaf(T(("select an item on the left", "dim")))
            return
        # level 1 of the item is open; deeper parts start closed
        keep = {getattr(x.data, "id", None) for x in self.walk(right.root) if x.is_expanded}
        if not right.root.children or right.root.children[0].data is None or right.root.children[0].data.id != n.id:
            keep = {n.id}
        right.clear()

        def add(parent, m: Node):
            tn = parent.add(self.decorate(m), data=m, expand=m.id in keep) if m.children else parent.add_leaf(self.decorate(m), data=m)
            for c in m.children:
                add(tn, c)
        add(right.root, n)
        right.root.expand()

    def walk(self, tn):
        yield tn
        for c in tn.children:
            yield from self.walk(c)

    def on_tree_node_highlighted(self, ev: Tree.NodeHighlighted) -> None:
        n = ev.node.data
        if n and n.kind == "card" and n.ref.get("key") in self.changed:
            self.changed.discard(n.ref["key"])
            ev.node.set_label(self.decorate(n))
        if self.variant == "B" and ev.control.id == "left":
            self.fill_detail()

    # -- actions
    def focused_tree(self) -> BoardTree | None:
        f = self.focused
        return f if isinstance(f, BoardTree) else None

    def activate(self, tree: BoardTree) -> None:
        tn = tree.cursor_node
        if tn is None or tn.data is None:
            return
        n: Node = tn.data
        if n.action and n.action[0] == "pick":
            _, key, value, label = n.action
            self.picks[key] = label
            self.write_outbox({"kind": "pick", "key": key, "value": value, "label": label})
            self.say("you", f"picked “{label}” for {key}")
            self.render_trees()
            return
        if n.action and n.action[0] == "answer":
            self.start_answer(n.action[1])
            return
        if n.action and n.action[0] == "link":
            self.copy_to_clipboard(n.action[1])
            self.say("prototype", f"copied {n.action[1]} (terminal clipboard; no browser)")
            return
        if self.variant == "B" and tree.id == "left" and n.kind == "card":
            self.query_one("#right").focus()
            return
        if tn.allow_expand:
            if not tn.is_expanded:
                tn.expand()
            else:  # second Enter: open the detail level, third closes
                more = next((c for c in tn.children if c.data and c.data.kind == "more"), None)
                if more is not None and not more.is_expanded:
                    more.expand()
                else:
                    tn.collapse()

    def action_tag(self) -> None:
        tree = self.focused_tree()
        if not tree or not tree.cursor_node or not tree.cursor_node.data:
            return
        n: Node = tree.cursor_node.data
        existing = [t for t in self.tags if t["_id"] == n.id]
        if existing:
            self.tags.remove(existing[0])
        else:
            self.tags.append({**n.ref, "_id": n.id, "kind": n.kind})
        self.paint_chips()
        for tr in self.query(BoardTree):
            for x in self.walk(tr.root):
                if x.data:
                    x.set_label(self.decorate(x.data))

    def action_clear_tags(self) -> None:
        self.tags = []
        self.paint_chips()
        self.render_trees()

    def paint_chips(self) -> None:
        if not self.tags:
            self.query_one("#chips", Static).update("")
            return
        t = Text()
        t.append("tagged: ", style="dim")
        for i, r in enumerate(self.tags):
            t.append(f" @{i + 1} ", style="reverse yellow")
            t.append(" " + short_ref(r) + "  ")
        self.query_one("#chips", Static).update(t)

    def action_chat(self) -> None:
        self.mode = ("chat",)
        inp = self.query_one("#chat", Input)
        inp.placeholder = "message the agent - tagged items ride along (@1, @2 …) · Esc back to the board"
        inp.focus()

    def action_answer(self) -> None:
        tree = self.focused_tree()
        n = tree.cursor_node.data if tree and tree.cursor_node else None
        if n and n.ref.get("section") == "captains_call":
            self.start_answer(n.ref["key"])

    def start_answer(self, key: str) -> None:
        self.mode = ("answer", key)
        inp = self.query_one("#chat", Input)
        inp.placeholder = f"your answer for {key} · Enter records it locally · Esc cancels"
        inp.focus()

    def action_leave_input(self) -> None:
        if isinstance(self.focused, Input):
            self.mode = ("chat",)
            self.query_one("#left").focus()

    def action_variant(self) -> None:
        self.variant = "B" if self.variant == "A" else "A"
        self.apply_variant()

    def on_input_submitted(self, ev: Input.Submitted) -> None:
        text = ev.value.strip()
        if not text:
            return
        ev.input.value = ""
        refs = [{k: v for k, v in r.items() if k != "_id"} for r in self.tags]
        if self.mode[0] == "answer":
            key = self.mode[1]
            self.picks[key] = f"“{text}”"
            self.write_outbox({"kind": "answer", "key": key, "text": text, "refs": refs})
            self.say("you", f"answered {key}: {text}")
        else:
            self.write_outbox({"kind": "chat", "text": text, "refs": refs})
            self.say("you", text + ("" if not refs else "  " + " ".join(f"@{i + 1}" for i in range(len(refs)))))
            for i, r in enumerate(refs):
                self.say("  ", f"@{i + 1} = {short_ref(r)}")
            self.say("agent", "(prototype: no agent attached - message and references written to the outbox only)")
        self.tags = []
        self.paint_chips()
        self.mode = ("chat",)
        self.render_trees()
        self.query_one("#left").focus()

    def write_outbox(self, rec: dict) -> None:
        rec = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "prototype": True, **rec}
        with OUTBOX.open("a") as f:
            f.write(json.dumps(rec) + "\n")

    def say(self, who: str, msg: str) -> None:
        style = {"you": "bold cyan", "agent": "bold magenta", "prototype": "dim"}.get(who, "")
        line = Text(no_wrap=True, overflow="ellipsis")
        line.append(f"{who:>9} ", style=style)
        line.append(msg)
        self.log_lines = (self.log_lines + [line])[-6:]
        self.query_one("#log", Static).update(Text("\n").join(self.log_lines))


if __name__ == "__main__":
    v = sys.argv[1].upper() if len(sys.argv) > 1 else "A"
    TuiBoard(v if v in ("A", "B") else "A").run()
