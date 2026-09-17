'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { test, expect } = require('@playwright/test');
const suiteRoot = process.env.QA_SUITE_ROOT || path.resolve(__dirname, '../..');
const AxeBuilder = require(path.join(suiteRoot, 'k6-axe-a11y', 'node_modules', '@axe-core', 'playwright')).default;
const runRoot = process.env.QA_RUN_DIR || path.join(suiteRoot, 'reports', 'manual-run');
const reportRoot = process.env.REPORT_DIR || runRoot;
const fragmentDir = process.env.AXE_FRAGMENT_DIR || path.join(runRoot, 'a11y-fragments');
const baselineRoot = path.join(suiteRoot, 'reports', 'visual-baselines');
const maxPages = Math.max(1, Math.min(500, Number(process.env.QA_MAX_PAGES || 20)));
const navTimeout = Math.max(1000, Math.min(60000, Number(process.env.QA_NAVIGATION_TIMEOUT_MS || 20000)));
const updateVisuals = process.env.QA_UPDATE_VISUAL_BASELINE === '1';

function writeJsonAtomic(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const temporary = filePath + '.tmp';
  fs.writeFileSync(temporary, JSON.stringify(value, null, 2) + '\n', 'utf8');
  fs.renameSync(temporary, filePath);
}

function shortHash(value) {
  return crypto.createHash('sha256').update(value).digest('hex').slice(0, 20);
}

function redactUrl(value) {
  try {
    const url = new URL(String(value));
    if (url.username) url.username = 'REDACTED';
    if (url.password) url.password = 'REDACTED';
    for (const key of [...url.searchParams.keys()]) {
      if (/(token|key|secret|password|passwd|auth|session|code|signature)/i.test(key)) url.searchParams.set(key, 'REDACTED');
    }
    return url.toString();
  } catch (_) {
    return '[URL unavailable]';
  }
}

function sameOrigin(value, origin) {
  try {
    return new URL(value).origin === origin;
  } catch (_) {
    return false;
  }
}

function normalizeCandidate(value, target) {
  try {
    const next = new URL(value, target);
    if (next.origin !== target.origin) return { skip: 'outside target origin' };
    next.hash = '';
    if (/\.(?:pdf|zip|7z|rar|png|jpe?g|gif|svg|webp|mp4|mp3|docx?|xlsx?|pptx?)(?:$|\?)/i.test(next.pathname)) {
      return { skip: 'download or media route' };
    }
    if (/(^|\/)(?:logout|log-out|signout|sign-out|delete|remove|unsubscribe|download)(?:\/|$)/i.test(next.pathname) ||
        /(?:action|intent)=(?:delete|logout|signout|remove|unsubscribe)/i.test(next.search)) {
      return { skip: 'potentially state-changing route' };
    }
    return { href: next.href };
  } catch (_) {
    return { skip: 'invalid or unsupported URL' };
  }
}

function errorText(error) {
  return String(error && (error.message || error) || '')
    .replace(/https?:\/\/[^\s"'<>]+/g, value => {
      const suffix = (value.match(/[),.;]+$/) || [''])[0];
      return redactUrl(value.slice(0, value.length - suffix.length)) + suffix;
    })
    .replace(/[\r\n\t]+/g, ' ')
    .slice(0, 1000);
}

function consoleErrorText(value) {
  let text = errorText(value);
  if (!text.startsWith('[JavaScript Error:')) return text;
  text = text.slice('[JavaScript Error:'.length).trim();
  const sourceMarker = text.indexOf(' {file:');
  if (sourceMarker >= 0) text = text.slice(0, sourceMarker).trim();
  if ((text.startsWith('"') && text.endsWith('"')) || (text.startsWith('\u201c') && text.endsWith('\u201d'))) {
    text = text.slice(1, -1);
  }
  return text;
}

