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
from sqlalchemy import update
from sqlmodel import Session, col, or_, select

from la_carte_api.db import sessions
from la_carte_api.models import (
    ApiToken,
    PersonalToken,
    PersonalTokenCreate,
    PersonalTokenCreated,
    TokenKind,
    TokenScope,
    User,
    utcnow,
)

log = logging.getLogger(__name__)

PREFIX = {TokenKind.access: "lc_at_", TokenKind.refresh: "lc_rt_", TokenKind.pat: "lc_pat_"}
LEGACY = "legacy"  # name of the owner's PAT imported from LA_CARTE_API_TOKEN
TOUCH_EVERY = timedelta(hours=1)  # `last_used_at` / `last_seen_at` are written at most this often
IOS_CLIENT = "la-carte-ios"  # the app's built-in OAuth client (spec 030b)
ACCESS_TTL = timedelta(hours=1)
REFRESH_IDLE = timedelta(days=90)  # a refresh token unused this long is dead
MAX_PATS = 20  # live personal access tokens per user


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
    """A new token for the user; the raw value is returned once and never stored. Every token
    is minted here (PATs, OAuth pairs), so a step that applies to all of them goes here."""
    raw = PREFIX[kind] + secrets.token_urlsafe(32)
    store(session, user_id, raw, kind, scope, **options)
    return raw


def mint_pair(
    session: Session,
    user_id: UUID,
    client_id: str,
    family_id: UUID,
    now: datetime | None = None,
) -> tuple[str, str]:
    """An OAuth access token (1 h) and refresh token (90 days idle) of one family (spec 030b)."""
    now = now or utcnow()
    common = {"client_id": client_id, "family_id": family_id, "now": now}
    access = mint(session, user_id, TokenKind.access, TokenScope.deck,
                  expires_at=now + ACCESS_TTL, **common)  # fmt: skip
    refresh = mint(session, user_id, TokenKind.refresh, TokenScope.deck,
                   expires_at=now + REFRESH_IDLE, **common)  # fmt: skip
    return access, refresh


def revoke_family(session: Session, family_id: UUID, now: datetime | None = None) -> None:
    """Revokes every live token of a refresh family (its refresh and access tokens)."""
    session.exec(
        update(ApiToken)
        .where(col(ApiToken.family_id) == family_id, col(ApiToken.revoked_at).is_(None))
        .values(revoked_at=now or utcnow())
    )
    session.commit()


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


class TooManyTokens(ValueError):
    def __init__(self) -> None:
        super().__init__(f"At most {MAX_PATS} access tokens: revoke one first")


def create_personal_token(
    session: Session, user_id: UUID, body: PersonalTokenCreate, now: datetime | None = None
) -> PersonalTokenCreated:
    """A new PAT of the user; its value is in this reply only (spec 030b decision 8)."""
    now = now or utcnow()
    if len(list_personal_tokens(session, user_id, now)) >= MAX_PATS:
        raise TooManyTokens()
    days = body.expires_in_days
    expires_at = now + timedelta(days=days) if days else None
    raw = mint(session, user_id, TokenKind.pat, body.scope, name=body.name,
               expires_at=expires_at, now=now)  # fmt: skip
    token = session.exec(select(ApiToken).where(ApiToken.hash == token_hash(raw))).one()
    return PersonalTokenCreated(**token.model_dump(), token=raw)


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


def _app_user(principal: PrincipalDep, _: CurrentUser) -> UUID:
    """Only the signed-in app: an `la-carte-ios` access token (not a PAT, not an agent's)."""
    if principal.kind != TokenKind.access or principal.client_id != IOS_CLIENT:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Create access tokens from the la-carte app")
    return principal.user_id


AppUser = Annotated[UUID, Depends(_app_user)]  # `POST /me/tokens`
