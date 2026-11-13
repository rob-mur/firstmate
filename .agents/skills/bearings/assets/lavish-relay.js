/* lavish-relay.js - lets a page shown inside the bearings board talk to its agent.
 *
 * bin/fm-board-page.sh copies this file next to every board page, and the page
 * loads it before its own script. Shown standalone in its own Lavish tab, the
 * page already has Lavish's window.lavish and this file does nothing. Shown in
 * place inside the board, the page is a nested frame Lavish does not equip, so
 * this file gives it the same three calls and passes each one to the board,
 * which queues it on the board's own Lavish session for the page's agent.
 * bin/fm-board-page.sh's header owns the contract.
 */
(function () {
  'use strict';
  if (window.lavish || window.parent === window) return;
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
    try {
      window.parent.postMessage({ type: type, prompt: prompt == null ? '' : String(prompt), opts: keep }, '*');
    } catch (e) { /* a board that is gone has nothing to receive */ }
  }
  window.lavish = {
    queuePrompt: function (prompt, opts) { post('fm-board-page:queuePrompt', prompt, opts); },
    sendQueuedPrompts: function () { post('fm-board-page:sendQueuedPrompts', ''); },
    endSession: function () { post('fm-board-page:endPage', ''); }
  };
}());
