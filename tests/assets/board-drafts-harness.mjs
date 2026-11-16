// Run a built bearings board's inline script under a minimal DOM shim, with a
// browser store and a simulated Lavish chrome that both outlive the run, so a
// rebuild-then-reload (or a refresh) can be asserted through the real template.
//
// Usage: node board-drafts-harness.mjs <built-board.html> <storage.json> [actions]
// The browser store is <storage.json>; the chrome's per-tab store (queued
// prompts and restored review state) is <storage.json>.session.json. Delete
// the session file to simulate a new tab. NO_STORAGE=1 makes localStorage throw
// like Lavish's sandboxed frame. Comma-separated actions run in order:
//   type[:<key>]    select the first option and type a note into every card,
//                   or only into that card
//   focus:<key>     put focus in that card's note box
//   blur            move focus off the page's controls
//   home            click the bearings header, which focuses it as a browser
//                   click focuses a button
//   run             run the shell command in FM_HARNESS_RUN (a rebuild while
//                   the page stays open)
//   poll            let the page's live-update poll run once
//   submit:<key>    submit that card's form
//   pick:<id>       tick a charted row's dispatch pick
//   dispatch        press the dispatch button
//   load            frame load: restore review state, then report queued anchors
//   send            the chrome sends every queued prompt, then reports anchors
//                   (the board's own send call does the same in ok mode and
//                   is counted in sends)
//   up:<key>        press the move-up button on that key's row in the order list
//   down:<key>      press the move-down button on that key's row
//   go              press "Start answering" on the order step
//   open:<key>      press that key's title in the order list to open its card
//   expand:<key>    press a waiting row ("waiting:<key>") to expand or
//                   collapse it in place
//                   or a card's context toggle ("card-context:<key>")
//   rowpage:<key>   press the first in-place page button in that row's details
//   note:<key>      type a note into that card without picking an option
//   tick            let pending timers (the debounced priority send) fire
//   reorder         press "Reorder" on the deck
//   page:<key>      press the first in-place page button on that key's card
//   max             press the shown page's full screen button
//   esc             press Esc on the board
//   pageesc         the shown page's relay passes up an Esc pressed inside it
//   snap            record the page frames now ({serial, src, parent, hidden}),
//                   so a later snap shows whether a frame was re-created or moved
//   annotate:on|off the chrome turns Lavish's annotate mode on or off
//   frameload:<id>  the in-place page <id> finishes loading in its frame
//   annotation:<id> the in-place page <id>'s relay passes up an annotation of
//                   its element p#why ("Why this change") with the note "unclear"
//   pageform:<id>   the in-place page <id>'s relay passes up its form's answer
//                   (tag round-answers, queueKey round, data {q1:"a"})
//   pagesend:<id>   the in-place page <id>'s relay asks to send the queue
//   formsunsent:<id>:<n> the in-place page <id>'s relay reports <n> changed
//                   forms it could not queue (0 when they are queued again)
//   unsentsend      press the send button in the shown page's unsent notice
//   pagetoggle:<id> the in-place page <id>'s relay asks to toggle annotate mode
//   stranger        an unknown frame passes up an annotation
//   chrome:<mode>   the simulated Lavish from now on: ok (queues and reports
//                   its anchors), drops (accepts the call but queues nothing
//                   and reports nothing, like a chrome that ignores a stale
//                   message), throws (the queue call throws), or gone (the
//                   page has no window.lavish); CHROME_MODE sets the start mode
//   retry:<key>     press "Queue again" in that card's error box; retry:priority
//                   and retry:page press the priority's and the page view's
//   wait            the board's own wait for Lavish's confirmation runs out
//                   (the same as tick: every pending timer fires)
// Pending timers fire after each chrome message and at the end of the run, in
// the order they were set. Like the real chrome, the simulated one reports its
// queued anchors after a queue call only when the set of anchors changed.
// The page's data file is read from beside <built-board.html> each time the
// page loads it, so a rebuild between polls is seen by the next poll.
// Prints { cards, storage, calls, queue, anchors, ids, order, stack, reloads,
//   opens, pageView, snaps, framePosts, keys, errors, boot, polls, rows, sends,
//   pageUnsent }; each card
//   also carries error {shown, text} from the box beside its answer, errors
//   has the priority's and the page view's boxes, pageUnsent is the page
//   view's notice of an answer queued but not sent ({shown, text, send}, send
//   being whether its send button shows), pageTabs maps each page tab's title
//   to whether it carries the unsent mark, boot is the load problem
//   the page shows while it waits for its data ({shown, text}), and polls
//   counts the page's live intervals; opens lists every url the
//   page asked to open elsewhere, framePosts every message the board sent
//   each page frame, keyed by page id, and keys every key press the board
//   dispatched to itself, and rows every waiting row that can
//   expand ({key, expanded, details}, details the shown detail text or null);
//   stack is the deck's counter text and whether its nav is hidden.
//   Lavish's own elements (ids starting "lavish-")
//   are absent unless the simulated chrome adds them.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { execSync } from "node:child_process";

