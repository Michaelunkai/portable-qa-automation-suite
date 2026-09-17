import http from 'k6/http';
import { check, sleep } from 'k6';

const target = __ENV.QA_TARGET_URL;
const api = __ENV.QA_API_BASE_URL || '';
const mode = String(__ENV.QA_PERFORMANCE_MODE || 'smoke').toLowerCase();
const vus = Math.max(1, Number(__ENV.QA_VUS || 5));
const ramp = Math.max(1, Number(__ENV.QA_RAMP_SECONDS || 5));
const hold = Math.max(1, Number(__ENV.QA_HOLD_SECONDS || 10));
const p95 = Math.max(1, Number(__ENV.QA_P95_MS || 1000));
const p99 = Math.max(p95, Number(__ENV.QA_P99_MS || 2000));
const errorRate = Math.min(10, Math.max(0, Number(__ENV.QA_ERROR_RATE_PERCENT || 1))) / 100;

function normalizeEndpoint(value) {
  const raw = String(value || '').trim();
  const match = /^([A-Za-z][A-Za-z0-9+.-]*:\/\/)([^/?#]*)([\s\S]*)$/.exec(raw);
  if (!match) return raw.replace(/\/+$/, '');

  const scheme = match[1].toLowerCase();
  const authority = match[2];
  const at = authority.lastIndexOf('@');
  const userInfo = at < 0 ? '' : authority.slice(0, at + 1);
  let hostPort = (at < 0 ? authority : authority.slice(at + 1)).toLowerCase();
  if ((scheme === 'http://' && hostPort.endsWith(':80')) || (scheme === 'https://' && hostPort.endsWith(':443'))) {
    hostPort = hostPort.slice(0, hostPort.lastIndexOf(':'));
  }

  const suffix = match[3] || '/';
  const queryOrFragment = suffix.search(/[?#]/);
  const pathname = queryOrFragment < 0 ? suffix : suffix.slice(0, queryOrFragment);
  const remainder = queryOrFragment < 0 ? '' : suffix.slice(queryOrFragment);
  const normalizedPath = (pathname || '/').replace(/\/+$/, '') || '/';
  return scheme + userInfo + hostPort + normalizedPath + remainder;
}

const endpoints = [['website', target]];
if (api) {
  const normalizedTarget = normalizeEndpoint(target);
  const normalizedApi = normalizeEndpoint(api);
  if (normalizedApi !== normalizedTarget) endpoints.push(['api', api]);
}

const scenarios = mode === 'load'
  ? {
      bounded_load: {
        executor: 'ramping-vus',
        startVUs: 1,
        stages: [
          { duration: String(ramp) + 's', target: vus },
          { duration: String(hold) + 's', target: vus },
          { duration: String(ramp) + 's', target: 0 }
        ],
        gracefulRampDown: '2s',
        gracefulStop: '2s'
      }
    }
  : {
      bounded_smoke: {
        executor: 'shared-iterations',
        vus: 1,
        iterations: 1,
        maxDuration: '30s',
        gracefulStop: '1s'
      }
    };

export const options = {
  scenarios,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  thresholds: {
    http_req_failed: ['rate<' + errorRate],
    http_req_duration: ['p(95)<' + p95, 'p(99)<' + p99]
  }
};

export default function () {
  for (const [name, url] of endpoints) {
    const response = http.get(url, {
      tags: { qa_target: name },
      timeout: '10s',
      redirects: 5
    });
    check(response, {
      [name + ' returned a successful HTTP response']: value => value.status >= 200 && value.status < 400
    });
    if (response.status < 200 || response.status >= 400) {
      console.warn('QA_HTTP_FAILURE ' + JSON.stringify({
        target: name,
        url,
        status: response.status,
        error: response.error || ''
      }));
    }
    sleep(mode === 'load' ? 1 : 0.25);
  }
}
