// Drive a bearings board that a real Lavish server shows, in a real headless
// Chrome, and type into the form of a page shown in place inside it.
//
// usage: node board-page-drafts.mjs <chrome> <session-url> <profile-dir> <board.html> <page-dir> <steps>
//
// The board is the Lavish session's artifact frame and the page is a frame
// inside it, so every step reaches into the frame it needs. <steps> is a
// comma-separated list, run in order:
//   type      show the page's tab, then type an answer into the page's
//             textarea and pick its second radio, as the captain would, and
//             leave both unsent
//   rerender  rewrite the page's data file, the way a page's worker moves its
//             page on, and wait for the page to render its form again
//   reload    rewrite the board file, so Lavish reloads the board and every
//             page frame in it, and wait for the page to load again
//   refresh   reload the whole browser tab, and wait for the page again
//   view      record the view now (see below)
//   queue     show the page's tab and press the page's own Queue answer button
//   bar       record the board's notice under the page bar now (see below)
//   send      press Send to agent in that notice
//
// Prints one JSON object: {views:[...], bars:[...], tabs, answer, errors}.
// Each bar is {visible, text, send}: whether the notice shows, its text, and
// whether its Send to agent button shows. Each view is
// {answer, pick, load, renders, version}: the page textarea's text, the
// picked radio's value ("" when none), an id the page draws once per load,
// how many times the page rendered its form in this load, and the page data
// version on screen. tabs counts the page targets open at the end.
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

const [chromeBin, sessionUrl, profile, boardPath, pageDir, stepList] = process.argv.slice(2);
const steps = stepList.split(",").filter(Boolean);
const ANSWER = "half-written answer the captain has not sent";

const chrome = spawn(chromeBin, [
  "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`,
  "--no-first-run", "--no-default-browser-check", "--disable-gpu",
  "--window-size=1280,900", "about:blank",
], { stdio: "ignore" });

let sock;
function finish(code, out) {
  if (out) process.stdout.write(JSON.stringify(out) + "\n");
  try { sock?.close(); } catch { /* already closed */ }
  chrome.kill("SIGKILL");
  process.exit(code);
}
setTimeout(() => { process.stderr.write("board-page-drafts: timed out\n"); finish(1, { errors: ["timed out"] }); }, 120000).unref();

async function waitFor(fn, what, ms = 30000) {
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
const target = await waitFor(async () => (await pageTargets())[0], "the first tab");

sock = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((ok, no) => { sock.onopen = ok; sock.onerror = () => no(new Error("cannot reach the tab")); });
let seq = 0;
const pending = new Map();
// Every default script context of every frame, in this tab's own session
// ("") or in the session of a frame Chrome runs in a process of its own.
let contexts = [];
const send = (method, params = {}, sessionId = "") => new Promise((ok, no) => {
  const id = ++seq;
  pending.set(id, { ok, no });
  const msg = { id, method, params };
  if (sessionId) msg.sessionId = sessionId;
  sock.send(JSON.stringify(msg));
});
const AUTO = { autoAttach: true, waitForDebuggerOnStart: true, flatten: true };
sock.onmessage = (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id && pending.has(msg.id)) {
    const { ok, no } = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) no(new Error(msg.error.message)); else ok(msg.result);
    return;
  }
  const s = msg.sessionId || "";
  const p = msg.params || {};
  if (msg.method === "Runtime.executionContextCreated" && p.context.auxData?.isDefault) {
    contexts.push({ s, id: p.context.id });
  } else if (msg.method === "Runtime.executionContextDestroyed") {
    contexts = contexts.filter((c) => !(c.s === s && c.id === p.executionContextId));
  } else if (msg.method === "Runtime.executionContextsCleared") {
    contexts = contexts.filter((c) => c.s !== s);
  } else if (msg.method === "Target.attachedToTarget") {
    const child = p.sessionId;
    send("Runtime.enable", {}, child)
      .then(() => send("Target.setAutoAttach", AUTO, child))
      .catch(() => {})
      .finally(() => send("Runtime.runIfWaitingForDebugger", {}, child).catch(() => {}));
  } else if (msg.method === "Target.detachedFromTarget") {
    contexts = contexts.filter((c) => c.s !== p.sessionId);
  }
};

