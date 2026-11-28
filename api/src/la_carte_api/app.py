import asyncio
import logging
from collections.abc import Callable
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from mcp.server.transport_security import TransportSecuritySettings
from sqlalchemy.engine import Engine
from sqlmodel import Session
from starlette.responses import FileResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from la_carte_api import auth, deck, oauth
from la_carte_api.build import source_hash
from la_carte_api.config import Settings
from la_carte_api.db import open_database
from la_carte_api.identity import provider_from
from la_carte_api.mcp_server import build_mcp
from la_carte_api.rest import router

log = logging.getLogger(__name__)
STATIC = Path(__file__).parent / "static"
# The la carte icon (rendered by docs/design/brand/render.py), for clients showing the site icon.
ICONS = {
    "/favicon.ico": ("favicon.ico", "image/x-icon"),
    "/icon.png": ("icon.png", "image/png"),
    "/apple-touch-icon.png": ("apple-touch-icon.png", "image/png"),
    "/icon.svg": ("icon.svg", "image/svg+xml"),
}
# Served without a bearer token: clients fetch them anonymously. Every other REST route needs one.
# (The OAuth routes of `oauth.routes` are public too; they are Starlette routes, not REST.)
PUBLIC_PATHS = {"/health", *ICONS}
PRUNE_EVERY = 24 * 60 * 60  # seconds: activity older than 90 days goes at start, then daily


def icon_route(file: Path, media_type: str) -> Callable[[], FileResponse]:
    def icon() -> FileResponse:
        headers = {"Cache-Control": "public, max-age=86400"}
        return FileResponse(file, media_type=media_type, headers=headers)

    return icon


def prune(engine: Engine) -> int:
    """Applies the activity retention (spec 029; the privacy policy promises 90 days)."""
    with Session(engine) as session:
        return deck.prune_activity(session)


async def prune_daily(engine: Engine, every: float = PRUNE_EVERY) -> None:
    """Prunes the activity log every `every` seconds while the server runs."""
    while True:
        await asyncio.sleep(every)
        try:
            await asyncio.to_thread(prune, engine)
        except Exception:  # a failed run must not stop the next ones
            log.exception("activity pruning failed")


def with_scope_challenge(app: ASGIApp) -> ASGIApp:
    """Adds `scope="deck"` to the 401 challenge of `/mcp` (MCP authorization spec): the SDK
    sends only `resource_metadata`."""

    async def wrapped(scope: Scope, receive: Receive, send: Send) -> None:
        async def send_with_scope(message: Message) -> None:
            if message["type"] == "http.response.start" and message["status"] == 401:
                message = {**message, "headers": [
                    (name, value + b', scope="deck"' if name == b"www-authenticate" else value)
                    for name, value in message["headers"]
                ]}  # fmt: skip
            await send(message)

        await app(scope, receive, send_with_scope)

    return wrapped


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    if settings.api_token and not settings.owner_email:  # before touching the database
        raise RuntimeError("LA_CARTE_API_TOKEN is set: set LA_CARTE_OWNER_EMAIL too")
    identity = provider_from(settings)  # refuses a configuration that must not start
    key, new_key = settings.database_keys()
    engine, first_start = open_database(settings.database_url, settings.owner_email, key, new_key)
    with Session(engine) as session:
        auth.import_owner(
            session, settings.owner_email, settings.api_token, first_start=first_start
        )
    prune(engine)  # spec 029: at start, then daily (lifespan)
    authorization = oauth.LaCarteOAuth(engine, settings, identity)
    mcp = build_mcp(engine, settings, authorization)
    mcp_app = mcp.streamable_http_app(
        streamable_http_path="/mcp",
        stateless_http=True,
        json_response=True,
        # Access is controlled by the bearer token, not by the Host header.
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        pruning = asyncio.create_task(prune_daily(engine))
        try:
            async with mcp.session_manager.run():
                yield
        finally:
            pruning.cancel()

    app = FastAPI(title="la carte", lifespan=lifespan)
    app.state.engine = engine
    app.state.settings = settings
    app.state.oauth = authorization
    build = source_hash()

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "build": build}

    for path, (name, media_type) in ICONS.items():
        app.add_api_route(path, icon_route(STATIC / name, media_type), include_in_schema=False)

    app.include_router(router)
    app.router.routes.extend(oauth.routes(authorization))  # before the mount: ours win
    # Serves /mcp (bearer-checked by the SDK) and /register; mounted last.
    app.mount("/", with_scope_challenge(mcp_app))
    return app
