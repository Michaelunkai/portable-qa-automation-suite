'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = process.env.QA_SUITE_ROOT || path.resolve(__dirname, '..');
const cli = path.join(__dirname, 'node_modules', '@playwright', 'test', 'cli.js');
const config = path.join(__dirname, 'playwright.config.js');
const reportPath = process.env.QA_PLAYWRIGHT_REPORT;
const stdoutPath = process.env.QA_PLAYWRIGHT_STDOUT;
const stderrPath = process.env.QA_PLAYWRIGHT_STDERR;
const timeoutMs = Number(process.env.QA_PLAYWRIGHT_TIMEOUT_MS || 900000);

function writeJsonAtomic(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const temporary = filePath + '.tmp';
  fs.writeFileSync(temporary, JSON.stringify(value, null, 2) + '\n', 'utf8');
  fs.renameSync(temporary, filePath);
}

function redactText(text) {
  return String(text || '').replace(/https?:\/\/[^\s"'<>]+/g, value => {
    try {
      const url = new URL(value.replace(/[),.;]+$/, ''));
      if (url.username) url.username = 'REDACTED';
      if (url.password) url.password = 'REDACTED';
      for (const key of [...url.searchParams.keys()]) {
        if (/(token|key|secret|password|passwd|auth|session|code|signature)/i.test(key)) url.searchParams.set(key, 'REDACTED');
      }
      return url.toString();
    } catch (_) {
      return '[URL unavailable]';
    }
  }).replace(/[\r\n\t]+/g, ' ').slice(0, 1000);
}

function redactLog(text) {
  return String(text || '').replace(/https?:\/\/[^\s"'<>]+/g, value => {
    try {
      const url = new URL(value.replace(/[),.;]+$/, ''));
      if (url.username) url.username = 'REDACTED';
      if (url.password) url.password = 'REDACTED';
      for (const key of [...url.searchParams.keys()]) {
        if (/(token|key|secret|password|passwd|auth|session|code|signature)/i.test(key)) url.searchParams.set(key, 'REDACTED');
      }
      return url.toString();
    } catch (_) {
      return '[URL unavailable]';
    }
  }).slice(-5 * 1024 * 1024);
}

function collectTests(suites, output = []) {
  for (const suite of suites || []) {
    for (const spec of suite.specs || []) {
      for (const test of spec.tests || []) {
        const results = test.results || [];
        const errors = results.flatMap(result => result.errors || []);
        output.push({
          title: spec.title || test.title || '',
          status: ['failed','unexpected','timedOut'].includes(test.status) || results.some(value => ['failed','timedOut'].includes(value.status))
            ? 'failed'
            : test.status === 'skipped' || results.every(value => value.status === 'skipped')
              ? 'skipped'
              : 'passed',
          projectId: test.projectId || '',
          errors: errors.map(error => redactText(error.message || error.value || 'Test failed'))
        });
      }
    }
    collectTests(suite.suites, output);
  }
  return output;
}

function main() {
  if (!reportPath || !stdoutPath || !stderrPath) throw new Error('Playwright report and log paths are required.');
  if (!Number.isFinite(timeoutMs) || timeoutMs < 1000 || timeoutMs > 1800000) throw new Error('Playwright timeout must be between 1000 and 1800000 milliseconds.');
  const started = Date.now();
  const result = spawnSync(process.execPath, [
    cli,
    'test',
    '--config',
    config,
    '--workers',
    '1'
  ], {
    cwd: root,
    env: process.env,
    encoding: 'utf8',
    windowsHide: true,
    timeout: timeoutMs,
    maxBuffer: 30 * 1024 * 1024
  });
  fs.mkdirSync(path.dirname(stdoutPath), { recursive: true });
  fs.writeFileSync(stdoutPath, redactLog(result.stdout), 'utf8');
  fs.writeFileSync(stderrPath, redactLog(result.stderr), 'utf8');

  if (result.error) throw new Error(String(result.error.message || result.error));
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  } catch (error) {
    throw new Error('Playwright did not produce a readable JSON report: ' + String(error.message || error));
  }
  const tests = collectTests(raw.suites || []);
  const failed = tests.filter(value => value.status === 'failed');
  const a11yFinding = error => /^(?:Error:\s*)?QA_A11Y_FINDINGS:/i.test(String(error || '').trim());
  const visualFinding = error => /^(?:Error:\s*)?QA_VISUAL_FINDINGS:/i.test(String(error || '').trim());
  const classifiedFinding = error => a11yFinding(error) || visualFinding(error);
  const a11yOnly = failed.length > 0 && failed.every(value => value.errors.length > 0 && value.errors.every(a11yFinding));
  const visualOnly = failed.length > 0 && failed.every(value => value.errors.length > 0 && value.errors.every(visualFinding));
  const browserFailures = failed.filter(value => value.errors.length === 0 || value.errors.some(error => !classifiedFinding(error)));
  const a11yFindings = failed.flatMap(test => test.errors.filter(a11yFinding).map(message => ({ test: test.title, project: test.projectId, message })));
  const visualFindings = failed.flatMap(test => test.errors.filter(visualFinding).map(message => ({ test: test.title, project: test.projectId, message })));
  const status = tests.length === 0
    ? 'incomplete'
    : browserFailures.length > 0
      ? 'failed'
      : failed.length > 0 && failed.some(value => value.errors.some(classifiedFinding))
        ? 'passed'
      : result.status !== 0
        ? 'error'
        : 'passed';
  const report = {
    schemaVersion: 1,
    generatedUtc: new Date().toISOString(),
    status,
    durationMs: Date.now() - started,
    exitCode: result.status,
    testRunnerExitCode: result.status,
    testFailures: failed.length,
    totalTests: tests.length,
    passedTests: tests.filter(value => value.status === 'passed').length,
    failedTests: failed.length,
    skippedTests: tests.filter(value => value.status === 'skipped').length,
    accessibilityOnlyFailure: a11yOnly,
    visualOnlyFailure: visualOnly,
    accessibilityFindings: a11yFindings,
    visualFindings,
    tests,
    findings: browserFailures.flatMap(test => test.errors.map(message => ({
      test: test.title,
      project: test.projectId,
      message
    }))),
    htmlReport: path.join(path.dirname(reportPath), 'playwright-html', 'index.html'),
    jsonReport: reportPath,
    stdoutLog: stdoutPath,
    stderrLog: stderrPath
  };
  writeJsonAtomic(path.join(path.dirname(reportPath), 'playwright-runner.json'), report);
  process.stdout.write('BROWSER: ' + status.toUpperCase() + ' - ' + report.passedTests + ' passed, ' +
    report.failedTests + ' failed, ' + report.skippedTests + ' skipped test(s)\n');
  return status === 'passed' ? 0 : status === 'failed' ? 1 : 2;
}

try {
  process.exitCode = main();
} catch (error) {
  const message = redactText(error.message || error);
  const report = {
    schemaVersion: 1,
    generatedUtc: new Date().toISOString(),
    status: 'error',
    findings: [{ test: '[runner]', project: '', message }],
    htmlReport: reportPath ? path.join(path.dirname(reportPath), 'playwright-html', 'index.html') : '',
    jsonReport: reportPath || ''
  };
  try {
    if (reportPath) writeJsonAtomic(path.join(path.dirname(reportPath), 'playwright-runner.json'), report);
  } catch (_) {}
  process.stderr.write('BROWSER: ERROR - ' + message + '\n');
  process.exitCode = 2;
}