test('bounded same-origin browser, visual, and accessibility crawl', async ({ page }, testInfo) => {
  const target = new URL(process.env.QA_TARGET_URL);
  const targetKey = shortHash(target.origin);
  const browserKey = testInfo.project.name;
  const viewport = testInfo.project.use.viewport || { width: 1280, height: 720 };
  const viewportKey = String(viewport.width) + 'x' + String(viewport.height);
  const screenshotDir = path.join(reportRoot, 'screenshots', browserKey);
  fs.mkdirSync(screenshotDir, { recursive: true });
  fs.mkdirSync(fragmentDir, { recursive: true });

  const fragmentPath = path.join(fragmentDir, browserKey + '.json');
  const fragment = {
    browser: browserKey,
    viewport: viewportKey,
    status: 'running',
    startedUtc: new Date().toISOString(),
    standards: ['WCAG 2.1 A', 'WCAG 2.1 AA', 'WCAG 2.1 AAA'],
    maxPages,
    discoveredCount: 1,
    visitedCount: 0,
    skippedCount: 0,
    visual: { compared: 0, recorded: 0, notCompared: 0, mismatched: 0 },
    audits: [],
    browserFindings: [],
    visualFindings: [],
    networkWarnings: [],
    incomplete: []
  };
  const queue = [target.href];
  const queued = new Set(queue);
  const seen = new Set();
  const allA11yFailures = [];
  let pageIndex = 0;

  function persist(status = 'running') {
    fragment.status = status;
    fragment.updatedUtc = new Date().toISOString();
    writeJsonAtomic(fragmentPath, fragment);
  }

  page.on('pageerror', error => {
    fragment.browserFindings.push({ type: 'pageerror', url: redactUrl(page.url()), message: errorText(error) });
  });
  page.on('console', message => {
    if (message.type() !== 'error') return;
    const text = consoleErrorText(message.text());
    // Network failures are recorded with their request/response status below.
    if (!text || /^(?:failed to load resource|net::ERR_)/i.test(text)) return;
    const location = message.location() || {};
    const source = location.url ? redactUrl(location.url) : '';
    const line = Number(location.lineNumber) > 0 ? ':' + Number(location.lineNumber) : '';
    fragment.browserFindings.push({
      type: 'console-error',
      url: redactUrl(page.url() || target.href),
      source: source ? source + line : '',
      message: text
    });
  });
  page.on('response', response => {
    if (response.status() >= 400) {
      const url = response.url();
      const record = { type: 'http-response', url: redactUrl(url), status: response.status(), statusText: response.statusText() };
      if (sameOrigin(url, target.origin)) fragment.browserFindings.push(record);
      else fragment.networkWarnings.push(record);
    }
  });
  page.on('requestfailed', request => {
    const failure = request.failure();
    const text = failure && failure.errorText || 'request failed';
    if (/ERR_ABORTED|NS_BINDING_ABORTED|CANCELLED|CANCELED/i.test(text)) return;
    const url = request.url();
    const record = { type: 'request-failed', url: redactUrl(url), resourceType: request.resourceType(), message: text };
    if (sameOrigin(url, target.origin)) fragment.browserFindings.push(record);
    else fragment.networkWarnings.push(record);
  });

  persist();
  while (queue.length > 0 && seen.size < maxPages) {
    const url = queue.shift();
    if (seen.has(url)) continue;
    seen.add(url);
    const audit = {
      browser: browserKey,
      viewport: viewportKey,
      url: redactUrl(url),
      title: '',
      statusCode: null,
      readiness: { domContentLoaded: false, fontsReady: null },
      screenshot: '',
      visualStatus: 'not-compared',
      violations: [],
      passes: 0,
      incomplete: []
    };
    let response = null;
    try {
      response = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: navTimeout });
      audit.readiness.domContentLoaded = true;
      audit.statusCode = response ? response.status() : null;
      if (!response) {
        fragment.browserFindings.push({ type: 'navigation', url: redactUrl(url), message: 'Navigation completed without an HTTP response.' });
      }
      if (response && response.status() >= 400) {
        fragment.browserFindings.push({ type: 'navigation', url: redactUrl(url), status: response.status(), statusText: response.statusText(), message: 'Target route returned an unsuccessful HTTP response.' });
      }
      audit.title = await page.title().catch(() => '');
      audit.readiness.fontsReady = await page.evaluate(async () => {
        if (!document.fonts || !document.fonts.ready) return true;
        await Promise.race([document.fonts.ready, new Promise(resolve => setTimeout(resolve, 1500))]);
        return document.fonts.status === 'loaded';
      }).catch(() => false);
      if (!audit.readiness.fontsReady) {
        audit.incomplete.push('Web fonts did not reach the loaded state within 1.5 seconds.');
        fragment.incomplete.push({ browser: browserKey, url: redactUrl(url), check: 'font readiness' });
      }

      const screenshotName = 'page-' + String(pageIndex).padStart(3, '0') + '.png';
      const screenshotPath = path.join(screenshotDir, screenshotName);
      const screenshotBytes = await page.screenshot({ path: screenshotPath, fullPage: true, animations: 'disabled', timeout: navTimeout });
      audit.screenshot = screenshotPath;

      const routeKey = shortHash(new URL(url).origin + new URL(url).pathname + new URL(url).search);
      const snapshotName = [targetKey, browserKey, viewportKey, routeKey + '.png'];
      const baselinePath = testInfo.snapshotPath(...snapshotName);
      audit.visualBaseline = baselinePath;
      if (updateVisuals) {
        fs.mkdirSync(path.dirname(baselinePath), { recursive: true });
        fs.writeFileSync(baselinePath, screenshotBytes);
        audit.visualStatus = 'recorded';
        fragment.visual.recorded += 1;
      } else if (fs.existsSync(baselinePath)) {
        try {
          await expect(screenshotBytes).toMatchSnapshot(snapshotName, {
            threshold: 0.2,
            maxDiffPixelRatio: 0.01
          });
          audit.visualStatus = 'matched';
          fragment.visual.compared += 1;
        } catch (error) {
          audit.visualStatus = 'mismatched';
          fragment.visual.mismatched += 1;
          fragment.visualFindings.push({
            type: 'visual-regression',
            url: redactUrl(url),
            message: errorText(error),
            baseline: baselinePath,
            screenshot: screenshotPath
          });
        }
      } else {
        audit.visualStatus = 'not-compared';
        fragment.visual.notCompared += 1;
      }

      try {
        const axe = await new AxeBuilder({ page })
          .withTags(['wcag2a', 'wcag2aa', 'wcag2aaa', 'wcag21a', 'wcag21aa', 'wcag21aaa'])
          .analyze();
        audit.violations = axe.violations.map(violation => ({
          id: violation.id,
          impact: violation.impact,
          description: violation.description,
          help: violation.help,
          helpUrl: violation.helpUrl,
          tags: violation.tags,
          nodes: violation.nodes.map(node => ({
            target: node.target,
            failureSummary: node.failureSummary
          }))
        }));
        audit.passes = axe.passes.length;
        audit.incomplete = axe.incomplete.map(value => ({ id: value.id, impact: value.impact, help: value.help }));
        for (const violation of audit.violations) {
          allA11yFailures.push({
            browser: browserKey,
            url: redactUrl(url),
            id: violation.id,
            impact: violation.impact,
            help: violation.help,
            helpUrl: violation.helpUrl,
            nodes: violation.nodes
          });
        }
      } catch (error) {
        audit.incomplete.push('Accessibility engine failed: ' + errorText(error));
        fragment.incomplete.push({ browser: browserKey, url: redactUrl(url), check: 'axe execution', message: errorText(error) });
      }
      fragment.audits.push(audit);
      fragment.visitedCount = fragment.audits.length;
      pageIndex += 1;
      persist();

      const links = await page.locator('a[href]').evaluateAll(nodes => nodes.map(node => node.href)).catch(() => []);
      for (const href of links) {
        const candidate = normalizeCandidate(href, target);
        if (!candidate.href) {
          fragment.skippedCount += 1;
          continue;
        }
        if (!seen.has(candidate.href) && !queued.has(candidate.href) && seen.size + queue.length < maxPages) {
          queue.push(candidate.href);
          queued.add(candidate.href);
          fragment.discoveredCount += 1;
        }
      }
      persist();
    } catch (error) {
      fragment.browserFindings.push({
        type: 'navigation-or-audit',
        url: redactUrl(url),
        status: response ? response.status() : null,
        message: errorText(error)
      });
      fragment.audits.push(audit);
      fragment.visitedCount = fragment.audits.length;
      pageIndex += 1;
      persist();
    }
  }

  if (queue.length > 0) {
    fragment.incomplete.push({
      check: 'crawl bound',
      message: 'The crawl stopped at the configured page limit of ' + maxPages + '.'
    });
  }
  if (!fragment.audits.length) fragment.incomplete.push({ check: 'crawl', message: 'No page completed a browser audit.' });
  fragment.finishedUtc = new Date().toISOString();
  persist(fragment.browserFindings.length || fragment.visualFindings.length ? 'failed' : fragment.audits.length ? 'completed' : 'incomplete');

  await testInfo.attach('qa-crawl-' + browserKey + '.json', {
    body: JSON.stringify(fragment, null, 2),
    contentType: 'application/json'
  });
  if (fragment.browserFindings.length) {
    throw new Error('QA_BROWSER_FAILURES: ' + fragment.browserFindings.length + ' browser or HTTP finding(s); see ' + fragmentPath);
  }
  if (fragment.visualFindings.length) {
    throw new Error('QA_VISUAL_FINDINGS: ' + fragment.visualFindings.length + ' visual regression finding(s); see ' + fragmentPath);
  }
  if (allA11yFailures.length) {
    throw new Error('QA_A11Y_FINDINGS: ' + allA11yFailures.length + ' accessibility violation(s); see ' + fragmentPath);
  }
});
