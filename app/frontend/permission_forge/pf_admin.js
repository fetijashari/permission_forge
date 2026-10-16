/*
 * PermissionForge admin UI — progressive enhancement only.
 *
 * Every flow works without this file: drawers and dialogs are real pages,
 * filters are links, forms post normally. This script only makes them
 * smoother (load pages into <dialog>, live search, change counters).
 * No globals, no inline handlers (CSP-safe); behaviour hangs off data-pf-*.
 */
(function () {
  'use strict';

  const root = document.documentElement;
  if (!root.classList.contains('pf-root')) return;
  root.classList.add('pf-js');

  const FRAGMENT_HEADER = 'X-PF-Fragment';

  // Replaces an element's content with a server-rendered fragment, using DOM
  // calls rather than an HTML-string property. This is not a sanitiser:
  // DOMParser keeps event-handler attributes and javascript: URLs just as the
  // HTML property would. What keeps them out is the server escaping every value
  // and the host's strict CSP; <script> elements parsed here never run.
  function setContent(el, html) {
    if (html === '' || html == null) { el.replaceChildren(); return; }
    el.replaceChildren(...new DOMParser().parseFromString(html, 'text/html').body.childNodes);
  }

  function $(sel, ctx) { return (ctx || document).querySelector(sel); }
  function $$(sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); }
  function on(type, sel, fn) {
    document.addEventListener(type, function (e) {
      const el = e.target && e.target.closest ? e.target.closest(sel) : null;
      if (el) fn(e, el);
    });
  }
  function debounce(fn, ms) {
    let t;
    return function () { const a = arguments, self = this; clearTimeout(t); t = setTimeout(function () { fn.apply(self, a); }, ms); };
  }
  function fmt(template, count) { return (template || '').replace('%{count}', count); }

  /* ------------------------------------------------ dialogs and drawers */
  let lastTrigger = null;

  function modalElement(kind) {
    const id = kind === 'drawer' ? 'pf-drawer' : 'pf-dialog';
    let el = document.getElementById(id);
    if (!el) {
      el = document.createElement('dialog');
      el.id = id;
      el.className = kind === 'drawer' ? 'pf-drawer' : 'pf-dialog';
      el.setAttribute('aria-modal', 'true');
      document.body.appendChild(el);
      el.addEventListener('click', function (e) { if (e.target === el) el.close(); });
      // The close event is dispatched asynchronously: if the dialog was
      // reopened with fresh content in the meantime (in-place refresh), keep it.
      el.addEventListener('close', function () {
        if (el.open) return;
        setContent(el, '');
        if (lastTrigger && document.contains(lastTrigger)) lastTrigger.focus();
      });
    }
    return el;
  }

  function openModal(url, kind, trigger) {
    if (typeof HTMLDialogElement === 'undefined') { window.location.href = url; return; }
    lastTrigger = trigger || null;
    fetch(url, { headers: { [FRAGMENT_HEADER]: '1', Accept: 'text/html' }, credentials: 'same-origin' })
      .then(function (res) { if (!res.ok) throw new Error(res.status); return res.text(); })
      .then(function (html) {
        $$('dialog[open]').forEach(function (d) { if (d.id === 'pf-dialog' || d.id === 'pf-drawer') d.close(); });
        const el = modalElement(kind);
        setContent(el, html);
        const role = $('[data-pf-role]', el);
        el.setAttribute('role', role ? role.getAttribute('data-pf-role') : 'dialog');
        if (kind !== 'drawer') el.classList.toggle('pf-dialog--wide', !!$('[data-pf-size="wide"]', el));
        const title = $('[data-pf-title]', el);
        if (title) { if (!title.id) title.id = el.id + '-title'; el.setAttribute('aria-labelledby', title.id); }
        el.showModal();
        enhance(el);
        // Not the form's out-of-sight default button, nor a hidden one: focus() on
        // those lands nowhere visible and the first real control never gets it.
        const focus = $('[autofocus]', el) || $('input:not([type=hidden]), select, textarea, button:not([hidden]):not([tabindex="-1"])', el);
        if (focus) focus.focus();
      })
      .catch(function () { window.location.href = url; });
  }

  on('click', 'a[data-pf-modal]', function (e, a) {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1) return;
    e.preventDefault();
    openModal(a.href, a.getAttribute('data-pf-modal'), a);
  });

  // GET forms marked data-pf-modal (e.g. "Revoke from selected") open their
  // confirmation page in a dialog.
  document.addEventListener('submit', function (e) {
    const form = e.target;
    if (!form.matches || !form.matches('form[data-pf-modal]') || form.closest('dialog')) return;
    if ((form.getAttribute('method') || 'get').toLowerCase() !== 'get') return;
    e.preventDefault();
    const data = new FormData(form);
    const action = form.getAttribute('action');
    openModal(action + (action.indexOf('?') < 0 ? '?' : '&') + new URLSearchParams(data).toString(),
              form.getAttribute('data-pf-modal'), e.submitter || null);
  });

  // Hands a submission back to the browser the way the user made it: pressing
  // the same button again keeps its name/value and formaction/formmethod, all
  // of which form.submit() drops. The flag lets it past the handlers below.
  function submitNatively(form, submitter) {
    // form.submit() fires no submit event, so the leave-page guard is dropped here.
    if (!submitter) { form._pfDirty = false; form.submit(); return; }
    form._pfNative = true;
    submitter.click();
    form._pfNative = false;
  }

  // Batched-edit forms (data-pf-review) show their "Review and save" page in a
  // dialog. A redirect (nothing changed) is followed as a normal navigation.
  document.addEventListener('submit', function (e) {
    const form = e.target;
    if (!form.matches || !form.matches('form[data-pf-review]') || typeof HTMLDialogElement === 'undefined' || form._pfNative) return;
    e.preventDefault();
    // The page stays, so the edits are still unsaved: re-arm the leave-page guard
    // that the form's own submit listener has just dropped. The dialog's form
    // drops it again when a save really happens.
    updateSavebar(form);
    // FormData(form) leaves out the pressed button, and the bulk "Set to"
    // buttons carry the chosen level in their name/value.
    const submitter = e.submitter;
    const body = new FormData(form);
    if (submitter && submitter.name) body.append(submitter.name, submitter.value);
    fetch(form.action, { method: 'POST', body: body, headers: { [FRAGMENT_HEADER]: '1' }, credentials: 'same-origin' })
      .then(function (res) {
        if (res.redirected) { form._pfDirty = false; window.location.href = res.url; return null; }
        return res.text();
      })
      .then(function (html) {
        if (html === null) return;
        const el = modalElement('dialog');
        setContent(el, html);
        el.classList.toggle('pf-dialog--wide', !!$('[data-pf-size="wide"]', el));
        el.setAttribute('role', 'dialog');
        el.showModal();
        enhance(el);
        const save = $('button[type=submit]', el);
        if (save) save.focus();
        $$('form', el).forEach(function (f) { f.addEventListener('submit', function () { form._pfDirty = false; }); });
      })
      .catch(function () { submitNatively(form, submitter); });
  });

  on('click', '[data-pf-close]', function (e, btn) {
    const dialog = btn.closest('dialog');
    if (dialog) { e.preventDefault(); dialog.close(); }
  });

  // GET submissions inside a dialog (person search, filters, formmethod=get
  // buttons) refresh the dialog in place instead of leaving the page.
  document.addEventListener('submit', function (e) {
    const form = e.target;
    const dialog = form.closest && form.closest('dialog.pf-dialog, dialog.pf-drawer');
    if (!dialog || form._pfNative) return;
    const submitter = e.submitter;
    const method = ((submitter && submitter.getAttribute('formmethod')) || form.getAttribute('method') || 'get').toLowerCase();
    if (method !== 'get' && submitter && submitter.hasAttribute('data-pf-stay')) {
      // POST that re-renders the same drawer (e.g. "Check names").
      e.preventDefault();
      const body = new FormData(form);
      if (submitter.name) body.append(submitter.name, submitter.value);
      fetch(submitter.getAttribute('formaction') || form.action, { method: 'POST', body: body, headers: { [FRAGMENT_HEADER]: '1' }, credentials: 'same-origin' })
        .then(function (r) { return r.text(); })
        .then(function (html) { setContent(dialog, html); enhance(dialog); })
        .catch(function () { submitNatively(form, submitter); });
      return;
    }
    if (method !== 'get') return;
    e.preventDefault();
    const action = (submitter && submitter.getAttribute('formaction')) || form.getAttribute('action');
    const data = new FormData(form);
    data.delete('authenticity_token'); data.delete('_method');
    if (submitter && submitter.name) data.append(submitter.name, submitter.value);
    const url = action + (action.indexOf('?') < 0 ? '?' : '&') + new URLSearchParams(data).toString();
    openModal(url, dialog.id === 'pf-drawer' ? 'drawer' : 'dialog', lastTrigger);
  });

  /* ------------------------------------------------------- close menus */
  document.addEventListener('click', function (e) {
    $$('details.pf-menu[open]').forEach(function (menu) { if (!menu.contains(e.target)) menu.removeAttribute('open'); });
  });
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape') return;
    $$('details.pf-menu[open]').forEach(function (menu) {
      menu.removeAttribute('open');
      const s = $('summary', menu); if (s) s.focus();
    });
  });

  /* ------------------------------------------------------------- toasts */
  function armToasts(ctx) {
    $$('.pf-toast', ctx).forEach(function (t) {
      if (t.getAttribute('data-pf-armed')) return;
      t.setAttribute('data-pf-armed', '1');
      setTimeout(function () { if (t.parentNode && !t.matches(':hover, :focus-within')) t.remove(); }, 6000);
    });
  }
  on('click', '[data-pf-dismiss]', function (e, btn) {
    const t = btn.closest('.pf-toast, [data-pf-dismissable]');
    if (t) { e.preventDefault(); t.remove(); }
  });

  /* --------------------------------------------------------- auto submit */
  on('change', '[data-pf-autosubmit]', function (e, el) {
    const form = el.form || el.closest('form');
    if (form && form.requestSubmit) form.requestSubmit(); else if (form) form.submit();
  });

  /* --------------------------------------------------------- live search */
  function liveSearch(input) {
    const form = input.form;
    const target = document.getElementById(input.getAttribute('data-pf-live'));
    if (!form || !target) return;
    const base = input.getAttribute('data-pf-live-url') || form.getAttribute('action') || window.location.pathname;
    let url = base;
    const data = new FormData(form); data.delete('authenticity_token'); data.delete('_method');
    const query = new URLSearchParams(data).toString();
    url += (url.indexOf('?') < 0 ? '?' : '&') + query;
    fetch(url, { headers: { [FRAGMENT_HEADER]: '1' }, credentials: 'same-origin' })
      .then(function (res) { return res.ok ? res.text() : Promise.reject(res.status); })
      .then(function (html) {
        const doc = new DOMParser().parseFromString(html, 'text/html');
        const fresh = doc.getElementById(target.id);
        if (fresh) { target.replaceChildren(...fresh.childNodes); enhance(target); }
        if (!input.closest('dialog') && !input.hasAttribute('data-pf-live-url') && window.history && history.replaceState) {
          history.replaceState(null, '', base + '?' + query);
        }
      })
      .catch(function () {});
  }
  const liveHandler = debounce(liveSearch, 200);
  on('input', 'input[data-pf-live]', function (e, input) { liveHandler(input); });

  /* --------------------------------------------------------------- copy */
  on('click', '[data-pf-copy]', function (e, btn) {
    e.preventDefault();
    const text = btn.getAttribute('data-pf-copy');
    const done = function () {
      const label = btn.getAttribute('data-pf-copied') || 'Copied';
      const prev = btn.textContent;
      btn.textContent = label;
      setTimeout(function () { btn.textContent = prev; }, 1600);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, function () {});
  });

  /* ------------------------------------------------- CRUD dependencies */
  // Within a [data-pf-crud] row: inputs with data-pf-requires="read_access edit_access"
  // are disabled (and shown as "Needs Read") while any required flag is off.
  function syncCrud(row) {
    const state = {};
    $$('input[type=checkbox][data-pf-flag]', row).forEach(function (i) { state[i.getAttribute('data-pf-flag')] = i.checked; });
    $$('input[type=checkbox][data-pf-requires]', row).forEach(function (input) {
      const needs = input.getAttribute('data-pf-requires').split(' ');
      const ok = needs.every(function (f) { return state[f] !== false; });
      const cell = input.closest('.pf-cell, .pf-scope-option');
      if (!ok && input.checked) { input.checked = false; state[input.getAttribute('data-pf-flag')] = false; }
      input.disabled = !ok || input.hasAttribute('data-pf-locked');
      if (cell) cell.setAttribute('data-pf-needs', ok ? 'false' : 'true');
    });
    const editOn = state.edit_access !== false && state.read_access !== false;
    const scope = row.getAttribute('data-pf-crud');
    if (scope) {
      $$('[data-pf-fields-of="' + scope + '"] input[type=radio][value=edit]').forEach(function (r) {
        if (r.hasAttribute('data-pf-locked')) return;
        r.disabled = !editOn;
        if (!editOn && r.checked) {
          const read = r.closest('[role=radiogroup]').querySelector('input[value=read]');
          if (read) { read.checked = true; read.dispatchEvent(new Event('change', { bubbles: true })); }
        }
      });
    }
  }
  on('change', '[data-pf-crud] input[type=checkbox]', function (e, input) {
    // Run twice: requirement chains (Modify All needs View All needs Read).
    const row = input.closest('[data-pf-crud]'); syncCrud(row); syncCrud(row);
  });

  /* ------------------------------------------------- unsaved changes */
  function snapshot(form) {
    const out = {};
    Array.prototype.slice.call(form.elements).forEach(function (el) {
      if (!el.name || el.type === 'hidden' || el.type === 'submit' || el.hasAttribute('data-pf-untracked')) return;
      if (el.type === 'checkbox' || el.type === 'radio') out[el.name + '|' + el.value] = el.checked;
      else out[el.name] = el.value;
    });
    return out;
  }
  function changedNames(form) {
    const now = snapshot(form), base = form._pfBase || {}, names = {};
    Object.keys(now).forEach(function (k) { if (now[k] !== base[k]) names[k.split('|')[0]] = true; });
    return Object.keys(names);
  }
  function updateSavebar(form) {
    const bar = document.getElementById(form.getAttribute('data-pf-track'));
    if (!bar) return;
    const names = changedNames(form);
    // Count logical changes: one per resource flag / field, not per radio.
    const count = names.length;
    bar.setAttribute('data-pf-dirty', count > 0 ? 'true' : 'false');
    const label = $('[data-pf-dirty-count]', bar);
    if (label) label.textContent = fmt(count === 1 ? label.getAttribute('data-pf-one') : label.getAttribute('data-pf-other'), count);
    form._pfDirty = count > 0;
  }
  function trackForm(form) {
    if (form._pfTracked) return;
    form._pfTracked = true;
    form._pfBase = snapshot(form);
    // Inputs may live outside the <form> (form="id"), so listen on the document.
    const refresh = function (e) { if (e.target.form === form) updateSavebar(form); };
    document.addEventListener('change', refresh);
    document.addEventListener('input', debounce(refresh, 150));
    form.addEventListener('submit', function () { form._pfDirty = false; });
    // A reset also unticks the bulk checkboxes (form="…"), so the bulk bar follows.
    form.addEventListener('reset', function () {
      setTimeout(function () { $$('[data-pf-crud]').forEach(syncCrud); $$('[data-pf-bulk]').forEach(syncBulk); updateSavebar(form); }, 0);
    });
    updateSavebar(form);
  }
  window.addEventListener('beforeunload', function (e) {
    const dirty = $$('form[data-pf-track]').some(function (f) { return f._pfDirty; });
    if (dirty) { e.preventDefault(); e.returnValue = ''; }
  });

  /* ------------------------------------------------- bulk selection */
  // The rows a bulk action can reach: shown (not filtered out) and not locked.
  function selectable(scope) {
    return $$('input[type=checkbox][data-pf-select]', scope).filter(function (b) { return !b.disabled && !b.closest('[hidden]'); });
  }
  function syncBulk(scope) {
    const boxes = selectable(scope);
    const picked = boxes.filter(function (b) { return b.checked; }).length;
    $$('[data-pf-bulk-bar]', scope).forEach(function (bar) {
      bar.hidden = picked === 0;
      const c = $('[data-pf-selected-count]', bar);
      if (c) c.textContent = fmt(picked === 1 ? c.getAttribute('data-pf-one') : c.getAttribute('data-pf-other'), picked);
    });
    const all = $('input[type=checkbox][data-pf-select-all]', scope);
    if (all) { all.checked = picked > 0 && picked === boxes.length; all.indeterminate = picked > 0 && picked < boxes.length; }
  }
  on('change', 'input[data-pf-select-all]', function (e, all) {
    const scope = all.closest('[data-pf-bulk]');
    selectable(scope).forEach(function (b) { b.checked = all.checked; });
    syncBulk(scope);
  });
  on('change', 'input[data-pf-select]', function (e, box) { syncBulk(box.closest('[data-pf-bulk]')); });

  /* ----------------------------------------------------------- why panel */
  on('click', 'a[data-pf-why]', function (e, a) {
    const key = a.getAttribute('data-pf-why');
    const item = document.getElementById('pf-why-' + key);
    if (!item) return;
    e.preventDefault();
    $$('.pf-why-item').forEach(function (i) { i.removeAttribute('data-pf-active'); });
    $$('[data-pf-why][aria-current]').forEach(function (i) { i.removeAttribute('aria-current'); });
    const empty = $('[data-pf-why-empty]'); if (empty) empty.hidden = true;
    item.setAttribute('data-pf-active', 'true');
    a.setAttribute('aria-current', 'true');
    if (window.history && history.replaceState) {
      const url = new URL(window.location.href); url.searchParams.set('why', key); history.replaceState(null, '', url);
    }
  });

  /* ------------------------------------------------- in-place toggles */
  // <a data-pf-toggle="id" href="?open[]=…"> expands a region without a reload.
  on('click', 'a[data-pf-toggle]', function (e, a) {
    const region = document.getElementById(a.getAttribute('data-pf-toggle'));
    if (!region) return;
    e.preventDefault();
    region.hidden = !region.hidden;
    a.setAttribute('aria-expanded', region.hidden ? 'false' : 'true');
    const icon = $('.pf-disclosure', a);
    if (icon) icon.classList.toggle('pf-disclosure--open', !region.hidden);
  });

  /* ------------------------------------------------------ mask preview */
  on('change', 'select[data-pf-mask-select]', function (e, select) {
    const scope = select.closest('[data-pf-mask-scope]') || document;
    $$('[data-pf-mask-preview]', scope).forEach(function (p) { p.hidden = p.getAttribute('data-pf-mask-preview') !== select.value; });
  });

  /* ------------------------------------------- level-dependent panels */
  // Elements with data-pf-show-when="name=value1,value2" toggle with radio groups.
  function syncShowWhen(ctx) {
    $$('[data-pf-show-when]', ctx).forEach(function (el) {
      const spec = el.getAttribute('data-pf-show-when').split('=');
      const form = el.closest('form') || document;
      const checked = form.querySelector('[name="' + spec[0] + '"]:checked') || form.querySelector('select[name="' + spec[0] + '"]');
      const value = checked ? checked.value : '';
      el.hidden = spec[1].split(',').indexOf(value) < 0;
    });
  }
  document.addEventListener('change', function (e) { if (e.target.form || e.target.closest('form')) syncShowWhen(e.target.closest('form')); });

  /* -------------------------------------------- rule builder refresh */
  // Selects that change the shape of the form (relationship path, field)
  // re-render the builder server-side via the hidden refresh button.
  on('change', 'select[data-pf-refresh]', function (e, select) {
    const btn = select.form && select.form.querySelector('[data-pf-refresh-button]');
    if (!btn) return;
    const dialog = select.closest('dialog');
    if (dialog) {
      const fd = new FormData(select.form); fd.append(btn.name, btn.value);
      const url = btn.getAttribute('formaction') || select.form.action;
      fetch(url, { method: 'POST', body: fd, headers: { [FRAGMENT_HEADER]: '1' }, credentials: 'same-origin' })
        .then(function (r) { return r.text(); })
        .then(function (html) { setContent(dialog, html); enhance(dialog); })
        .catch(function () { btn.click(); });
    } else {
      btn.click();
    }
  });

  /* ------------------------------------------- rule builder preview */
  // The preview is the sentence the saved rule shows, rendered by the server
  // (the preview action, SentencesHelper): as the value, "the current user"
  // or "or empty" change, the panel's content is fetched again. Field and
  // operator changes re-render the whole builder (refresh above).
  function previewRule(form) {
    const panel = form && $('[data-pf-rule-preview]', form);
    if (!panel) return;
    const data = new FormData(form); data.delete('authenticity_token'); data.delete('_method');
    const base = panel.getAttribute('data-pf-rule-preview');
    const url = base + (base.indexOf('?') < 0 ? '?' : '&') + new URLSearchParams(data).toString();
    fetch(url, { headers: { [FRAGMENT_HEADER]: '1' }, credentials: 'same-origin' })
      .then(function (res) { return res.ok ? res.text() : Promise.reject(res.status); })
      .then(function (html) { setContent(panel, html); })
      .catch(function () {});
  }
  const previewHandler = debounce(previewRule, 250);
  const PREVIEW_INPUTS = '[name="rule[value]"], [name="rule[values_text]"], [name="rule[values][]"], [name="rule[value_from]"], ' +
    '[name="rule[value_to]"], [name="rule[current_user]"], [name="rule[include_nulls]"]';
  ['input', 'change'].forEach(function (type) {
    on(type, PREVIEW_INPUTS, function (e, el) { previewHandler(el.form); });
  });

  /* ------------------------------------------- typed confirmation */
  on('input', 'input[data-pf-confirm-match]', function (e, input) {
    const btn = input.form && input.form.querySelector('[data-pf-confirm-target]');
    if (btn) btn.disabled = input.value.trim() !== input.getAttribute('data-pf-confirm-match');
  });

  /* ------------------------------------------- client-side row filter */
  // Filters rows in place (keeps unsaved edits); the GET form is the no-JS path.
  // A row that is filtered out leaves the bulk selection, as it does on the
  // no-JS path: bulk buttons only ever act on rows that are shown.
  on('input', 'input[data-pf-row-filter]', function (e, input) {
    const box = document.getElementById(input.getAttribute('data-pf-row-filter'));
    if (!box) return;
    const q = input.value.trim().toLowerCase();
    $$('[data-pf-row-text]', box).forEach(function (row) {
      row.hidden = q !== '' && row.getAttribute('data-pf-row-text').indexOf(q) < 0;
      if (row.hidden) $$('input[data-pf-select]', row).forEach(function (b) { b.checked = false; });
    });
    const scope = box.closest('[data-pf-bulk]');
    if (scope) syncBulk(scope);
  });
  on('submit', 'form', function (e, form) {
    if (form.querySelector('input[data-pf-row-filter]')) e.preventDefault();
  });

  /* ------------------------------------------------- settings filter */
  on('input', 'input[data-pf-settings-filter]', function (e, input) {
    const q = input.value.trim().toLowerCase();
    $$('[data-pf-setting-row]').forEach(function (row) {
      row.hidden = q !== '' && row.getAttribute('data-pf-setting-row').indexOf(q) < 0;
    });
    $$('details[data-pf-setting-section]').forEach(function (sec) {
      const visible = $$('[data-pf-setting-row]', sec).some(function (r) { return !r.hidden; });
      sec.hidden = !visible;
      if (q !== '' && visible) sec.open = true;
    });
  });

  /* ------------------------------------------------------- enhance */
  function enhance(ctx) {
    armToasts(ctx);
    $$('form[data-pf-track]', ctx).forEach(trackForm);
    $$('[data-pf-crud]', ctx).forEach(function (row) { syncCrud(row); syncCrud(row); });
    $$('[data-pf-bulk]', ctx).forEach(syncBulk);
    $$('[data-pf-js-hide]', ctx).forEach(function (el) { el.hidden = true; });
    $$('[data-pf-js-show]', ctx).forEach(function (el) { el.hidden = false; });
    $$('input[data-pf-confirm-match]', ctx).forEach(function (input) {
      const btn = input.form && input.form.querySelector('[data-pf-confirm-target]');
      if (btn) btn.disabled = input.value.trim() !== input.getAttribute('data-pf-confirm-match');
    });
    syncShowWhen(ctx);
    const focus = $('[data-pf-focus="true"]', ctx);
    if (focus && ctx === document) focus.scrollIntoView({ block: 'center' });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { enhance(document); });
  else enhance(document);
})();
