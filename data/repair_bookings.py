#!/usr/bin/env python3
"""Repair the live `bookings` container from a point-in-time-restored Cosmos DB account (Lab 9).

A Cosmos DB restore always creates a NEW account. This script copies the bookings from that
restored account back into the live one. It only upserts (never deletes), so it is safe to run
more than once and it does not overwrite bookings created after the incident unless they share an id.

Usage (from the repo root):
    python data/repair_bookings.py --source-endpoint https://<restored-account>.documents.azure.com:443/
    python data/repair_bookings.py --source-endpoint ... --dry-run
"""
from __future__ import annotations

import argparse
import sys
import time

from _common import cosmos_client, database_name


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source-endpoint", required=True, help="documentEndpoint of the restored account")
    parser.add_argument("--dry-run", action="store_true", help="count what would be copied, write nothing")
    args = parser.parse_args()

    from azure.cosmos import CosmosClient
    from azure.identity import DefaultAzureCredential

    source = CosmosClient(args.source_endpoint, credential=DefaultAzureCredential(exclude_interactive_browser_credential=True))
    source_bookings = source.get_database_client(database_name()).get_container_client("bookings")
    target_bookings = cosmos_client().get_database_client(database_name()).get_container_client("bookings")

    system_fields = {"_rid", "_self", "_etag", "_attachments", "_ts"}
    started = time.monotonic()
    copied = 0
    for item in source_bookings.query_items("SELECT * FROM c", enable_cross_partition_query=True):
        clean = {k: v for k, v in item.items() if k not in system_fields}
        if not args.dry_run:
            target_bookings.upsert_item(clean)
        copied += 1

    verb = "Would copy" if args.dry_run else "Copied"
    print(f"{verb} {copied} bookings in {time.monotonic() - started:.1f}s")
    print("Verify: python data/query.py revenue-by-category")
    return 0


if __name__ == "__main__":
    sys.exit(main())
