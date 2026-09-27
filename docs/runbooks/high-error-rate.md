# Runbook: Booking API high error rate (HTTP 5xx) / SLO fast burn

| | |
|---|---|
| **Alerts** | `alert-api-5xx-*` (Sev2), `alert-slo-fast-burn-*` (Sev1) |
| **Service** | Summit Coaching booking API — Container App `ca-api-*` in `rg-<env>` |
| **User impact** | Customers cannot browse offerings and/or cannot create bookings (lost revenue) |
| **SLO** | 99.5% of `/api/*` requests return < 500 (28-day window). Fast burn = budget burning ≥ 14.4× |

## 1. Triage (first 5 minutes)

1. **Acknowledge** and declare an incident if the burn-rate alert fired (Sev1). Name an incident commander.
2. **Scope:** which flows fail? Run `docs/kql/sli-availability.kql` with a 1h window, or:
   `./scripts/slo-report.sh 1`
3. **What changed?** The single most useful question.
   - `./scripts/inject-fault.sh status` — did a new revision appear shortly before errors started?
   - `docs/kql/exceptions-by-revision.kql` — is there a new exception type tied to one revision (`AppVersion`)?
   - Activity Log: `az monitor activity-log list -g <rg> --offset 2h --query "[?contains(operationName.value,'Microsoft.App')].{time:eventTimestamp, op:operationName.value, caller:caller}" -o table`
4. **Dependency or code?** `docs/kql/dependency-failures.kql` and `curl $SERVICE_API_URI/healthz/deps`.
   - Dependency failing → go to [cosmos-dependency-outage.md](cosmos-dependency-outage.md).
   - Dependency healthy, errors started with a new revision → **bad release**, continue below.

## 2. Mitigate (stop the bleeding first, find root cause later)

| Situation | Action | Command |
|---|---|---|
| Errors began with a new revision | **Roll back** to the last healthy revision | `./scripts/rollback.sh <previous-revision>` |
| Errors caused by a config/env change | Revert the setting (new revision) | `./scripts/inject-fault.sh clear` (lab) |
| Cannot identify the change | Roll back anyway if a deploy happened in the last 2 hours | `./scripts/rollback.sh` |

Rolling back is safe here: the API is stateless and bookings are idempotent.

## 3. Verify

- `./scripts/traffic.sh 120` shows availability back at ~100%.
- 5xx metric alert auto-resolves after ~5 minutes; burn-rate alert after its next evaluation.
- `./scripts/slo-report.sh 24` — note how much error budget the incident consumed.

## 4. Escalate

- Rollback did not help, or errors persist > 15 minutes → page the application owner.
- Cosmos DB side issue → check Azure Service Health; open a support case.

## 5. Afterwards

Write a blameless postmortem with [../postmortem-template.md](../postmortem-template.md) within 48 hours.
