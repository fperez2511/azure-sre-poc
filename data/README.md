# data/ — Cosmos DB model, seed data and queries

Everything about the database lives here. The Bicep in `infra/` reads the container definitions from
`schema/containers.json`, so this folder is where you change the data model.

```
data/
├── schema/containers.json   # containers, partition keys, indexing policies (deployed by infra/modules/cosmos.bicep)
├── seed/offerings.json      # service catalog (1-on-1, group, business presentation, workshop)
├── seed/bookings.json       # a few sample bookings
├── queries/*.sql            # saved Cosmos DB NoSQL queries used in the labs
├── seed.py                  # idempotent seeding (Entra ID auth, no keys)
├── query.py                 # run a saved query and print its RU charge
└── requirements.txt
```

## Model

| Container | Partition key | Why this key | Typical access pattern | RU cost |
|---|---|---|---|---|
| `offerings` | `/category` | Few, stable categories; the whole catalog is tiny and cached in the API | Read everything, rarely written | Negligible (API caches it) |
| `bookings` | `/customerId` | The hot path is "a customer's bookings" and point reads by `(id, customerId)` | Point read = ~1 RU; list = single-partition query | Low, spreads writes across many customers |

Both containers share **400 RU/s provisioned at database level** (free tier covers 1000 RU/s in total,
so two regions × 400 RU/s still cost nothing).

**Trade-off to discuss:** a corporate customer booking dozens of workshops creates a "hot" partition
(`cust-contoso-hr`). At this scale it does not matter; at real scale you would consider a hierarchical
partition key (`/customerId` + `/yearMonth`). Queries that do not include the partition key
(`find-booking-by-id.sql`, `upcoming-bookings-by-category.sql`) fan out to every physical partition —
run them with `query.py` and compare the RU charge with `bookings-by-customer.sql --partition ...`.

**Indexing:** everything is indexed except large free-text fields (`/description`, `/notes`), which
reduces write RU. Composite indexes support `ORDER BY` on two properties.

## Seed the database

```bash
pip install -r data/requirements.txt
python data/seed.py                  # safe to run repeatedly (upsert)
python data/seed.py --reset-bookings # wipe bookings first
```

The scripts read `COSMOS_ENDPOINT` / `COSMOS_DATABASE` from your shell or from the active azd
environment, and sign in with your Azure CLI identity. Key-based auth is **disabled** on the account
(`disableLocalAuth: true`), so you need the *Cosmos DB Built-in Data Contributor* data-plane role —
Bicep grants it to the identity that ran `azd up`. A `403 Forbidden` right after provisioning usually
means the role assignment is still propagating; `seed.py` retries for you.

## Saved queries

| File | Container | Partition-scoped? | Used in |
|---|---|---|---|
| `offerings-active.sql` | offerings | no (tiny) | Lab 1 |
| `offerings-by-category.sql` (`@category`) | offerings | yes | Lab 1 |
| `bookings-by-customer.sql` (`@customerId`) | bookings | yes → pass `--partition` | Lab 1, Lab 9 |
| `find-booking-by-id.sql` (`@id`) | bookings | **no** — fan-out | Lab 1 (cost comparison) |
| `upcoming-bookings-by-category.sql` (`@category`, `@fromUtc`) | bookings | no | Lab 1 |
| `revenue-by-category.sql` | bookings | no | business check after incidents |
| `bookings-created-since.sql` (`@sinceUtc`) | bookings | no | Lab 6 / Lab 9 (data-loss check, RPO) |

Dates are stored as ISO 8601 strings with an explicit offset (`2026-11-03T15:00:00+00:00`), so string
comparison works as time comparison — keep the same format in parameters.

```bash
python data/query.py bookings-by-customer --param customerId=cust-ana --partition cust-ana
python data/query.py find-booking-by-id --param id=seed-0003
```

## Backup and restore (Lab 9)

The account uses **continuous backup, 7-day tier** (backup storage is free; a restore is billed per GB
restored). A point-in-time restore always creates a **new account**, which you then use to repair the
original data. The README walks through the drill; delete the restored account afterwards.
