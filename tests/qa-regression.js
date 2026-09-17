'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const readline = require('node:readline');
const crypto = require('node:crypto');

const suite = path.resolve(__dirname, '..');
const installRoot = path.dirname(suite);
const node = path.join(suite, 'playwright', 'node.exe');
const powershell = 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
const publicScript = path.join(installRoot, 'Ultimate-QA-Orchestrator.ps1');
const tempRoot = path.join(suite, 'tmp', 'qa-regression-' + crypto.randomUUID());
const acceptanceRoot = path.join(suite, 'reports', 'acceptance', 'qa-regression-' + crypto.randomUUID());
const reports = {};
const completedChecks = [];
const acceptanceScope = process.argv.includes('--k6-only') ? 'targeted-k6' : process.argv.includes('--api-only') ? 'api-semantics' : 'full-regression';

function powershellQuote(value) {
  return "'" + String(value).replace(/'/g, "''") + "'";
}

function startLocalApi() {
  const server = http.createServer((request, response) => {
    if (request.url === '/html') {
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      response.end('<!doctype html><html><title>HTML endpoint</title></html>');
    } else if (request.url === '/json') {
      response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ ok: true, items: [{ id: 1 }] }));
    } else if (request.url === '/empty') {
      response.writeHead(204);
      response.end();
    } else {
      response.writeHead(404, { 'content-type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ error: 'expected test route' }));
    }
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve({ server, origin: 'http://127.0.0.1:' + server.address().port }));
  });
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2) + '\n', 'utf8');
}

function runApiCase(apiRoot, name, settings = {}) {
  const directory = path.join(tempRoot, 'api', name);
  fs.mkdirSync(directory, { recursive: true });
  const report = path.join(directory, 'api.json');
  const env = {
    ...process.env,
    QA_SUITE_ROOT: suite,
    QA_API_REPORT: report,
    QA_API_BASE_URL: settings.url || '',
    QA_API_COLLECTION: settings.collection || '',
    QA_API_SCHEMA_PATH: settings.schema || '',
    QA_API_TIMEOUT_MS: '3000',
    QA_API_MAX_REQUESTS: '10',
    QA_API_MAX_RUN_MS: '15000'
  };
  return new Promise((resolve, reject) => {
    const child = spawn(node, [path.join(suite, 'postman-cli', 'qa-newman-runner.js')], {
      cwd: suite,
      env,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe']
    });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => child.kill(), 30000);
    child.stdout.setEncoding('utf8').on('data', chunk => { stdout += chunk; });
    child.stderr.setEncoding('utf8').on('data', chunk => { stderr += chunk; });
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('exit', code => {
      clearTimeout(timer);
      try {
        const evidence = JSON.parse(fs.readFileSync(report, 'utf8'));
        reports['api_' + name] = report;
        resolve({ code, stdout, stderr, evidence });
      } catch (error) {
        reject(new Error('API case ' + name + ' did not produce evidence. stdout=' + stdout + ' stderr=' + stderr + ' error=' + error.message));
      }
    });
  });
}

function expectedCollection(name, url, scriptLine) {
  return {
    info: { name, schema: 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json' },
    item: [{
      name,
      request: { method: 'GET', header: [], url },
      event: [{ listen: 'test', script: { type: 'text/javascript', exec: [scriptLine] } }]
    }]
  };
}

async function startMock() {
  const child = spawn(node, [path.join(suite, 'mock', 'mock-server.js')], {
    cwd: suite,
    env: { ...process.env, QA_MOCK_PORT: '0' },
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let output = '';
  const ready = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('local mock server startup timed out; output: ' + output)), 10000);
    const lines = readline.createInterface({ input: child.stdout });
    lines.on('line', line => {
      output += line + '\n';
      const match = /^ready:(\d+)$/.exec(line.trim());
      if (match) {
        clearTimeout(timeout);
        resolve(Number(match[1]));
      }
    });
    child.once('error', error => { clearTimeout(timeout); reject(error); });
    child.once('exit', code => { clearTimeout(timeout); reject(new Error('local mock exited before ready (' + code + '): ' + output)); });
  });
  return { child, url: 'http://127.0.0.1:' + ready + '/' };
}

function readRun(runId) {
  const runDir = path.join(suite, 'reports', 'runs', runId);
  const overallPath = path.join(runDir, 'overall_results.json');
  const summaryPath = path.join(runDir, 'summary.txt');
  return {
    runDir,
    overallPath,
    summaryPath,
    overall: JSON.parse(fs.readFileSync(overallPath, 'utf8')),
    summary: fs.readFileSync(summaryPath, 'utf8')
  };
}

