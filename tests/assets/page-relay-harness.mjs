// Run a board page's lavish-relay.js inside a simulated board frame, under a
// small DOM shim with real capture and bubble event dispatch, so the relay's
// annotate mode can be asserted through the messages it posts to the board.
//
// Usage: node page-relay-harness.mjs <lavish-relay.js> [actions]
// The page is fixed: main#understand holds h2, p, p, div#answer-box, a button,
// a link marked data-lavish-action, a plain link, and a span inside a
// role=button widget. Name an element by its text: heading, first, second,
// answer, submit, action, link, widget. Comma-separated actions run in order:
//   annotate:on|off   the board says annotate is on or off
//   stranger:on       another frame (not the board) says annotate is on
//   click:<name>      click that element; ctrl-click:<name> holds Ctrl
//   select:<name>     select that element's text, then release and click
//   type:<text>       type text into the open note card
//   key:<key>         press a key in the note card: Enter, ctrl+Enter,
//                     shift+Enter, Escape
//   hotkey            press Ctrl+I on the page
//   queue|cancel      press the card's Queue or Cancel button
// Prints { posted, card, prevented, pageClicks }: posted is every message the
// relay sent the board, card is the open card's quoted text or null,
// prevented lists the clicks the relay kept from the page, and pageClicks the
// clicks the page's own handler saw.
import { readFileSync } from "node:fs";

const [, , relayPath, actionList = ""] = process.argv;

class Node {
  constructor(tag, attrs = {}, text = "") {
    this.nodeType = 1; this.tagName = tag.toUpperCase(); this.attributes = { ...attrs };
    this.children = []; this.parentNode = null; this.listeners = []; this._text = text;
    this.style = {}; this.className = ""; this.value = ""; this.type = ""; this.placeholder = "";
    this.shadowRoot = null; this.host = null;
  }
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
};
globalThis.document = {
  documentElement: html, body,
  createElement: (tag) => new Node(tag),
  addEventListener: (type, fn, capture) => docListeners.push({ type, fn, capture: !!capture }),
  getSelection: () => selection,
};
// The page's own handler, which annotate mode must keep from seeing clicks.
body.addEventListener("click", (ev) => { pageClicks.push(name(ev.target)); });

function name(el) { return Object.keys(named).find((k) => named[k] === el) || el.tagName.toLowerCase(); }

// Capture from the document down, then bubble back up. A listener outside a
// shadow root sees the shadow host as the target, as in a browser.
function dispatch(target, type, init = {}) {
  const path = [];
  for (let n = target; n; n = n.parentNode || n.host) path.push(n);
  let stopped = false;
  const ev = {
    type, key: init.key || "", ctrlKey: !!init.ctrlKey, metaKey: false, shiftKey: !!init.shiftKey, altKey: false,
    defaultPrevented: false, target,
    preventDefault() { this.defaultPrevented = true; },
    stopPropagation() { stopped = true; },
  };
  const outside = (i) => { let t = target; for (let j = 0; j < i; j++) if (path[j].host) t = path[j].host; return t; };
  ev.target = outside(path.length);
  for (const l of docListeners) if (l.type === type && l.capture && !stopped) l.fn(ev);
  for (let i = path.length - 1; i >= 0 && !stopped; i--) {
    ev.target = outside(i);
    for (const l of path[i].listeners) if (l.type === type && l.capture) l.fn(ev);
  }
  for (let i = 0; i < path.length && !stopped; i++) {
    ev.target = outside(i);
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
  else throw new Error("unknown action " + act);
}
process.stdout.write(JSON.stringify({ posted, card: card() ? card().children[0].textContent : null, prevented, pageClicks }) + "\n");
