'use strict';
const path = require('node:path');
const { defineConfig } = require('@playwright/test');
const reports = process.env.REPORT_DIR || path.join(__dirname, '..', 'reports', 'playwright', 'current');
module.exports = defineConfig({
  testDir: path.join(__dirname, 'tests'),
  fullyParallel: false,
  workers: 1,
  timeout: 60000,
  outputDir: process.env.PW_OUTPUT_DIR || path.join(reports, 'test-output'),
  reporter: [['json', { outputFile: path.join(reports, 'playwright-results.json') }]],
  use: { headless: true, trace: 'on', screenshot: 'on', video: 'on', actionTimeout: 15000 },
  projects: ['chromium', 'firefox', 'webkit'].map(name => ({ name, use: { browserName: name } }))
});
