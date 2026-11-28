from contextlib import asynccontextmanager
from uuid import UUID

import pytest
from fastapi.testclient import TestClient
from mcp import Client
from mcp.server.auth.middleware.auth_context import auth_context_var
from mcp.server.auth.middleware.bearer_auth import AuthenticatedUser
from mcp.server.auth.provider import AccessToken
from sqlalchemy.engine import Engine
from sqlmodel import Session

from la_carte_api import auth
from la_carte_api.app import create_app
from la_carte_api.config import Settings
from la_carte_api.db import make_engine
from la_carte_api.mcp_server import build_mcp
from la_carte_api.models import TokenKind, TokenScope, User

# The user every single-user test acts as (spec 030a: every deck call is scoped to a user).
USER = UUID("00000000-0000-4000-8000-000000000001")
USER_EMAIL = "user@example.com"


def add_user(engine: Engine, email: str, user_id: UUID | None = None) -> UUID:
    with Session(engine) as session:
        user = User(email=email) if user_id is None else User(id=user_id, email=email)
        session.add(user)
        session.commit()
        return user.id


def token_for(engine: Engine, user_id: UUID, scope: TokenScope = TokenScope.deck) -> str:
    """A fresh personal access token of the user."""
    with Session(engine) as session:
        return auth.mint(session, user_id, TokenKind.pat, scope, name="test")


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


@asynccontextmanager
async def mcp_client(engine: Engine, user_id: UUID = USER, settings: Settings | None = None):
    """An in-process MCP client whose calls run as `user_id`, as if it sent that user's token
    (the HTTP bearer check itself is covered in test_accounts)."""
    token = AccessToken(token="test", client_id="test", scopes=["deck"], subject=str(user_id))
    reset = auth_context_var.set(AuthenticatedUser(token))
    try:
        async with Client(build_mcp(engine, settings)) as client:
            yield client
    finally:
        auth_context_var.reset(reset)


@pytest.fixture
def engine():
    engine = make_engine("sqlite://")
    add_user(engine, USER_EMAIL, USER)
    return engine


@pytest.fixture
def session(engine):
    with Session(engine) as session:
        yield session


@pytest.fixture
def client():
    """REST as `USER`, with a deck-scoped token."""
    with TestClient(create_app(Settings(database_url="sqlite://", _env_file=None))) as client:
        engine = client.app.state.engine
        add_user(engine, USER_EMAIL, USER)
        client.headers.update(bearer(token_for(engine, USER)))
        yield client
