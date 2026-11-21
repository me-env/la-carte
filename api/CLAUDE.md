# api/

- `uv` project, Python 3.13. Add deps with `uv add`, run with `uv run`.
- Layering: `deck.py` (behavior) ← `rest.py` (iOS) / `mcp_server.py` (agents). See `../docs/architecture.md`.
- mcp SDK 2.x: `MCPServer` from `mcp.server.mcpserver` (no FastMCP). Tests use `mcp.Client(server)` in-process.
- `scripts/api-test.sh` must be green (ruff check, ruff format --check, pytest).
- Config via `LA_CARTE_*` env vars (`config.py`): `DATABASE_URL`, `API_TOKEN`, `HOST`, `PORT`.
