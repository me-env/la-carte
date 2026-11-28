"""la-carte as an OAuth 2.1 authorization server (spec 030b), for agents and the iOS app.

The MCP SDK serves `/register` and `/revoke` and validates `/authorize` and `/token`; `LaCarteOAuth`
is its provider. Our own routes (`routes`) add what the SDK lacks: the metadata we advertise, the
`lc_auth` cookie on `/authorize`, the `resource` check on `/token`, the consent page, the identity
provider's callback and the fake provider. Sign-in goes:

    /authorize → (agents: /oauth/consent) → identity provider → /oauth/callback → our code → /token

The app also signs in with Apple natively: `POST /oauth/apple` (spec 030e) answers like `/token`.
Codes and tokens are ours, opaque and stored hashed (`auth.mint`). The only identity provider token
kept is Apple's refresh token, to revoke it on account deletion. Token values, codes, nonces and
emails are never logged.
"""

import html
import logging
import secrets
from collections.abc import Callable
from datetime import datetime, timedelta
from urllib.parse import ParseResult, parse_qs, urlparse
from uuid import UUID, uuid4

from mcp.server.auth.handlers.authorize import AuthorizationHandler
from mcp.server.auth.handlers.token import TokenHandler
from mcp.server.auth.middleware.client_auth import AuthenticationError, ClientAuthenticator
from mcp.server.auth.provider import (
    AccessToken,
    AuthorizationCode,
    AuthorizationParams,
    AuthorizeError,
    RefreshToken,
    RegistrationError,
    TokenError,
    construct_redirect_uri,
)
from mcp.server.auth.routes import cors_middleware
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken
from pydantic import AnyUrl
from sqlalchemy import update
from sqlalchemy.engine import Engine
from sqlmodel import Session, col, delete, select
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from starlette.routing import Route

from la_carte_api import auth
from la_carte_api.config import LOOPBACK, Settings
from la_carte_api.identity import (
    AppleProvider,
    FakeProvider,
    IdentityError,
    IdentityProvider,
    VerifiedIdentity,
    pkce_challenge,
)
from la_carte_api.models import (
    ApiToken,
    AuthCode,
    AuthRequest,
    Identity,
    OAuthClient,
    TokenKind,
    User,
    utcnow,
)

log = logging.getLogger(__name__)
SCOPE = "deck"
COOKIE = "lc_auth"  # binds the browser that consented to the request it consented to
CODE_PREFIX = "lc_ac_"
REQUEST_TTL = timedelta(minutes=10)
CODE_TTL = timedelta(minutes=5)
NO_STORE = {"Cache-Control": "no-store"}
MAX_CLIENT_NAME, MAX_REDIRECT_URIS = 100, 10  # DCR limits: a registration is unauthenticated


# --- Clients -----------------------------------------------------------------------------------


def _loopback(uri: str) -> bool:
    url = urlparse(uri)
    return url.scheme == "http" and url.hostname in LOOPBACK


class LaCarteClient(OAuthClientInformationFull):
    """A client whose loopback redirect URIs match on any port (RFC 8252 §7.3); every other
    URI matches exactly."""

    def validate_redirect_uri(self, redirect_uri: AnyUrl | None) -> AnyUrl:
        if redirect_uri is not None and _loopback(str(redirect_uri)):
            asked = _without_port(str(redirect_uri))
            for registered in self.redirect_uris or []:
                if _loopback(str(registered)) and _without_port(str(registered)) == asked:
                    return redirect_uri
        return super().validate_redirect_uri(redirect_uri)


def _without_port(uri: str) -> ParseResult:
    url = urlparse(uri)
    return url._replace(netloc=url.hostname or "")


# The iOS app: built in, public (PKCE, no secret), one redirect URI.
IOS = LaCarteClient(
    client_id=auth.IOS_CLIENT,
    client_name="la-carte",
    redirect_uris=[AnyUrl("lacarte://oauth")],
    token_endpoint_auth_method="none",
    grant_types=["authorization_code", "refresh_token"],
    response_types=["code"],
    scope=SCOPE,
)


