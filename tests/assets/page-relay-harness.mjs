// Run a board page's lavish-relay.js inside a simulated board frame, under a
// small DOM shim with real capture and bubble event dispatch, so the relay's
// annotate mode and its handling of the page's forms can be asserted through
// the messages it posts to the board.
//
// Usage: node page-relay-harness.mjs <lavish-relay.js> [actions]
// The page is fixed: main#understand holds h2, p, p, div#answer-box, a button,
// a link marked data-lavish-action, a plain link, and a span inside a
// role=button widget, followed by three forms:
//   round  form#round: a q1 radio group (picked a) and a notes textarea; its
//          own submit handler queues tag round-answers, queueKey round, data
//          {q1, notes}, with the form as the element, like a board page does
//   quick  form#quick: one input; its handler queues tag quick and sends
//   plain  form#plain: one input and no handler that queues anything
// Name an element by its text: heading, first, second, answer, submit,
// action, link, widget. Timers run on a fake clock that only tick advances.
// Comma-separated actions run in order:
//   annotate:on|off   the board says annotate is on or off
//   stranger:on       another frame (not the board) says annotate is on
//   click:<name>      click that element; ctrl-click:<name> holds Ctrl
//   select:<name>     select that element's text, then release and click
//   type:<text>       type text into the open note card
//   key:<key>         press a key in the note card: Enter, ctrl+Enter,
//                     shift+Enter, Escape
//   hotkey            press Ctrl+I on the page
//   queue|cancel      press the card's Queue or Cancel button
//   pick:<value>      pick that q1 radio in form#round (a change event)
//   notes:<text>      type text into form#round's notes (an input event)
//   fill:<form>:<text> type text into the input of form#quick or form#plain
//   submitform:<form> the captain submits that form with its own button
//   reset:<form>      the page resets that form
//   tick:<ms>         advance the fake clock and run the timers now due
//   leave             the pointer leaves the page's frame
//   blur              the page's frame loses focus
// Prints { posted, card, prevented, pageClicks, warning, submits }: posted is
// every message the relay sent the board, card is the open card's quoted text
// or null, prevented lists the clicks the relay kept from the page,
// pageClicks the clicks the page's own handler saw, warning the text of the
// relay's notice of form changes not queued (null when hidden), and submits
// how many submit events each form's own handler saw, by form name.
import { readFileSync } from "node:fs";

const [, , relayPath, actionList = ""] = process.argv;

class Node {
  constructor(tag, attrs = {}, text = "") {
    this.nodeType = 1; this.tagName = tag.toUpperCase(); this.attributes = { ...attrs };
    this.children = []; this.parentNode = null; this.listeners = []; this._text = text;
    this.style = {}; this.className = ""; this.value = ""; this.type = ""; this.placeholder = "";
    this.shadowRoot = null; this.host = null; this.form = null; this.hidden = false;
  }
  dispatchEvent(ev) { return !dispatch(this, ev.type, { submitter: ev.submitter }).defaultPrevented; }
  checkValidity() { return true; }
  get id() { return this.attributes.id || ""; }
  get parentElement() { return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null; }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(""); }
  set textContent(v) { this._text = String(v); this.children = []; }
  get innerText() { return this.textContent; }
  appendChild(n) { if (n.parentNode) n.parentNode.removeChild(n); n.parentNode = this; this.children.push(n); return n; }
  removeChild(n) { const i = this.children.indexOf(n); if (i >= 0) this.children.splice(i, 1); n.parentNode = null; return n; }
  contains(n) { for (; n; n = n.parentNode) if (n === this) return true; return false; }
  getAttribute(k) { return k in this.attributes ? this.attributes[k] : null; }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  hasAttribute(k) { return k in this.attributes; }
  attachShadow() { this.shadowRoot = new Node("#shadow"); this.shadowRoot.nodeType = 11; this.shadowRoot.host = this; return this.shadowRoot; }
  addEventListener(type, fn, capture) { this.listeners.push({ type, fn, capture: !!capture }); }
  getBoundingClientRect() { return { left: 10, top: 10, right: 110, bottom: 30, width: 100, height: 20 }; }
  focus() { focused = this; }
  // One simple selector: tag, [attr], [attr='v'], :not([attr='v']), in any order.
  matchesOne(sel) {
    let rest = sel.trim();
    const not = rest.match(/:not\((.*)\)$/);
    if (not) { if (this.matchesOne(not[1])) return false; rest = rest.slice(0, not.index); }
    const tag = rest.match(/^[a-z][a-z0-9]*/);
    if (tag) { if (this.tagName !== tag[0].toUpperCase()) return false; rest = rest.slice(tag[0].length); }
    for (const m of rest.matchAll(/\[([\w-]+)(?:='([^']*)')?\]/g)) {
      if (!(m[1] in this.attributes)) return false;
      if (m[2] !== undefined && this.attributes[m[1]] !== m[2]) return false;
    }
    return true;
  }
  matches(sel) { return sel.split(",").some((s) => this.matchesOne(s)); }
  closest(sel) { for (let n = this; n && n.nodeType === 1; n = n.parentNode) if (n.matches(sel)) return n; return null; }
}

