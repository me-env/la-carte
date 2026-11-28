"""Who is calling (spec 030a): our opaque bearer tokens, stored as SHA-256 only.

Every REST request and every `/mcp` request resolves to one user through `verify`. Tokens are
`lc_<at|rt|pat>_` + 43 url-safe characters; the database never holds a token, only its hash.
Token values, hashes and emails are never logged.
"""

import hashlib
import logging
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Annotated
from uuid import UUID

from fastapi import Depends, HTTPException, Request, status
from mcp.server.auth.provider import AccessToken
from sqlalchemy.engine import Engine
from sqlmodel import Session, col, or_, select

from la_carte_api.db import sessions
from la_carte_api.models import (
    ApiToken,
    PersonalToken,
    TokenKind,
    TokenScope,
    User,
    utcnow,
)

log = logging.getLogger(__name__)

PREFIX = {TokenKind.access: "lc_at_", TokenKind.refresh: "lc_rt_", TokenKind.pat: "lc_pat_"}
LEGACY = "legacy"  # name of the owner's PAT imported from LA_CARTE_API_TOKEN
TOUCH_EVERY = timedelta(hours=1)  # `last_used_at` / `last_seen_at` are written at most this often


@dataclass(frozen=True)
class Principal:
    user_id: UUID
    scope: TokenScope
    client_id: str | None
    token_id: UUID
    kind: TokenKind
    expires_at: datetime | None


def token_hash(raw: str) -> str:
    return hashlib.sha256(raw.encode()).hexdigest()


def store(
    session: Session,
    user_id: UUID,
    raw: str,
    kind: TokenKind,
    scope: TokenScope,
    *,
    name: str | None = None,
    client_id: str | None = None,
    family_id: UUID | None = None,
    expires_at: datetime | None = None,
    now: datetime | None = None,
) -> ApiToken:
    """Saves the hash of `raw` as one of the user's tokens."""
    token = ApiToken(
        user_id=user_id, kind=kind, hash=token_hash(raw), scope=scope, name=name,
        client_id=client_id, family_id=family_id, expires_at=expires_at,
        created_at=now or utcnow(),
    )  # fmt: skip
    session.add(token)
    session.commit()
    return token


def mint(session: Session, user_id: UUID, kind: TokenKind, scope: TokenScope, **options) -> str:
    """A new token for the user; the raw value is returned once and never stored."""
    raw = PREFIX[kind] + secrets.token_urlsafe(32)
    store(session, user_id, raw, kind, scope, **options)
    return raw


def verify(session: Session, raw: str, now: datetime | None = None) -> Principal | None:
    """The principal behind a bearer token, or None: unknown, revoked, expired, or a refresh
    token (only good at `/token`)."""
    now = now or utcnow()
    token = session.exec(select(ApiToken).where(ApiToken.hash == token_hash(raw))).first()
    if (
        token is None
        or token.kind == TokenKind.refresh
        or token.revoked_at is not None
        or (token.expires_at is not None and token.expires_at <= now)
    ):
        return None
    if token.last_used_at is None or now - token.last_used_at >= TOUCH_EVERY:
        token.last_used_at = now
        if user := session.get(User, token.user_id):
            user.last_seen_at = now
            session.add(user)
        session.add(token)
        session.commit()
    return Principal(
        token.user_id, token.scope, token.client_id, token.id, token.kind, token.expires_at
    )


# --- Personal access tokens (REST only) --------------------------------------------------------


class TokenNotFound(LookupError):
    def __init__(self, token_id: UUID) -> None:
        super().__init__(f"No token with id {token_id}")


def list_personal_tokens(
    session: Session, user_id: UUID, now: datetime | None = None
) -> list[PersonalToken]:
    """The user's live PATs (not revoked, not expired), newest first (never the token or its
    hash)."""
    now = now or utcnow()
    tokens = session.exec(
        select(ApiToken)
        .where(
            ApiToken.user_id == user_id,
            ApiToken.kind == TokenKind.pat,
            col(ApiToken.revoked_at).is_(None),
            or_(col(ApiToken.expires_at).is_(None), col(ApiToken.expires_at) > now),
        )
        .order_by(col(ApiToken.created_at).desc())
    )
    return [PersonalToken(**token.model_dump()) for token in tokens]


