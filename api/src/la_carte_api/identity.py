"""Who the user is, according to an external identity provider (spec 030b decision 5).

A provider sends the browser to its sign-in page and, back on `/oauth/callback`, turns the code it
returned into a `VerifiedIdentity`: the provider's account key (`sub`) and a verified email. Nothing
else is kept: no name, no picture, and no Google token (revoked right away). Apple (spec 030e) signs
the app in natively (`POST /oauth/apple`); its refresh token is kept only to revoke it when the
account is deleted.
"""

import base64
import hashlib
import json
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Protocol
from urllib.parse import urlencode

import anyio
import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import load_pem_private_key

from la_carte_api.config import Settings, _secret

log = logging.getLogger(__name__)

GOOGLE_AUTHORIZE = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN = "https://oauth2.googleapis.com/token"
GOOGLE_REVOKE = "https://oauth2.googleapis.com/revoke"
GOOGLE_ISSUERS = {"https://accounts.google.com", "accounts.google.com"}
CALLBACK = "/oauth/callback"


@dataclass(frozen=True)
class VerifiedIdentity:
    provider: str  # "google" | "apple" | "fake"
    subject: str  # the provider's `sub`: the account key
    email: str  # verified by the provider, casefolded
    # Apple only: its refresh token, kept to revoke on deletion, and the `client_id` it belongs to.
    provider_token: str | None = field(default=None, repr=False)
    provider_client_id: str | None = None


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


APPLE_ISSUER = "https://appleid.apple.com"
APPLE_KEYS = f"{APPLE_ISSUER}/auth/keys"
APPLE_TOKEN = f"{APPLE_ISSUER}/auth/token"
APPLE_REVOKE = f"{APPLE_ISSUER}/auth/revoke"
APPLE_KEYS_TTL = 24 * 60 * 60  # seconds the JWKS stays cached
APPLE_KEYS_MIN_REFETCH = 60  # seconds between two JWKS fetches (`/oauth/apple` is public)
CLIENT_SECRET_TTL = 5 * 60  # seconds; minted per call (Apple accepts up to 6 months)
REVOKE_TIMEOUT = 5  # seconds