# --- What the SDK's handlers get back from us --------------------------------------------------


class Code(AuthorizationCode):
    user_id: UUID


class Refresh(RefreshToken):
    user_id: UUID
    token_id: UUID
    family_id: UUID


class Access(AccessToken):
    token_id: UUID
    kind: TokenKind


# --- Accounts ----------------------------------------------------------------------------------


class SignInRefused(Exception):
    """No account for this sign-in; `reason` is the OAuth `error_description`."""

    def __init__(self, reason: str) -> None:  # not_allowed | email_in_use | use_apple | use_google
        super().__init__(reason)
        self.reason = reason


def resolve_account(
    session: Session, who: VerifiedIdentity, settings: Settings, now: datetime | None = None
) -> UUID:
    """The user `who` signs in as (030 principle 4), creating the account when sign-up allows
    it. Shared by every identity provider. A refusal (`SignInRefused`) writes nothing."""
    now = now or utcnow()
    if settings.signup == "allowlist" and who.email not in settings.allowed:
        raise SignInRefused("not_allowed")
    known = session.get(Identity, (who.provider, who.subject))
    holder = session.exec(select(User).where(User.email == who.email)).first()
    if known is not None:
        user = session.get(User, known.user_id)
        assert user is not None  # identity rows cascade with their user
        if holder is None:  # a changed email is taken over unless another account has it
            user.email = who.email
        if who.provider_token:  # Apple: the newest refresh token replaces the stored one
            known.provider_token = who.provider_token
            known.provider_client_id = who.provider_client_id
            session.add(known)
    else:
        theirs = (
            session.exec(select(Identity).where(Identity.user_id == holder.id)).first()
            if holder is not None
            else None
        )
        if holder is not None and theirs is None and who.email == settings.owner_email:
            user = holder  # the migrated owner (030a) claims their deck
        elif holder is not None:  # never merged by email
            if theirs is None or theirs.provider == who.provider:
                raise SignInRefused("email_in_use")
            raise SignInRefused(f"use_{theirs.provider}")
        else:
            user = User(email=who.email, created_at=now)
        session.add(user)
        session.flush()
        session.add(Identity(
            provider=who.provider, subject=who.subject, user_id=user.id, created_at=now,
            provider_token=who.provider_token, provider_client_id=who.provider_client_id,
        ))  # fmt: skip
    user.last_seen_at = now
    session.add(user)
    session.commit()
    return user.id


# --- The SDK provider --------------------------------------------------------------------------