def revoke_personal_token(
    session: Session, user_id: UUID, token_id: UUID, now: datetime | None = None
) -> None:
    """Revokes one of the user's PATs that is not revoked yet; anything else is `TokenNotFound`."""
    token = session.get(ApiToken, token_id)
    if (
        token is None
        or token.user_id != user_id
        or token.kind != TokenKind.pat
        or token.revoked_at is not None
    ):
        raise TokenNotFound(token_id)
    token.revoked_at = now or utcnow()
    session.add(token)
    session.commit()


# --- Startup: the owner and the legacy token ---------------------------------------------------


def import_owner(
    session: Session, owner_email: str | None, api_token: str | None, *, first_start: bool
) -> None:
    """Creates the owner's user (no identity) when missing (spec 030a decision 5). On the
    `first_start` with accounts only (migration 030 ran, or a fresh database), also stores
    `LA_CARTE_API_TOKEN` as the owner's PAT `legacy`. Never afterwards: a revoked token, or one
    whose owner deleted their account, does not come back on a restart."""
    if not owner_email:  # `create_app` refuses LA_CARTE_API_TOKEN without it
        return
    owner = session.exec(select(User).where(User.email == owner_email)).first()
    if owner is None:
        owner = User(email=owner_email)
        session.add(owner)
        session.commit()
    if not api_token:
        return
    hash_ = token_hash(api_token)
    if not first_start or session.exec(select(ApiToken.id).where(ApiToken.hash == hash_)).first():
        log.info("LA_CARTE_API_TOKEN already imported; you can remove it")
        return
    store(session, owner.id, api_token, TokenKind.pat, TokenScope.deck, name=LEGACY)
    log.warning("LA_CARTE_API_TOKEN is imported; remove it from the environment")


# --- REST --------------------------------------------------------------------------------------


def _session(request: Request):
    yield from sessions(request.app.state.engine)


SessionDep = Annotated[Session, Depends(_session)]
UNAUTHORIZED = HTTPException(
    status.HTTP_401_UNAUTHORIZED, "Unauthorized", headers={"WWW-Authenticate": "Bearer"}
)


def _principal(request: Request, session: SessionDep) -> Principal:
    scheme, _, raw = request.headers.get("authorization", "").partition(" ")
    if scheme.lower() != "bearer" or not raw.strip():
        raise UNAUTHORIZED
    principal = verify(session, raw.strip())
    if principal is None:
        raise UNAUTHORIZED
    return principal


PrincipalDep = Annotated[Principal, Depends(_principal)]


def _deck_user(principal: PrincipalDep) -> UUID:
    if principal.scope != TokenScope.deck:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Insufficient scope")
    return principal.user_id


def _stats_user(principal: PrincipalDep) -> UUID:
    return principal.user_id  # `deck` and `stats` both read the stats


CurrentUser = Annotated[UUID, Depends(_deck_user)]  # every route but `GET /stats`
StatsUser = Annotated[UUID, Depends(_stats_user)]  # `GET /stats`: the widget's token too


# --- MCP ---------------------------------------------------------------------------------------


class McpTokenVerifier:
    """The MCP SDK's `TokenVerifier` over `verify`: the token's user is the `subject`."""

    def __init__(self, engine: Engine, resource: str) -> None:
        self.engine = engine
        self.resource = resource

    async def verify_token(self, token: str) -> AccessToken | None:
        with Session(self.engine) as session:
            principal = verify(session, token)
        if principal is None:
            return None
        expires_at = principal.expires_at
        return AccessToken(
            token=token,
            client_id=principal.client_id or principal.kind.value,
            scopes=[principal.scope.value],
            expires_at=int(expires_at.timestamp()) if expires_at else None,
            resource=self.resource,
            subject=str(principal.user_id),
        )
