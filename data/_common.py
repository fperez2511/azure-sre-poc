"""Shared helpers for the data scripts: resolve settings from env vars or the azd environment."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys


def azd_value(name: str) -> str | None:
    """Return a value from the process environment, falling back to `azd env get-value`."""
    value = os.getenv(name)
    if value:
        return value
    if shutil.which("azd") is None:
        return None
    try:
        result = subprocess.run(
            ["azd", "env", "get-value", name],
            capture_output=True, text=True, check=True, timeout=30,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    value = result.stdout.strip()
    return value or None


def cosmos_client():
    """Create a CosmosClient that authenticates with Entra ID (az login / managed identity)."""
    try:
        from azure.cosmos import CosmosClient
        from azure.identity import DefaultAzureCredential
    except ImportError:
        sys.exit("Missing packages. Run: pip install -r data/requirements.txt")

    endpoint = azd_value("COSMOS_ENDPOINT")
    if not endpoint:
        sys.exit("COSMOS_ENDPOINT not found. Run `azd up` first (or export COSMOS_ENDPOINT).")

    # Key auth is disabled on the account; your signed-in identity needs the
    # "Cosmos DB Built-in Data Contributor" role (Bicep assigns it to AZURE_PRINCIPAL_ID).
    credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    return CosmosClient(endpoint, credential=credential)


def database_name() -> str:
    return azd_value("COSMOS_DATABASE") or "coaching"
