# Runbook: Cosmos DB unreachable or failing

| | |
|---|---|
| **Alerts** | `alert-dependency-failures-*` (Sev2), often together with `alert-api-5xx-*` |
| **User impact (by design)** | *Browse offerings* keeps working from the cached catalog (header `X-Data-Stale: true`). *Create booking* and *view bookings* return **503 + Retry-After** within ~3 s. Nothing is half-written. |

## 1. Triage

1. Confirm: `curl -s $SERVICE_API_URI/healthz/deps` → `Unhealthy` with an error message.
2. Is it the **network path** or **Cosmos DB itself**?
   - App side: `docs/kql/dependency-failures.kql` — failed calls / timeouts from the API.
   - Service side: `docs/kql/cosmos-data-plane.kql` — did Cosmos DB *receive* requests?
     - App shows failures **but Cosmos DB saw no traffic** → network path (NSG, DNS, firewall, private endpoint).
     - Cosmos DB saw requests with 5xx/408 → service-side issue; check Azure Service Health.
     - Cosmos DB returned **429** → RU/s exhausted → see [high-latency.md](high-latency.md).
3. Network path checks:
   - `az network nsg rule list -g <rg> --nsg-name <NSG_NAME> -o table` — any unexpected **Deny** rule
     (e.g. `chaos-deny-cosmos` during a chaos experiment)?
   - Is a Chaos Studio experiment running? `./scripts/chaos.sh status blackout`
4. Circuit breaker state: `docs/kql/circuit-breaker.kql` (open → the app is protecting itself; expected).

## 2. Mitigate

| Cause | Action |
|---|---|
| Chaos experiment running unexpectedly | `./scripts/chaos.sh cancel blackout` (Chaos Studio removes the rule) |
| Stray NSG deny rule | Remove it: `az network nsg rule delete -g <rg> --nsg-name <nsg> -n <rule>` (with approval) |
| Regional Cosmos DB outage, multi-region account | Service-managed failover should kick in; manual: `az cosmosdb failover-priority-change` |
| Regional outage, single region | Nothing to fail over to — communicate, wait, and file a reliability action item (add a region) |

**Do NOT** restart or scale the API for a dependency outage: replicas are healthy, restarting them
throws away the cached catalog and makes browsing worse.

## 3. Verify

- `/healthz/deps` → Healthy; circuit breaker logs "CLOSED".
- `X-Data-Stale` header disappears from `/api/offerings` responses within ~30 s (background refresh).
- `./scripts/smoke-test.sh` passes.
