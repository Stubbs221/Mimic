//
//  check-build-resources.mjs
//  Mimic
//
//  Created by Василий Маслов on 27.10.2026.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)(process.env.MIMIC_PLAYWRIGHT_MODULE ?? 'playwright');
const html = await readFile(new URL('../Sources/MimicMCP/Resources/panel.html', import.meta.url));
const server = createServer((_, res) => { res.setHeader('Content-Type', 'text/html'); res.end(html); });
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const output = '/private/tmp/MimicResourceReadiness-web'; await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true, executablePath: process.env.MIMIC_CHROME_EXECUTABLE });
try {
 const page = await browser.newPage({ viewport: { width: 520, height: 1000 }, reducedMotion: 'reduce' });
 const errors = []; page.on('pageerror', e => errors.push(e.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1&layout=all&data=empty`);
 await page.waitForFunction(() => !!window.mimicBuildFixture);
 const card = page.locator('[data-block="builds"]');
 const resources = (status, activity) => page.evaluate(async ([s, a]) => { await window.mimicBuildFixture.resources(s, a); }, [status, activity]);
 for (const width of [520, 360, 260]) for (const dark of [false, true]) {
  await page.setViewportSize({ width, height: 1000 }); await page.emulateMedia({ colorScheme: dark ? 'dark' : 'light' });
  await page.evaluate(mode => window.mimicBuildFixture.mode(mode), width === 520 ? 'full' : 'mini');
  await resources('missing');
  const restore = card.locator('[data-resource-restore]'); await restore.waitFor();
  assert(await restore.isEnabled()); assert(await card.locator('[data-build-action="build"]').isDisabled());
  assert(await card.locator('[data-build-action="tests"]').isDisabled());
  assert.equal(await card.locator('[data-build-action="run"]').count(), 0);
  const bounds = await card.evaluate(card => {
   const r = card.getBoundingClientRect(); const controls = [...card.querySelectorAll('button,select')].filter(c => c.offsetParent !== null);
   return { height: r.height, overflow: card.scrollWidth > card.clientWidth + 1, escaped: controls.filter(c => { const b = c.getBoundingClientRect(); return b.right > r.right + 1 || b.bottom > r.bottom + 1; }).map(c => c.outerHTML) };
  });
  assert.equal(bounds.height, 160); assert(!bounds.overflow); assert.deepEqual(bounds.escaped, []);
  await card.screenshot({ path: `${output}/r1-${width}-${dark ? 'dark' : 'light'}.png` });
 }
 await card.locator('[data-resource-restore]').focus(); await card.locator('[data-resource-restore]').press('Enter');
 await card.locator('[data-resource-cancel]').waitFor();
 assert.equal((await page.evaluate(() => window.mimicBuildFixture.calls())).filter(c => c.operation === 'restoreResources').length, 1);
 assert(!await card.evaluate(c => c.classList.contains('expanded')));
 await card.locator('[data-resource-cancel]').click(); await card.locator('[data-resource-restore]').waitFor();
 await resources('missing', 'failed');
 assert(await card.getByRole('button', { name: 'Повторить', exact: true }).isVisible());
 assert(await card.getByRole('button', { name: 'Лог', exact: true }).isVisible());
 await resources('stale'); assert((await card.locator('.build-resource-reason').textContent()).includes('26.10.03'));
 for (const state of ['unknown', 'modified']) { await resources(state); assert(await card.locator('[data-resource-restore]').isDisabled()); }
 await resources('ready'); assert(await card.locator('[data-build-action="run"]').isEnabled());
 assert.equal((await page.evaluate(() => window.mimicBuildFixture.calls())).filter(c => ['run', 'build', 'tests'].includes(c.operation)).length, 0, 'recovery never automatically builds');
 await page.evaluate(() => window.mimicBuildFixture.task('queued')); await resources('missing');
 assert(await card.locator('[data-build-cancel]').isVisible(), 'queued build keeps its cancel action if resources disappear');
 await page.evaluate(() => window.mimicBuildFixture.empty());
 assert.deepEqual(errors, []);
 console.log('PASS: R1 Mini/Full, direct keyboard recovery, cancel/retry/log, platform/version reason, protected local edits, equal heights, narrow widths, both themes, no automatic build');
} finally { await browser.close(); server.close(); }
