#!/usr/bin/env python3
"""Seed the Summit Coaching Cosmos DB containers with sample offerings and bookings.

Usage (from the repo root, after `azd up`):
    pip install -r data/requirements.txt
    python data/seed.py                   # upsert offerings + sample bookings (idempotent)
    python data/seed.py --reset-bookings  # also delete every booking first
    python data/seed.py --offerings-only
    python data/seed.py --wipe-bookings   # Lab 9: simulate an operator error (deletes ALL bookings)

Settings come from environment variables or, if missing, from the current azd environment
(COSMOS_ENDPOINT, COSMOS_DATABASE). Authentication uses your Azure CLI sign-in.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import time

from _common import cosmos_client, database_name

HERE = pathlib.Path(__file__).resolve().parent
SEED_FILES = {
    "offerings": (HERE / "seed" / "offerings.json", "category"),
    "bookings": (HERE / "seed" / "bookings.json", "customerId"),
}


def load(path: pathlib.Path) -> list[dict]:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def delete_all(container, partition_key_field: str) -> int:
    deleted = 0
    for item in container.query_items(
        query=f"SELECT c.id, c.{partition_key_field} FROM c",
        enable_cross_partition_query=True,
    ):
        container.delete_item(item["id"], partition_key=item[partition_key_field])
        deleted += 1
    return deleted


def upsert_with_retry(container, item: dict, attempts: int = 5) -> None:
    """Retry 403s briefly: new data-plane role assignments can take a few minutes to apply."""
    from azure.cosmos import exceptions

    for attempt in range(1, attempts + 1):
        try:
            container.upsert_item(item)
            return
        except exceptions.CosmosHttpResponseError as err:
            if err.status_code == 403 and attempt < attempts:
                wait = 20 * attempt
                print(f"  403 Forbidden (role assignment still propagating?) - retrying in {wait}s")
                time.sleep(wait)
                continue
            raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reset-bookings", action="store_true", help="delete all bookings before seeding")
    parser.add_argument("--offerings-only", action="store_true", help="seed only the offerings catalog")
    parser.add_argument("--wipe-bookings", action="store_true",
                        help="DELETE every booking and exit (simulated operator error for the restore drill)")
    args = parser.parse_args()

    client = cosmos_client()
    db = client.get_database_client(database_name())

    if args.wipe_bookings:
        from datetime import datetime, timezone
        print(f"Wiping bookings at {datetime.now(timezone.utc).isoformat(timespec='seconds')} (note this time for the restore)")
        print(f"Deleted {delete_all(db.get_container_client('bookings'), 'customerId')} bookings")
        return 0

    for container_name, (path, pk_field) in SEED_FILES.items():
        if args.offerings_only and container_name != "offerings":
            continue
        container = db.get_container_client(container_name)

        if container_name == "bookings" and args.reset_bookings:
            print(f"Deleted {delete_all(container, pk_field)} existing bookings")

        items = load(path)
        for item in items:
            upsert_with_retry(container, item)
        print(f"Upserted {len(items):>3} items into '{container_name}' (partition key /{pk_field})")

    print("Done. Try: curl \"$SERVICE_API_URI/api/offerings\"")
    return 0


if __name__ == "__main__":
    sys.exit(main())
