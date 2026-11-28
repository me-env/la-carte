"""Who the user is, according to an external identity provider (spec 030b decision 5).

A provider sends the browser to its sign-in page and, back on `/oauth/callback`, turns the code it
returned into a `VerifiedIdentity`: the provider's account key (`sub`) and a verified email. Nothing
else is kept: no name, no picture, and no provider token (Google's is revoked right away).
"""

import base64
import hashlib
import json
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol
from urllib.parse import urlencode

import httpx

from la_carte_api.config import Settings

log = logging.getLogger(__name__)

GOOGLE_AUTHORIZE = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN = "https://oauth2.googleapis.com/token"
GOOGLE_REVOKE = "https://oauth2.googleapis.com/revoke"
GOOGLE_ISSUERS = {"https://accounts.google.com", "accounts.google.com"}
CALLBACK = "/oauth/callback"


@dataclass(frozen=True)
class VerifiedIdentity:
    provider: str  # "google" | "fake"
    subject: str  # the provider's `sub`: the account key
    email: str  # verified by the provider, casefolded


class IdentityError(Exception):
    """The sign-in failed; `reason` is the OAuth `error_description` the client gets."""

    def __init__(self, reason: str) -> None:  # "unverified_email" | "sign_in_failed"
        super().__init__(reason)
        self.reason = reason


class IdentityProvider(Protocol):
    name: str

    def authorization_url(self, *, state: str, nonce: str, code_challenge: str) -> str: ...

    async def verify(self, *, code: str, code_verifier: str, nonce: str) -> VerifiedIdentity: ...


def pkce_challenge(verifier: str) -> str:
    """The S256 code challenge of a PKCE verifier."""
    digest = hashlib.sha256(verifier.encode()).digest()
    return base64.urlsafe_b64encode(digest).decode().rstrip("=")


class GoogleProvider:
    """Google, scopes `openid email` only. The ID token comes straight from Google's token
    endpoint over TLS, so its signature check is replaced by TLS (OIDC Core 3.1.3.7)."""

    name = "google"

    def __init__(
        self,
        client_id: str,
        client_secret: str,
        base_url: str,
        transport: httpx.AsyncBaseTransport | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.client_id = client_id
        self.client_secret = client_secret
        self.redirect_uri = base_url + CALLBACK
        self.transport = transport  # tests inject one: no test calls Google
        self.clock = clock

    def authorization_url(self, *, state: str, nonce: str, code_challenge: str) -> str:
        query = {
            "response_type": "code",
            "client_id": self.client_id,
            "redirect_uri": self.redirect_uri,
            "scope": "openid email",
            "state": state,
            "nonce": nonce,
            "code_challenge": code_challenge,
            "code_challenge_method": "S256",
            "prompt": "select_account",
        }
        return f"{GOOGLE_AUTHORIZE}?{urlencode(query)}"

    async def verify(self, *, code: str, code_verifier: str, nonce: str) -> VerifiedIdentity:
        async with httpx.AsyncClient(transport=self.transport, timeout=10) as client:
            try:
                response = await client.post(GOOGLE_TOKEN, data={
                    "grant_type": "authorization_code", "code": code,
                    "code_verifier": code_verifier, "redirect_uri": self.redirect_uri,
                    "client_id": self.client_id, "client_secret": self.client_secret,
                })  # fmt: skip
                response.raise_for_status()
                tokens = response.json()
            except (httpx.HTTPError, ValueError) as error:
                log.warning("Google token exchange failed: %s", type(error).__name__)
                raise IdentityError("sign_in_failed") from error
            if not isinstance(tokens, dict):
                log.warning("Google token exchange failed: not a JSON object")
                raise IdentityError("sign_in_failed")
            try:
                return self._identity(tokens.get("id_token"), nonce)
            finally:  # no Google grant outlives a sign-in, whatever the outcome
                if access_token := tokens.get("access_token"):
                    await self._revoke(client, access_token)

    def _identity(self, id_token: object, nonce: str) -> VerifiedIdentity:
        claims = _payload(id_token)
        if (
            claims.get("iss") not in GOOGLE_ISSUERS
            or claims.get("aud") != self.client_id
            or not isinstance(claims.get("exp"), int | float)
            or claims["exp"] <= self.clock()
            or claims.get("nonce") != nonce
            or not isinstance(claims.get("sub"), str)
            or not isinstance(claims.get("email"), str)
        ):
            raise IdentityError("sign_in_failed")
        if claims.get("email_verified") is not True:
            raise IdentityError("unverified_email")
        return VerifiedIdentity(self.name, claims["sub"], claims["email"].strip().casefold())

    async def _revoke(self, client: httpx.AsyncClient, access_token: str) -> None:
        """Best effort: a failed revocation never fails the sign-in (the token expires in 1 h)."""
        try:
            await client.post(GOOGLE_REVOKE, data={"token": access_token})
        except httpx.HTTPError as error:
            log.warning("Google token revocation failed: %s", type(error).__name__)


def _payload(id_token: object) -> dict:
    """The claims of a JWT (not its signature: see `GoogleProvider`)."""
    parts = id_token.split(".") if isinstance(id_token, str) else []
    try:
        part = parts[1]
        claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    except (IndexError, ValueError) as error:
        raise IdentityError("sign_in_failed") from error
    if not isinstance(claims, dict):
        raise IdentityError("sign_in_failed")
    return claims


class FakeProvider:
    """Tests and e2e: `/oauth/fake/authorize` signs `email` in at once. Refused at startup unless
    the server is on loopback (`provider_from`)."""

    name = "fake"

    def __init__(self, base_url: str, email: str) -> None:
        self.base_url = base_url
        self.email = email

    def authorization_url(self, *, state: str, nonce: str, code_challenge: str) -> str:
        return f"{self.base_url}/oauth/fake/authorize?{urlencode({'state': state})}"

    async def verify(self, *, code: str, code_verifier: str, nonce: str) -> VerifiedIdentity:
        email = code.strip().casefold()  # the fake code is the email
        if email.startswith("unverified"):
            raise IdentityError("unverified_email")
        return VerifiedIdentity(self.name, f"fake-{email}", email)


def provider_from(settings: Settings) -> IdentityProvider | None:
    """The configured identity provider, or None (personal access tokens only). Raises
    `RuntimeError` on a configuration that must not start."""
    if settings.identity_provider == "fake":
        if not settings.is_loopback:
            raise RuntimeError(
                "LA_CARTE_IDENTITY_PROVIDER=fake is for tests: LA_CARTE_PUBLIC_URL must be unset "
                "or loopback"
            )
        return FakeProvider(settings.base_url, settings.fake_email)
    client_id, secret = settings.google_client_id, settings.google_client_secret
    if not client_id and not secret:
        return None
    if not client_id or not secret:
        raise RuntimeError("Set both LA_CARTE_GOOGLE_CLIENT_ID and LA_CARTE_GOOGLE_CLIENT_SECRET")
    if not settings.public_url or (
        not settings.public_url.startswith("https://") and not settings.is_loopback
    ):
        raise RuntimeError("Google sign-in needs LA_CARTE_PUBLIC_URL with https://")
    return GoogleProvider(client_id, secret, settings.base_url)
