import http from 'k6/http';
import { check } from 'k6';

const target = __ENV.QA_TARGET_URL;
const api = __ENV.QA_API_BASE_URL || target;
const vus = Math.max(1, Number(__ENV.QA_VUS || 5));
const ramp = Math.max(1, Number(__ENV.QA_RAMP_SECONDS || 5));
const hold = Math.max(1, Number(__ENV.QA_HOLD_SECONDS || 10));
const p95 = Math.max(1, Number(__ENV.QA_P95_MS || 1000));
const p99 = Math.max(p95, Number(__ENV.QA_P99_MS || 2000));

export const options = {
  scenarios: {
    ramped_qa: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: String(ramp) + 's', target: vus },
        { duration: String(hold) + 's', target: vus },
        { duration: String(ramp) + 's', target: 0 }
      ]
    }
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<' + p95, 'p(99)<' + p99]
  }
};

export default function () {
  for (const [label, url] of [['ui', target], ['api', api]]) {
    const response = http.get(url, { tags: { pathway: label }, timeout: '30s' });
    check(response, {
      [label + ' returns 2xx/3xx']: r => r.status >= 200 && r.status < 400,
      [label + ' responds within p99 budget']: r => r.timings.duration < p99
    });
  }
}
