'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = process.env.QA_SUITE_ROOT;
const report = process.env.QA_API_REPORT;
const tempFile = process.env.QA_TEMP_COLLECTION;
const schemaPath = process.env.QA_API_SCHEMA_PATH || '';
const sourcePath = process.env.QA_API_COLLECTION || '';
const baseUrl = process.env.QA_API_BASE_URL || '';
const maxMs = Number(process.env.QA_API_TIMEOUT_MS || 5000);
const newmanCli = path.join(root, 'postman-cli', 'node_modules', 'newman', 'bin', 'newman.js');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function testEvent() {
  return {
    listen: 'test',
    script: {
      type: 'text/javascript',
      exec: [
        'pm.test("QA: successful status", function () { pm.expect(pm.response.code).to.be.within(200, 299); });',
        'pm.test("QA: response time within budget", function () { pm.expect(pm.response.responseTime).to.be.at.most(Number(pm.collectionVariables.get("qaMaxApiMs") || 5000)); });',
        'pm.test("QA: JSON response and object payload", function () { var ct = (pm.response.headers.get("Content-Type") || "").toLowerCase(); pm.expect(ct).to.include("json"); var body = pm.response.json(); pm.expect(body).to.be.an("object"); });',
        'var qaSchema = pm.collectionVariables.get("qaContractSchema");',
        'if (qaSchema) { pm.test("QA: JSON schema contract", function () { pm.response.to.have.jsonSchema(JSON.parse(qaSchema)); }); }'
      ]
    }
  };
}
function addTests(items) {
  for (const item of items || []) {
    if (Array.isArray(item.item)) addTests(item.item);
    if (item.request) {
      item.event = Array.isArray(item.event) ? item.event : [];
      item.event.push(testEvent());
    }
  }
}
try {
  let collection;
  if (sourcePath) {
    collection = JSON.parse(fs.readFileSync(sourcePath, 'utf8'));
  } else {
    collection = {
      info: { name: 'Portable QA generated API contract', schema: 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json' },
      item: [{ name: 'API base endpoint', request: { method: 'GET', header: [], url: baseUrl } }]
    };
  }
  assert(collection && Array.isArray(collection.item) && collection.item.length > 0, 'Postman collection contains no requests.');
  collection.variable = Array.isArray(collection.variable) ? collection.variable : [];
  const schema = schemaPath ? fs.readFileSync(schemaPath, 'utf8') : '';
  collection.variable = collection.variable.filter(v => !['qaMaxApiMs', 'qaContractSchema'].includes(v.key));
  collection.variable.push({ key: 'qaMaxApiMs', value: String(maxMs), type: 'string' });
  collection.variable.push({ key: 'qaContractSchema', value: schema, type: 'string' });
  addTests(collection.item);
  fs.writeFileSync(tempFile, JSON.stringify(collection, null, 2), 'utf8');

  const args = [newmanCli, 'run', tempFile, '--reporters', 'cli,json', '--reporter-json-export', report, '--timeout-request', String(maxMs)];
  if (baseUrl) args.push('--env-var', 'baseUrl=' + baseUrl);
  const result = spawnSync(process.execPath, args, { cwd: root, env: process.env, stdio: 'inherit', windowsHide: true });
  if (result.error) throw result.error;
  process.exitCode = result.status === null ? 1 : result.status;
} catch (error) {
  process.stderr.write('API collection preparation failed: ' + error.message + '\n');
  process.exitCode = 1;
} finally {
  try { if (fs.existsSync(tempFile)) fs.unlinkSync(tempFile); } catch (_) {}
}
