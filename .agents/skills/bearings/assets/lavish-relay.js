/* lavish-relay.js - lets a page shown inside the bearings board talk to its agent.
 *
 * bin/fm-board-page.sh copies this file next to every board page, and the page
 * loads it before its own script. Shown standalone in its own Lavish tab, the
 * page already has Lavish's window.lavish and this file does nothing. Shown in
 * place inside the board, the page is a nested frame Lavish does not equip, so
 * this file gives it the same three calls and passes each one to the board,
 * which queues it on the board's own Lavish session for the page's agent, and
 * passes Esc up so the board can leave full screen.
 * Lavish's annotate mode cannot reach into this frame either, so while the
 * board says annotate is on, this file takes the clicks itself and passes each
 * note up as an annotation action for the page's agent.
 * A form the captain changed is queued through the page's own submit handler
 * before anything is sent, so answers are never left behind in the page.
 * bin/fm-board-page.sh's header owns the contract.
 */
(function () {
  'use strict';
  if (window.lavish || window.parent === window) return;
  function tell(msg) {
    try {
      window.parent.postMessage(msg, '*');
    } catch (e) { /* a board that is gone has nothing to receive */ }
  }
  function post(type, prompt, opts) {
    var o = opts || {};
    var keep = {};
    ['tag', 'text', 'data', 'queueKey', 'selector', 'uid'].forEach(function (k) {
      if (o[k] !== undefined) keep[k] = o[k];
    });
    /* An element cannot cross frames, so keep the one thing Lavish reads from
       it for queueing: a later answer to the same question replaces the
       earlier one. */
    if (keep.queueKey === undefined && o.element && o.element.closest) {
      var q = o.element.closest('[data-lavish-question]');
      if (q) keep.queueKey = 'question:' + q.getAttribute('data-lavish-question');
    }
    tell({ type: type, prompt: prompt == null ? '' : String(prompt), opts: keep });
  }
  window.lavish = {
    queuePrompt: function (prompt, opts) {
      formQueued(opts && opts.element);
      post('fm-board-page:queuePrompt', prompt, opts);
    },
    sendQueuedPrompts: function () {
      if (autoSubmitting) return;
      flushForms();
      post('fm-board-page:sendQueuedPrompts', '');
    },
    endSession: function () {
      if (autoSubmitting) return;
      flushForms();
      post('fm-board-page:endPage', '');
    }
  };

  /* CHANGED FORMS. A page form queues its answers only from its own submit
     button, while a note and Lavish's Send go straight through, so a captain
     who answered a form and then sent would lose every answer. A form the
     captain changes is therefore queued by firing a submit event at it, which
     runs the page's own handler and so queues under the page's own tag and
     queueKey, replacing any earlier answer. A dispatched submit event never
     submits the form, so this cannot reload the page. It happens before the
     relay passes on any send or end, when the captain has stopped changing
     the form for FLUSH_MS, when the pointer leaves the page, and when the page
     loses focus, so the answers are queued before Lavish's own Send, which
     sits outside the page, can be pressed. Any send or end the handler asks
     for while the relay runs it is dropped: only the captain sends. A form
     counts as queued when its handler calls queuePrompt while the submit
     event runs, or later with an element inside the form; a changed form
     that is not queued within GRACE_MS of its submit is flagged, in the page
     and to the board, until it is queued or reset. */
  var FLUSH_MS = 1000;
  var GRACE_MS = 500;
  var forms = [];
  var autoSubmitting = false;
  var submitting = null;
  var flushTimer = null;
  var warnBox = null;
  var toldUnsent = 0;
  function formRecord(form, add) {
    for (var i = 0; i < forms.length; i++) if (forms[i].form === form) return forms[i];
    if (!add) return null;
    var rec = { form: form, dirty: false, pending: false, unsent: false, grace: null };
    forms.push(rec);
    return rec;
  }
  function showUnsentForms() {
    var n = 0;
    forms.forEach(function (rec) { if (rec.unsent) n++; });
    if (n || warnBox) {
      ensureUi();
      if (!warnBox) {
        warnBox = document.createElement('div');
        warnBox.className = 'unsent';
        warnBox.setAttribute('role', 'status');
        root.appendChild(warnBox);
      }
      warnBox.textContent = n ? 'Changes in ' + (n === 1 ? 'a form' : n + ' forms') +
        ' on this page are not queued for the agent. Use the form\'s own button to queue them.' : '';
      warnBox.hidden = !n;
    }
    if (n !== toldUnsent) {
      toldUnsent = n;
      tell({ type: 'fm-board-page:formsUnsent', count: n });
    }
  }
  /* dirty: changed since the page last queued it; pending: the relay fired
     its submit and waits for the queue; unsent: flagged as not queued */
  function settle(rec) {
    if (rec.grace) { clearTimeout(rec.grace); rec.grace = null; }
    rec.dirty = false;
    rec.pending = false;
    rec.unsent = false;
  }
  function formQueued(el) {
    var changed = false;
    forms.forEach(function (rec) {
      var hit = rec.form === submitting || (!!el && el.nodeType === 1 && rec.form.contains(el));
      if (!hit || !(rec.dirty || rec.pending || rec.unsent)) return;
      settle(rec);
      changed = true;
    });
    if (changed) showUnsentForms();
  }
  function submitEvent(form) {
    var button = form.querySelector ? form.querySelector('button[type=submit],input[type=submit],button:not([type])') : null;
    if (typeof SubmitEvent === 'function') {
      try {
        return new SubmitEvent('submit', { bubbles: true, cancelable: true, submitter: button });
      } catch (e) { /* a submitter the browser will not take */ }
    }
    return new Event('submit', { bubbles: true, cancelable: true });
  }
  function flushForms() {
    if (flushTimer) { clearTimeout(flushTimer); flushTimer = null; }
    forms.slice().forEach(function (rec) {
      if (!rec.dirty) return;
      rec.dirty = false;
      var form = rec.form;
      if (!document.documentElement.contains(form)) { settle(rec); return; }
      if (form.checkValidity && !form.checkValidity()) { rec.unsent = true; return; }
      rec.pending = true;
      autoSubmitting = true;
      try {
        form.dispatchEvent(submitEvent(form));
      } catch (e) { /* the page's handler failed; the form stays unqueued */ }
      autoSubmitting = false;
      if (submitting === form) submitting = null;
      if (!rec.pending) return;
      /* a handler may wait before it queues */
      rec.grace = setTimeout(function () {
        rec.grace = null;
        if (!rec.pending) return;
        rec.pending = false;
        rec.unsent = true;
        showUnsentForms();
      }, GRACE_MS);
    });
    showUnsentForms();
  }
  function formChanged(ev) {
    var t = ev.target;
    if (inUi(ev) || !t || !t.form || t.form.nodeType !== 1) return;
    var rec = formRecord(t.form, true);
    rec.dirty = true;
    rec.pending = false;
    if (rec.grace) { clearTimeout(rec.grace); rec.grace = null; }
    if (flushTimer) clearTimeout(flushTimer);
    flushTimer = setTimeout(flushForms, FLUSH_MS);
  }
  document.addEventListener('input', formChanged, true);
  document.addEventListener('change', formChanged, true);
  document.addEventListener('reset', function (ev) {
    var rec = formRecord(ev.target, false);
    if (rec) { settle(rec); showUnsentForms(); }
  }, true);
  /* a submit, the captain's or the relay's, attributes the queuePrompt its
     handler makes to that form */
  document.addEventListener('submit', function (ev) {
    var form = ev.target;
    submitting = form;
    setTimeout(function () { if (submitting === form) submitting = null; }, 0);
  }, true);
  document.addEventListener('mouseout', function (ev) {
    if (!ev.relatedTarget) flushForms();
  }, true);
  window.addEventListener('blur', function () { flushForms(); });
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') flushForms();
  });
  /* Keys typed in the page stay in its frame, so pass Esc up for the board to
     leave full screen; a page that handles Esc itself prevents the default. */
  window.addEventListener('keydown', function (ev) {
    if (ev.key === 'Escape' && !ev.defaultPrevented) post('fm-board-page:escape', '');
  });

  /* ANNOTATE. Mirrors Lavish's own annotate mode: hover outlines an element,
     a click or a text selection opens a note card, Enter queues the note,
     Ctrl/Cmd+Enter queues and sends, Escape closes an empty card, and
     Ctrl/Cmd+I toggles the mode on the whole board. Controls, links marked
     data-lavish-action, and Ctrl/Cmd+click on a link keep working. */
  var annotateOn = false;
  var host = null;
  var root = null;
  var mark = null;
  var card = null;
  var target = null;
  var ignoreNextClick = false;
  var CONTROLS = "button,input,select,textarea,option,optgroup,label,summary,[contenteditable]:not([contenteditable='false'])";
  var WIDGETS = "[role='button'],[role='checkbox'],[role='combobox'],[role='menuitem'],[role='menuitemcheckbox'],[role='menuitemradio'],[role='option'],[role='radio'],[role='switch'],[role='tab'],[role='treeitem']";
  function elementOf(node) {
    return node && node.nodeType === 1 ? node : node && node.parentElement ? node.parentElement : null;
  }
  function skipped(el) {
    if (!el || !el.closest) return true;
    if (el === host || el.closest('[data-lavish-ui],[data-lavish-action]')) return true;
    if (el.closest(CONTROLS)) return true;
    var widget = el.closest(WIDGETS);
    if (!widget) return false;
    var link = el.closest('a[href]');
    return !(link && widget.contains(link));
  }
  function cssEscape(s) {
    return window.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, '\\$&');
  }
  /* the same selector Lavish records for an element in the board itself */
  function selector(el) {
    var parts = [];
    var node = el;
    while (node && node.nodeType === 1 && parts.length < 5) {
      var part = node.tagName.toLowerCase();
      if (node.id) {
        parts.unshift(part + '#' + cssEscape(node.id));
        break;
      }
      var up = node.parentElement;
      if (up) {
        var same = Array.prototype.filter.call(up.children, function (x) { return x.tagName === node.tagName; });
        if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')';
      }
      parts.unshift(part);
      node = up;
    }
    return parts.join(' > ');
  }
  function textOf(el) {
    return (el.innerText || el.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 240);
  }
  function ensureUi() {
    if (host) return;
    host = document.createElement('div');
    host.setAttribute('data-lavish-ui', '');
    host.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483647';
    root = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;
    var style = document.createElement('style');
    style.textContent =
      '.mark{position:fixed;outline:2px solid #f4c95d;outline-offset:2px;pointer-events:none;display:none}' +
      '.card{position:fixed;pointer-events:auto;width:280px;background:#1e1f24;color:#f2f2f2;border:1px solid #f4c95d;' +
      'border-radius:8px;padding:8px;font:13px system-ui,sans-serif;box-shadow:0 6px 24px rgba(0,0,0,.4)}' +
      '.card p{margin:0 0 6px;opacity:.8;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
      '.card textarea{box-sizing:border-box;width:100%;min-height:64px;font:inherit;resize:vertical}' +
      '.card div{display:flex;gap:6px;justify-content:flex-end;margin-top:6px}' +
      '.unsent{position:fixed;left:8px;right:8px;bottom:8px;pointer-events:auto;background:#1e1f24;color:#f2f2f2;' +
      'border:1px solid #f4c95d;border-radius:8px;padding:8px 12px;font:13px system-ui,sans-serif}' +
      '.unsent[hidden]{display:none}';
    root.appendChild(style);
    mark = document.createElement('div');
    mark.className = 'mark';
    root.appendChild(mark);
    document.documentElement.appendChild(host);
  }
  function outline(el) {
    ensureUi();
    if (!el) { mark.style.display = 'none'; return; }
    var r = el.getBoundingClientRect();
    mark.style.left = r.left + 'px';
    mark.style.top = r.top + 'px';
    mark.style.width = r.width + 'px';
    mark.style.height = r.height + 'px';
    mark.style.display = 'block';
  }
  function closeCard() {
    if (card && card.parentNode) card.parentNode.removeChild(card);
    card = null;
    target = null;
    if (mark) mark.style.display = 'none';
  }
  function queueNote(note, quote, send) {
    var el = target.el;
    var said = quote || textOf(el);
    var data = { selector: selector(el), tag: el.tagName.toLowerCase(), text: textOf(el) };
    if (el.id) data.id = el.id;
    if (quote) data.selection = quote;
    post('fm-board-page:queuePrompt', note, { tag: 'annotation', text: said, data: data });
    if (send) window.lavish.sendQueuedPrompts();
  }
  function openCard(el, quote) {
    closeCard();
    ensureUi();
    target = { el: el, quote: quote || '' };
    outline(el);
    card = document.createElement('div');
    card.className = 'card';
    card.setAttribute('role', 'dialog');
    card.setAttribute('aria-label', 'Annotation');
    var said = document.createElement('p');
    said.textContent = quote || textOf(el) || el.tagName.toLowerCase();
    var box = document.createElement('textarea');
    box.placeholder = 'Note for this page';
    var row = document.createElement('div');
    var cancel = document.createElement('button');
    cancel.type = 'button';
    cancel.textContent = 'Cancel';
    var queue = document.createElement('button');
    queue.type = 'button';
    queue.textContent = 'Queue';
    row.appendChild(cancel);
    row.appendChild(queue);
    card.appendChild(said);
    card.appendChild(box);
    card.appendChild(row);
    function submit(send) {
      var note = box.value.trim();
      if (!note || !target) return;
      queueNote(note, target.quote, send);
      closeCard();
    }
    queue.addEventListener('click', function () { submit(false); });
    cancel.addEventListener('click', closeCard);
    box.addEventListener('keydown', function (ev) {
      if (ev.key === 'Enter' && !ev.shiftKey) {
        ev.preventDefault();
        submit(ev.ctrlKey || ev.metaKey);
      } else if (ev.key === 'Escape' && !box.value.trim()) {
        ev.preventDefault();
        closeCard();
      }
    });
    var r = el.getBoundingClientRect();
    var top = r.bottom + 8;
    if (top + 140 > window.innerHeight) top = Math.max(8, r.top - 148);
    card.style.top = top + 'px';
    card.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 296)) + 'px';
    root.appendChild(card);
    box.focus();
  }
  function setAnnotate(on) {
    annotateOn = !!on;
    if (!annotateOn) closeCard();
  }
  function inUi(ev) {
    return !!host && (ev.target === host || host.contains(ev.target));
  }
  window.addEventListener('message', function (ev) {
    var d = ev && ev.data;
    if (ev.source !== window.parent || !d || d.type !== 'fm-board-page:annotate') return;
    setAnnotate(d.enabled);
  });
  document.addEventListener('keydown', function (ev) {
    if (ev.shiftKey || ev.altKey || !(ev.ctrlKey || ev.metaKey) || String(ev.key || '').toLowerCase() !== 'i') return;
    ev.preventDefault();
    post('fm-board-page:toggleAnnotate', '');
  }, true);
  document.addEventListener('mouseover', function (ev) {
    if (!annotateOn || card || inUi(ev)) return;
    var el = elementOf(ev.target);
    outline(skipped(el) ? null : el);
  }, true);
  document.addEventListener('mouseout', function () {
    if (annotateOn && !card && mark) mark.style.display = 'none';
  }, true);
  document.addEventListener('mouseup', function (ev) {
    var el = elementOf(ev.target);
    if (!annotateOn || inUi(ev) || skipped(el)) return;
    var sel = document.getSelection ? document.getSelection() : null;
    var quote = sel && !sel.isCollapsed ? String(sel).trim().replace(/\s+/g, ' ').slice(0, 240) : '';
    if (!quote) return;
    var anchor = elementOf(sel.getRangeAt(0).commonAncestorContainer) || el;
    ignoreNextClick = true;
    openCard(anchor, quote);
  }, true);
  document.addEventListener('click', function (ev) {
    var el = elementOf(ev.target);
    if (!annotateOn || inUi(ev) || skipped(el)) return;
    var follow = /Mac|iPhone|iPad/.test(navigator.platform || '') ? ev.metaKey : ev.ctrlKey;
    if (follow && el.closest('a[href]')) {
      ignoreNextClick = false;
      return;
    }
    ev.preventDefault();
    ev.stopPropagation();
    if (ignoreNextClick) {
      ignoreNextClick = false;
      return;
    }
    openCard(el, '');
  }, true);
}());
