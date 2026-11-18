"""PROTOTYPE - throwaway. A Lavish page as a markdown file the captain writes in.

convert() turns a Lavish page.html into blocks of markdown, deterministically:
no text of its own beyond fixed labels. Each block starts with a marker line
`<!-- block: <id> -->` so a comment can be tied to it:

- an element with an id (section, article, heading) is a block with that id;
- a heading with no id is a block "<enclosing id>/<slug of its text>";
- a radio group outside any block is a block "pick-<input name>";
- text before the first block is the block "top".

A radio group becomes a lettered option list (the checked one is "(default)").
A code table becomes a fenced block, one numbered line per row. A data table
becomes one bullet per row, each other cell a "<column>: <cell>" sub-bullet.

captain_groups() finds the captain's text in a page: every line added or
changed since the run last wrote it (its baseline), and with no baseline only
lines starting with the marker "//". No generated line ever starts with "//".
Standard library only.
"""

from __future__ import annotations

import difflib
import re
import textwrap
from dataclasses import dataclass, field
from html.parser import HTMLParser

WIDTH = 78
LETTERS = "abcdefghijklmnopqrstuvwxyz"
MARKER = "//"
BLOCK_LINE = re.compile(r"^<!-- block: (\S+) -->$")
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
SKIP = {"script", "style", "head", "title", "nav", "button", "template"}
BLOCK_TAGS = {"address", "article", "aside", "blockquote", "details", "div", "dl", "fieldset", "figure", "footer",
              "form", "header", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "li", "main", "ol", "p", "pre",
              "section", "summary", "table", "tbody", "thead", "tfoot", "tr", "td", "th", "ul", "textarea"}
HEADINGS = {"h1", "h2", "h3", "h4", "h5", "h6"}
BLOCK_CONTAINERS = {"section", "article"}


# ---------------------------------------------------------------- a small DOM

@dataclass
class Node:
    tag: str
    attrs: dict
    children: list = field(default_factory=list)

    def classes(self) -> set[str]:
        return set((self.attrs.get("class") or "").split())

    def elements(self) -> list["Node"]:
        return [c for c in self.children if isinstance(c, Node)]

    def walk(self):
        for c in self.elements():
            yield c
            yield from c.walk()


class _Builder(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = Node("#root", {})
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, {k: (v if v is not None else "") for k, v in attrs})
        self.stack[-1].children.append(node)
        if tag not in VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.stack[-1].children.append(Node(tag, {k: (v if v is not None else "") for k, v in attrs}))

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def parse(html: str) -> Node:
    b = _Builder()
    b.feed(html)
    b.close()
    return b.root


def find(node: Node, tag: str) -> Node | None:
    return next((n for n in node.walk() if n.tag == tag), None)


# ---------------------------------------------------------------- inline text

BR = "\x00"


def inline(node: Node | str) -> str:
    """Markdown inline text of a node: **bold**, `code`, [text](href), line breaks kept as BR."""
    if isinstance(node, str):
        return node
    if node.tag in SKIP or node.tag in ("textarea", "input"):
        return ""
    if node.tag == "br":
        return BR
    inner = "".join(inline(c) for c in node.children)
    if node.tag in ("b", "strong"):
        return _wrap_marks(inner, "**")
    if node.tag in ("i", "em"):
        return _wrap_marks(inner, "_")
    if node.tag == "code":
        return _wrap_marks(squash(inner), "`")
    if node.tag == "a" and node.attrs.get("href"):
        text = squash(inner)
        href = node.attrs["href"]
        return f"[{text}]({href})" if text and text != href else href
    return inner


def _wrap_marks(text: str, mark: str) -> str:
    core = text.strip(" \t\n")
    if not core.replace(BR, ""):
        return text
    lead = text[: len(text) - len(text.lstrip(" \t\n"))]
    trail = text[len(text.rstrip(" \t\n")):]
    return f"{lead}{mark}{core}{mark}{trail}"


def squash(text: str) -> str:
    return re.sub(r"[ \t\r\n\f\v]+", " ", text or "").strip()


def paragraphs(text: str) -> list[list[str]]:
    """Split inline text at line breaks: one blank break line starts a new paragraph."""
    paras: list[list[str]] = [[]]
    for piece in text.split(BR):
        piece = squash(piece)
        if piece:
            paras[-1].append(piece)
        elif paras[-1]:
            paras.append([])
    return [p for p in paras if p]


