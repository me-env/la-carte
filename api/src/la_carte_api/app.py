import secrets
from collections.abc import Callable
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from mcp.server.transport_security import TransportSecuritySettings
from starlette.responses import FileResponse, JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from la_carte_api.build import source_hash
from la_carte_api.config import Settings
from la_carte_api.db import make_engine
from la_carte_api.mcp_server import build_mcp
from la_carte_api.rest import router

STATIC = Path(__file__).parent / "static"
# The la-carte icon (rendered by docs/design/brand/render.py), for clients showing the site icon.
ICONS = {
    "/favicon.ico": ("favicon.ico", "image/x-icon"),
    "/icon.png": ("icon.png", "image/png"),
    "/apple-touch-icon.png": ("apple-touch-icon.png", "image/png"),
    "/icon.svg": ("icon.svg", "image/svg+xml"),
}
# Served without the bearer token: clients fetch them anonymously.
PUBLIC_PATHS = {"/health", *ICONS}


def icon_route(file: Path, media_type: str) -> Callable[[], FileResponse]:
    def icon() -> FileResponse:
        headers = {"Cache-Control": "public, max-age=86400"}
        return FileResponse(file, media_type=media_type, headers=headers)

    return icon


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    engine = make_engine(settings.database_url)
    mcp = build_mcp(engine, settings.public_url)
    mcp_app = mcp.streamable_http_app(
        streamable_http_path="/mcp",
        stateless_http=True,
        json_response=True,
        # Access is controlled by the bearer token, not by the Host header.
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        async with mcp.session_manager.run():
            yield

    app = FastAPI(title="la-carte", lifespan=lifespan)
    app.state.engine = engine
    build = source_hash()

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "build": build}

    for path, (name, media_type) in ICONS.items():
        app.add_api_route(path, icon_route(STATIC / name, media_type), include_in_schema=False)

    app.include_router(router)
    app.mount("/", mcp_app)  # serves /mcp; mounted last so REST routes match first
    if settings.api_token:
        app.add_middleware(BearerTokenMiddleware, token=settings.api_token)
    return app


class BearerTokenMiddleware:
    """Requires `Authorization: Bearer <token>` on every HTTP request except `PUBLIC_PATHS`."""

    def __init__(self, app: ASGIApp, token: str) -> None:
        self.app = app
        self.expected = f"Bearer {token}".encode()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http" and scope["path"] not in PUBLIC_PATHS:
            sent = dict(scope["headers"]).get(b"authorization", b"")
            if not secrets.compare_digest(sent, self.expected):
                await JSONResponse({"detail": "Unauthorized"}, status_code=401)(
                    scope, receive, send
                )
                return
        await self.app(scope, receive, send)
