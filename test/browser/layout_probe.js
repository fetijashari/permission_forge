#!/usr/bin/env node
// Layout at phone width, measured in a browser (plan class LY). Reads the
// screens the preview app prints (test/support/preview_app.rb: paths, error
// states, flows), renders each at every width in every locale under the
// system Chrome (channel: 'chrome', nothing downloaded) and fails a load when:
//   - the document scrolls sideways (documentElement.scrollWidth > clientWidth);
//   - a visible element's right edge passes the viewport outside a scroll
//     container that scrolls (content in a frame is reachable; content clipped
//     by overflow: hidden, or outside any frame, is not);
//   - a single-line input's placeholder is wider than its box;
//   - two sticky or fixed layers intersect (a toast over the savebar).
// Chrome lays out the content of a closed <details>: that content is skipped,
// then every details.pf-reason is opened once and the page measured again.
//
//   node test/browser/layout_probe.js --log tmp/browser/preview.log
//        [--widths 360,390,600,1024] [--locales en,sq,mk]
//        [--out tmp/browser/layout.json] [--shots tmp/browser]
//
// Exit status 1 on any failure, with a screenshot per failing load under
// --shots. The Minitest proxies (test/permission_forge/html/layout_lint_test.rb)
// are the required guards; this is the measurement (`browser` CI job).
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const args = Object.fromEntries(process.argv.slice(2).map((arg, index, all) => (arg.startsWith('--') ? [arg.slice(2), all[index + 1]] : null)).filter(Boolean));
const widths = (args.widths || '360,390,600,1024').split(',').map(Number);
const locales = (args.locales || 'en,sq,mk').split(',');
const shots = args.shots || null;
const out = args.out || null;

