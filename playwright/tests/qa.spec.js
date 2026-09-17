'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { test, expect } = require('@playwright/test');
const AxeBuilder = require('@axe-core/playwright').default;

test('crawl same-origin pages, capture visuals, and audit WCAG 2.1 AA/AAA', async ({ page }, testInfo) => {
  const target = new URL(process.env.QA_TARGET_URL);
  const maxPages = Math.max(1, Number(process.env.QA_MAX_PAGES || 20));
  const reportDir = process.env.REPORT_DIR;
  const fragmentDir = process.env.AXE_FRAGMENT_DIR;
  const screenshotDir = path.join(reportDir, 'screenshots', testInfo.project.name);
  fs.mkdirSync(screenshotDir, { recursive: true });
  fs.mkdirSync(fragmentDir, { recursive: true });
  const queue = [target.href];
  const seen = new Set();
  const audits = [];
  const visualBaselineDir = path.join(__dirname, 'qa.spec.js-snapshots');
  const updateVisuals = process.env.QA_UPDATE_VISUAL_BASELINE === '1';

  while (queue.length && seen.size < maxPages) {
    const url = queue.shift();
    if (seen.has(url)) continue;
    seen.add(url);
    const response = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
    expect(response, 'navigation response for ' + url).not.toBeNull();
    expect(response.status(), 'HTTP status for ' + url).toBeLessThan(400);

    const index = seen.size - 1;
    const shot = await page.screenshot({
      path: path.join(screenshotDir, 'page-' + index + '.png'),
      fullPage: true,
      animations: 'disabled'
    });
    const snapshotName = 'page-' + index + '.png';
    const baselinePath = testInfo.snapshotPath(snapshotName);
    let visual = 'no-baseline';
    if (updateVisuals) {
      fs.mkdirSync(visualBaselineDir, { recursive: true });
      fs.writeFileSync(baselinePath, shot);
      visual = 'baseline-recorded';
    } else if (fs.existsSync(baselinePath)) {
      await expect(page).toHaveScreenshot(snapshotName, { animations: 'disabled' });
      visual = 'matched';
    }

    const axe = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag2aaa', 'wcag21a', 'wcag21aa', 'wcag21aaa'])
      .analyze();
    audits.push({
      browser: testInfo.project.name,
      url,
      title: await page.title(),
      visual,
      violations: axe.violations.map(v => ({
        id: v.id,
        impact: v.impact,
        description: v.description,
        help: v.help,
        helpUrl: v.helpUrl,
        tags: v.tags,
        nodes: v.nodes.map(n => ({ target: n.target, summary: n.failureSummary }))
      })),
      passes: axe.passes.length,
      incomplete: axe.incomplete.map(v => ({ id: v.id, impact: v.impact }))
    });

    const links = await page.locator('a[href]').evaluateAll(nodes => nodes.map(a => a.href));
    for (const href of links) {
      try {
        const next = new URL(href);
        if (next.origin === target.origin && !seen.has(next.href) && !queue.includes(next.href) && queue.length + seen.size < maxPages) queue.push(next.href);
      } catch (_) {}
    }
  }

  const outFile = path.join(fragmentDir, testInfo.project.name + '.json');
  fs.writeFileSync(outFile, JSON.stringify({ browser: testInfo.project.name, standards: ['WCAG 2.1 A', 'WCAG 2.1 AA', 'WCAG 2.1 AAA'], audits }, null, 2));
  const failures = audits.flatMap(a => a.violations.map(v => a.browser + ' ' + a.url + ': ' + v.id + ' (' + v.impact + ')'));
  expect(failures, 'Accessibility violations: ' + failures.join('; ')).toEqual([]);
});
