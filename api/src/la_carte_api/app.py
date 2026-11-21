import secrets
from contextlib import asynccontextmanager

from fastapi import FastAPI
from mcp.server.transport_security import TransportSecuritySettings
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from la_carte_api.config import Settings
from la_carte_api.db import make_engine
from la_carte_api.mcp_server import build_mcp
from la_carte_api.rest import router


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    engine = make_engine(settings.database_url)
    mcp = build_mcp(engine)
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

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    app.include_router(router)
    app.mount("/", mcp_app)  # serves /mcp; mounted last so REST routes match first
    if settings.api_token:
        app.add_middleware(BearerTokenMiddleware, token=settings.api_token)
    return app


class BearerTokenMiddleware:
    """Requires `Authorization: Bearer <token>` on every HTTP request except /health."""

    def __init__(self, app: ASGIApp, token: str) -> None:
        self.app = app
        self.expected = f"Bearer {token}".encode()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http" and scope["path"] != "/health":
            sent = dict(scope["headers"]).get(b"authorization", b"")
            if not secrets.compare_digest(sent, self.expected):
                await JSONResponse({"detail": "Unauthorized"}, status_code=401)(
                    scope, receive, send
                )
                return
        await self.app(scope, receive, send)
