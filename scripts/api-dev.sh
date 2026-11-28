#!/usr/bin/env bash
# Run the API locally with auto-reload: http://127.0.0.1:8000 (REST) and /mcp (MCP).
# The access log has no query strings (OAuth codes, searches): `create_app` filters it (app.strip_query).
set -euo pipefail
cd "$(dirname "$0")/../api"
exec uv run uvicorn la_carte_api.app:create_app --factory --reload --host "${LA_CARTE_HOST:-127.0.0.1}" --port "${LA_CARTE_PORT:-8000}"
