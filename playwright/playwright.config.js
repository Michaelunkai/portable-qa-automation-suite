'use strict';

const path = require('node:path');
const { defineConfig } = require('@playwright/test');

const suiteRoot = process.env.QA_SUITE_ROOT || path.resolve(__dirname, '..');
const runRoot = process.env.QA_RUN_DIR || path.join(suiteRoot, 'reports', 'manual-run');
const testTimeout = Math.min(900000, Math.max(10000, Number(process.env.QA_BROWSER_TEST_TIMEOUT_MS || 600000)));
const projects = [
  {
    name: 'chromium-desktop',
    use: { browserName: 'chromium', viewport: { width: 1365, height: 768 } }
  },
  {
    name: 'firefox-desktop',
    use: { browserName: 'firefox', viewport: { width: 1365, height: 768 } }
  },
  {
    name: 'webkit-desktop',
    use: { browserName: 'webkit', viewport: { width: 1365, height: 768 } }
  },
  {
    name: 'chromium-mobile-emulation',
    use: { browserName: 'chromium', viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }
  }
];

module.exports = defineConfig({
  testDir: path.join(__dirname, 'tests'),
  fullyParallel: false,
  workers: 1,
  timeout: testTimeout,
  expect: { timeout: 5000 },
  outputDir: process.env.QA_PLAYWRIGHT_OUTPUT_DIR || path.join(runRoot, 'playwright-output'),
  snapshotDir: path.join(suiteRoot, 'reports', 'visual-baselines'),
  snapshotPathTemplate: '{snapshotDir}/{arg}{ext}',
  updateSnapshots: 'none',
  reporter: [
    ['json', { outputFile: process.env.QA_PLAYWRIGHT_REPORT || path.join(runRoot, 'playwright-results.json') }],
    ['html', { outputFolder: path.join(runRoot, 'playwright-html'), open: 'never' }]
  ],
  use: {
    headless: true,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    actionTimeout: 10000
  },
  projects
});
