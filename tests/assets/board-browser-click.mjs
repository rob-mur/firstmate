// Drive a built bearings board in a real headless Chrome with real mouse
// clicks, so the browser's own hit-testing decides which element each click
// lands on. A click on an element that something else covers reaches the cover,
// exactly as it would for the captain.
//
// usage: node board-browser-click.mjs <chrome> <board.html> <profile-dir> <steps>
//
// <steps> is a comma-separated list, run in order:
//   go       press "Start answering" when the order step shows it
//   page     press the first in-place page button on the shown card
//   max      press the shown page's full screen button
//   home     press the bearings header
//   view     record the view now (see below)
//
// Prints one JSON object: {views:[...], reloads, tabs, errors}. Each view is
// {page, max, main, focus}: whether the page view is shown and full screen,
// whether the board's main view is shown, and the focused element's id ("" for
// the page body). reloads counts main-frame navigations after the first load,
// and tabs counts the page targets the browser has open at the end.
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { pathToFileURL } from "node:url";

const [chromeBin, boardPath, profile, stepList] = process.argv.slice(2);
const steps = stepList.split(",").filter(Boolean);

const chrome = spawn(chromeBin, [
  "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`,
  "--no-first-run", "--no-default-browser-check", "--disable-gpu",
  "--window-size=1280,800", "about:blank",
], { stdio: "ignore" });

let sock;
function finish(code, out) {
  if (out) process.stdout.write(JSON.stringify(out) + "\n");
  try { sock?.close(); } catch { /* already closed */ }
  chrome.kill("SIGKILL");
  process.exit(code);
}
setTimeout(() => { process.stderr.write("board-browser-click: timed out\n"); finish(1); }, 60000).unref();

async function waitFor(fn, what, ms = 20000) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error(`gave up waiting for ${what}`);
    await sleep(100);
  }
}

const portFile = `${profile}/DevToolsActivePort`;
const port = await waitFor(() => existsSync(portFile) && readFileSync(portFile, "utf8").split("\n")[0].trim(), "the debugging port");
const base = `http://127.0.0.1:${port}`;
const pageTargets = async () => (await (await fetch(`${base}/json/list`)).json()).filter((t) => t.type === "page");
const target = (await waitFor(async () => (await pageTargets())[0], "the first tab"));

sock = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((ok, no) => { sock.onopen = ok; sock.onerror = () => no(new Error("cannot reach the tab")); });
let seq = 0;
const pending = new Map();
const events = [];
sock.onmessage = (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id && pending.has(msg.id)) {
    const { ok, no } = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) no(new Error(msg.error.message)); else ok(msg.result);
  } else if (msg.method) events.push(msg);
};
const send = (method, params = {}) => new Promise((ok, no) => {
  const id = ++seq;
  pending.set(id, { ok, no });
  sock.send(JSON.stringify({ id, method, params }));
});
const evaluate = async (expr) => {
  const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(`page script failed: ${expr}`);
  return r.result.value;
};

const errors = [];
try {
  await send("Page.enable");
  await send("Runtime.enable");
  const frameTree = await send("Page.getFrameTree");
  const mainFrame = frameTree.frameTree.frame.id;
  await send("Page.navigate", { url: pathToFileURL(boardPath).href });
  await waitFor(() => events.some((e) => e.method === "Page.loadEventFired"), "the board to load");
  await waitFor(() => evaluate("!!document.querySelector('button[data-board-page]')"), "the board to render its cards");
  const navigationsAtLoad = events.filter((e) => e.method === "Page.frameNavigated" && e.params.frame.id === mainFrame).length;

  // Press an element the way the captain does: move to its centre and click
  // there, letting the browser decide what is under the pointer.
  const press = async (selector) => {
    const box = await evaluate(`(() => {
      const el = [...document.querySelectorAll(${JSON.stringify(selector)})].find((n) => n.getClientRects().length);
      if (!el) return null;
      el.scrollIntoView({ block: "nearest" });
      const r = el.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    })()`);
    if (!box) throw new Error(`nothing on screen matches ${selector}`);
    await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: box.x, y: box.y });
    await send("Input.dispatchMouseEvent", { type: "mousePressed", x: box.x, y: box.y, button: "left", clickCount: 1 });
    await send("Input.dispatchMouseEvent", { type: "mouseReleased", x: box.x, y: box.y, button: "left", clickCount: 1 });
    await sleep(150);
  };

  const views = [];
  for (const step of steps) {
    if (step === "go") {
      if (await evaluate("(() => { const b = document.getElementById('bb-order-go'); return !!b && !!b.getClientRects().length; })()")) await press("#bb-order-go");
    } else if (step === "page") await press("button[data-board-page]");
    else if (step === "max") await press("#bb-page-max");
    else if (step === "home") await press("#bb-brand");
    else if (step === "view") {
      views.push(await evaluate(`(() => {
        const pv = document.getElementById("bb-pageview");
        const act = document.activeElement;
        return { page: !pv.hidden, max: pv.classList.contains("is-max"),
          main: !document.querySelector(".bb-main").hidden,
          focus: act && act !== document.body ? (act.id || act.tagName.toLowerCase()) : "" };
      })()`));
    } else throw new Error(`unknown step ${step}`);
  }
  const reloads = events.filter((e) => e.method === "Page.frameNavigated" && e.params.frame.id === mainFrame).length - navigationsAtLoad;
  const tabs = (await pageTargets()).length;
  finish(0, { views, reloads, tabs, errors });
} catch (e) {
  errors.push(String(e.message || e));
  finish(1, { errors });
}