class LaCarteOAuth:
    """The MCP SDK's `OAuthAuthorizationServerProvider` over our tables. `identity` is None
    when no identity provider is configured: sign-in answers `temporarily_unavailable`, while
    tokens (personal access tokens) keep working. `apple` is None when Sign in with Apple is
    not configured (`/oauth/apple` answers `temporarily_unavailable`)."""

    def __init__(
        self,
        engine: Engine,
        settings: Settings,
        identity: IdentityProvider | None,
        clock: Callable[[], datetime] = utcnow,
        apple: AppleProvider | None = None,
    ) -> None:
        self.engine = engine
        self.settings = settings
        self.identity = identity
        self.apple = apple
        self.clock = clock  # tests move it forward
        self.base = settings.base_url
        self.resource = f"{self.base}/mcp"

    # Clients

    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        if client_id == auth.IOS_CLIENT:
            return IOS
        with Session(self.engine) as session:
            row = session.get(OAuthClient, client_id)
        return LaCarteClient.model_validate_json(row.info) if row else None

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        if len(client_info.client_name or "") > MAX_CLIENT_NAME:
            raise RegistrationError(
                "invalid_client_metadata", f"client_name is over {MAX_CLIENT_NAME} characters"
            )
        if len(client_info.redirect_uris or []) > MAX_REDIRECT_URIS:
            raise RegistrationError(
                "invalid_client_metadata", f"At most {MAX_REDIRECT_URIS} redirect_uris"
            )
        for uri in client_info.redirect_uris or []:
            if not (str(uri).startswith("https://") or _loopback(str(uri))):
                raise RegistrationError(
                    "invalid_redirect_uri", "Redirect URIs must be https:// or loopback http://"
                )
        with Session(self.engine) as session:
            info = client_info.model_dump_json()
            client_id = client_info.client_id or ""
            session.add(OAuthClient(client_id=client_id, info=info, created_at=self.clock()))
            session.commit()

    # Authorization

    async def authorize(
        self, client: OAuthClientInformationFull, params: AuthorizationParams
    ) -> str:
        if self.identity is None:
            raise AuthorizeError("temporarily_unavailable", "Sign-in is not set up on this server")
        resource = params.resource or self.resource
        if resource not in (self.resource, self.base):
            raise AuthorizeError("invalid_target", f"Unknown resource; use {self.resource}")
        now, verifier = self.clock(), secrets.token_urlsafe(48)
        request = AuthRequest(
            id=secrets.token_urlsafe(32), client_id=client.client_id or "",
            redirect_uri=str(params.redirect_uri),
            redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly,
            code_challenge=params.code_challenge, scopes=" ".join(params.scopes or [SCOPE]),
            resource=resource, client_state=params.state, provider=self.identity.name,
            nonce=secrets.token_urlsafe(16), provider_verifier=verifier, created_at=now,
        )  # fmt: skip
        with Session(self.engine) as session:
            stale = col(AuthRequest.created_at) <= now - REQUEST_TTL
            session.exec(delete(AuthRequest).where(stale))
            session.add(request)
            session.commit()
            if client.client_id == auth.IOS_CLIENT:  # the app: straight to the provider
                return self._provider_url(request)
            return f"{self.base}/oauth/consent?request={request.id}"

    def _provider_url(self, request: AuthRequest) -> str:
        assert self.identity is not None
        challenge = pkce_challenge(request.provider_verifier)
        return self.identity.authorization_url(
            state=request.id, nonce=request.nonce, code_challenge=challenge
        )

    def pending(self, session: Session, request_id: str | None) -> AuthRequest | None:
        """A live pending request (younger than 10 min, from the current identity provider)."""
        request = session.get(AuthRequest, request_id) if request_id else None
        if (
            request is None
            or request.created_at <= self.clock() - REQUEST_TTL
            or self.identity is None
            or request.provider != self.identity.name
        ):
            return None
        return request

    def mint_code(self, session: Session, request: AuthRequest, user_id: UUID) -> str:
        raw = CODE_PREFIX + secrets.token_urlsafe(32)
        session.add(AuthCode(
            hash=auth.token_hash(raw), user_id=user_id, client_id=request.client_id,
            redirect_uri=request.redirect_uri,
            redirect_uri_provided_explicitly=request.redirect_uri_provided_explicitly,
            code_challenge=request.code_challenge, scopes=request.scopes,
            resource=request.resource, expires_at=self.clock() + CODE_TTL,
        ))  # fmt: skip
        session.delete(request)
        session.commit()
        return raw

    # Tokens

    async def load_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: str
    ) -> Code | None:
        """Single use: the code is deleted as it is loaded, whatever happens next."""
        with Session(self.engine) as session:
            row = session.get(AuthCode, auth.token_hash(authorization_code))
            if row is None:
                return None
            session.delete(row)
            session.commit()
        if row.expires_at <= self.clock():
            return None
        return Code(
            code=authorization_code, scopes=row.scopes.split(),
            expires_at=row.expires_at.timestamp(), client_id=row.client_id,
            code_challenge=row.code_challenge, redirect_uri=AnyUrl(row.redirect_uri),
            redirect_uri_provided_explicitly=row.redirect_uri_provided_explicitly,
            resource=row.resource, subject=str(row.user_id), user_id=row.user_id,
        )  # fmt: skip

    async def exchange_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: Code
    ) -> OAuthToken:
        return self._pair(authorization_code.user_id, client, uuid4(), authorization_code.scopes)

    async def load_refresh_token(
        self, client: OAuthClientInformationFull, refresh_token: str
    ) -> Refresh | None:
        """A live refresh token. Presenting one that was already rotated or revoked revokes its
        whole family (a stolen token was used), and is refused."""
        now = self.clock()
        with Session(self.engine) as session:
            row = session.exec(
                select(ApiToken).where(ApiToken.hash == auth.token_hash(refresh_token))
            ).first()
            if row is None or row.kind != TokenKind.refresh or row.family_id is None:
                return None
            if row.revoked_at is not None:
                auth.revoke_family(session, row.family_id, now)
                return None
            if row.expires_at is not None and row.expires_at <= now:
                return None
        return Refresh(
            token=refresh_token, client_id=row.client_id or "", scopes=[row.scope.value],
            expires_at=int(row.expires_at.timestamp()) if row.expires_at else None,
            subject=str(row.user_id), user_id=row.user_id, token_id=row.id,
            family_id=row.family_id,
        )  # fmt: skip

    async def exchange_refresh_token(
        self, client: OAuthClientInformationFull, refresh_token: Refresh, scopes: list[str]
    ) -> OAuthToken:
        """Rotation: the presented refresh token is spent, a new pair joins its family.
        Compare-and-set: if a concurrent request spent it first, that is reuse (family revoked)."""
        now = self.clock()
        with Session(self.engine) as session:
            spent = session.exec(
                update(ApiToken)
                .where(col(ApiToken.id) == refresh_token.token_id)
                .where(col(ApiToken.revoked_at).is_(None))
                .values(revoked_at=now)
            )
            session.commit()
            if spent.rowcount == 0:
                auth.revoke_family(session, refresh_token.family_id, now)
                raise TokenError("invalid_grant", "refresh token already used")
        return self._pair(refresh_token.user_id, client, refresh_token.family_id, scopes)

    def _pair(
        self, user_id: UUID, client: OAuthClientInformationFull, family: UUID, scopes: list[str]
    ) -> OAuthToken:
        with Session(self.engine) as session:
            access, refresh = auth.mint_pair(
                session, user_id, client.client_id or "", family, self.clock()
            )
        expires_in = int(auth.ACCESS_TTL.total_seconds())
        return OAuthToken(access_token=access, expires_in=expires_in, refresh_token=refresh,
                          scope=" ".join(scopes))  # fmt: skip

    async def load_access_token(self, token: str) -> Access | None:
        """Any of our bearer tokens: OAuth access tokens and personal access tokens."""
        with Session(self.engine) as session:
            principal = auth.verify(session, token, self.clock())
        if principal is None:
            return None
        expires_at = principal.expires_at
        return Access(
            token=token, client_id=principal.client_id or principal.kind.value,
            scopes=[principal.scope.value],
            expires_at=int(expires_at.timestamp()) if expires_at else None,
            resource=self.resource, subject=str(principal.user_id),
            token_id=principal.token_id, kind=principal.kind,
        )  # fmt: skip

    async def revoke_token(self, token: Access | Refresh) -> None:
        """A refresh token takes its family with it; an access token goes alone."""
        with Session(self.engine) as session:
            if isinstance(token, Refresh):
                auth.revoke_family(session, token.family_id, self.clock())
            elif token.kind == TokenKind.access and (row := session.get(ApiToken, token.token_id)):
                row.revoked_at = self.clock()
                session.add(row)
                session.commit()

    def token_resource_error(self, form: dict) -> str | None:
        """RFC 8707 on `/token` (the SDK doesn't check it): a `resource` sent with a code must
        be the code's; with a refresh token, one of ours."""
        resource = form.get("resource")
        if not resource:
            return None
        if form.get("grant_type") == "authorization_code":
            with Session(self.engine) as session:
                row = session.get(AuthCode, auth.token_hash(str(form.get("code", ""))))
            if row is not None and row.resource != resource:
                return "resource differs from the authorization request's"
        elif resource not in (self.resource, self.base):
            return f"Unknown resource; use {self.resource}"
        return None

    async def revoke_provider_grants(self, user_id: UUID) -> None:
        """Before an account deletion (spec 030e decision 5): revokes the user's Sign in with
        Apple authorization with the stored refresh token. Best effort: never raises."""
        with Session(self.engine) as session:
            identities = session.exec(
                select(Identity)
                .where(Identity.user_id == user_id)
                .where(col(Identity.provider_token).is_not(None))
            ).all()
        for identity in identities:
            if identity.provider != "apple" or not identity.provider_token:
                continue
            if self.apple is None:
                log.warning("apple revoke skipped: Sign in with Apple is not configured")
                continue
            client_id = identity.provider_client_id or self.apple.bundle_id
            await self.apple.revoke(identity.provider_token, client_id)

    # Metadata

    def server_metadata(self) -> dict:
        methods = ["none", "client_secret_post", "client_secret_basic"]
        return {
            "issuer": self.base,
            "authorization_endpoint": f"{self.base}/authorize",
            "token_endpoint": f"{self.base}/token",
            "registration_endpoint": f"{self.base}/register",
            "revocation_endpoint": f"{self.base}/revoke",
            "scopes_supported": [SCOPE],
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "token_endpoint_auth_methods_supported": methods,
            "revocation_endpoint_auth_methods_supported": methods,
            "code_challenge_methods_supported": ["S256"],
            "authorization_response_iss_parameter_supported": True,
        }

    def resource_metadata(self) -> dict:
        return {
            "resource": self.resource,
            "authorization_servers": [self.base],
            "scopes_supported": [SCOPE],
            "bearer_methods_supported": ["header"],
            "resource_name": "la-carte",
        }