function persistAcceptance(status, failureMessage) {
  fs.mkdirSync(acceptanceRoot, { recursive: true });
  const apiReports = {};
  for (const [name, source] of Object.entries(reports)) {
    if (!name.startsWith('api_') || !fs.existsSync(source)) continue;
    const destination = path.join(acceptanceRoot, 'api', name + '.json');
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(source, destination);
    apiReports[name.slice(4)] = destination;
  }
  const inputs = {};
  for (const name of ['contract.json','mismatch.json','expected-404.postman_collection.json','expected-204.postman_collection.json']) {
    const source = path.join(tempRoot, name);
    if (!fs.existsSync(source)) continue;
    const destination = path.join(acceptanceRoot, 'inputs', name);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(source, destination);
    inputs[name] = destination;
  }
  const indexPath = path.join(acceptanceRoot, 'acceptance.json');
  writeJson(indexPath, {
    schemaVersion: 1,
    scope: acceptanceScope,
    status,
    completedUtc: new Date().toISOString(),
    checks: completedChecks,
    failure: failureMessage,
    evidence: {
      apiReports,
      inputs,
      localPositiveRun: reports.localPositiveRun || '',
      localNegativeRun: reports.localNegativeRun || '',
      localK6PositiveRun: reports.localK6PositiveRun || '',
      localK6Failure: reports.localK6Failure || '',
       localBrowser404Run: reports.localBrowser404Run || '',
       localBrowserConsoleErrorRun: reports.localBrowserConsoleErrorRun || ''
    }
  });
  return indexPath;
}

function findRunResult(output) {
  const match = /Run ID:\s*([0-9TZ-]+-[a-f0-9]+)/i.exec(output);
  assert(match, 'orchestrator output did not include a run id');
  return readRun(match[1]);
}

function runPowerShell(file, timeoutMs = 900000) {
  return spawnSync(powershell, ['-NoProfile', '-NoLogo', '-NonInteractive', '-File', file], {
    cwd: suite,
    encoding: 'utf8',
    windowsHide: true,
    timeout: timeoutMs,
    maxBuffer: 40 * 1024 * 1024
  });
}

function runPublicPowerShell(args, timeoutMs = 900000) {
  return spawnSync(powershell, ['-NoProfile', '-NoLogo', '-NonInteractive', '-File', publicScript, ...args], {
    cwd: suite,
    encoding: 'utf8',
    windowsHide: true,
    timeout: timeoutMs,
    maxBuffer: 40 * 1024 * 1024
  });
}

