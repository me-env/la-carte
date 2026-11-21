# Production image for the la-carte API (REST + MCP on :8000). Deployed with Dokploy (docs/deploy.md).
#   docker build -t la-carte-api api/
#   docker run -p 8000:8000 -e LA_CARTE_API_TOKEN=... -v la-carte-data:/data la-carte-api

# --- build: resolve the locked dependencies into /app/.venv ---
FROM ghcr.io/astral-sh/uv:0.11-python3.13-trixie-slim AS build
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=0
WORKDIR /app
# Dependencies first (cached layer), then the project itself.
COPY pyproject.toml uv.lock .python-version ./
RUN --mount=type=cache,target=/root/.cache/uv uv sync --frozen --no-dev --no-install-project
COPY README.md ./
COPY src ./src
RUN --mount=type=cache,target=/root/.cache/uv uv sync --frozen --no-dev --no-editable

# --- runtime: same Python, no uv, non-root ---
FROM python:3.13-slim-trixie
RUN useradd --system --uid 10001 --no-create-home lacarte \
 && mkdir /data && chown lacarte:lacarte /data
COPY --from=build --chown=lacarte:lacarte /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    LA_CARTE_DATABASE_URL=sqlite:////data/la-carte.db \
    LA_CARTE_HOST=0.0.0.0 \
    LA_CARTE_PORT=8000 \
    FORWARDED_ALLOW_IPS=*
# FORWARDED_ALLOW_IPS: trust X-Forwarded-* from the reverse proxy (Traefik). Safe because the port
# is only reachable on the Docker network, never published on the host in production.
USER lacarte
VOLUME /data
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)"]
CMD ["la-carte-api"]