# --- Server HTML -------------------------------------------------------------------------------

STYLE = """
:root { color-scheme: light dark; --ink: #1c1c1e; --paper: #fbfaf7; --muted: #6e6e73; }
@media (prefers-color-scheme: dark) { :root { --ink: #f2f2f7; --paper: #000; --muted: #98989f; } }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--paper);
  color: var(--ink); font: 17px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; }
main { max-width: 22rem; padding: 2rem; text-align: center; }
img { width: 64px; height: 64px; }
h1 { font-size: 1.5rem; margin: 1rem 0 .5rem; }
p { color: var(--muted); margin: 0 0 1.5rem; }
p strong { color: var(--ink); }
button { font: inherit; font-weight: 600; padding: .75rem 1.5rem; border: 0; border-radius: 999px;
  background: var(--ink); color: var(--paper); cursor: pointer; }
"""
EXPIRED = "This sign-in expired. Start again from your app."


def page(heading: str, sentence: str, status: int = 200, form: str = "") -> HTMLResponse:
    """One heading, one sentence (already escaped), at most one button. Never framed."""
    body = (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        f"<title>{heading} · la-carte</title><style>{STYLE}</style></head><body><main>"
        f'<img src="/icon.svg" alt=""><h1>{heading}</h1><p>{sentence}</p>{form}'
        "</main></body></html>"
    )
    headers = NO_STORE | {
        "Content-Security-Policy": "frame-ancestors 'none'",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "no-referrer",
    }
    return HTMLResponse(body, status_code=status, headers=headers)