class AppleProvider:
    """Sign in with Apple from the native app (spec 030e). The identity token is checked
    against Apple's JWKS (signature, `iss`, `aud` = the bundle id, `exp`, nonce), then the
    authorization code is exchanged for Apple's refresh token, the only way to revoke the user's
    authorization when they delete their account."""

    name = "apple"

    def __init__(
        self,
        team_id: str,
        key_id: str,
        private_key: ec.EllipticCurvePrivateKey,
        bundle_id: str,
        transport: httpx.AsyncBaseTransport | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.team_id = team_id
        self.key_id = key_id
        self.private_key = private_key
        self.bundle_id = bundle_id
        self.transport = transport  # tests inject one: no test calls Apple
        self.clock = clock
        self._keys: dict[str, jwt.PyJWK] = {}
        self._keys_at = float("-inf")  # when the JWKS was last fetched, or tried

    async def verify_native(
        self, identity_token: str, code: str, raw_nonce: str
    ) -> VerifiedIdentity:
        async with httpx.AsyncClient(transport=self.transport, timeout=10) as client:
            claims = await self._claims(client, identity_token, raw_nonce)
            refresh_token = await self._exchange(client, code, claims["sub"])
        return VerifiedIdentity(
            self.name, claims["sub"], claims["email"].strip().casefold(),
            provider_token=refresh_token, provider_client_id=self.bundle_id,
        )  # fmt: skip

    async def revoke(self, refresh_token: str, client_id: str) -> None:
        """Ends the user's Sign in with Apple authorization. Best effort: a failure is logged
        (status only) and swallowed, so an account deletion never waits on Apple."""
        form = {"client_id": client_id, "client_secret": self.client_secret(client_id),
                "token": refresh_token, "token_type_hint": "refresh_token"}  # fmt: skip
        try:
            with anyio.fail_after(REVOKE_TIMEOUT):
                async with httpx.AsyncClient(transport=self.transport, timeout=REVOKE_TIMEOUT) as c:
                    response = await c.post(APPLE_REVOKE, data=form)
        except (httpx.HTTPError, TimeoutError) as error:
            log.warning("apple revoke failed: %s", type(error).__name__)
            return
        if response.status_code != 200:
            log.warning("apple revoke failed: %s", response.status_code)

    def client_secret(self, client_id: str) -> str:
        """The ES256 JWT that authenticates us to Apple's token and revoke endpoints."""
        now = int(self.clock())
        claims = {"iss": self.team_id, "iat": now, "exp": now + CLIENT_SECRET_TTL,
                  "aud": APPLE_ISSUER, "sub": client_id}  # fmt: skip
        return jwt.encode(claims, self.private_key, algorithm="ES256", headers={"kid": self.key_id})

    async def _claims(self, client: httpx.AsyncClient, token: str, raw_nonce: str) -> dict:
        try:
            key = await self._key(client, jwt.get_unverified_header(token).get("kid"))
            claims = jwt.decode(
                token, key, algorithms=["RS256"], audience=self.bundle_id, issuer=APPLE_ISSUER,
                options={"require": ["iss", "aud", "exp", "sub"], "verify_exp": False},
            )  # fmt: skip
        except jwt.PyJWTError as error:
            log.warning("Apple identity token refused: %s", type(error).__name__)
            raise IdentityError("sign_in_failed") from error
        nonce = hashlib.sha256(raw_nonce.encode()).hexdigest()
        if (
            not isinstance(claims["exp"], int | float)
            or claims["exp"] <= self.clock()
            or claims.get("nonce") != nonce
            or not isinstance(claims["sub"], str)
            or not claims["sub"]
            or not isinstance(claims.get("email"), str)
            or claims.get("email_verified") not in (True, "true")
        ):
            log.warning("Apple identity token refused: claims")
            raise IdentityError("sign_in_failed")
        return claims

    async def _key(self, client: httpx.AsyncClient, kid: object) -> jwt.PyJWK:
        """Apple's public key `kid`, from the cached JWKS; refetched when older than 24 h, or
        when `kid` is unknown (Apple rotated its keys), but at most once a minute, failed
        fetches included: the endpoint is public, so a caller can't make us hammer Apple."""
        if not isinstance(kid, str):
            raise jwt.InvalidKeyError("no kid")
        age = self.clock() - self._keys_at
        if age >= APPLE_KEYS_TTL or (kid not in self._keys and age >= APPLE_KEYS_MIN_REFETCH):
            await self._fetch_keys(client)
        if kid not in self._keys:
            raise jwt.InvalidKeyError("unknown kid")
        return self._keys[kid]

    async def _fetch_keys(self, client: httpx.AsyncClient) -> None:
        self._keys_at = self.clock()  # before the await: parallel or failed fetches count too
        try:
            response = await client.get(APPLE_KEYS)
            response.raise_for_status()
            keys = jwt.PyJWKSet.from_dict(response.json()).keys
        except (httpx.HTTPError, ValueError, jwt.PyJWTError) as error:
            log.warning("Apple JWKS fetch failed: %s", type(error).__name__)
            raise IdentityError("sign_in_failed") from error
        self._keys = {key.key_id: key for key in keys if key.key_id}

    async def _exchange(self, client: httpx.AsyncClient, code: str, subject: str) -> str:
        """Apple's refresh token for `code`; its `id_token` must be the same user's (it comes
        straight from Apple over TLS, so only its claims are read)."""
        form = {"client_id": self.bundle_id, "client_secret": self.client_secret(self.bundle_id),
                "code": code, "grant_type": "authorization_code"}  # fmt: skip
        try:
            response = await client.post(APPLE_TOKEN, data=form)
            response.raise_for_status()
            tokens = response.json()
        except (httpx.HTTPError, ValueError) as error:
            log.warning("Apple code exchange failed: %s", type(error).__name__)
            raise IdentityError("sign_in_failed") from error
        refresh = tokens.get("refresh_token") if isinstance(tokens, dict) else None
        if not isinstance(refresh, str) or not refresh:
            log.warning("Apple code exchange failed: no refresh token")
            raise IdentityError("sign_in_failed")
        if _payload(tokens.get("id_token")).get("sub") != subject:
            log.warning("Apple code exchange failed: another subject")
            raise IdentityError("sign_in_failed")
        return refresh


APPLE_SETTINGS = {
    "LA_CARTE_APPLE_TEAM_ID": "apple_team_id",
    "LA_CARTE_APPLE_KEY_ID": "apple_key_id",
    "LA_CARTE_APPLE_PRIVATE_KEY_B64": "apple_private_key_b64",
    "LA_CARTE_APPLE_BUNDLE_ID": "apple_bundle_id",
}


def apple_from(settings: Settings) -> AppleProvider | None:
    """Sign in with Apple when its four variables are set; None when none is. Raises
    `RuntimeError` (naming the variable, never its value) on a partial or unusable setup."""
    values = {}
    for variable, attribute in APPLE_SETTINGS.items():
        value = getattr(settings, attribute)
        values[variable] = _secret(value) if not isinstance(value, str) else value.strip()
    missing = [variable for variable, value in values.items() if not value]
    if len(missing) == len(values):
        return None
    if missing:
        raise RuntimeError(f"Sign in with Apple: set {', '.join(missing)} (or none of the four)")
    try:
        key = load_pem_private_key(base64.b64decode(values["LA_CARTE_APPLE_PRIVATE_KEY_B64"]), None)
    except (ValueError, TypeError) as error:
        raise RuntimeError("LA_CARTE_APPLE_PRIVATE_KEY_B64 is not a base64 .p8 key") from error
    if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
        raise RuntimeError("LA_CARTE_APPLE_PRIVATE_KEY_B64 is not an EC P-256 key (.p8)")
    return AppleProvider(
        values["LA_CARTE_APPLE_TEAM_ID"], values["LA_CARTE_APPLE_KEY_ID"], key,
        values["LA_CARTE_APPLE_BUNDLE_ID"],
    )  # fmt: skip


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
