# Service overview: Summit Coaching booking API

> Upload this file (and the files in `docs/runbooks/`) to the SRE Agent knowledge base.
> It gives the agent the context a new on-call engineer would need on day one.

## What the business does
Summit Coaching sells coaching services: 1-on-1 calls, group calls, business presentations and
workshops. Customers browse the catalog and book a slot. **Bookings are revenue**; browsing is important
but can tolerate slightly stale data.

## Architecture
- **API:** ASP.NET Core (.NET 10) minimal API on **Azure Container Apps** (`ca-api-*`), Consumption
  workload profile, single-revision mode, HTTP autoscaling. Revision name = `AppVersion` in telemetry.
- **Database:** **Azure Cosmos DB for NoSQL** (`cosmos-*`), database `coaching`, containers
  `offerings` (pk `/category`) and `bookings` (pk `/customerId`). Entra ID auth only, Session consistency,
  continuous backup (7 days). Optional secondary region.
- **Network:** Container Apps environment in VNet `vnet-*`, subnet `snet-aca` with NSG `nsg-aca-*`.
- **Telemetry:** Application Insights `appi-*` (cloud role name `coaching-api`) → Log Analytics `log-*`.
  Useful tables: `AppRequests`, `AppDependencies`, `AppExceptions`, `AppTraces`,
  `ContainerAppSystemLogs_CL`, `ContainerAppConsoleLogs_CL`, `CDBDataPlaneRequests`.

## Critical flows and SLOs (28-day window)
| Flow | Endpoint | Availability SLO | Latency SLO (p95) | Degradation mode |
|---|---|---|---|---|
| Browse offerings | `GET /api/offerings` | 99.5% | 300 ms | serves cached catalog (`X-Data-Stale: true`) |
| Create booking | `POST /api/bookings` | 99.5% | 800 ms | fails fast with 503 + Retry-After |
| View my bookings | `GET /api/customers/{id}/bookings` | 99.5% | 500 ms | fails fast with 503 |

## Known failure modes
1. **Bad release** – a new revision raises 5xx or latency. Signal: errors start right after a new
   revision; new exception type in `AppExceptions` for that `AppVersion`. Mitigation: roll back
   (`az containerapp revision copy --from-revision <last-good>`).
2. **Cosmos DB unreachable** – dependency failures, circuit breaker opens, 503s on bookings, stale
   catalog. Check NSG rules and Chaos Studio experiments before blaming the database.
3. **Cosmos DB throttling (429)** – 400 RU/s shared throughput exhausted.
4. **Cold start** – `minReplicas = 0`; first request after idle is slow. Not an incident.

## Change sources
- Revisions of the container app (deployments via `azd deploy` / GitHub Actions, or env-var changes).
- Chaos Studio experiments `exp-cosmos-blackout-*`, `exp-cosmos-failover-*` (planned game days).

## Safe actions (allowed with approval)
- Roll back the container app to a previous revision.
- Cancel a running Chaos Studio experiment.
- Scale `maxReplicas` up to 5.

## Never do
- Delete or modify the Cosmos DB account, databases or containers.
- Rotate identities or change role assignments.
- Restart the app to "fix" a dependency outage (it discards the cached catalog).
