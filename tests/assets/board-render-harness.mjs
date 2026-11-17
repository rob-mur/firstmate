// Render a built bearings board's shipped script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// The payload is read from the bearings-board.data.js file the build writes
// beside the page, the way the page's own <script src> loads it.
// Prints one JSON document:
//   { stats:[{n,label}], waiting:{shown,rows}, open_mrs:{shown,rows:[{text,links}]},
//     captains_call:[text], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], call:[{key,links:[{href,text,action}],
//     pages:[{page,text}],notes:[text],options:[{value,label,aside}],
//     answer_box:null|{tag,name,label,placeholder,before_aside}}],
//     empty, more, error }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      contains: (c) => this.className.split(/\s+/).includes(c),
      toggle: (c, force) => {
        const classes = new Set(this.className.split(/\s+/).filter(Boolean));
        const enabled = force ?? !classes.has(c);
        if (enabled) classes.add(c); else classes.delete(c);
        this.className = [...classes].join(" ");
        return enabled;
      },
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) {
    if (n.parentNode) n.parentNode.removeChild(n);
    n.parentNode = this; this.children.push(n); return n;
  }
  removeChild(n) { const i = this.children.indexOf(n); if (i >= 0) this.children.splice(i, 1); n.parentNode = null; return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener() {}
  findAll(pred) {
    const out = [];
    const walk = (n) => { for (const c of n.children) { if (pred(c)) out.push(c); walk(c); } };
    walk(this);
    return out;
  }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();

globalThis.document = {
  createElement: (tag) => new Node(tag),
  addEventListener() {},
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
globalThis.window = { addEventListener() {} };
globalThis.TextEncoder = TextEncoder;
// The page polls its data file for live updates; one render needs no polling.
globalThis.setInterval = () => 0;
let dataSource = "";
try { dataSource = readFileSync(process.argv[2].replace(/\.html$/, ".data.js"), "utf8"); } catch { /* no data file */ }
if (dataSource) new Function(dataSource)();

// A built page loads its code from bearings-board.app.js beside it; the bare
// template carries the same code inline.
const script = html.includes("<script>")
  ? html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"))
  : readFileSync(process.argv[2].replace(/\.html$/, ".app.js"), "utf8");
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);
const captains_call = (byId.get("bb-call") || new Node("div")).children
  .filter((n) => n.className.split(/\s+/).includes("bb-decision"))
  .map((n) => n.textContent);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
// Each Captain's Call card is the container holding its answer form; its links are
// the anchors the card renders, with the href the page would navigate to.
const call = (byId.get("bb-call") || new Node("div")).children.map((card) => ({
  key: card.findAll((n) => n.attributes["data-lavish-question"] != null)
    .map((n) => n.attributes["data-lavish-question"])[0] ?? "",
  links: card.findAll((n) => n.tagName === "a")
    .map((a) => ({ href: a.href ?? "", text: a.textContent,
      action: a.attributes["data-lavish-action"] != null })),
  // In-place page buttons, by the board page each opens, and the plain notes a
  // card shows for a page the board does not have.
  pages: card.findAll((n) => n.tagName === "button" && n.attributes["data-board-page"] != null)
    .map((b) => ({ page: b.attributes["data-board-page"], text: b.textContent })),
  notes: card.findAll((n) => n.className.includes("bb-decision__link--note"))
    .map((n) => n.textContent),
  // Each answer choice in render order, its full label, and whether it sits
  // in the separate group apart from the decision's own options.
  options: card.findAll((n) => n.className.split(/\s+/).includes("bb-opts"))
    .flatMap((g) => g.children.map((lab) => ({
      value: lab.children.find((c) => c.tagName === "input")?.value ?? "",
      label: lab.findAll((c) => c.className.includes("bb-opt__label"))[0]?.textContent ?? "",
      aside: g.className.includes("bb-opts--aside"),
    }))),
  // The free-text answer box: what it is, the label shown with it, and whether
  // it sits above the separate reconcile group.
  answer_box: (() => {
    const form = card.findAll((n) => n.tagName === "form")[0];
    const box = card.findAll((n) => n.className.split(/\s+/).includes("bb-freeform"))[0];
    if (!form || !box) return null;
    const wrap = form.children.find((c) => c === box || c.findAll((n) => n === box).length > 0);
    const asideAt = form.children.findIndex((c) => c.className.split(/\s+/).includes("bb-opts--aside"));
    return {
      tag: box.tagName, name: box.name ?? "", placeholder: box.placeholder ?? "",
      label: wrap && wrap !== box ? wrap.findAll((n) => n.className.includes("bb-answer__label"))[0]?.textContent ?? "" : "",
      before_aside: asideAt < 0 || form.children.indexOf(wrap) < asideAt,
    };
  })(),
}));
const waitingNode = byId.get("bb-waiting");
const waiting = {
  shown: waitingNode ? waitingNode.hidden === false : false,
  rows: (byId.get("bb-waiting-list") || new Node("div")).children.map((r) => r.textContent),
};
// The captain's open MRs no task covers: each row's text and its links.
const openMrsNode = byId.get("bb-open-mrs");
const open_mrs = {
  shown: openMrsNode ? openMrsNode.hidden === false : false,
  rows: (byId.get("bb-open-mrs-list") || new Node("div")).children.map((r) => ({
    text: r.textContent,
    links: r.findAll((n) => n.tagName === "a").map((a) => ({ href: a.href ?? "", text: a.textContent })),
  })),
};
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

process.stdout.write(
  JSON.stringify({ stats, waiting, open_mrs, captains_call, underway, charted, call, empty, more, error: errorText }) + "\n");
