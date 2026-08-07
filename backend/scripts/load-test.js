'use strict';

const baseUrl = String(process.env.LOAD_BASE_URL || 'http://127.0.0.1:3000').replace(/\/$/, '');
const concurrency = Math.min(200, Math.max(1, Number(process.env.LOAD_CONCURRENCY) || 20));
const durationSeconds = Math.min(600, Math.max(5, Number(process.env.LOAD_DURATION_SECONDS) || 30));
const requestsPerSecond = Math.min(2000, Math.max(1, Number(process.env.LOAD_REQUESTS_PER_SECOND) || 20));
const target = `${baseUrl}${process.env.LOAD_PATH || '/health'}`;

async function worker(deadline, totals) {
  const minimumIntervalMs = Math.ceil((1000 * concurrency) / requestsPerSecond);
  while (Date.now() < deadline) {
    const started = performance.now();
    try {
      const response = await fetch(target, { signal: AbortSignal.timeout(10000) });
      totals.codes[response.status] = (totals.codes[response.status] || 0) + 1;
      if (!response.ok) totals.failed += 1;
      await response.arrayBuffer();
    } catch (_) {
      totals.failed += 1;
    }
    totals.latencies.push(performance.now() - started);
    const remainingDelay = minimumIntervalMs - (performance.now() - started);
    if (remainingDelay > 0) await new Promise((resolve) => setTimeout(resolve, remainingDelay));
  }
}

async function main() {
  if (!/^https?:\/\//.test(target)) throw new Error('LOAD_BASE_URL invalida');
  const totals = { failed: 0, codes: {}, latencies: [] };
  const deadline = Date.now() + durationSeconds * 1000;
  await Promise.all(Array.from({ length: concurrency }, () => worker(deadline, totals)));
  totals.latencies.sort((a, b) => a - b);
  const percentile = (p) => totals.latencies[Math.min(totals.latencies.length - 1,
    Math.floor(totals.latencies.length * p))] || 0;
  const result = {
    target, concurrency, durationSeconds, configuredRequestsPerSecond: requestsPerSecond,
    requests: totals.latencies.length,
    achievedRequestsPerSecond: Number((totals.latencies.length / durationSeconds).toFixed(2)),
    failed: totals.failed, statusCodes: totals.codes,
    latencyMs: { p50: Math.round(percentile(.5)), p95: Math.round(percentile(.95)), p99: Math.round(percentile(.99)) },
  };
  console.log(JSON.stringify(result, null, 2));
  if (totals.failed > Math.max(1, totals.latencies.length * .01)) process.exitCode = 1;
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