// The PREVIEW line of the preview app's log, once it is there.
const readPreview = async (file) => {
  const deadline = Date.now() + 180000;
  while (Date.now() < deadline) {
    if (fs.existsSync(file)) {
      const line = fs.readFileSync(file, 'utf8').split('\n').find((l) => l.startsWith('PREVIEW:'));
      if (line) return JSON.parse(line.slice('PREVIEW:'.length));
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`no PREVIEW line in ${file} after 180s`);
};

// Runs in the page. Returns the failures of the current layout.
const measure = (pass) => {
  const vw = document.documentElement.clientWidth;
  const sw = document.documentElement.scrollWidth;
  const failures = [];
  const describe = (el) => `${el.tagName.toLowerCase()}${el.id ? `#${el.id}` : ''}${el.className && typeof el.className === 'string' ? `.${el.className.trim().split(/\s+/).join('.')}` : ''}`;
  const chainOf = (el) => { const parts = []; for (let e = el; e && e !== document.body && parts.length < 6; e = e.parentElement) parts.push(describe(e)); return parts.join(' < '); };
  const closedContent = (el) => {
    for (let e = el.parentElement; e; e = e.parentElement) {
      if (e.tagName === 'DETAILS' && !e.open) { const summary = e.querySelector(':scope > summary'); if (!summary || !summary.contains(el)) return true; }
    }
    return false;
  };
  // Why an element whose right edge passes the viewport cannot be reached, or
  // null. Walking up: a frame that scrolls makes everything in it reachable
  // (what matters from there is the frame's own edge); a box that clips must
  // contain the element (text an ellipsis truncates on purpose is exempt); at
  // the top, the edge must be inside the viewport.
  const unreachable = (el, rect) => {
    let right = rect.right;
    for (let e = el.parentElement; e && e !== document.documentElement; e = e.parentElement) {
      const cs = getComputedStyle(e);
      const overflow = cs.overflowX;
      const box = e.getBoundingClientRect();
      if (overflow === 'auto' || overflow === 'scroll') {
        if (e.scrollWidth <= e.clientWidth && right > box.right + 1) return `cut off by ${describe(e)}, which does not scroll`;
        right = Math.min(right, box.right);
      } else if (overflow === 'hidden' || overflow === 'clip') {
        if (right > box.right + 1) return cs.textOverflow === 'ellipsis' ? null : `cut off by ${describe(e)} (overflow hidden)`;
        right = Math.min(right, box.right);
      }
    }
    return right > vw + 1 ? 'outside any scroll frame' : null;
  };
  if (sw > vw + 1) failures.push({ kind: 'document-overflow', detail: `the document scrolls sideways: scrollWidth ${sw} > ${vw}` });
  const layers = [];
  for (const el of document.querySelectorAll('body *')) {
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden' || closedContent(el)) continue;
    const rect = el.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) continue;
    if (cs.position === 'sticky' || cs.position === 'fixed') layers.push({ el, rect });
    if (cs.position !== 'fixed' && rect.right > vw + 1) {
      const why = unreachable(el, rect);
      const childPasses = [...el.children].some((child) => child.getBoundingClientRect().right > vw + 1);
      if (why && !childPasses) failures.push({ kind: 'unframed-edge', detail: `${chainOf(el)} ends at ${Math.round(rect.right)}px in a ${vw}px viewport, ${why}: ${(el.textContent || '').trim().slice(0, 40)}` });
    }
    if (el.tagName === 'INPUT' && el.placeholder) {
      const probe = document.createElement('span');
      probe.textContent = el.placeholder;
      probe.style.cssText = `position:absolute;visibility:hidden;white-space:nowrap;font:${cs.font};letter-spacing:${cs.letterSpacing}`;
      document.body.appendChild(probe);
      const textWidth = probe.getBoundingClientRect().width;
      probe.remove();
      const boxWidth = el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
      if (textWidth > boxWidth + 1) failures.push({ kind: 'clipped-placeholder', detail: `${describe(el)} placeholder ${Math.round(textWidth)}px wide in a ${Math.round(boxWidth)}px box: ${el.placeholder}` });
    }
  }
  for (let i = 0; i < layers.length; i++) {
    for (let j = i + 1; j < layers.length; j++) {
      const a = layers[i]; const b = layers[j];
      if (a.el.contains(b.el) || b.el.contains(a.el)) continue;
      const x = Math.min(a.rect.right, b.rect.right) - Math.max(a.rect.left, b.rect.left);
      const y = Math.min(a.rect.bottom, b.rect.bottom) - Math.max(a.rect.top, b.rect.top);
      if (x > 1 && y > 1) failures.push({ kind: 'sticky-intersection', detail: `${describe(a.el)} and ${describe(b.el)} overlap by ${Math.round(x)}×${Math.round(y)}px` });
    }
  }
  return failures.map((failure) => ({ ...failure, pass }));
};

const openReasons = () => {
  const reasons = document.querySelectorAll('details.pf-reason:not([open])');
  reasons.forEach((details) => { details.open = true; });
  return reasons.length;
};

// Submits a form the way a page would (same origin, the page's CSRF token).
const submitForm = ({ action, method, params, locale }) => {
  const form = document.createElement('form');
  form.method = 'post';
  form.action = action;
  const add = (name, value) => { const input = document.createElement('input'); input.type = 'hidden'; input.name = name; input.value = value; form.appendChild(input); };
  const token = document.querySelector('meta[name="csrf-token"]');
  if (token) add('authenticity_token', token.content);
  add('locale', locale);
  if (method !== 'post') add('_method', method);
  const flatten = (prefix, value) => {
    if (Array.isArray(value)) value.forEach((item) => flatten(`${prefix}[]`, item));
    else if (value && typeof value === 'object') Object.entries(value).forEach(([key, item]) => flatten(`${prefix}[${key}]`, item));
    else add(prefix, value == null ? '' : String(value));
  };
  Object.entries(params || {}).forEach(([key, value]) => flatten(key, value));
  document.body.appendChild(form);
  form.submit();
};