// Evaluate expr in the first frame whose address contains `where`, or
// return undefined when no such frame is loaded yet.
async function inFrame(where, expr) {
  for (const c of contexts.slice()) {
    try {
      const href = await send("Runtime.evaluate", { expression: "location.href", contextId: c.id, returnByValue: true }, c.s);
      if (!String(href.result.value || "").includes(where)) continue;
      const r = await send("Runtime.evaluate", { expression: expr, contextId: c.id, returnByValue: true, awaitPromise: true }, c.s);
      if (r.exceptionDetails) throw new Error(`frame script failed in ${where}: ${r.exceptionDetails.exception?.description || r.exceptionDetails.text}`);
      return r.result.value;
    } catch (e) {
      if (/frame script failed/.test(e.message)) throw e;
      /* a context that went away mid-call */
    }
  }
  return undefined;
}

const PAGE = "/pages/drafts-page/page.html";
const BOARD = "/index.html";
const pageReady = () => inFrame(PAGE, "!!document.querySelector('form textarea') && window.pageLoad || ''");
const view = () => inFrame(PAGE, `(() => {
  const t = document.querySelector('form textarea');
  const r = document.querySelector('form input[type=radio]:checked');
  return { answer: t ? t.value : null, pick: r ? r.value : "", load: window.pageLoad,
    renders: window.pageRenders, version: window.pageVersion };
})()`);

const errors = [];
try {
  await send("Runtime.enable");
  await send("Target.setAutoAttach", AUTO);
  await send("Page.enable");
  await send("Page.navigate", { url: sessionUrl });
  await waitFor(() => inFrame(BOARD, "!!document.querySelector('.bb-tab') && document.querySelectorAll('.bb-tab').length > 1"), "the board to show the page's tab");
  let load = await waitFor(pageReady, "the page to render its form");

  const showTab = () => inFrame(BOARD, `(() => {
    const tab = [...document.querySelectorAll('.bb-tab')].find((b) => b.textContent === 'Drafts page');
    tab.click();
  })()`);
  const views = [];
  const bars = [];
  const bar = () => inFrame(BOARD, `(() => {
    const n = document.getElementById('bb-page-unsent');
    const b = [...n.querySelectorAll('button')].find((x) => x.textContent === 'Send to agent');
    return { visible: n.classList.contains('is-visible') && getComputedStyle(n).display !== 'none',
      text: n.textContent, send: !!b && !b.hidden && getComputedStyle(b).display !== 'none' };
  })()`);
  let reloads = 0;
  for (const step of steps) {
    if (step === "type") {
      await showTab();
      // The captain types and picks: each keystroke is an input event on the
      // textarea, and the pick a click on the radio.
      await inFrame(PAGE, `(() => {
        const t = document.querySelector('form textarea');
        t.focus();
        for (const ch of ${JSON.stringify(ANSWER)}) {
          t.value += ch;
          t.dispatchEvent(new InputEvent('input', { bubbles: true, data: ch, inputType: 'insertText' }));
        }
        document.querySelectorAll('form input[type=radio]')[1].click();
        t.focus();
      })()`);
      await sleep(2500);
    } else if (step === "rerender") {
      const before = await view();
      const next = (before?.version || 0) + 1;
      writeFileSync(`${pageDir}/page.data.js`, `window.PAGE_DATA = { version: ${next}, question: "Round ${next}: which way?" };\n`);
      await waitFor(async () => (await view())?.version === next, "the page to render its new data");
      await sleep(1500);
    } else if (step === "reload" || step === "refresh") {
      if (step === "reload") appendFileSync(boardPath, `\n<!-- rewritten by the drafts guard ${++reloads} -->\n`);
      else await send("Page.reload", { ignoreCache: false });
      await waitFor(async () => { const now = await pageReady(); return now && now !== load ? now : ""; }, `the page to load again after a ${step}`);
      load = await pageReady();
      await sleep(3000);
    } else if (step === "view") {
      views.push(await view());
    } else if (step === "queue") {
      await showTab();
      await inFrame(PAGE, "document.querySelector('form button[type=submit]').click()");
      await sleep(1500);
    } else if (step === "bar") {
      bars.push(await bar());
    } else if (step === "send") {
      await inFrame(BOARD, `[...document.querySelectorAll('#bb-page-unsent button')]
        .find((x) => x.textContent === 'Send to agent').click()`);
      await sleep(2500);
    } else throw new Error(`unknown step ${step}`);
  }
  const tabs = (await pageTargets()).length;
  finish(0, { views, bars, tabs, answer: ANSWER, errors });
} catch (e) {
  errors.push(String(e.message || e));
  finish(1, { errors });
}
