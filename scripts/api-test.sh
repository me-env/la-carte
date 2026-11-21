#!/usr/bin/env bash
# API checks: lint + tests.
set -euo pipefail
cd "$(dirname "$0")/../api"
uv run ruff check .
uv run ruff format --check .
uv run pytest -q
