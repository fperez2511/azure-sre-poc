# Runbook: New revision fails to start / crash loop

| | |
|---|---|
| **Alerts** | `alert-api-restarts-*` (Sev2); deployment pipeline failure |
| **Expected user impact** | **None**, if single-revision mode and probes are working: the old revision keeps serving until the new one is healthy. If users *are* affected, treat as [high-error-rate.md](high-error-rate.md). |

## 1. Triage

1. `./scripts/inject-fault.sh status` — newest revision `health` = Unhealthy / `state` = Failed or Activating;
   the previous revision still `active` with 100% traffic?
2. Why does it fail? `docs/kql/container-app-events.kql` (probe failures, `BackOff`, exit codes) and
   the console log of the failing revision:
   `az containerapp logs show -n <app> -g <rg> --revision <new-revision> --type console --tail 50`
3. Look for a fatal startup message (missing setting, bad secret reference, image pull error).

## 2. Mitigate

- Users unaffected → no emergency. Fix forward (correct the setting / image) or roll back to make the
  latest revision healthy again: `./scripts/rollback.sh <previous-revision>`.
- Pipeline should fail the deployment when the new revision never becomes healthy — check
  `.github/workflows/deploy.yml` smoke test.

## 3. Learn

This is the "safe deployment" guardrail working. Ask in the postmortem: *would we have noticed if the
probes did not exist?* and *could a bad release pass the probes but still fail users?* (answer: yes —
the error-rate fault in Lab 7 does exactly that, which is why you also need SLO alerts).