def safe(line: str) -> str:
    """No generated line may start with the captain's marker."""
    return "\\" + line if line.lstrip().startswith(MARKER) else line


def wrap(text: str, first: str = "", rest: str | None = None) -> list[str]:
    lines = textwrap.wrap(text, WIDTH, initial_indent=first, subsequent_indent=first if rest is None else rest,
                          break_long_words=False, break_on_hyphens=False) or [first.rstrip()]
    return [safe(l) for l in lines]


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", squash(re.sub(r"[*`_\[\]]|\(http[^)]*\)", "", text)).lower()).strip("-")[:40]


# ---------------------------------------------------------------- blocks

@dataclass
class Block:
    id: str
    lines: list[str] = field(default_factory=list)
    picks: list[dict] = field(default_factory=list)  # [{"name", "options": [{"value", "label", "default"}]}]
    notes: list[str] = field(default_factory=list)    # textarea names


class _Converter:
    def __init__(self, root: Node) -> None:
        self.root = root
        self.blocks = [Block("top")]
        self.ids: set[str] = {"top"}
        self.open: list[str] = []       # ids of the block containers we are inside
        self.closed = False             # content after a block container closed needs a new block
        self.level = 1                  # level of the last heading
        self.placeholders: set[str] = set()
        self.done_groups: set[str] = set()

    @property
    def cur(self) -> Block:
        return self.blocks[-1]

    def empty(self) -> bool:
        return not any(l.strip() for l in self.cur.lines)

    def start(self, bid: str) -> None:
        base, n = bid, 2
        while bid in self.ids:
            bid, n = f"{base}-{n}", n + 1
        self.ids.add(bid)
        self.blocks.append(Block(bid))
        self.closed = False

    def emit(self, lines: list[str]) -> None:
        if self.closed:
            self.start(f"after-{self.cur.id}")
        if self.cur.lines and self.cur.lines[-1] != "" and lines and lines[0] != "":
            self.cur.lines.append("")
        self.cur.lines += lines

    # A container is rendered by grouping inline runs into paragraphs, flushed at each block child.
    def container(self, node: Node, indent: str = "") -> None:
        run: list = []

        def flush():
            if run:
                text = "".join(inline(c) for c in run)
                out: list[str] = []
                for para in paragraphs(text):
                    if out:
                        out.append("")
                    for piece in para:
                        out += wrap(piece, indent)
                if out:
                    self.emit(out)
                run.clear()

        for c in node.children:
            if isinstance(c, str) or (c.tag not in BLOCK_TAGS and not self.radio_label(c) and c.tag not in SKIP):
                run.append(c)
            else:
                flush()
                self.node(c, indent)
        flush()

    @staticmethod
    def radio_label(node: Node) -> bool:
        return node.tag == "label" and any(n.tag == "input" and n.attrs.get("type") == "radio" for n in node.walk())

    def node(self, node: Node, indent: str = "") -> None:
        tag = node.tag
        if tag in SKIP:
            return
        nid = node.attrs.get("id")
        if tag in BLOCK_CONTAINERS and nid:
            self.start(nid)
            self.open.append(nid)
            if tag == "article":
                self.article(node)
            else:
                self.container(node)
            self.open.pop()
            self.closed = True
            return
        if tag in HEADINGS:
            self.heading(node, int(tag[1]))
            return
        if self.radio_label(node):
            self.pick(node)
            return
        if tag in ("div", "fieldset") and not self.open and self.has_radio(node):
            name = next(n.attrs.get("name") for n in node.walk() if n.tag == "input" and n.attrs.get("type") == "radio")
            self.start(f"pick-{name}")
            self.container(node)
            self.closed = True
            return
        if tag in ("ul", "ol"):
            self.emit(self.list_lines(node, indent))
            return
        if tag == "table":
            self.table(node, indent)
            return
        if tag == "details":
            for c in node.elements():
                if c.tag == "summary":
                    self.emit(wrap(squash(inline(c).replace(BR, " ")), indent))
            self.container(Node("div", {}, [c for c in node.children if not (isinstance(c, Node) and c.tag == "summary")]), indent)
            return
        if tag == "textarea":
            self.note(node)
            return
        if tag == "pre":
            text = "".join(c if isinstance(c, str) else squash(inline(c)) for c in node.children)
            self.emit(["```"] + [f"    {l}" for l in text.strip("\n").splitlines()] + ["```"])
            return
        self.container(node, indent)

    @staticmethod
    def has_radio(node: Node) -> bool:
        return any(n.tag == "input" and n.attrs.get("type") == "radio" for n in node.walk())

    def heading(self, node: Node, level: int, text: str | None = None) -> None:
        text = squash((text if text is not None else inline(node)).replace(BR, " "))
        nid = node.attrs.get("id")
        if nid:
            self.start(nid)
        elif level == 1 and self.cur.id == "top" and self.empty():
            pass
        elif not self.empty() or self.closed:
            parent = self.open[-1] if self.open else ""
            self.start(f"{parent}/{slug(text)}" if parent else slug(text) or "part")
        self.level = level
        self.emit([safe("#" * level + " " + text)])

    def article(self, node: Node) -> None:
        header = next((c for c in node.elements() if c.tag == "header"), None)
        if header is not None:
            parts = [squash(inline(c).replace(BR, " ")) for c in header.children]
            text = " · ".join(p for p in parts if p)
            self.emit([safe("#" * min(self.level + 1, 6) + " " + text)])
        self.container(Node("div", {}, [c for c in node.children if c is not header]))

    def pick(self, label: Node) -> None:
        radio = next(n for n in label.walk() if n.tag == "input")
        name = radio.attrs.get("name") or ""
        if name in self.done_groups:
            return
        self.done_groups.add(name)
        options = []
        for n in self.scope_labels():
            r = next((x for x in n.walk() if x.tag == "input" and x.attrs.get("type") == "radio"), None)
            if r is not None and r.attrs.get("name") == name:
                options.append({"value": r.attrs.get("value", ""), "label": squash(inline(n).replace(BR, " ")),
                                "default": "checked" in r.attrs})
        self.cur.picks.append({"name": name, "options": options})
        lines = ["Pick one:"]
        for letter, o in zip(LETTERS, options):
            lines += wrap(o["label"] + (" (default)" if o["default"] else ""), f"  {letter}) ", "     ")
        lines.append("To pick, write its letter on its own line, like  b")
        self.emit(lines)

    def scope_labels(self):
        return [n for n in self.root.walk() if self.radio_label(n)]

    def note(self, node: Node) -> None:
        self.cur.notes.append(node.attrs.get("name") or "")
        placeholder = squash(node.attrs.get("placeholder", ""))
        lines = [NOTE_MARK]
        if placeholder and placeholder not in self.placeholders:
            self.placeholders.add(placeholder)
            lines += wrap(f"Hint: {placeholder}")
        self.emit(lines)

    def list_lines(self, node: Node, indent: str) -> list[str]:
        out: list[str] = []
        for i, li in enumerate((c for c in node.elements() if c.tag == "li"), 1):
            bullet = f"{i}. " if node.tag == "ol" else "- "
            out += self.cell_lines(li, indent + bullet, indent + " " * len(bullet))
        return out

    def cell_lines(self, node: Node, first: str, rest: str) -> list[str]:
        """A list item or table cell: its text on the bullet line, nested lists indented under it."""
        out: list[str] = []
        run: list = []

        def flush():
            text = "".join(inline(c) for c in run)
            for para in paragraphs(text):
                for piece in para:
                    out.extend(wrap(piece, first if not out else rest, rest))
            run.clear()

        for c in node.children:
            if isinstance(c, Node) and c.tag in ("ul", "ol"):
                flush()
                if not out:
                    out.append(first.rstrip())
                out += self.list_lines(c, rest)
            elif isinstance(c, Node) and c.tag in BLOCK_TAGS:
                flush()
                out += self.cell_lines(c, first if not out else rest, rest)
            else:
                run.append(c)
        flush()
        return out

    def table(self, node: Node, indent: str) -> None:
        rows = [n for n in node.walk() if n.tag == "tr"]
        if "code" in node.classes():
            body = []
            for tr in rows:
                cells = [c for c in tr.elements() if c.tag in ("td", "th")]
                ln = squash(inline(cells[0])) if cells else ""
                mk = squash(inline(cells[1])) if len(cells) > 1 else ""
                code = "".join(raw_text(cells[-1])) if cells else ""
                hl = ">" if "hl" in tr.classes() else " "
                body.append(f"{hl}{ln:>5} {mk or ' '} {code}".rstrip())
            self.emit(["```"] + body + ["```"])
            return
        head = [squash(inline(c)) for c in rows[0].elements() if c.tag == "th"] if rows else []
        out: list[str] = []
        for tr in rows:
            cells = [c for c in tr.elements() if c.tag == "td"]
            if not cells:
                continue
            out += self.cell_lines(cells[0], indent + "- ", indent + "  ")
            for name, cell in zip(head[1:] or [""] * (len(cells) - 1), cells[1:]):
                label = Node("span", {}, [Node("b", {}, [name + ":"]), " "]) if name else Node("span", {})
                out += self.cell_lines(Node("div", {}, [label] + cell.children), indent + "  - ", indent + "    ")
        self.emit(out)


def raw_text(node: Node):
    """Raw text of a node, whitespace kept (for code)."""
    for c in node.children:
        if isinstance(c, str):
            yield c
        else:
            yield from raw_text(c)


def convert(html: str) -> list[Block]:
    """The page's blocks, in page order; the body only."""
    root = parse(html)
    body = find(root, "body") or root
    conv = _Converter(body)
    conv.container(body)
    blocks = [b for b in conv.blocks if any(l.strip() for l in b.lines) or b.picks]
    for b in blocks:
        while b.lines and not b.lines[-1].strip():
            b.lines.pop()
    return blocks


# ---------------------------------------------------------------- the captain's text

def block_at(lines: list[str], index: int) -> str:
    """The id of the block a line belongs to: the nearest block marker at or above it."""
    for l in reversed(lines[: index + 1]):
        if m := BLOCK_LINE.match(l):
            return m.group(1)
    return "top"


# Text the captain marks as theirs, anywhere in a card or a page: <!--captain: ...-->, on one line
# or over several. The editor's \c (normal mode) and Ctrl-g c (insert mode) write an empty one.
# An empty marker says nothing, so it is not the captain's text, and a marker never runs on into
# another comment (an unfinished one would otherwise take the text up to the next "-->").
ANY_CAPTAIN = re.compile(r"<!--\s*captain:((?:(?!<!--).)*?)-->", re.S | re.I)
CAPTAIN = re.compile(r"<!--\s*captain:(\s*(?!-->|<!--)\S(?:(?!<!--).)*?)-->", re.S | re.I)


def captain_words(text: str) -> list[str]:
    """What each captain marker in a text says, without the marker itself."""
    return [w for m in CAPTAIN.finditer(text) if (w := " ".join(m.group(1).split()))]


def without_captain_marks(text: str) -> str:
    """The text with its captain markers, empty ones too, removed, keeping its line breaks so line
    numbers hold."""
    return ANY_CAPTAIN.sub(lambda m: "\n" * m.group(0).count("\n"), text)


def captain_lines(lines: list[str]) -> set[int]:
    """The indexes of the lines a captain marker covers."""
    text, out = "\n".join(lines), set()
    for m in CAPTAIN.finditer(text):
        out |= set(range(text.count("\n", 0, m.start()), text.count("\n", 0, m.end()) + 1))
    return out


def marked(line: str) -> bool:
    return line.lstrip().startswith(MARKER)


def unmark(line: str) -> str:
    s = line.lstrip()
    return s[len(MARKER):].lstrip() if s.startswith(MARKER) else line


def in_fence(lines: list[str]) -> list[bool]:
    inside, out = False, []
    for l in lines:
        if l.startswith("```"):
            out.append(True)
            inside = not inside
        else:
            out.append(inside)
    return out


@dataclass
class Group:
    start: int            # index of its first line in the current page
    end: int              # index after its last line
    lines: list[str]      # the captain's lines, as written
    was: list[str]        # agent lines these replaced, if any


def captain_groups(base: list[str] | None, now: list[str], is_ack) -> list[Group]:
    """The captain's text in a page: each run of lines added or changed since the baseline.

    With no baseline, only lines starting with the marker (//) or holding a captain marker
    (<!--captain: ...-->) count. Blank lines at the edges of a run and acknowledgement lines are
    not part of it. A changed line whose only change is a captain marker is that marker, not a
    rewrite of the line.
    """
    spans: list[tuple[int, int, list[str]]] = []
    if base is None:
        fence, mine = in_fence(now), captain_lines(now)

        def ours(i: int) -> bool:
            return i in mine or (marked(now[i]) and not fence[i])
        i = 0
        while i < len(now):
            if ours(i):
                j = i
                while j < len(now) and ours(j):
                    j += 1
                spans.append((i, j, []))
                i = j
            else:
                i += 1
    else:
        sm = difflib.SequenceMatcher(a=base, b=now, autojunk=False)
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag in ("insert", "replace"):
                spans.append((j1, j2, [l for l in base[i1:i2] if l.strip()] if tag == "replace" else []))
    groups = []
    for j1, j2, was in spans:
        while j1 < j2 and (not now[j1].strip() or is_ack(now[j1])):
            j1 += 1
        while j2 > j1 and (not now[j2 - 1].strip() or is_ack(now[j2 - 1])):
            j2 -= 1
        if j1 < j2:
            lines = now[j1:j2]
            clean = [l.rstrip() for l in without_captain_marks("\n".join(lines)).splitlines() if l.strip()]
            if was and clean == [l.rstrip() for l in was]:
                lines, was = [m.group(0) for m in CAPTAIN.finditer("\n".join(lines))], []
            groups.append(Group(j1, j2, lines, was))
    return groups


def text_of(lines: list[str]) -> str:
    return "\n".join(unmark(l) for l in lines).strip()


def agent_line_above(lines: list[str], index: int, captain: set[int]) -> str:
    for i in range(index - 1, -1, -1):
        if i not in captain and lines[i].strip() and not BLOCK_LINE.match(lines[i]):
            return lines[i]
    return ""


def interpret(text: str, picks: list[dict]) -> dict | None:
    """A letter on the first line picks an option of the block's first radio group."""
    if not picks:
        return None
    text = without_captain_marks(text).strip()
    m = re.match(r"^\s*\(?([a-z])(?:\)|[.:,]|\s*$)", text.splitlines()[0] if text else "", re.I)
    options = picks[0]["options"]
    if m and LETTERS.index(m.group(1).lower()) < len(options):
        o = options[LETTERS.index(m.group(1).lower())]
        return {"name": picks[0]["name"], "value": o["value"], "label": o["label"]}
    return None


# ---------------------------------------------------------------- the page file

HELP = [
    "- PROTOTYPE: this page is a file. Your comments go to a local outbox only.",
    "- Write on a new line anywhere. Each line you add or change is a comment on the part above it.",
    "- To pick an option, write its letter on its own line (like b).",
    "- You can also start a line with two slashes (//) to mark it as yours.",
    "- To mark text as yours inside a line, press \\c (or Ctrl-g c while you type): it writes <!--captain:  -->.",
    "- Save with :w. Close the tab with :q.",
]
# Where the captain writes a note: a heading so it stands out in the editor. A page an older run
# built has the plain line (OLD_NOTE_MARK) or that line with the field's hint after a colon.
NOTE_MARK = "### Your note goes on a new line here"
OLD_NOTE_MARK = "Your note goes on a new line here."
FIXED = {"Pick one:", "To pick, write its letter on its own line, like  b", NOTE_MARK, OLD_NOTE_MARK}


def same_agent_line(a: str, b: str) -> bool:
    """Whether two agent lines are the same place in a page: equal, or both a note line (old or new)."""
    return a == b or (is_note_mark(a) and is_note_mark(b))


def is_note_mark(line: str) -> bool:
    s = line.strip()
    return s in (NOTE_MARK, OLD_NOTE_MARK) or s.startswith(OLD_NOTE_MARK[:-1] + ":")
GONE = "## Comments on parts no longer on the page"
LIST_ITEM = re.compile(r"^\s*(?:[-*]|\d+\.|[a-z]\))\s")


def lint_lines(lines: list[str]) -> list[str]:
    """A block's text as the lint should read it: one line per paragraph or list item, unwrapped.

    Wrapped lines join into one, a list marker ("-", "1.", "a)") is dropped so it never counts as a
    word, whitespace is squashed and fixed labels are left out.
    """
    out: list[str] = []
    open_para = in_item = False
    for l in lines:
        if l in FIXED or not l.strip():
            open_para = in_item = False
            continue
        text = " ".join(l.split())
        if LIST_ITEM.match(l):
            out.append(LIST_ITEM.sub("", l, count=1).strip())
            open_para = in_item = True
        elif open_para and (l[:1] == " " or not in_item):  # the wrapped rest of an item or paragraph
            out[-1] += " " + text
        else:
            out.append(text)
            open_para, in_item = True, False
    return [o for o in out if o]


def render_page(page_id: str, meta: dict, blocks: list[Block], faults: dict[str, list[str]] | None,
                version: str) -> list[str]:
    """The page as the run writes it: id line, help, check summary, then each block under its marker."""
    out = [f"<!-- page: {page_id} | task: {meta.get('task') or '-'} | opened: {meta.get('opened') or '-'}"
           f" | from: .lavish/pages/{page_id}/page.html (version {version}) -->", ""]
    out += HELP + [""]
    if faults is None:
        out += ["The plain-language check did not run on this page.", ""]
    elif faults:
        n = len(faults)
        one = n == 1
        out += [f"Check: {n} part{'' if one else 's'} of this page fail{'s' if one else ''} the"
                f" plain-language check. Firstmate rewrites {'it' if one else 'them'}.", ""]
    for b in blocks:
        out.append(f"<!-- block: {b.id} -->")
        for f in (faults or {}).get(b.id, []):
            out += wrap(f"Check: {f}", "> ", "> ")
        out += b.lines + [""]
    while out and not out[-1].strip():
        out.pop()
    return out


def block_range(lines: list[str], block: str) -> tuple[int, int] | None:
    """(marker index, index of the next marker or the end) of a block, or None when it is not there."""
    start = next((i for i, l in enumerate(lines) if l == f"<!-- block: {block} -->"), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if BLOCK_LINE.match(lines[i]) or lines[i] == GONE), len(lines))
    return start, end


