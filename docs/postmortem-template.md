# Postmortem: <short title>

> Blameless: we look for how the *system* (code, process, tooling) allowed the failure,
> never for who to blame. Engineers acted reasonably given what they knew at the time.

| | |
|---|---|
| Date | YYYY-MM-DD |
| Authors | |
| Status | Draft / Reviewed / Action items complete |
| Severity | Sev1 / Sev2 / Sev3 |
| Error budget consumed | e.g. 38% of the 28-day budget (from `scripts/slo-report.sh`) |

## Summary
Two or three sentences: what happened, impact, how it was resolved.

## Impact
- Users affected / flows affected (browse, create booking, view bookings)
- Duration of impact (start → end, UTC)
- Bookings lost or delayed; revenue impact (use `data/query.py revenue-by-category`)

## Timeline (UTC)
| Time | Event |
|---|---|
| hh:mm | Trigger (deploy / config change / experiment / platform event) |
| hh:mm | First alert fired (**time to detect** = alert − trigger) |
| hh:mm | Acknowledged / incident declared |
| hh:mm | Mitigation applied |
| hh:mm | Recovery confirmed (**time to mitigate** = recovery − alert) |

## Root cause and trigger
- **Trigger:** what started it.
- **Root cause:** why the system was vulnerable to that trigger.
- **Detection:** how we found out. Did the right alert fire at the right severity?

## What went well / what went wrong / where we got lucky

## Role of automation
What did Azure SRE Agent (or other tooling) find, propose or do? Was it correct? What context was it missing?

## Action items
| Action | Type (prevent / detect / mitigate / process) | Owner | Due | Tracking |
|---|---|---|---|---|
| | | | | |