const query = (params) => {
  const pairs = [];
  const flatten = (prefix, value) => {
    if (Array.isArray(value)) value.forEach((item) => flatten(`${prefix}[]`, item));
    else if (value && typeof value === 'object') Object.entries(value).forEach(([key, item]) => flatten(`${prefix}[${key}]`, item));
    else pairs.push([prefix, value == null ? '' : String(value)]);
  };
  Object.entries(params || {}).forEach(([key, value]) => flatten(key, value));
  return new URLSearchParams(pairs).toString();
};

const slug = (text) => text.replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '').slice(0, 80);

(async () => {
  const preview = await readPreview(args.log || 'tmp/browser/preview.log');
  const { base } = preview;
  const requests = [
    ...preview.paths.map((p) => ({ label: `GET ${p}`, verb: 'get', path: p, params: {}, status: 200 })),
    ...preview.error_states.filter((s) => s.renders !== false).map((s) => ({ label: `${s.verb.toUpperCase()} ${s.path}`, ...s })),
    ...preview.flows.map((s) => ({ label: `${s.verb.toUpperCase()} ${s.path}`, ...s })),
  ];
  const browser = await chromium.launch({ channel: 'chrome' });
  const results = [];
  let loads = 0;
  if (shots) fs.mkdirSync(shots, { recursive: true });
  for (const locale of locales) {
    for (const width of widths) {
      const context = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 1 });
      const page = await context.newPage();
      let status = 0;
      page.on('response', (response) => { if (response.request().resourceType() === 'document' && response.frame() === page.mainFrame()) status = response.status(); });
      await page.goto(`${base}/?locale=${locale}`, { waitUntil: 'networkidle' });
      for (const request of requests) {
        loads += 1;
        const result = { locale, width, label: request.label, failures: [] };
        try {
          const joiner = request.path.includes('?') ? '&' : '?';
          if (request.verb === 'get') {
            const extra = query(request.params);
            await page.goto(`${base}${request.path}${joiner}locale=${locale}${extra ? `&${extra}` : ''}`, { waitUntil: 'networkidle' });
          } else {
            await Promise.all([
              page.waitForNavigation({ waitUntil: 'networkidle' }),
              page.evaluate(submitForm, { action: `${base}${request.path}`, method: request.verb, params: request.params, locale }),
            ]);
          }
          result.status = status;
          if (status !== request.status) result.failures.push({ kind: 'status', detail: `answered ${status}, want ${request.status}` });
          result.failures.push(...(await page.evaluate(measure, 'closed')));
          if (await page.evaluate(openReasons)) result.failures.push(...(await page.evaluate(measure, 'reasons-open')));
        } catch (error) {
          result.failures.push({ kind: 'error', detail: error.message.slice(0, 200) });
        }
        if (result.failures.length && shots) {
          result.screenshot = path.join(shots, `${locale}-${width}-${slug(request.label)}.png`);
          try { await page.screenshot({ path: result.screenshot }); } catch (_) { /* a navigation may be in flight */ }
        }
        results.push(result);
      }
      await context.close();
    }
  }
  await browser.close();
  const failing = results.filter((result) => result.failures.length);
  const byKind = {};
  for (const result of failing) for (const failure of result.failures) byKind[failure.kind] = (byKind[failure.kind] || 0) + 1;
  const summary = { loads, screens: requests.length, widths, locales, failingLoads: failing.length, byKind };
  if (out) { fs.mkdirSync(path.dirname(out), { recursive: true }); fs.writeFileSync(out, JSON.stringify({ summary, results }, null, 1)); }
  for (const result of failing) {
    console.log(`FAIL ${result.locale} ${result.width}px ${result.label}${result.screenshot ? ` (${result.screenshot})` : ''}`);
    for (const failure of result.failures) console.log(`  [${failure.pass || 'load'}] ${failure.kind}: ${failure.detail}`);
  }
  console.log(JSON.stringify(summary));
  process.exit(failing.length ? 1 : 0);
})().catch((error) => { console.error(error); process.exit(1); });
