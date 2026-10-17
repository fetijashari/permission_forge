#!/usr/bin/env node
// The documentation's denial flows in a real browser, with Turbo (plan class
// DX). test/support/docs_app.rb --serve prints a DOCS: line (base URL, the
// people, their password); this drives the flows docs/row-level-rules.md
// "Handling Denials", docs/getting-started.md and docs/controller-actions.md
// "Callback order" describe, under the system Chrome (playwright-core,
// channel: 'chrome', nothing downloaded), and fails when:
//   - after Dave (no Permission Set) signs in, the 403 page is not shown in
//     the layout, or Reload does not land on / with it (the Turbo address
//     bar + SessionsController#new line), or Sign out does not land on the
//     sign-in form;
//   - a signed-out visit to the guarded root or the public index does not
//     end on the sign-in form after one redirect (a loop is ERR_TOO_MANY_REDIRECTS);
//   - Bob does not read his own customer masked, or opening Carol's does
//     not show the 403 page with the rule's message, or the public index
//     (resume_session ahead of the guard) does not show his rows.
//
//   node test/browser/docs_flows.spec.js --log tmp/browser/docs.log [--shots tmp/browser]
//
// Exit status 1 on any failure, with a screenshot per failing flow under
// --shots. The request-level scenarios of test/permission_forge/docs/
// doc_samples_test.rb are the required guard; this is where Turbo is seen.
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const args = Object.fromEntries(process.argv.slice(2).map((arg, index, all) => (arg.startsWith('--') ? [arg.slice(2), all[index + 1]] : null)).filter(Boolean));
const shots = args.shots || null;
const FORBIDDEN = 'You are not allowed to see this page';

// The DOCS line of the docs app's log, once it is there.
const readDocs = async (file) => {
  const deadline = Date.now() + 180000;
  while (Date.now() < deadline) {
    if (fs.existsSync(file)) {
      const line = fs.readFileSync(file, 'utf8').split('\n').find((l) => l.startsWith('DOCS:'));
      if (line) return JSON.parse(line.slice('DOCS:'.length));
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`no DOCS line in ${file} after 180s`);
};

const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

const pathOf = (page) => new URL(page.url()).pathname;

const signIn = async (page, docs, who) => {
  await page.goto(`${docs.base}/session/new`);
  await page.fill('input[name="email_address"]', docs.people[who]);
  await page.fill('input[name="password"]', docs.password);
  await page.click('input[type="submit"]');
};

const flows = {
  // Dave: the Turbo sign-in lands on the refused root, in the layout; Reload
  // stays on the 403 page at /; Sign out shows the form.
  async dave(page, docs) {
    await signIn(page, docs, 'dave');
    await page.getByRole('heading', { name: FORBIDDEN }).waitFor({ timeout: 10000 });
    assert(await page.locator('header#session').isVisible(), 'the 403 page is rendered in the layout (header present)');
    await page.reload();
    await page.getByRole('heading', { name: FORBIDDEN }).waitFor({ timeout: 10000 });
    assert(pathOf(page) === '/', `after Reload the address is / (got ${pathOf(page)})`);
    await page.getByRole('button', { name: 'Sign out' }).first().click();
    await page.waitForURL('**/session/new', { timeout: 10000 });
    assert(await page.locator('input[name="email_address"]').isVisible(), 'Sign out lands on the sign-in form');
  },

  // Signed out: the guarded root and the public index each redirect to the
  // form once (never ERR_TOO_MANY_REDIRECTS).
  async signedOut(page, docs) {
    for (const target of ['/', '/public']) {
      const response = await page.goto(`${docs.base}${target}`);
      assert(response && response.ok(), `${target} signed out ends on a page (${response && response.status()})`);
      assert(pathOf(page) === '/session/new', `${target} signed out lands on /session/new (got ${pathOf(page)})`);
    }
  },

  // Bob: his own customer masked on the root and on the public index; Carol's
  // customer refused in the layout with the rule's message.
  async bob(page, docs) {
    await signIn(page, docs, 'bob');
    await page.waitForURL(`${docs.base}/`, { timeout: 10000 });
    const root = await page.content();
    assert(root.includes('Acme') && !root.includes('acme@example.test'), 'Bob reads Acme with the email masked');
    assert(!root.includes('Globex'), "Bob does not read Carol's customers");
    await page.goto(`${docs.base}/customers/${docs.customers.Globex.id}`);
    await page.getByRole('heading', { name: FORBIDDEN }).waitFor({ timeout: 10000 });
    assert((await page.content()).includes('Only your own customers'), "the rule's message is on the 403 page");
    assert(pathOf(page) === `/customers/${docs.customers.Globex.id}`, 'the 403 page is rendered at the refused address');
    await page.goto(`${docs.base}/public`);
    const publicIndex = await page.content();
    assert(publicIndex.includes('Acme') && !publicIndex.includes('acme@example.test'), 'the public index resumes the session: Acme, masked');
  }
};

(async () => {
  const docs = await readDocs(args.log);
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const failures = [];
  for (const [name, flow] of Object.entries(flows)) {
    const context = await browser.newContext({ viewport: { width: 1024, height: 768 } });
    const page = await context.newPage();
    try {
      await flow(page, docs);
      console.log(`ok   ${name}`);
    } catch (error) {
      failures.push(`${name}: ${error.message} (at ${page.url()})`);
      console.log(`FAIL ${name}: ${error.message}`);
      if (shots) {
        fs.mkdirSync(shots, { recursive: true });
        await page.screenshot({ path: path.join(shots, `docs-${name}.png`), fullPage: true }).catch(() => {});
      }
    }
    await context.close();
  }
  await browser.close();
  if (failures.length) {
    console.error(`\n${failures.length} flow(s) failed:\n  ${failures.join('\n  ')}`);
    process.exit(1);
  }
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
