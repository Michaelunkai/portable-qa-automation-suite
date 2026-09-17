'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const reportPath = process.env.QA_K6_REPORT;
const stdoutPath = process.env.QA_K6_STDOUT;
const stderrPath = process.env.QA_K6_STDERR;
const executable = process.env.QA_K6_EXE || path.join(__dirname, 'k6.exe');
const script = process.env.QA_K6_SCRIPT || path.join(__dirname, 'performance.js');
const timeoutMs = Number(process.env.QA_K6_TIMEOUT_MS || 60000);
const mode = process.env.QA_PERFORMANCE_MODE || 'smoke';
const p95ThresholdMs = Math.max(1, Number(process.env.QA_P95_MS || 1000));
const p99ThresholdMs = Math.max(p95ThresholdMs, Number(process.env.QA_P99_MS || 2000));
const errorRateThreshold = Math.min(10, Math.max(0, Number(process.env.QA_ERROR_RATE_PERCENT || 1))) / 100;

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
  }).slice(-5 * 1024 * 1024);
}

function finite(value) {
  if (value === null || value === undefined || value === '') return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function metric(summary, name, key) {
  const value = summary && summary.metrics && summary.metrics[name];
  const values = value && value.values && Object.prototype.hasOwnProperty.call(value.values, key) ? value.values : value;
  return finite(values && values[key]);
}

function requestFailures(output) {
  const values = [];
  for (const line of String(output || '').split(/\r?\n/)) {
    const marker = line.indexOf('QA_HTTP_FAILURE ');
    if (marker < 0) continue;
    try {
      let payload = line.slice(marker + 'QA_HTTP_FAILURE '.length).trim();
      const start = payload.indexOf('{');
      const end = payload.lastIndexOf('}');
      if (start >= 0 && end >= start) payload = payload.slice(start, end + 1);
      if (payload.includes('\\"')) payload = payload.replace(/\\"/g, '"');
      const parsed = JSON.parse(payload);
      if (parsed.url) parsed.url = redactText(parsed.url);
      values.push(parsed);
    } catch (_) {
      values.push({ message: redactText(line.slice(marker + 'QA_HTTP_FAILURE '.length)) });
    }
  }
  return values;
}

function main() {
  if (!reportPath || !stdoutPath || !stderrPath) throw new Error('k6 report and log paths are required.');
  if (!Number.isFinite(timeoutMs) || timeoutMs < 1000 || timeoutMs > 1800000) throw new Error('k6 timeout must be between 1000 and 1800000 milliseconds.');
  if (!fs.existsSync(executable)) throw new Error('k6 executable was not found: ' + executable);
  if (!fs.existsSync(script)) throw new Error('k6 test script was not found: ' + script);

  const summaryPath = reportPath + '.raw.json';
  try { fs.rmSync(summaryPath, { force: true }); } catch (_) {}
  const started = Date.now();
  const result = spawnSync(executable, ['run', '--summary-export', summaryPath, script], {
    cwd: path.dirname(script),
    env: process.env,
    encoding: 'utf8',
    windowsHide: true,
    timeout: timeoutMs,
    maxBuffer: 20 * 1024 * 1024
  });
  fs.mkdirSync(path.dirname(stdoutPath), { recursive: true });
  fs.writeFileSync(stdoutPath, redactText(result.stdout), 'utf8');
  fs.writeFileSync(stderrPath, redactText(result.stderr), 'utf8');

  let rawSummary = null;
  let summaryError = '';
  try { rawSummary = JSON.parse(fs.readFileSync(summaryPath, 'utf8')); }
  catch (error) { summaryError = String(error.message || error); }

  const count = metric(rawSummary, 'http_reqs', 'count');
  const errorRate = metric(rawSummary, 'http_req_failed', 'rate') ?? metric(rawSummary, 'http_req_failed', 'value');
  const failed = count !== null && errorRate !== null ? Math.round(count * errorRate) : null;
  const p95 = metric(rawSummary, 'http_req_duration', 'p(95)');
  const p99 = metric(rawSummary, 'http_req_duration', 'p(99)');
  const rate = metric(rawSummary, 'http_reqs', 'rate');
  const allowedErrorRate = errorRateThreshold;
  const withinErrorBudget = errorRate !== null && errorRate < allowedErrorRate;
  const failures = requestFailures(String(result.stdout || '') + '\n' + String(result.stderr || ''));
  const stderrText = String(result.stderr || '');
  const scriptFailure = /hint="script exception"/i.test(stderrText);
  const noRequests = count === null || count === 0;
  const thresholds = [
    { name: 'p(95)<' + p95ThresholdMs, passed: p95 !== null && p95 < p95ThresholdMs },
    { name: 'p(99)<' + p99ThresholdMs, passed: p99 !== null && p99 < p99ThresholdMs },
    { name: 'rate<' + errorRateThreshold, passed: errorRate !== null && errorRate < errorRateThreshold }
  ];
  const targetErrors = result.error ? String(result.error.message || result.error) : '';
  const hasMetrics = count !== null && errorRate !== null && p95 !== null && p99 !== null;
  const status = !hasMetrics || targetErrors || scriptFailure || noRequests
    ? 'error'
    : result.status === 0
      ? 'passed'
      : 'failed';
  const findings = failures.map(value => ({
    severity: withinErrorBudget ? 'warning' : 'high',
    kind: 'http-request',
    target: value.target || '',
    url: value.url || '',
    status: value.status === undefined ? null : value.status,
    message: value.error || (value.status ? 'HTTP response was outside 2xx/3xx.' : 'HTTP request failed.')
  }));
  if (status === 'failed') {
    for (const threshold of thresholds.filter(value => !value.passed)) {
      let message = '';
      if (threshold.name === 'p(95)<' + p95ThresholdMs) {
        message = 'p95 latency did not meet the configured limit: ' + p95.toFixed(1) + ' ms observed, expected < ' + p95ThresholdMs + ' ms.';
      } else if (threshold.name === 'p(99)<' + p99ThresholdMs) {
        message = 'p99 latency did not meet the configured limit: ' + p99.toFixed(1) + ' ms observed, expected < ' + p99ThresholdMs + ' ms.';
      } else if (threshold.name === 'rate<' + errorRateThreshold) {
        message = 'HTTP error rate did not meet the configured limit: ' + (errorRate * 100).toFixed(4) + '% observed, expected < ' + (errorRateThreshold * 100).toFixed(2) + '%.';
      }
      if (message) findings.push({
        severity: 'high',
        kind: 'threshold',
        metric: threshold.name.startsWith('p(') ? 'http_req_duration' : 'http_req_failed',
        threshold: threshold.name,
        target: 'all configured endpoints',
        url: '',
        message
      });
    }
  }
  if (status === 'failed' && findings.length === 0) {
    findings.push({ severity: 'high', kind: 'threshold', url: '', message: 'k6 exited with code ' + result.status + '; one or more configured performance thresholds failed.' });
  }
  if (status === 'error') {
    const stderrSummary = stderrText.trim().split(/\r?\n/).filter(Boolean).slice(-5).join(' ').slice(0, 2000);
    findings.unshift({ severity: 'error', kind: 'runner', url: '', message: targetErrors || (scriptFailure || noRequests ? stderrSummary || 'k6 completed without an HTTP request.' : summaryError ? 'k6 summary export could not be read: ' + summaryError : 'k6 did not produce the required HTTP metrics.') });
  }

  const report = {
    schemaVersion: 1,
    generatedUtc: new Date().toISOString(),
    durationMs: Date.now() - started,
    status,
    mode,
    exitCode: result.status,
    requests: { count, failed, errorRate, throughputRps: rate },
    latency: { p95Ms: p95, p99Ms: p99 },
    thresholds,
    observedRequestFailures: failures,
    summaryExport: summaryPath,
    stdoutLog: stdoutPath,
    stderrLog: stderrPath,
    findings
  };
  if (rawSummary) report.rawSummary = rawSummary;
  writeJsonAtomic(reportPath, report);
  process.stdout.write('PERFORMANCE: ' + status.toUpperCase() + ' - ' +
    (count === null ? 'metrics unavailable' : count + ' request(s), ' + failed + ' failed; p95 ' + p95 + ' ms, p99 ' + p99 + ' ms') + '\n');
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
    findings: [{ severity: 'error', kind: 'runner', url: '', message }]
  };
  try { if (reportPath) writeJsonAtomic(reportPath, report); } catch (_) {}
  process.stderr.write('PERFORMANCE: ERROR - ' + message + '\n');
  process.exitCode = 2;
}