const [, , boardPath, storagePath, actionList = ""] = process.argv;
const html = readFileSync(boardPath, "utf8");
const sessionPath = storagePath + ".session.json";

let nodeSeq = 0;
class Node {
  constructor(tag) {
    this.serial = ++nodeSeq; this.tagName = tag;
    // A frame's window, so a message can come from the page inside it.
    if (tag === "iframe") this.contentWindow = { frame: this.serial }; this.className = ""; this.children = []; this.attributes = {};
    this._text = ""; this.hidden = false; this.disabled = false; this.innerHTML = "";
    this.parentNode = null; this.type = ""; this.name = ""; this.value = ""; this.checked = false;
    this.listeners = {};
    this.classList = {
      add: (c) => { if (!this.classList.contains(c)) this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" "); },
      toggle: (c, force) => {
        const on = force ?? !this.classList.contains(c);
        if (on) this.classList.add(c); else this.classList.remove(c);
        return on;
      },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get textContent() { return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text; }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) {
    if (n.parentNode) n.parentNode.removeChild(n);
    n.parentNode = this; this.children.push(n); return n;
  }
  removeChild(n) { const i = this.children.indexOf(n); if (i >= 0) this.children.splice(i, 1); n.parentNode = null; return n; }
  insertBefore(n, ref) {
    if (!ref) return this.appendChild(n);
    if (n.parentNode) n.parentNode.removeChild(n);
    this.children.splice(this.children.indexOf(ref), 0, n); n.parentNode = this; return n;
  }
  replaceChild(n, old) {
    if (n.parentNode) n.parentNode.removeChild(n);
    this.children[this.children.indexOf(old)] = n; n.parentNode = this; old.parentNode = null; return old;
  }
  contains(n) { for (; n; n = n.parentNode) if (n === this) return true; return false; }
  getAttribute(k) { return k in this.attributes ? this.attributes[k] : null; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(t, fn) { (this.listeners[t] ||= []).push(fn); }
  fire(t) { for (const fn of this.listeners[t] || []) fn({ preventDefault() {} }); }
  blur() { if (document.activeElement === this) document.activeElement = document.body; }
  dispatchEvent(ev) { for (let n = this; n; n = ev.bubbles ? n.parentNode : null) for (const fn of n.listeners[ev.type] || []) fn(ev); return true; }
  matches(sel) {
    const checked = sel.endsWith(":checked");
    const base = checked ? sel.slice(0, -8) : sel;
    if (checked && !this.checked) return false;
    if (base.startsWith(".")) return this.className.split(/\s+/).includes(base.slice(1));
    const m = base.match(/^(\w+)(?:\[(\w+)=([\w-]+)\])?$/);
    return !!m && this.tagName === m[1] && (!m[2] || this[m[2]] === m[3]);
  }
  querySelectorAll(sel) {
    const out = [];
    const walk = (n) => { for (const c of n.children) { if (c.matches(sel)) out.push(c); walk(c); } };
    walk(this);
    return out;
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}

globalThis.Event = class { constructor(type, init = {}) { this.type = type; this.bubbles = !!init.bubbles; } };
globalThis.KeyboardEvent = class extends Event {
  constructor(type, init = {}) { super(type, init); this.key = init.key || ""; this.ctrlKey = !!init.ctrlKey; this.metaKey = !!init.metaKey; this.shiftKey = !!init.shiftKey; this.altKey = !!init.altKey; }
};

const byId = new Map();
// Any other selector the page asks for is one stable element per selector.
const bySel = new Map();
const dataPath = boardPath.replace(/\.html$/, ".data.js");
// A built page loads its code from bearings-board.app.js beside it; the bare
// template carries the same code inline.
const boardCode = (path, page) => page.includes("<script>")
  ? page.slice(page.indexOf("<script>") + 8, page.lastIndexOf("</script>"))
  : readFileSync(path.replace(/\.html$/, ".app.js"), "utf8");
// A data file that is cut short still "loads": the browser runs what arrived,
// which throws, and fires the script's load event anyway.
const loadData = () => {
  if (!existsSync(dataPath)) return;
  try { new Function(readFileSync(dataPath, "utf8"))(); } catch { /* a broken script sets nothing */ }
};
// Anything that would replace the whole page is recorded, never performed.
const reloads = [];
const opens = [];
const keys = [];
// An in-place page frame records what the board sends it, keyed by page id.
const framePosts = {};
const iframes = [];
const pageOf = (frame) => (String(frame.src).match(/^pages\/([^/]+)\/page\.html$/) || [])[1] || "";
// A script element added to the body loads its src from beside the board.
const body = new Node("body");
const bodyAppend = body.appendChild.bind(body);
body.appendChild = (n) => {
  bodyAppend(n);
  if (n.tagName === "script" && n.src) {
    if (n.src.split("?")[0] === "bearings-board.data.js" && existsSync(dataPath)) { loadData(); n.onload?.(); }
    else n.onerror?.();
  }
  return n;
};

// The selectors the simulated chrome reports follow Lavish's rule: "#<id>"
// for an element with an id, else a position ("pos:<n>" among the deck's
// forms), so an anchor without an id follows whatever sits at its position.
const findId = (id) => {
  if (byId.has(id)) return byId.get(id);
  const walk = (n) => { for (const c of n.children) { if (c.id === id) return c; const hit = walk(c); if (hit) return hit; } return null; };
  for (const root of byId.values()) { const hit = walk(root); if (hit) return hit; }
  return null;
};
const anchorFor = (el) => {
  if (!el) return "";
  if (el.id) return "#" + el.id;
  const i = (byId.get("bb-call")?.querySelectorAll("form") || []).indexOf(el);
  return i >= 0 ? "pos:" + i : "";
};
globalThis.document = {
  body,
  activeElement: body,
  write: () => reloads.push("document.write"),
  open: () => reloads.push("document.open"),
  createElement: (tag) => {
    const n = new Node(tag);
    if (tag === "iframe") {
      n.contentWindow = { postMessage: (data) => (framePosts[pageOf(n)] ||= []).push(data) };
      iframes.push(n);
    }
    return n;
  },
  querySelectorAll: (sel) => [...new Set([...byId.values()].map((n) => { while (n.parentNode) n = n.parentNode; return n; }))]
    .flatMap((root) => root.querySelectorAll(sel)),
  dispatchEvent: (ev) => { keys.push({ type: ev.type, key: ev.key, ctrlKey: ev.ctrlKey, metaKey: ev.metaKey }); return true; },
  getElementById: (id) => {
    if (id.startsWith("lavish-")) return null;
    if (!byId.has(id)) { const n = new Node("div"); n.id = id; new Node("div").appendChild(n); byId.set(id, n); }
    return byId.get(id);
  },
  querySelector: (sel) => {
    if (sel.startsWith("#")) return findId(sel.slice(1));
    if (sel.startsWith("pos:")) return (byId.get("bb-call")?.querySelectorAll("form") || [])[Number(sel.slice(4))] || null;
    if (!bySel.has(sel)) bySel.set(sel, new Node("div"));
    return bySel.get(sel);
  },
};

const store = existsSync(storagePath) ? JSON.parse(readFileSync(storagePath, "utf8")) : {};
const session = existsSync(sessionPath) ? JSON.parse(readFileSync(sessionPath, "utf8")) : { queue: {}, review: [] };
const listeners = [];
const keyListeners = [];
const calls = [];
const timers = [];
const parent = {};
let timerSeq = 0;
globalThis.setTimeout = (fn) => { const id = ++timerSeq; timers.push({ id, fn }); return id; };
globalThis.clearTimeout = (id) => { const i = timers.findIndex((t) => t.id === id); if (i >= 0) timers.splice(i, 1); };
const flush = () => { while (timers.length) timers.shift().fn(); };
const intervals = [];
globalThis.setInterval = (fn) => { const id = ++timerSeq; intervals.push({ id, fn }); return id; };
globalThis.clearInterval = (id) => { const i = intervals.findIndex((t) => t.id === id); if (i >= 0) intervals.splice(i, 1); };

globalThis.window = {
  parent,
  open: (url) => { opens.push(String(url)); return null; },
  location: { reload: () => reloads.push("location.reload"), assign: () => reloads.push("location.assign"), replace: () => reloads.push("location.replace") },
  addEventListener: (t, fn) => { if (t === "message") listeners.push(fn); if (t === "keydown") keyListeners.push(fn); },
  localStorage: process.env.NO_STORAGE
    ? { getItem() { throw new Error("SecurityError"); }, setItem() { throw new Error("SecurityError"); }, removeItem() { throw new Error("SecurityError"); } }
    : {
        getItem: (k) => (k in store ? store[k] : null),
        setItem: (k, v) => { store[k] = String(v); writeFileSync(storagePath, JSON.stringify(store)); },
        removeItem: (k) => { delete store[k]; writeFileSync(storagePath, JSON.stringify(store)); },
      },
};
// Lavish keys a queued prompt by the explicit queueKey, else by the anchoring
// element's question; the same key replaces the unsent entry.
let chromeMode = process.env.CHROME_MODE || "ok";
const dropped = [];
let sends = 0;
const lavish = {
  sendQueuedPrompts: () => {
    sends++;
    if (chromeMode !== "ok") return;
    session.queue = {};
    setTimeout(() => anchors(false));
  },
  queuePrompt: (prompt, opts) => {
    if (chromeMode === "throws") throw new Error("queue refused");
    const anchor = anchorFor(opts.element);
    const key = opts.queueKey !== undefined ? opts.queueKey : "question:" + opts.element.attributes["data-lavish-question"];
    const call = { key, anchor, prompt, tag: opts.tag, text: opts.text, data: opts.data };
    if (chromeMode === "drops") { dropped.push(call); return; }
    calls.push(call);
    session.queue[key] = { anchor, prompt };
    setTimeout(() => anchors(false));
  },
};
const setChrome = (mode) => { chromeMode = mode; window.lavish = mode === "gone" ? undefined : lavish; };
setChrome(chromeMode);
globalThis.FormData = class {
  constructor(form) { this.form = form; }
  get(name) {
    const els = this.form.querySelectorAll("input");
    const hit = name === "answer" ? els.find((e) => e.name === name && e.checked) : els.find((e) => e.name === name);
    return hit ? hit.value : null;
  }
};
globalThis.TextEncoder = TextEncoder;

loadData();
new Function(boardCode(boardPath, html))();

const post = (data) => { for (const fn of listeners) fn({ data, source: parent }); flush(); };
// A frame load or a send always reports; a queue call reports only a change
// from what the chrome last reported, which for a run that starts on an open
// page is the queue it starts with.
let reported = JSON.stringify(Object.values(session.queue).map((q) => q.anchor).sort());
const anchors = (always = true) => {
  const selectors = Object.values(session.queue).map((q) => q.anchor);
  const sig = JSON.stringify([...selectors].sort());
  if (!always && sig === reported) return;
  reported = sig;
  post({ type: "lavish:queuedAnchors", selectors });
};
// Lavish collects every control under a data-lavish-question scope.
const scopes = () => {
  const out = [];
  const walk = (n) => { for (const c of n.children) { if (c.attributes["data-lavish-question"]) out.push(c); walk(c); } };
  for (const id of ["bb-call", "bb-order"]) walk({ children: [byId.get(id)].filter(Boolean) });
  return out;
};
const controls = () => scopes().flatMap((scope) =>
  scope.querySelectorAll("input").map((el, index) => ({
    el, index, question: scope.attributes["data-lavish-question"],
    key: [scope.attributes["data-lavish-question"], el.name, el.type, el.type === "hidden" ? "" : el.value].join("|"),
  })));

// A board still waiting for its data has built none of its sections.
const get = (id) => byId.get(id) || new Node("div");
const forms = () => get("bb-call").querySelectorAll("form");
const frames = () => get("bb-pageframes").children;
const shownFrame = () => frames().find((f) => !f.hidden);
const snaps = [];
const expandable = () => [
  ...get("bb-order-list").children.map((r) => ({ key: r.attributes["data-order-key"], row: r })),
  ...get("bb-waiting-list").children.map((r) => ({ key: r.attributes["data-waiting-key"], row: r })),
].map(({ key, row }) => ({ key, button: row.querySelector(".bb-expand"), details: row.querySelector(".bb-row-details") }))
  .filter((r) => r.button);
// Each card's recorded context toggles in place under its links.
const cardContexts = () => forms().map((f) => ({
  key: "card-context:" + f.attributes["data-lavish-question"], card: f.parentNode.parentNode,
})).map(({ key, card }) => ({ key, button: card.querySelector(".bb-ctx-toggle"), details: card.querySelector(".bb-row-details") }))
  .filter((r) => r.button);
const allExpandable = () => [...expandable(), ...cardContexts()];
for (const act of actionList.split(",").filter(Boolean)) {
  const cut = act.indexOf(":");
  const [name, arg] = cut < 0 ? [act, undefined] : [act.slice(0, cut), act.slice(cut + 1)];
  if (name === "type") {
    for (const f of forms()) {
      if (arg !== undefined && f.attributes["data-lavish-question"] !== arg) continue;
      f.querySelector("input[type=radio]").checked = true;
      f.querySelector("input[name=note]").value = "typed " + f.attributes["data-lavish-question"];
      f.fire("input");
    }
  } else if (name === "submit") {
    forms().find((f) => f.attributes["data-lavish-question"] === arg).fire("submit");
  } else if (name === "load") {
    for (const f of session.review) {
      const hit = controls().find((c) => c.key === f.key) || controls().find((c) => c.question === f.question && c.index === f.index);
      if (!hit) continue;
      if (f.checked === null) hit.el.value = f.value; else hit.el.checked = f.checked;
    }
    post({ type: "lavish:restoreReviewState" });
    anchors();
  } else if (name === "up" || name === "down") {
    const row = byId.get("bb-order-list").children.find((r) => r.attributes["data-order-key"] === arg);
    row.querySelector(name === "up" ? ".bb-order__up" : ".bb-order__down").fire("click");
  } else if (name === "open") {
    const row = byId.get("bb-order-list").children.find((r) => r.attributes["data-order-key"] === arg);
    row.querySelector(".bb-order__open").fire("click");
  } else if (name === "expand") {
    allExpandable().find((r) => r.key === arg).button.fire("click");
  } else if (name === "rowpage") {
    allExpandable().find((r) => r.key === arg).details.querySelectorAll("button")
      .find((b) => b.attributes["data-board-page"] != null).fire("click");
  } else if (name === "note") {
    const f = forms().find((x) => x.attributes["data-lavish-question"] === arg);
    f.querySelector("input[name=note]").value = "noted " + arg;
    f.fire("input");
  } else if (name === "focus") {
    document.activeElement = forms().find((f) => f.attributes["data-lavish-question"] === arg).querySelector("input[name=note]");
  } else if (name === "blur") {
    document.activeElement = document.body;
  } else if (name === "run") {
    execSync(process.env.FM_HARNESS_RUN, { stdio: ["ignore", "ignore", "inherit"] });
  } else if (name === "poll") {
    for (const t of [...intervals]) if (intervals.includes(t)) t.fn();
    flush();
  } else if (name === "tick" || name === "wait") {
    flush();
  } else if (name === "chrome") {
    setChrome(arg);
  } else if (name === "retry") {
    const box = arg === "priority" ? byId.get("bb-priority-error") : arg === "page" ? byId.get("bb-page-error")
      : forms().find((f) => f.attributes["data-lavish-question"] === arg).querySelector(".bb-submit-error");
    box.querySelector("button").fire("click");
    flush();
  } else if (name === "go") {
    byId.get("bb-order-go").fire("click");
  } else if (name === "page") {
    const card = forms().find((f) => f.attributes["data-lavish-question"] === arg).parentNode.parentNode;
    card.querySelectorAll("button").find((b) => b.attributes["data-board-page"] != null).fire("click");
  } else if (name === "max") {
    byId.get("bb-page-max").fire("click");
  } else if (name === "esc") {
    for (const fn of keyListeners) fn({ key: "Escape", preventDefault() {} });
  } else if (name === "pageesc") {
    for (const fn of listeners) fn({ data: { type: "fm-board-page:escape", prompt: "", opts: {} }, source: shownFrame().contentWindow });
    flush();
  } else if (name === "snap") {
    snaps.push(frames().map((f) => ({ serial: f.serial, src: f.src, parent: f.parentNode?.id ?? "", hidden: f.hidden })));
  } else if (name === "reorder") {
    byId.get("bb-reorder").fire("click");
  } else if (name === "home") {
    document.activeElement = byId.get("bb-brand");
    byId.get("bb-brand").fire("click");
  } else if (name === "annotate") {
    post({ type: "lavish:setAnnotationMode", enabled: arg === "on" });
  } else if (name === "frameload") {
    iframes.find((f) => pageOf(f) === arg).fire("load");
  } else if (name === "unsentsend") {
    byId.get("bb-page-unsent").querySelector("button").fire("click");
    flush();
  } else if (name === "formsunsent") {
    const [id, n] = arg.split(":");
    const source = iframes.find((f) => pageOf(f) === id).contentWindow;
    for (const fn of listeners) fn({ data: { type: "fm-board-page:formsUnsent", count: Number(n) }, source });
    flush();
  } else if (["annotation", "pagetoggle", "stranger", "pageform", "pagesend"].includes(name)) {
    const source = name === "stranger" ? {} : iframes.find((f) => pageOf(f) === arg).contentWindow;
    const data = name === "pagetoggle" ? { type: "fm-board-page:toggleAnnotate", prompt: "", opts: {} }
      : name === "pagesend" ? { type: "fm-board-page:sendQueuedPrompts", prompt: "", opts: {} }
      : name === "pageform" ? { type: "fm-board-page:queuePrompt", prompt: "answers", opts: { tag: "round-answers",
          text: "Round answers", queueKey: "round", data: { q1: "a" } } }
      : { type: "fm-board-page:queuePrompt", prompt: "unclear", opts: { tag: "annotation", text: "Why this change",
          data: { selector: "p#why", id: "why", tag: "p", text: "Why this change" } } };
    for (const fn of listeners) fn({ data, source });
    flush();
  } else if (name === "send") {
    session.queue = {};
    anchors();
  }
}
flush();
// The chrome saves review state as the page changes; mirror its final shape.
session.review = controls().map((c) => ({
  key: c.key, index: c.index, question: c.question, value: c.el.value,
  checked: c.el.type === "checkbox" || c.el.type === "radio" ? c.el.checked : null,
}));
writeFileSync(sessionPath, JSON.stringify(session));

const errorOf = (box, textClass = ".bb-submit-error__text") => ({
  shown: !!box && box.classList.contains("is-visible"),
  text: box?.querySelector(textClass)?.textContent ?? "",
});
const loadNote = (bySel.get(".bb-main")?.children || []).find((c) => c.id === "bb-load-problem");
const cards = forms().map((f) => ({
  key: f.attributes["data-lavish-question"],
  selection: f.querySelectorAll("input").find((r) => r.type === "radio" && r.checked)?.value ?? "",
  note: f.querySelector("input[name=note]").value,
  queued: f.parentNode.parentNode.classList.contains("is-queued"),
  state: f.querySelectorAll("input").find((i) => i.name === "lavish-state")?.value ?? "",
  title: f.parentNode.parentNode.querySelector(".bb-decision__title")?.textContent ?? "",
  hidden: f.parentNode.parentNode.hidden,
  error: errorOf(f.querySelector(".bb-submit-error")),
}));
process.stdout.write(JSON.stringify({
  cards, storage: store, calls, queue: Object.keys(session.queue),
  anchors: Object.fromEntries(Object.entries(session.queue).map(([k, q]) => [k, q.anchor])),
  ids: forms().map((f) => f.id || ""),
  reloads,
  opens,
  pageView: {
    shown: !get("bb-pageview").hidden, title: get("bb-page-title").textContent,
    max: get("bb-pageview").classList.contains("is-max"),
    maxPressed: get("bb-page-max").getAttribute("aria-pressed"),
  },
  snaps,
  framePosts,
  keys,
  polls: intervals.length,
  dropped: dropped.length,
  errors: { priority: errorOf(get("bb-priority-error")), page: errorOf(get("bb-page-error")) },
  sends,
  pageUnsent: { ...errorOf(get("bb-page-unsent"), ".bb-page-unsent__text"),
    send: get("bb-page-unsent")?.querySelector("button")?.hidden === false },
  pageTabs: Object.fromEntries((get("bb-tabs")?.children || []).slice(1)
    .map((t) => [t.textContent, t.classList.contains("is-unsent")])),
  boot: { shown: !!loadNote, text: loadNote?.textContent ?? "" },
  sub: get("bb-call-sub").textContent,
  order: {
    stepShown: !get("bb-order").hidden,
    deckShown: !get("bb-callwrap").hidden,
    list: get("bb-order-list").children.map((r) => r.attributes["data-order-key"]),
    titles: get("bb-order-list").children.map((r) => r.children[1].children[0].textContent),
    reorderDisabled: get("bb-reorder").disabled,
  },
  stack: { count: get("bb-stack-count").textContent, navHidden: !!get("bb-stack-count").parentNode?.hidden },
  rows: allExpandable().map((r) => ({
    key: r.key, expanded: r.button.getAttribute("aria-expanded"),
    details: r.details && !r.details.hidden ? r.details.textContent : null,
  })),
}) + "\n");
