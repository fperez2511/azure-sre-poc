#!/usr/bin/env python3
"""Run a saved Cosmos DB NoSQL query from data/queries and show its RU cost.

Examples (from the repo root):
    python data/query.py offerings-active
    python data/query.py bookings-by-customer --param customerId=cust-ana --partition cust-ana
    python data/query.py find-booking-by-id --param id=seed-0003          # cross-partition fan-out
    python data/query.py bookings-created-since --param sinceUtc=2026-09-27T00:00:00+00:00

Compare the RU charge of a single-partition query (--partition) with a cross-partition one:
that difference is why partition-key design matters for both cost and reliability.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

from _common import cosmos_client, database_name

QUERIES = pathlib.Path(__file__).resolve().parent / "queries"
DEFAULT_CONTAINER = {"offerings": "offerings"}  # prefix -> container; everything else -> bookings


def container_for(query_name: str) -> str:
    for prefix, container in DEFAULT_CONTAINER.items():
        if query_name.startswith(prefix):
            return container
    return "bookings"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("query", help="file name in data/queries (with or without .sql)")
    parser.add_argument("--param", action="append", default=[], metavar="NAME=VALUE",
                        help="query parameter, e.g. customerId=cust-ana (repeatable)")
    parser.add_argument("--partition", help="partition key value -> single-partition query")
    parser.add_argument("--container", help="override the container (default is inferred from the file name)")
    args = parser.parse_args()

    name = args.query.removesuffix(".sql")
    path = QUERIES / f"{name}.sql"
    if not path.exists():
        available = ", ".join(sorted(p.stem for p in QUERIES.glob("*.sql")))
        sys.exit(f"Unknown query '{name}'. Available: {available}")

    sql = path.read_text(encoding="utf-8").strip()
    parameters = []
    for pair in args.param:
        key, _, value = pair.partition("=")
        parameters.append({"name": f"@{key.lstrip('@')}", "value": value})

    client = cosmos_client()
    container = client.get_database_client(database_name()).get_container_client(
        args.container or container_for(name))

    kwargs = {"query": sql, "parameters": parameters}
    if args.partition:
        kwargs["partition_key"] = args.partition
    else:
        kwargs["enable_cross_partition_query"] = True

    items = list(container.query_items(**kwargs))
    headers = container.client_connection.last_response_headers
    print(json.dumps(items, indent=2, default=str))
    print(f"\n{len(items)} result(s) | container={container.id} | "
          f"{'single-partition' if args.partition else 'cross-partition'} | "
          f"RU charge (last page) = {headers.get('x-ms-request-charge')}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