let focused = null;
let selection = null;
const html = new Node("html");
const body = html.appendChild(new Node("body"));
const main = body.appendChild(new Node("main", { id: "understand" }));
const named = {
  heading: main.appendChild(new Node("h2", {}, "Why this change")),
  first: main.appendChild(new Node("p", {}, "The first reason.")),
  second: main.appendChild(new Node("p", {}, "The   second\n reason, with spacing.")),
  answer: main.appendChild(new Node("div", { id: "answer-box" }, "Your answer goes here")),
  submit: main.appendChild(new Node("button", {}, "Submit")),
  action: main.appendChild(new Node("a", { href: "x.html", "data-lavish-action": "" }, "Open in place")),
  link: main.appendChild(new Node("a", { href: "y.html" }, "Read more")),
};
named.widget = main.appendChild(new Node("div", { role: "button" })).appendChild(new Node("span", {}, "Widget"));
function field(form, tag, attrs) { const n = form.appendChild(new Node(tag, attrs)); n.form = form; return n; }
const forms = {
  round: main.appendChild(new Node("form", { id: "round", "data-lavish-question": "round" })),
  quick: main.appendChild(new Node("form", { id: "quick" })),
  plain: main.appendChild(new Node("form", { id: "plain" })),
};
const q1 = ["a", "b"].map((v) => { const r = field(forms.round, "input", { name: "q1" }); r.value = v; r.checked = v === "a"; return r; });
const notes = field(forms.round, "textarea", { name: "notes" });
field(forms.round, "button", { type: "submit" }).textContent = "Queue all answers";
const inputs = { quick: field(forms.quick, "input", { name: "quick" }), plain: field(forms.plain, "input", { name: "plain" }) };
const submits = { round: 0, quick: 0, plain: 0 };

const docListeners = [];
const winListeners = [];
const posted = [];
const prevented = [];
const pageClicks = [];
const board = { postMessage: (data) => posted.push(data) };
const stranger = { postMessage() {} };
Object.defineProperty(globalThis, "navigator", { value: { platform: "Linux x86_64" }, configurable: true });
globalThis.window = {
  parent: board, innerWidth: 1000, innerHeight: 800, CSS: undefined,
  addEventListener: (type, fn) => winListeners.push({ type, fn }),
  setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms),
  clearTimeout: (id) => globalThis.clearTimeout(id),
};
globalThis.document = {
  documentElement: html, body,
  createElement: (tag) => new Node(tag),
  addEventListener: (type, fn, capture) => docListeners.push({ type, fn, capture: !!capture }),
  getSelection: () => selection,
};
// The page's own handler, which annotate mode must keep from seeing clicks.
body.addEventListener("click", (ev) => { pageClicks.push(name(ev.target)); });
// The pages' own form handlers, as a board page writes them.
forms.round.addEventListener("submit", (ev) => {
  submits.round++;
  ev.preventDefault();
  window.lavish.queuePrompt("answers", { tag: "round-answers", text: "Round answers", element: forms.round,
    queueKey: "round", data: { q1: q1.find((r) => r.checked).value, notes: notes.value } });
});
forms.quick.addEventListener("submit", (ev) => {
  submits.quick++;
  ev.preventDefault();
  window.lavish.queuePrompt(inputs.quick.value, { tag: "quick", element: forms.quick });
  window.lavish.sendQueuedPrompts();
});
forms.plain.addEventListener("submit", (ev) => { submits.plain++; ev.preventDefault(); });

// A fake clock: timers run only when tick advances past them.
let now = 0;
let timers = [];
let timerId = 0;
globalThis.setTimeout = (fn, ms) => { timers.push({ id: ++timerId, at: now + (ms || 0), fn }); return timerId; };
globalThis.clearTimeout = (id) => { timers = timers.filter((t) => t.id !== id); };
function tick(ms) {
  const end = now + ms;
  for (;;) {
    const due = timers.filter((t) => t.at <= end).sort((x, y) => x.at - y.at)[0];
    if (!due) break;
    timers = timers.filter((t) => t !== due);
    now = due.at;
    due.fn();
  }
  now = end;
}

function name(el) { return Object.keys(named).find((k) => named[k] === el) || el.tagName.toLowerCase(); }