def captain_chunks(built: list[str] | None, now: list[str], is_ack) -> list[dict]:
    """Every run of captain text in a page, with any acknowledgements under it, to carry into a rebuild.

    The captain's lines are those not in the page as built (`built`); with no built copy, the
    lines marked "//". Each chunk records its block and the agent line it follows: that line's
    text and which occurrence of it in the block (0 for the block marker itself).
    """
    if built is None:
        mine = {i for i, l in enumerate(now) if marked(l) or is_ack(l)}
    else:
        sm = difflib.SequenceMatcher(a=built, b=now, autojunk=False)
        mine = {j for tag, _, _, j1, j2 in sm.get_opcodes() if tag in ("insert", "replace") for j in range(j1, j2)}
    mine = {j for j in mine if not BLOCK_LINE.match(now[j]) and now[j] != GONE}
    chunks, j = [], 0
    while j < len(now):
        if j not in mine:
            j += 1
            continue
        k = j
        while k in mine:
            k += 1
        lines = now[j:k]
        while lines and (not lines[0].strip() or is_ack(lines[0])):
            lines.pop(0)
        while lines and not lines[-1].strip():
            lines.pop()
        if any(not is_ack(l) for l in lines):
            start = j + next(i for i, l in enumerate(now[j:k]) if l == lines[0])
            block = block_at(now, start)
            a = next((i for i in range(start - 1, -1, -1) if i not in mine and now[i].strip()), None)
            after = now[a] if a is not None and not BLOCK_LINE.match(now[a]) else ""
            rng = block_range(now, block)
            nth = sum(1 for i in range(rng[0] if rng else 0, (a or 0) + 1) if now[i] == after) if after else 0
            chunks.append({"block": block, "after": after, "nth": nth, "lines": lines})
        j = k
    return chunks