function runSummaryFormatRegression() {
  const reportPath = path.join(tempRoot, 'summary-format-report.json');
  const scriptPath = path.join(tempRoot, 'summary-format-regression.ps1');
  const browsers = ['chromium-desktop','chromium-mobile-emulation','firefox-desktop','webkit-desktop'];
  const rules = [
    ['aria-prohibited-attr','Elements must only use permitted ARIA attributes'],
    ['color-contrast','Elements must meet minimum color contrast ratio thresholds'],
    ['color-contrast-enhanced','Elements must meet enhanced color contrast ratio thresholds']
  ];
  const report = {
    runId: 'summary-format-regression',
    targetUrl: 'https://qa-fixture.example/',
    startedUtc: new Date().toISOString(),
    durationSeconds: 1.25,
    status: 'FAIL',
    phases: {
      api: { status: 'skipped', details: 'No API contract was supplied.' },
      browser: { status: 'failed', details: '13 distinct HTTP failures.' },
      accessibility: { status: 'incomplete', details: '4 audits; 0 violations; 12 incomplete checks.' },
      visual: { status: 'incomplete', details: 'No baselines.' },
      performance: { status: 'passed', details: 'Smoke sample.' }
    },
    findings: Array.from({ length: 13 }, (_, index) => ({
      severity: 'high',
      phase: 'browser',
      title: 'HTTP response failure',
      browser: browsers.join(', '),
      status: 404,
      occurrences: 4,
      url: 'https://qa-fixture.example/missing-' + (index + 1),
      details: 'Same-origin request returned HTTP 404.',
      nextAction: 'Inspect the affected route and the corresponding browser response evidence.'
    })),
    accessibility: {
      violationOccurrences: 0,
      violations: [],
      incompleteCount: 12,
      incomplete: browsers.flatMap(browser => rules.map(([rule,help]) => ({
        browser,
        url: 'https://qa-fixture.example/',
        check: 'axe manual review',
        rule,
        impact: 'serious',
        help
      })))
    },
      coverage: { browserProjects: browsers, notes: ['Fixture coverage note.', '<img src=x onerror=alert(1)>', 'Cookie “__cf_bm” was rejected.'] },
      evidence: {
        summary: 'C:\\qa\\summary.txt',
        htmlReport: 'C:\\qa\\report.html',
        overall: 'C:\\qa\\overall_results.json',
        traces: 'C:\\qa\\playwright-output\\one\\trace.zip; C:\\qa\\playwright-output\\two\\trace.zip',
        videos: 'C:\\qa\\playwright-output\\one\\video.webm'
      },
    rerunCommand: "& 'C:\\qa\\Ultimate-QA-Orchestrator.ps1' -TargetUrl 'https://qa-fixture.example/'"
  };
  writeJson(reportPath, report);
  const script = [
    "$ErrorActionPreference = 'Stop'",
    '$sourcePath = ' + powershellQuote(path.join(suite, 'Ultimate-QA-Orchestrator.ps1')),
    '$reportPath = ' + powershellQuote(reportPath),
    '$tokens = $null; $parseErrors = $null',
    '$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$parseErrors)',
    'if ($parseErrors) { throw "Could not parse orchestrator functions: $($parseErrors[0].Message)" }',
    "$requiredNames = @('Format-Number','Format-SummaryText','Get-RunSummaryLines','Get-ReportValue','ConvertTo-HtmlText','Get-HtmlStatusClass','Get-ReportHref','Get-RunHtmlReport')",
    '$browsers = @(' + browsers.map(powershellQuote).join(',') + ')',
    '$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $requiredNames -contains $node.Name },$true)',
    'foreach ($function in $functions) { Invoke-Expression ([string]$function.Extent.Text) }',
    '$report = Get-Content -Encoding UTF8 -LiteralPath $reportPath -Raw | ConvertFrom-Json',
    '$lines = @(Get-RunSummaryLines $report)',
    '$summary = $lines -join [Environment]::NewLine',
    '$html = Get-RunHtmlReport $report "C:\\qa"',
    '$htmlText = @($html) -join ""',
    '$findingCount = @($lines | Where-Object { $_ -eq "  [HIGH] HTTP response failure" }).Count',
    'if ($findingCount -ne 13) { throw "Summary omitted findings: expected 13, received $findingCount." }',
    'if ($summary.IndexOf("FINDINGS (13 item(s); all reported items shown)",[StringComparison]::Ordinal) -lt 0) { throw "Summary finding count is missing." }',
    'if ($summary -notmatch "Confirmed automated violations: 0") { throw "Zero confirmed violations were not made explicit." }',
    'if ($summary -notmatch "Incomplete checks requiring review: 12") { throw "Incomplete review count is missing." }',
    `if ($summary.IndexOf('Cookie "__cf_bm" was rejected.',[StringComparison]::Ordinal) -lt 0) { throw "Curly quotation marks were not made readable in the ASCII terminal report." }`,
    `if ($htmlText -notmatch "Website test report" -or $htmlText -notmatch "Browser and navigation") { throw "The HTML report is missing its title or phase coverage." }`,
    `if ([regex]::Matches($htmlText, '<article class="finding(?: warning)?">').Count -ne 13) { throw "The HTML report did not show all 13 findings." }`,
    `if ($htmlText.IndexOf('&lt;img src=x onerror=alert(1)&gt;',[StringComparison]::Ordinal) -lt 0 -or $htmlText.IndexOf('<img src=x',[StringComparison]::Ordinal) -ge 0) { throw "Untrusted report text was not HTML-escaped." }`,
    `if ($htmlText.IndexOf('href="report.html"',[StringComparison]::Ordinal) -lt 0 -or !$lines.Where({ $_ -like '*HTML report:*' }).Count) { $allHrefs = @([regex]::Matches($htmlText,'href="[^"]+"') | ForEach-Object { $_.Value }) -join ' | '; $htmlLine = @($lines | Where-Object { $_ -like '*HTML report:*' }) -join ' | '; throw "The HTML report link or terminal evidence path is missing. Hrefs: $allHrefs; evidence line: $htmlLine" }`,
    `if ($summary -match "trace.zip|video.webm") { throw "The terminal evidence section expanded the trace/video file inventory." }`,
    'foreach ($rule in @("aria-prohibited-attr","color-contrast","color-contrast-enhanced")) { if ($summary -notmatch [regex]::Escape($rule)) { throw "Manual-review rule is missing: $rule" } }',
    'foreach ($browser in $browsers) { if ($summary -notmatch [regex]::Escape($browser)) { throw "Browser coverage is missing: $browser" } }',
    '$rerunCount = [regex]::Matches($summary,[regex]::Escape([string]$report.rerunCommand)).Count',
    'if ($rerunCount -ne 1) { throw "Rerun command was omitted or duplicated: expected one copy, received $rerunCount." }',
    'Write-Output "SUMMARY_FORMAT_REGRESSION_PASS"'
  ].join('\r\n') + '\r\n';
  fs.writeFileSync(scriptPath, script, 'utf8');
  const result = spawnSync(powershell, ['-NoProfile','-NoLogo','-NonInteractive','-File',scriptPath], {
    cwd: suite,
    encoding: 'utf8',
    windowsHide: true,
    timeout: 30000,
    maxBuffer: 8 * 1024 * 1024
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, 'summary formatter regression failed:\n' + result.stdout + '\n' + result.stderr);
  assert.match(result.stdout, /SUMMARY_FORMAT_REGRESSION_PASS/);
}

function writeSameProcessScript(filePath) {
  const envNames = ['TEMP','TMP','USERPROFILE','APPDATA','LOCALAPPDATA','HOME','PATH','NPM_CONFIG_CACHE','NPM_CONFIG_PREFIX','npm_config_userconfig','PLAYWRIGHT_BROWSERS_PATH','NODE_PATH'];
  const script = [
    "$ErrorActionPreference = 'Stop'",
    '$wrapper = ' + powershellQuote(publicScript),
    '$names = @(' + envNames.map(powershellQuote).join(',') + ')',
    '$before = @{}',
    'foreach ($name in $names) { $before[$name] = [Environment]::GetEnvironmentVariable($name,"Process") }',
    '$beforeOutput = $OutputEncoding.WebName',
    '$beforeConsoleOutput = [Console]::OutputEncoding.WebName',
    '$beforeConsoleInput = [Console]::InputEncoding.WebName',
    '$beforeLocation = (Get-Location).Path',
    '$beforeCurrentDirectory = [Environment]::CurrentDirectory',
    '$runOutput = & $wrapper -DryRun -PerformanceMode Smoke -MaxPages 2 -BrowserTimeoutMs 600000 -UpdateVisualBaseline -SkipToolUpdates',
    '$runCode = [int]$LASTEXITCODE',
    '$problems = @()',
    'foreach ($name in $names) { if ([Environment]::GetEnvironmentVariable($name,"Process") -cne $before[$name]) { $problems += ("environment not restored: " + $name) } }',
    'if ($OutputEncoding.WebName -cne $beforeOutput) { $problems += "OutputEncoding not restored" }',
    'if ([Console]::OutputEncoding.WebName -cne $beforeConsoleOutput) { $problems += "Console.OutputEncoding not restored" }',
    'if ([Console]::InputEncoding.WebName -cne $beforeConsoleInput) { $problems += "Console.InputEncoding not restored" }',
    'if ((Get-Location).Path -cne $beforeLocation) { $problems += "PowerShell location not restored" }',
    'if ([Environment]::CurrentDirectory -cne $beforeCurrentDirectory) { $problems += "process current directory not restored" }',
    'if ($runCode -ne 0) { $problems += ("positive dry run exit code was " + $runCode) }',
    'if ($problems.Count -gt 0) { Write-Output ("RESTORATION FAIL: " + ($problems -join "; ")); exit 42 }',
    'Write-Output "SAME_PROCESS_RESTORATION_PASS; subsequent PowerShell statements executed"'
  ].join('\r\n') + '\r\n';
  fs.writeFileSync(filePath, script, 'utf8');
}

async function main() {
  fs.mkdirSync(tempRoot, { recursive: true });
  const { server, origin } = await startLocalApi();
  let mock = null;
  let acceptanceStatus = 'failed';
  let failureMessage = '';
  try {
    const noApi = await runApiCase(origin, 'blank-api');
    assert.equal(noApi.code, 0);
    assert.equal(noApi.evidence.status, 'skipped');
    assert.match(noApi.stdout, /API: SKIPPED/);
    completedChecks.push('Blank API input skips API checks without inventing an endpoint.');

    const html = await runApiCase(origin, 'html-endpoint', { url: origin + '/html' });
    assert.equal(html.code, 0);
    assert.equal(html.evidence.status, 'passed');
    assert.equal(html.evidence.requests[0].statusCode, 200);
    assert.match(html.evidence.requests[0].contentType, /text\/html/i);
    completedChecks.push('Generated endpoint accepts an HTML homepage without imposing JSON semantics.');

    const schemaPath = path.join(tempRoot, 'contract.json');
    writeJson(schemaPath, { type: 'object', required: ['ok','items'], properties: { ok: { type: 'boolean' }, items: { type: 'array' } } });
    const schemaPass = await runApiCase(origin, 'json-schema-pass', { url: origin + '/json', schema: schemaPath });
    assert.equal(schemaPass.code, 0);
    assert.equal(schemaPass.evidence.status, 'passed');
    assert.equal(schemaPass.evidence.schemaConfigured, true);
    completedChecks.push('Explicit JSON schema accepts a matching response.');
    const mismatchPath = path.join(tempRoot, 'mismatch.json');
    writeJson(mismatchPath, { type: 'object', required: ['requiredButMissing'] });
    const schemaFail = await runApiCase(origin, 'json-schema-fail', { url: origin + '/json', schema: mismatchPath });
    assert.equal(schemaFail.code, 1);
    assert.equal(schemaFail.evidence.status, 'failed');
    assert(schemaFail.evidence.findings.some(value => /schema/i.test(value.message)));
    completedChecks.push('Explicit JSON schema rejects a mismatching response.');

    const custom404Path = path.join(tempRoot, 'expected-404.postman_collection.json');
    writeJson(custom404Path, expectedCollection('Expected 404', origin + '/missing', "pm.test('404 is expected', function () { pm.response.to.have.status(404); });"));
    const custom404 = await runApiCase(origin, 'custom-404', { collection: custom404Path });
    assert.equal(custom404.code, 0);
    assert.equal(custom404.evidence.status, 'passed');
    assert.equal(custom404.evidence.requests[0].statusCode, 404);
    completedChecks.push('Supplied collection preserves an explicit expected 404 status.');

    const custom204Path = path.join(tempRoot, 'expected-204.postman_collection.json');
    writeJson(custom204Path, expectedCollection('Expected 204', origin + '/empty', "pm.test('204 is expected', function () { pm.response.to.have.status(204); });"));
    const custom204 = await runApiCase(origin, 'custom-204', { collection: custom204Path });
    assert.equal(custom204.code, 0);
    assert.equal(custom204.evidence.status, 'passed');
    assert.equal(custom204.evidence.requests[0].statusCode, 204);
    completedChecks.push('Supplied collection preserves an explicit expected 204 status.');
    process.stdout.write('API SEMANTICS PASS: blank endpoint skips; HTML is not forced to JSON; explicit schemas pass/fail; supplied 404 and 204 expectations are preserved.\n');
    if (process.argv.includes('--api-only')) {
      acceptanceStatus = 'passed';
      process.stdout.write('API REGRESSION ACCEPTANCE PASS\n');
      return;
    }

    if (process.argv.includes('--k6-only')) {
      mock = await startMock();
      const k6Positive = runPublicPowerShell([
        '-TargetUrl', mock.url, '-ApiBaseUrl', mock.url, '-NonInteractive', '-PerformanceMode', 'Smoke',
        '-MaxPages', '1', '-SkipToolUpdates', '-ExitCodeOnCompletion'
      ], 1200000);
      assert.ifError(k6Positive.error);
      assert.equal(k6Positive.status, 2, 'local duplicate-endpoint k6 smoke should be incomplete only because no visual baseline was supplied:\n' + k6Positive.stdout + '\n' + k6Positive.stderr);
      const k6PositiveRun = findRunResult(k6Positive.stdout);
      reports.localK6PositiveRun = k6PositiveRun.overallPath;
      assert.equal(k6PositiveRun.overall.phases.api.status, 'passed');
      assert.equal(k6PositiveRun.overall.phases.browser.status, 'passed');
      assert.equal(k6PositiveRun.overall.phases.accessibility.status, 'passed');
      assert.equal(k6PositiveRun.overall.phases.visual.status, 'incomplete');
      assert.equal(k6PositiveRun.overall.performance.status, 'passed');
      assert.equal(k6PositiveRun.overall.performance.requests.count, 1);
      assert.equal(k6PositiveRun.overall.performance.requests.failed, 0);
      assert.equal(k6PositiveRun.overall.performance.requests.errorRate, 0);
      assert.match(k6PositiveRun.summary, /QA RESULT: INCOMPLETE/);
      completedChecks.push('Local k6 Smoke makes one successful request for duplicate URLs; API, browser, and accessibility pass, while visual comparison stays incomplete without a target baseline.');

      const k6Failure = runPublicPowerShell([
        '-TargetUrl', mock.url + 'server-error', '-NonInteractive', '-PerformanceMode', 'Smoke',
        '-MaxPages', '1', '-SkipToolUpdates', '-ExitCodeOnCompletion'
      ], 1200000);
      assert.ifError(k6Failure.error);
      assert.equal(k6Failure.status, 1, 'local HTTP 500 k6 smoke must produce a nonzero QA exit:\n' + k6Failure.stdout + '\n' + k6Failure.stderr);
      const k6FailureRun = findRunResult(k6Failure.stdout);
      reports.localK6Failure = k6FailureRun.overallPath;
      assert.equal(k6FailureRun.overall.status, 'FAIL');
      assert.equal(k6FailureRun.overall.phases.performance.status, 'failed');
      assert.equal(k6FailureRun.overall.performance.requests.count, 1);
      assert.equal(k6FailureRun.overall.performance.requests.failed, 1);
      assert.equal(k6FailureRun.overall.performance.requests.errorRate, 1);
      assert(k6FailureRun.overall.performance.observedRequestFailures.some(value => value.status === 500));
      assert(k6FailureRun.overall.performance.thresholds.some(value => value.name.startsWith('rate<') && value.passed === false));
      assert(k6FailureRun.overall.performance.thresholds.filter(value => value.name.startsWith('p(')).every(value => value.passed === true));
      assert.equal(k6FailureRun.overall.phases.browser.status, 'failed');
      const k6BrowserReport = JSON.parse(fs.readFileSync(path.join(k6FailureRun.runDir, 'playwright-runner.json'), 'utf8'));
      assert.equal(k6BrowserReport.status, 'failed');
      assert(k6BrowserReport.findings.some(value => /QA_BROWSER_FAILURES:/.test(value.message)));
      assert.match(k6FailureRun.summary, /Performance\s+FAILED\s+Smoke;\s+1 request\(s\), 1 failed;/);
      assert.match(k6FailureRun.summary, /\[HIGH\] Performance HTTP response failure/);
      assert.match(k6FailureRun.summary, /\[HIGH\] Performance threshold not met/);
      assert.match(k6FailureRun.summary, /HTTP error rate did not meet the configured limit: 100\.0000% observed, expected < 1\.00%\./);
      completedChecks.push('Local HTTP 500 Smoke preserves the failed browser status, one failed k6 request, accurate thresholds, and direct process exit code 1.');
      acceptanceStatus = 'passed';
      process.stdout.write('TARGETED K6 ACCEPTANCE PASS: duplicate endpoint made one request; HTTP 500 produced one recorded failed request and exit code 1.\n');
      return;
    }

    runSummaryFormatRegression();
     completedChecks.push('Summary formatter shows all findings without dumping trace/video inventories; the HTML report groups accessibility review, links evidence, and escapes untrusted text.');

    const sameProcessPath = path.join(tempRoot, 'same-process.ps1');
    writeSameProcessScript(sameProcessPath);
    const positive = runPowerShell(sameProcessPath, 1200000);
    assert.ifError(positive.error);
    assert.equal(positive.status, 0, 'positive same-process dry run failed:\n' + positive.stdout + '\n' + positive.stderr);
    assert.match(positive.stdout, /SAME_PROCESS_RESTORATION_PASS/);
    const positiveRun = findRunResult(positive.stdout);
    reports.localPositiveRun = positiveRun.overallPath;
    assert.equal(positiveRun.overall.status, 'PASS', positiveRun.summary);
    assert.equal(positiveRun.overall.phases.api.status, 'passed');
    assert.equal(positiveRun.overall.phases.browser.status, 'passed');
    assert.equal(positiveRun.overall.phases.accessibility.status, 'passed');
    assert.equal(positiveRun.overall.phases.visual.status, 'passed');
    assert.equal(positiveRun.overall.phases.performance.status, 'passed');
    assert.match(positiveRun.summary, /QA RESULT: PASS/);
    assert.match(positiveRun.summary, /EVIDENCE/i);
    assert.match(positiveRun.summary, /p95 .*limit < 1000 ms: PASS/);
    assert.match(positiveRun.summary, /p99 .*limit < 2000 ms: PASS/);
    assert.match(positiveRun.summary, /error budget < 1\.00%: PASS/);
    assert(positiveRun.overall.evidence.summary.startsWith(positiveRun.runDir));
    completedChecks.push('Local positive dry run passes all phases and ends with durable absolute evidence paths.');
    completedChecks.push('Same PowerShell process continues and restores environment, encodings, and location.');
    process.stdout.write('LOCAL POSITIVE PASS: all phases, same-terminal summary, evidence paths, and same-process environment/location/encoding restoration.\n');

    mock = await startMock();
    const negative = runPublicPowerShell([
      '-TargetUrl', mock.url + 'contrast', '-NonInteractive', '-PerformanceMode', 'Skip',
      '-MaxPages', '1', '-SkipToolUpdates', '-ExitCodeOnCompletion'
    ], 1200000);
    assert.ifError(negative.error);
    assert.equal(negative.status, 1, 'negative accessibility run must return failure code 1:\n' + negative.stdout + '\n' + negative.stderr);
    const negativeRun = findRunResult(negative.stdout);
    reports.localNegativeRun = negativeRun.overallPath;
    assert.equal(negativeRun.overall.status, 'FAIL');
    assert.equal(negativeRun.overall.phases.accessibility.status, 'failed');
    assert.equal(negativeRun.overall.phases.browser.status, 'passed');
    assert(negativeRun.overall.accessibility.violations.some(value => value.rule === 'color-contrast'));
    assert.match(negativeRun.summary, /color-contrast/);
    assert(negativeRun.summary.includes('serious') || negativeRun.summary.includes('high'));
    assert.equal(negativeRun.overall.phases.visual.status, 'incomplete');
    assert.match(negativeRun.summary, /QA RESULT: FAIL/);
    completedChecks.push('Local negative accessibility fixture reports serious color contrast and child exit code 1.');
    process.stdout.write('LOCAL NEGATIVE PASS: serious color contrast is preserved as an accessibility failure and the child process exits 1.\n');

    const browser404 = runPublicPowerShell([
      '-TargetUrl', mock.url + 'browser-404', '-NonInteractive', '-PerformanceMode', 'Skip',
      '-MaxPages', '2', '-SkipToolUpdates', '-ExitCodeOnCompletion'
    ], 1200000);
    assert.ifError(browser404.error);
    assert.equal(browser404.status, 1, 'browser HTTP 404 fixture must produce exit code 1:\n' + browser404.stdout + '\n' + browser404.stderr);
    const browser404Run = findRunResult(browser404.stdout);
    reports.localBrowser404Run = browser404Run.overallPath;
    const browser404Findings = browser404Run.overall.findings.filter(value => value.phase === 'browser' && value.status === 404);
    assert.equal(browser404Run.overall.phases.browser.status, 'failed');
    assert.equal(browser404Findings.length, 1, JSON.stringify(browser404Run.overall.findings, null, 2));
    assert.match(browser404Findings[0].url, /\/missing-404$/);
    assert.equal(browser404Findings[0].occurrences, 4);
    assert.equal(browser404Findings[0].browser.split(', ').length, 4);
    assert.match(browser404Run.summary, /HTTP 404/);
    assert.match(browser404Run.summary, /firefox-desktop/);
    assert.doesNotMatch(browser404Run.summary, /Playwright runner finding/);
    assert.doesNotMatch(browser404Run.summary, /at F:\\.*qa\.spec\.js:/i);
    assert.match(browser404Run.summary, /Playwright runner results:/);
    assert.match(browser404Run.summary, /Browser data fragments:/);
    assert.equal((browser404Run.summary.match(/^RERUN$/gm) || []).length, 1);
    completedChecks.push('Local browser HTTP 404 is grouped across all four projects with its status and route; duplicate Playwright stack output is suppressed while runner and fragment evidence paths remain available.');
    process.stdout.write('LOCAL BROWSER FINDING PASS: HTTP 404, route, affected browser projects, and concise summary are preserved.\n');

    const consoleError = runPublicPowerShell([
      '-TargetUrl', mock.url + 'console-error', '-NonInteractive', '-PerformanceMode', 'Skip',
      '-MaxPages', '1', '-SkipToolUpdates', '-ExitCodeOnCompletion'
    ], 1200000);
    assert.ifError(consoleError.error);
    assert.equal(consoleError.status, 1, 'browser console error fixture must produce exit code 1:\n' + consoleError.stdout + '\n' + consoleError.stderr);
    const consoleErrorRun = findRunResult(consoleError.stdout);
    reports.localBrowserConsoleErrorRun = consoleErrorRun.overallPath;
    const consoleErrorFindings = consoleErrorRun.overall.findings.filter(value => value.phase === 'browser' && value.title === 'JavaScript console error');
    assert.equal(consoleErrorRun.overall.phases.browser.status, 'failed');
    assert.equal(consoleErrorFindings.length, 1, JSON.stringify(consoleErrorRun.overall.findings, null, 2));
    assert.match(consoleErrorFindings[0].details, /QA_FIXTURE_CONSOLE_ERROR/);
    assert.equal(consoleErrorFindings[0].occurrences, 4);
    assert.equal(consoleErrorFindings[0].browser.split(', ').length, 4);
    assert(consoleErrorFindings[0].sourceLocations.length > 0);
    assert.match(consoleErrorRun.summary, /\[HIGH\] JavaScript console error/);
    completedChecks.push('Local JavaScript console.error is reported, grouped across all four browser projects, and fails the browser phase.');
    process.stdout.write('LOCAL CONSOLE ERROR PASS: logged JavaScript errors are visible as actionable browser findings.\n');

    const k6Failure = runPublicPowerShell([
      '-TargetUrl', mock.url + 'server-error', '-NonInteractive', '-PerformanceMode', 'Smoke',
      '-MaxPages', '1', '-SkipToolUpdates', '-ExitCodeOnCompletion'
    ], 1200000);
    assert.ifError(k6Failure.error);
    assert.equal(k6Failure.status, 1, 'HTTP 500 smoke must produce a nonzero QA exit:\n' + k6Failure.stdout + '\n' + k6Failure.stderr);
    const k6FailureRun = findRunResult(k6Failure.stdout);
    reports.localK6Failure = k6FailureRun.overallPath;
    assert.equal(k6FailureRun.overall.status, 'FAIL');
    assert.equal(k6FailureRun.overall.phases.performance.status, 'failed');
    assert.equal(k6FailureRun.overall.performance.requests.count, 1);
    assert.equal(k6FailureRun.overall.performance.requests.failed, 1);
    assert.equal(k6FailureRun.overall.performance.requests.errorRate, 1);
    assert(k6FailureRun.overall.performance.observedRequestFailures.some(value => value.status === 500));
    assert.equal(k6FailureRun.overall.phases.browser.status, 'failed');
    const k6BrowserReport = JSON.parse(fs.readFileSync(path.join(k6FailureRun.runDir, 'playwright-runner.json'), 'utf8'));
    assert.equal(k6BrowserReport.status, 'failed');
    assert(k6BrowserReport.findings.some(value => /QA_BROWSER_FAILURES:/.test(value.message)));
    assert.match(k6FailureRun.summary, /Performance\s+FAILED\s+Smoke;\s+1 request\(s\), 1 failed;/);
    assert.match(k6FailureRun.summary, /\[HIGH\] Performance HTTP response failure/);
    assert.match(k6FailureRun.summary, /\[HIGH\] Performance threshold not met/);
    assert.match(k6FailureRun.summary, /HTTP error rate did not meet the configured limit: 100\.0000% observed, expected < 1\.00%\./);
    completedChecks.push('Local HTTP 500 smoke preserves the failed browser status, observed k6 request failure, threshold failure, and direct process exit code 1.');
    process.stdout.write('LOCAL K6 NEGATIVE PASS: one HTTP 500 is recorded as one failed request and returns exit code 1.\n');
    acceptanceStatus = 'passed';
    process.stdout.write('REGRESSION ACCEPTANCE PASS\n');
  } catch (error) {
    failureMessage = String(error.stack || error.message || error);
    throw error;
  } finally {
    await new Promise(resolve => server.close(resolve));
    if (mock && mock.child.exitCode === null) mock.child.kill();
    try {
      const evidencePath = persistAcceptance(acceptanceStatus,failureMessage);
      process.stdout.write('ACCEPTANCE EVIDENCE: ' + evidencePath + '\n');
    } catch (error) {
      process.stderr.write('Could not preserve acceptance evidence: ' + (error.message || error) + '\n');
      if (!failureMessage) process.exitCode = 1;
    }
    try { fs.rmSync(tempRoot, { recursive: true, force: true }); }
    catch (error) { process.stderr.write('Could not remove regression temp directory: ' + (error.message || error) + '\n'); process.exitCode = 1; }
  }
}

main().catch(error => {
  process.stderr.write('REGRESSION ACCEPTANCE FAIL: ' + (error.stack || error.message || error) + '\n');
  process.exitCode = 1;
});