// Capture from the document down, then bubble back up. A listener outside a
// shadow root sees the shadow host as the target, as in a browser.
function dispatch(target, type, init = {}) {
  const path = [];
  for (let n = target; n; n = n.parentNode || n.host) path.push(n);
  let stopped = false;
  const ev = {
    type, key: init.key || "", ctrlKey: !!init.ctrlKey, metaKey: false, shiftKey: !!init.shiftKey, altKey: false,
    defaultPrevented: false, target, relatedTarget: init.relatedTarget || null, submitter: init.submitter || null,
    preventDefault() { this.defaultPrevented = true; },
    stopPropagation() { stopped = true; },
  };
  const outside = (i) => { let t = target; for (let j = 0; j < i; j++) if (path[j].host) t = path[j].host; return t; };
  ev.target = outside(path.length);
  for (const l of docListeners) if (l.type === type && l.capture && !stopped) l.fn(ev);
  for (let i = path.length - 1; i >= 0 && !stopped; i--) {
    ev.target = outside(i);
    ev.currentTarget = path[i];
    for (const l of path[i].listeners) if (l.type === type && l.capture) l.fn(ev);
  }
  for (let i = 0; i < path.length && !stopped; i++) {
    ev.target = outside(i);
    ev.currentTarget = path[i];
    for (const l of path[i].listeners) if (l.type === type && !l.capture) l.fn(ev);
  }
  ev.target = outside(path.length);
  for (const l of docListeners) if (l.type === type && !l.capture && !stopped) l.fn(ev);
  return ev;
}

new Function(readFileSync(relayPath, "utf8"))();

const host = () => html.children.find((c) => c.attributes["data-lavish-ui"] !== undefined) || null;
const card = () => { const h = host(); return h && h.shadowRoot ? h.shadowRoot.children.find((c) => c.className === "card") || null : null; };
const cardButton = (label) => card().children[2].children.find((b) => b.textContent === label);
const message = (source, data) => { for (const l of winListeners) if (l.type === "message") l.fn({ source, data }); };
const warning = () => {
  const h = host();
  const box = h && h.shadowRoot ? h.shadowRoot.children.find((c) => c.className === "unsent") : null;
  return box && !box.hidden ? box.textContent : null;
};
const click = (el, init) => {
  const ev = dispatch(el, "click", init);
  if (ev.defaultPrevented) prevented.push(name(el));
};

for (const act of actionList.split(",").filter(Boolean)) {
  const cut = act.indexOf(":");
  const [verb, arg] = cut < 0 ? [act, ""] : [act.slice(0, cut), act.slice(cut + 1)];
  if (verb === "annotate") message(board, { type: "fm-board-page:annotate", enabled: arg === "on" });
  else if (verb === "stranger") message(stranger, { type: "fm-board-page:annotate", enabled: arg === "on" });
  else if (verb === "click") click(named[arg]);
  else if (verb === "ctrl-click") click(named[arg], { ctrlKey: true });
  else if (verb === "select") {
    const el = named[arg];
    selection = { isCollapsed: false, toString: () => el.textContent, getRangeAt: () => ({ commonAncestorContainer: el }) };
    dispatch(el, "mouseup");
    click(el);
    selection = null;
  } else if (verb === "type") focused.value = arg;
  else if (verb === "key") {
    const parts = arg.split("+");
    dispatch(focused, "keydown", { key: parts.pop(), ctrlKey: parts.includes("ctrl"), shiftKey: parts.includes("shift") });
  } else if (verb === "hotkey") dispatch(body, "keydown", { key: "i", ctrlKey: true });
  else if (verb === "queue") dispatch(cardButton("Queue"), "click");
  else if (verb === "cancel") dispatch(cardButton("Cancel"), "click");
  else if (verb === "pick") {
    const r = q1.find((x) => x.value === arg);
    q1.forEach((x) => { x.checked = x === r; });
    dispatch(r, "change");
  } else if (verb === "notes") {
    notes.value = arg;
    dispatch(notes, "input");
  } else if (verb === "fill") {
    const [form, text] = arg.split(":");
    inputs[form].value = text;
    dispatch(inputs[form], "input");
  } else if (verb === "submitform") dispatch(forms[arg], "submit");
  else if (verb === "reset") dispatch(forms[arg], "reset");
  else if (verb === "tick") tick(Number(arg));
  else if (verb === "leave") dispatch(html, "mouseout", { relatedTarget: null });
  else if (verb === "blur") { for (const l of winListeners) if (l.type === "blur") l.fn({ target: window }); }
  else throw new Error("unknown action " + act);
}
process.stdout.write(JSON.stringify({ posted, card: card() ? card().children[0].textContent : null, prevented, pageClicks,
  warning: warning(), submits }) + "\n");
