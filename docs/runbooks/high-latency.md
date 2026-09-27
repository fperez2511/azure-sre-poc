# Runbook: Booking API is slow

| | |
|---|---|
| **Alerts** | `alert-api-latency-*` (Sev3), `alert-cosmos-429-*` (Sev3) |
| **Latency SLOs** | p95: browse < 300 ms, create booking < 800 ms, view bookings < 500 ms |

## 1. Triage

1. Which flows and how slow? `docs/kql/sli-latency.kql` (1h window).
2. Server time vs dependency time: compare request p95 with `docs/kql/dependency-failures.kql` p95.
   - Requests slow, Cosmos DB fast → the **app** is slow (new revision? CPU saturation? cold start?).
   - Cosmos DB slow or 429 → the **database** is the bottleneck.
3. What changed? `./scripts/inject-fault.sh status` — new revision just before latency rose?
4. Saturation: Container App metrics *CPU usage*, *Replica count*. Is it pinned at `maxReplicas`?
5. Cold starts: with `minReplicas = 0`, the first request after idle takes seconds. Expected in the lab;
   set `MIN_REPLICAS=1` for a latency SLO you actually mean.

## 2. Mitigate

| Cause | Action |
|---|---|
| New revision introduced latency | `./scripts/rollback.sh <previous-revision>` |
| Replicas saturated at max | Raise the ceiling: `azd env set MAX_REPLICAS 5 && azd provision` |
| Cosmos DB 429s | Temporarily raise RU/s (`azd env set COSMOS_THROUGHPUT 800 && azd provision` — leaves the free tier), then fix the hot query/partition |

## 3. Verify

`./scripts/slo-report.sh 1` — latency SLI back above target; alerts auto-resolve.
