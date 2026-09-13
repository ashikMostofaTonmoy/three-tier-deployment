// Everything Prometheus scrapes from this process, at GET /metrics.
//
// Two different KINDS of metric live here on purpose — keep them mentally
// separate, the README (§36) leans on this distinction:
//
//   1. HTTP metrics (httpRequestsTotal, httpRequestDuration) — describe the
//      WEB LAYER. They'd look almost the same no matter what this app did.
//   2. Business metrics (weatherSearchesTotal, weatherCurrentTemperature) —
//      describe THIS APP. A generic "requests per second" dashboard can't
//      tell you "which city do people check most" or "what's the weather
//      right now, according to the last person who asked" — these can.
//
// A "Counter" only ever goes up (good for "how many"); a "Gauge" can go up
// or down (good for "what is the value right now"); a "Histogram" buckets
// observations so you can ask "how long do requests take, at the 95th
// percentile" later, in Prometheus, without deciding percentiles in advance.
import express from 'express';
import client from 'prom-client';
import { logger } from './logger.js';

export const registry = new client.Registry();

// Default Node.js process metrics (heap, event loop lag, GC, open handles) —
// free, and genuinely useful for spotting a memory leak or event-loop stall.
client.collectDefaultMetrics({ register: registry });

export const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests handled, by method/route/status code',
  labelNames: ['method', 'route', 'status_code'],
  registers: [registry],
});

export const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds, by method/route',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [registry],
});

// --- business/application metrics -----------------------------------------
export const weatherSearchesTotal = new client.Counter({
  name: 'weather_search_requests_total',
  help: 'Total weather lookups, by city',
  labelNames: ['city'],
  registers: [registry],
});

export const weatherCurrentTemperature = new client.Gauge({
  name: 'weather_current_temperature_celsius',
  help: 'Temperature returned by the last lookup for each city',
  labelNames: ['city'],
  registers: [registry],
});

// Express middleware: times every request, records it under a normalised
// route (req.route.path, e.g. "/api/v1/forecast" — NOT the raw URL, which
// would create a new time series per query string and blow up Prometheus's
// cardinality) once the response has actually finished.
export function metricsMiddleware(req, res, next) {
  const start = process.hrtime.bigint();
  res.on('finish', () => {
    const route = req.route?.path || req.path;
    const seconds = Number(process.hrtime.bigint() - start) / 1e9;
    const labels = { method: req.method, route, status_code: res.statusCode };
    httpRequestsTotal.inc(labels);
    httpRequestDuration.observe(labels, seconds);
  });
  next();
}

// --- the cluster-mode gotcha, and why /metrics gets its own port -----------
//
// This backend runs as 2 PM2 "cluster mode" processes sharing port 3000
// (README §13/§15). That's great for zero-downtime deploys — but it quietly
// breaks metrics if you're not careful: `registry` above lives in ONE
// process's memory. If /metrics were served on the shared port 3000, every
// scrape would land on whichever of the 2 workers the OS/PM2 happens to
// round-robin the connection to — so a `Counter` you were told only ever
// goes up could appear to Prometheus to jump UP and DOWN between scrapes
// (worker A's count, then worker B's, then worker A's again), and any
// query that assumes "this is the total" is quietly wrong half the time.
//
// The fix: give each worker its OWN metrics port, so Prometheus scrapes
// both workers as two separate targets and combines them itself with
// `sum by (...)` in PromQL (see the dashboard queries in
// monitoring/dashboards/three-tier-app-dashboard.json). PM2 sets
// NODE_APP_INSTANCE to 0, 1, 2... automatically for each cluster worker —
// that's all we need to pick a distinct port per worker.
const METRICS_PORT = 9200 + Number(process.env.NODE_APP_INSTANCE || 0);

export function startMetricsServer() {
  const metricsApp = express();
  metricsApp.get('/metrics', async (req, res) => {
    res.set('Content-Type', registry.contentType);
    res.end(await registry.metrics());
  });
  // 127.0.0.1 only — Prometheus is on this same machine (README §12); this
  // port is never opened in the security group.
  metricsApp.listen(METRICS_PORT, '127.0.0.1', () => {
    logger.info({ port: METRICS_PORT }, 'metrics server listening');
  });
}