def place_chunks(lines: list[str], chunks: list[dict]) -> list[str]:
    """Put captain chunks into a freshly built page.

    A chunk goes after the same occurrence of its agent line in its block, else at the end of
    the block. A chunk on a block no longer on the page goes at the end, under its block marker.
    """
    places, gone = [], []
    for order, c in enumerate(chunks):
        rng = block_range(lines, c["block"])
        if rng is None and c["block"] == "top":
            rng = (0, block_range(lines, "top")[0] if block_range(lines, "top") else len(lines))
        if rng is None:
            gone.append(c)
            continue
        start, end = rng
        at = None
        if not c["after"]:
            at = start + 1 if BLOCK_LINE.match(lines[start]) else start
        else:
            seen = 0
            for i in range(start, end):
                if same_agent_line(lines[i], c["after"]):
                    seen += 1
                    if seen == c["nth"]:
                        at = i + 1
                        break
        if at is None:
            at = end
            while at > start + 1 and not lines[at - 1].strip():
                at -= 1
        places.append((at, order, c["lines"]))
    out = list(lines)
    for at, _, new in sorted(places, reverse=True):
        pad_before = [""] if at > 0 and out[at - 1].strip() and not BLOCK_LINE.match(out[at - 1]) else []
        pad_after = [""] if at < len(out) and out[at].strip() else []
        out[at:at] = pad_before + new + pad_after
    if gone:
        out += ["", GONE]
        for c in gone:
            out += ["", f"<!-- block: {c['block']} -->"] + c["lines"]
    return out
