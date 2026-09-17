'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = process.env.QA_SUITE_ROOT || path.resolve(__dirname, '..');
const reportPath = process.env.QA_API_REPORT;
const schemaPath = process.env.QA_API_SCHEMA_PATH || '';
const sourcePath = process.env.QA_API_COLLECTION || '';
const baseUrl = process.env.QA_API_BASE_URL || '';
const maxMs = Number(process.env.QA_API_TIMEOUT_MS || 5000);
const maxRequests = Number(process.env.QA_API_MAX_REQUESTS || 1000);
const maxRunMs = Number(process.env.QA_API_MAX_RUN_MS || 300000);
const newmanPath = path.join(root, 'postman-cli', 'node_modules', 'newman');

function writeJsonAtomic(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const temporary = filePath + '.tmp';
  fs.writeFileSync(temporary, JSON.stringify(value, null, 2) + '\n', 'utf8');
  fs.renameSync(temporary, filePath);
}

function redactUrl(value) {
  if (!value) return '';
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

function safeError(error) {
  if (!error) return '';
  return String(error.message || error).replace(/[\r\n\t]+/g, ' ').replace(/https?:\/\/[^\s"'<>]+/g, value => redactUrl(value.replace(/[),.;]+$/, ''))).slice(0, 500);
}

function listRequests(items, output = []) {
  for (const item of items || []) {
    if (item && Array.isArray(item.item)) listRequests(item.item, output);
    else if (item && item.request) output.push(item);
  }
  return output;
}

function getCollectionVariable(collection, key) {
  const vars = Array.isArray(collection.variable) ? collection.variable : [];
  const found = vars.find(value => value && value.key === key);
  return found ? String(found.value || '') : '';
}

function setCollectionVariable(collection, key, value) {
  collection.variable = Array.isArray(collection.variable) ? collection.variable : [];
  const found = collection.variable.find(entry => entry && entry.key === key);
  if (found) {
    found.value = String(value);
    found.type = 'string';
  } else {
    collection.variable.push({ key, value: String(value), type: 'string' });
  }
}

function addTestEvent(item, lines) {
  item.event = Array.isArray(item.event) ? item.event : [];
  item.event.push({ listen: 'test', script: { type: 'text/javascript', exec: lines } });
}

function extractResponseHeader(response, name) {
  try {
    if (response && response.headers && typeof response.headers.get === 'function') return response.headers.get(name) || '';
    const header = (response && response.headers || []).find(value => String(value.key).toLowerCase() === name.toLowerCase());
    return header ? String(header.value || '') : '';
  } catch (_) {
    return '';
  }
}

function extractUrl(request) {
  if (!request || !request.url) return '';
  try {
    return typeof request.url.toString === 'function' ? request.url.toString() : String(request.url);
  } catch (_) {
    return '';
  }
}

function formatSummary(result) {
  if (result.status === 'skipped') return 'API: SKIPPED - ' + result.reason;
  if (result.status === 'passed') {
    return 'API: PASS - ' + result.requests.length + ' request(s), ' + result.assertions.passed +
      '/' + result.assertions.total + ' assertion(s) passed';
  }
  const lines = ['API: ' + result.status.toUpperCase() + ' - ' + result.requests.length +
    ' request(s), ' + result.assertions.failed + ' assertion failure(s)'];
  for (const finding of result.findings.slice(0, 5)) {
    lines.push('  ' + finding.request + ' | ' + (finding.url || '[URL unavailable]') + ' | ' + finding.message);
  }
  return lines.join('\n');
}

async function main() {
  if (!reportPath) throw new Error('QA_API_REPORT is required.');
  if (!Number.isFinite(maxMs) || maxMs < 100 || maxMs > 600000) throw new Error('API timeout must be between 100 and 600000 milliseconds.');
  if (!Number.isInteger(maxRequests) || maxRequests < 1 || maxRequests > 10000) throw new Error('API request limit must be between 1 and 10000.');
  if (!Number.isInteger(maxRunMs) || maxRunMs < 1000 || maxRunMs > 1800000) throw new Error('API run timeout must be between 1000 and 1800000 milliseconds.');

  if (!sourcePath && !baseUrl) {
    const skipped = {
      status: 'skipped',
      reason: 'No API endpoint or Postman collection was supplied. Website checks still run.',
      generatedUtc: new Date().toISOString(),
      requests: [],
      assertions: { total: 0, passed: 0, failed: 0 },
      findings: []
    };
    writeJsonAtomic(reportPath, skipped);
    process.stdout.write(formatSummary(skipped) + '\n');
    return 0;
  }

  let collection;
  let schema = null;
  let schemaForRequests = false;
  const generated = !sourcePath;
  if (sourcePath) collection = JSON.parse(fs.readFileSync(sourcePath, 'utf8'));
  else {
    collection = {
      info: { name: 'Portable QA HTTP check', schema: 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json' },
      item: [{ name: 'API endpoint', request: { method: 'GET', header: [], url: baseUrl } }]
    };
  }
  if (!collection || !Array.isArray(collection.item) || collection.item.length === 0) throw new Error('Postman collection contains no requests.');

  if (schemaPath) {
    schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
    if (!schema || typeof schema !== 'object' || Array.isArray(schema)) throw new Error('JSON schema must be a JSON object.');
    schemaForRequests = generated || getCollectionVariable(collection, 'qaValidateJsonSchema').toLowerCase() === 'true';
  }

  const requests = listRequests(collection.item);
  if (requests.length === 0) throw new Error('Postman collection contains no runnable requests.');
  if (requests.length > maxRequests) throw new Error('Postman collection has ' + requests.length + ' requests; the configured safety limit is ' + maxRequests + '.');

  const tests = {
    responseTime: [
      'pm.test("QA: response time within configured budget", function () {',
      '  pm.expect(pm.response.responseTime).to.be.at.most(Number(pm.collectionVariables.get("qaMaxApiMs") || 5000));',
      '});'
    ],
    expectedStatus: [
      'pm.test("QA: expected successful HTTP status", function () {',
      '  pm.expect(pm.response.code).to.be.within(200, 399);',
      '});'
    ],
    schema: [
      'pm.test("QA: configured JSON schema contract", function () {',
      '  var raw = pm.collectionVariables.get("qaContractSchema");',
      '  pm.expect(raw, "QA schema was not supplied").to.be.a("string").and.not.empty;',
      '  pm.response.to.have.jsonSchema(JSON.parse(raw));',
      '});'
    ]
  };

  setCollectionVariable(collection, 'qaMaxApiMs', String(maxMs));
  if (baseUrl) setCollectionVariable(collection, 'baseUrl', baseUrl);
  if (schemaForRequests) {
    setCollectionVariable(collection, 'qaContractSchema', JSON.stringify(schema));
    setCollectionVariable(collection, 'qaValidateJsonSchema', 'true');
  }
  for (const item of requests) {
    addTestEvent(item, tests.responseTime);
    if (generated) {
      addTestEvent(item, tests.expectedStatus);
      if (schemaForRequests) addTestEvent(item, tests.schema);
    } else if (schemaForRequests) addTestEvent(item, tests.schema);
  }

  const run = {
    generatedUtc: new Date().toISOString(),
    status: 'incomplete',
    endpoint: baseUrl ? redactUrl(baseUrl) : '',
    collection: sourcePath ? path.basename(sourcePath) : '',
    schemaConfigured: schemaForRequests,
    assertions: { total: 0, passed: 0, failed: 0 },
    requests: [],
    findings: [],
    runnerError: ''
  };

  const newman = require(newmanPath);
  await new Promise(resolve => {
    let abortedForLimit = false;
    let seen = 0;
    const runner = newman.run({
      collection,
      reporters: [],
      timeout: maxRunMs,
      timeoutRequest: maxMs,
      iterationCount: 1
    }, (error, summary) => {
      run.runnerError = safeError(error);
      if (abortedForLimit) run.runnerError = 'Newman exceeded the request safety limit.';
      const result = summary && summary.run;
      const executions = result && Array.isArray(result.executions) ? result.executions : [];
      const assertionRecords = [];
      for (const execution of executions) {
        const itemName = execution.item && execution.item.name ? String(execution.item.name) : 'Unnamed request';
        const response = execution.response || null;
        const request = execution.request || {};
        const assertionResults = (execution.assertions || []).map(assertion => {
          const errorText = safeError(assertion.error);
          const record = { name: String(assertion.assertion || 'Unnamed assertion'), passed: !assertion.error, message: errorText };
          assertionRecords.push(record);
          return record;
        });
        const requestResult = {
          name: itemName,
          method: String(request.method || ''),
          url: redactUrl(extractUrl(request)),
          statusCode: response && Number.isFinite(Number(response.code)) ? Number(response.code) : null,
          status: response && response.status ? String(response.status) : '',
          contentType: extractResponseHeader(response, 'content-type'),
          latencyMs: response && Number.isFinite(Number(response.responseTime)) ? Number(response.responseTime) : null,
          assertions: assertionResults
        };
        run.requests.push(requestResult);
        for (const assertion of assertionResults) {
          if (!assertion.passed) run.findings.push({
            request: requestResult.name,
            url: requestResult.url,
            message: assertion.name + (assertion.message ? ': ' + assertion.message : '')
          });
        }
        if (!response && execution.requestError) run.findings.push({
          request: itemName,
          url: redactUrl(extractUrl(request)),
          message: safeError(execution.requestError) || 'Request did not receive a response.'
        });
      }
      const stats = result && result.stats && result.stats.assertions;
      run.assertions = {
        total: stats && Number.isFinite(Number(stats.total)) ? Number(stats.total) : assertionRecords.length,
        failed: stats && Number.isFinite(Number(stats.failed)) ? Number(stats.failed) : assertionRecords.filter(value => !value.passed).length,
        passed: 0
      };
      run.assertions.passed = Math.max(0, run.assertions.total - run.assertions.failed);
      if (run.runnerError) {
        run.status = 'error';
        run.findings.unshift({ request: '[runner]', url: '', message: run.runnerError });
      } else if (run.assertions.failed > 0 || run.findings.length > 0 || (result && result.failures && result.failures.length > 0)) {
        run.status = 'failed';
      } else if (run.requests.length === 0 || run.requests.some(value => value.statusCode === null)) {
        run.status = 'incomplete';
        run.findings.push({ request: '[runner]', url: '', message: 'One or more requests have no response record.' });
      } else {
        run.status = 'passed';
      }
      resolve();
    });
    if (runner && typeof runner.on === 'function') runner.on('request', () => {
      seen += 1;
      if (seen > maxRequests && !abortedForLimit) {
        abortedForLimit = true;
        if (typeof runner.abort === 'function') runner.abort();
      }
    });
  });

  writeJsonAtomic(reportPath, run);
  process.stdout.write(formatSummary(run) + '\n');
  return run.status === 'passed' || run.status === 'skipped' ? 0 : run.status === 'failed' ? 1 : 2;
}

main().then(code => {
  process.exitCode = code;
}).catch(error => {
  const result = {
    status: 'error',
    generatedUtc: new Date().toISOString(),
    requests: [],
    assertions: { total: 0, passed: 0, failed: 0 },
    findings: [{ request: '[configuration]', url: '', message: safeError(error) }],
    runnerError: safeError(error)
  };
  try {
    if (reportPath) writeJsonAtomic(reportPath, result);
  } catch (_) {
    // The terminal still receives the failure when the report directory is unwritable.
  }
  process.stderr.write('API: ERROR - ' + safeError(error) + '\n');
  process.exitCode = 2;
});