def expired() -> HTMLResponse:
    return page("Sign-in expired", EXPIRED, 400)


# --- Routes ------------------------------------------------------------------------------------


def routes(oauth: LaCarteOAuth) -> list[Route]:
    """Our OAuth routes, all public. Added before the MCP app's mount, so `/authorize`,
    `/token`, `/revoke` and the metadata documents here win over the SDK's own."""
    authorize_handler = AuthorizationHandler(oauth).handle
    authenticator = ClientAuthenticator(oauth)
    token_handler = TokenHandler(oauth, authenticator).handle
    consent_prefix = f"{oauth.base}/oauth/consent?request="

    async def authorize(request: Request) -> Response:
        response = await authorize_handler(request)
        location = response.headers.get("location", "")
        if "error" in parse_qs(urlparse(location).query):  # RFC 9207, which we advertise
            response.headers["location"] = construct_redirect_uri(location, iss=oauth.base)
        if location.startswith(consent_prefix):  # an agent: bind this browser to its request
            response.set_cookie(
                COOKIE, location.removeprefix(consent_prefix), max_age=600, path="/oauth",
                secure=not oauth.settings.is_loopback, httponly=True, samesite="lax",
            )  # fmt: skip
        return response

    async def token(request: Request) -> Response:
        if error := oauth.token_resource_error(dict(await request.form())):
            body = {"error": "invalid_target", "error_description": error}
            return JSONResponse(body, status_code=400, headers=NO_STORE)
        return await token_handler(request)  # the form is cached on `request`

    async def revoke(request: Request) -> Response:
        """RFC 7009, for public clients too: the SDK's handler requires a `client_secret`
        field (mcp 2.3.0). Unknown tokens and other clients' tokens: 200, nothing done."""
        try:
            client = await authenticator.authenticate_request(request)
        except AuthenticationError as error:
            body = {"error": "invalid_client", "error_description": error.message}
            return JSONResponse(body, status_code=401, headers=NO_STORE)
        raw = str((await request.form()).get("token", ""))
        token = await oauth.load_access_token(raw) or await oauth.load_refresh_token(client, raw)
        if token is not None and token.client_id == client.client_id:
            await oauth.revoke_token(token)
        return Response(status_code=200, headers=NO_STORE)

    async def consent(request: Request) -> Response:
        """The confused-deputy guard: the user sees who asks and where they'll be sent."""
        if request.method == "POST":
            request_id = str((await request.form()).get("request", ""))
        else:
            request_id = request.query_params.get("request", "")
        with Session(oauth.engine) as session:
            pending = oauth.pending(session, request_id)
        if pending is None:
            return expired()
        if request.method == "POST":
            if request.cookies.get(COOKIE) != pending.id:  # not the browser that started it
                return expired()
            return RedirectResponse(oauth._provider_url(pending), status_code=303)
        client = await oauth.get_client(pending.client_id)
        name = html.escape((client and client.client_name) or pending.client_id)
        host = html.escape(urlparse(pending.redirect_uri).hostname or pending.redirect_uri)
        sentence = (
            f"<strong>{name}</strong> wants to use your la-carte deck. After you sign in, "
            f"you'll return to <strong>{host}</strong>."
        )
        label = "Continue with Google" if pending.provider == "google" else "Continue"
        form = (
            '<form method="post" action="/oauth/consent">'
            f'<input type="hidden" name="request" value="{html.escape(pending.id)}">'
            f'<button id="continue" type="submit">{label}</button></form>'
        )
        return page("Connect to la-carte", sentence, form=form)

    async def callback(request: Request) -> Response:
        query = request.query_params
        state = query.get("state")
        cookie = request.cookies.get(COOKIE)
        with Session(oauth.engine) as session:
            pending = oauth.pending(session, state)
            if pending is None:
                return expired()
            # An agent's sign-in must come back to the browser that consented (else an attacker
            # could send a victim the provider URL of their own request). The app skips consent;
            # a stale cookie from an abandoned agent sign-in must not break it.
            if pending.client_id != auth.IOS_CLIENT and cookie != state:
                return expired()  # not this browser's request: we can't trust where to send it

            def back(**params: str) -> Response:
                url = construct_redirect_uri(
                    pending.redirect_uri, **params, state=pending.client_state, iss=oauth.base
                )
                response = RedirectResponse(url, status_code=302, headers=NO_STORE)
                response.delete_cookie(COOKIE, path="/oauth")
                return response

            def refuse(reason: str) -> Response:
                session.delete(pending)
                session.commit()
                return back(error="access_denied", error_description=reason)

            if query.get("error") or not query.get("code"):
                return refuse("cancelled" if query.get("error") else "sign_in_failed")
            assert oauth.identity is not None  # `pending` checked it
            try:
                who = await oauth.identity.verify(
                    code=query["code"], code_verifier=pending.provider_verifier,
                    nonce=pending.nonce,
                )  # fmt: skip
                user_id = resolve_account(session, who, oauth.settings, oauth.clock())
            except (IdentityError, SignInRefused) as error:
                session.rollback()
                return refuse(error.reason)
            return back(code=oauth.mint_code(session, pending, user_id))

    async def apple(request: Request) -> Response:
        """Sign in with Apple from the app (spec 030e): Apple's identity token, its authorization
        code and the raw nonce → our tokens, with the same body as `/token`."""
        form = await request.form()

        def error(code: str, description: str) -> Response:
            body = {"error": code, "error_description": description}
            return JSONResponse(body, status_code=400, headers=NO_STORE)

        if form.get("client_id") != auth.IOS_CLIENT:
            return error("invalid_client", f"Use client_id {auth.IOS_CLIENT}")
        if oauth.apple is None:
            return error("temporarily_unavailable", "Sign in with Apple is not set up")
        names = ("identity_token", "authorization_code", "nonce")
        values = [form.get(name) for name in names]
        if not all(isinstance(value, str) and value for value in values):
            return error("invalid_request", f"Required: {', '.join(names)}")
        identity_token, code, nonce = (str(value) for value in values)
        try:
            who = await oauth.apple.verify_native(identity_token, code, nonce)
        except IdentityError as refused:
            return error("invalid_grant", refused.reason)
        with Session(oauth.engine) as session:
            try:
                user_id = resolve_account(session, who, oauth.settings, oauth.clock())
            except SignInRefused as refused:
                session.rollback()
                if who.provider_token and who.provider_client_id:  # don't leave the grant live
                    await oauth.apple.revoke(who.provider_token, who.provider_client_id)
                return error("access_denied", refused.reason)
        token = oauth._pair(user_id, IOS, uuid4(), [SCOPE])
        return JSONResponse(token.model_dump(mode="json", exclude_none=True), headers=NO_STORE)

    async def fake_authorize(request: Request) -> Response:
        """The fake provider's "sign-in page": signs its configured email in at once."""
        assert isinstance(oauth.identity, FakeProvider)
        state = request.query_params.get("state", "")
        url = construct_redirect_uri(f"{oauth.base}/oauth/callback",
                                     code=oauth.identity.email, state=state)  # fmt: skip
        return RedirectResponse(url, status_code=302)

    def document(content: Callable[[], dict]) -> Callable[[Request], Response]:
        async def serve(_: Request) -> Response:
            return JSONResponse(content(), headers={"Cache-Control": "public, max-age=3600"})

        return serve

    listed = [
        Route("/authorize", authorize, methods=["GET", "POST"]),
        Route("/token", cors_middleware(token, ["POST", "OPTIONS"]), methods=["POST", "OPTIONS"]),
        Route("/revoke", cors_middleware(revoke, ["POST", "OPTIONS"]), methods=["POST", "OPTIONS"]),
        Route("/oauth/consent", consent, methods=["GET", "POST"]),
        Route("/oauth/callback", callback, methods=["GET"]),
        Route("/oauth/apple", apple, methods=["POST"]),
        Route("/.well-known/oauth-authorization-server", document(oauth.server_metadata)),
        Route("/.well-known/oauth-protected-resource", document(oauth.resource_metadata)),
        Route("/.well-known/oauth-protected-resource/mcp", document(oauth.resource_metadata)),
    ]
    if isinstance(oauth.identity, FakeProvider):
        listed.append(Route("/oauth/fake/authorize", fake_authorize, methods=["GET"]))
    return listed
