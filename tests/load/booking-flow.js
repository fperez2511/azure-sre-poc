// k6 load test for the critical user flows, with the SLOs encoded as thresholds
// ("SLOs as code"): the run FAILS if the SLOs are not met.
//
//   k6 run -e BASE_URL=$SERVICE_API_URI tests/load/booking-flow.js
//   k6 run -e BASE_URL=$SERVICE_API_URI -e VUS=20 -e DURATION=5m tests/load/booking-flow.js
//
// Install k6: https://grafana.com/docs/k6/latest/set-up/install-k6/
// Tip: run it while a chaos experiment is active and watch which thresholds break.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL;
if (!BASE_URL) {
  throw new Error('Set BASE_URL, e.g. -e BASE_URL=https://ca-api-xxxx.<region>.azurecontainerapps.io');
}

export const options = {
  scenarios: {
    shoppers: {
      executor: 'constant-vus',
      vus: Number(__ENV.VUS || 5),
      duration: __ENV.DURATION || '2m',
    },
  },
  thresholds: {
    // Availability SLO 99.5% -> at most 0.5% of requests may fail (5xx / network errors).
    http_req_failed: ['rate<0.005'],
    'checks{flow:browse}': ['rate>0.995'],
    'checks{flow:book}': ['rate>0.995'],
    // Latency SLOs (95th percentile)
    'http_req_duration{flow:browse}': ['p(95)<300'],
    'http_req_duration{flow:book}': ['p(95)<800'],
  },
};

const offerings = [
  { id: 'career-1on1-60', attendees: 1 },
  { id: 'group-circle-90', attendees: 3 },
  { id: 'workshop-resilience-halfday', attendees: 15 },
  { id: 'biz-keynote-60', attendees: 120 },
];

function isoInDays(days) {
  const d = new Date(Date.now() + days * 24 * 3600 * 1000);
  d.setUTCMinutes(0, 0, 0);
  return d.toISOString().replace('.000Z', '+00:00');
}

export default function () {
  const browse = http.get(`${BASE_URL}/api/offerings`, { tags: { flow: 'browse' } });
  check(browse, { 'browse: not 5xx': (r) => r.status > 0 && r.status < 500 }, { flow: 'browse' });

  if (Math.random() < 0.4) {
    const o = offerings[Math.floor(Math.random() * offerings.length)];
    const customer = `cust-k6-${__VU}`;
    const payload = JSON.stringify({
      offeringId: o.id,
      customerId: customer,
      customerEmail: `${customer}@example.com`,
      startTimeUtc: isoInDays(2 + Math.floor(Math.random() * 50)),
      attendees: o.attendees,
    });
    const book = http.post(`${BASE_URL}/api/bookings`, payload, {
      headers: { 'Content-Type': 'application/json', 'Idempotency-Key': `k6-${__VU}-${__ITER}-${Date.now()}` },
      tags: { flow: 'book' },
    });
    check(book, { 'book: 201 or 200': (r) => r.status === 201 || r.status === 200 }, { flow: 'book' });
  }

  sleep(1);
}
