"""Spec 030e: Sign in with Apple on the server (`POST /oauth/apple`) and revocation on deletion
(AC numbers in comments). A test RSA key is Apple's JWKS, a test EC key ours, and Apple's
endpoints are an injected `httpx` transport: no test calls Apple or Google."""

import base64
import hashlib
import json
import logging
import time
from urllib.parse import parse_qs

import httpx
import jwt
import pytest
from conftest import bearer
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from sqlmodel import Session, select
from test_oauth import (
    GOOGLE_ID,
    OWNER,
    FakeGoogle,
    _app,
    _authorize,
    _counts,
    _exchange,
    _mcp,
    _query,
)

from la_carte_api import deck
from la_carte_api.identity import APPLE_ISSUER
from la_carte_api.models import ApiToken, Identity, NoteCreate, User

BUNDLE = "com.example.lacarte"
TEAM, KEY_ID = "TEAM123456", "KEY1234567"
RAW_NONCE = "raw-nonce-from-the-app"
APPLE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_RSA = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OUR_KEY = ec.generate_private_key(ec.SECP256R1())
OUR_KEY_B64 = base64.b64encode(
    OUR_KEY.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
).decode()
APPLE_SETTINGS = {
    "apple_team_id": TEAM,
    "apple_key_id": KEY_ID,
    "apple_private_key_b64": OUR_KEY_B64,
    "apple_bundle_id": BUNDLE,
}


def _jwk(key: rsa.RSAPrivateKey, kid: str) -> dict:
    public = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    return public | {"kid": kid, "alg": "RS256", "use": "sig"}


def _identity_token(kid: str = "k1", key=APPLE_KEY, **claims) -> str:
    now = int(time.time())
    payload = {
        "iss": APPLE_ISSUER, "aud": BUNDLE, "exp": now + 600, "iat": now, "sub": "apple-001",
        "nonce": hashlib.sha256(RAW_NONCE.encode()).hexdigest(), "nonce_supported": True,
        "email": "Ann@Example.com", "email_verified": "true", "is_private_email": "false",
    } | claims  # fmt: skip
    return jwt.encode(payload, key, algorithm="RS256", headers={"kid": kid})


class FakeApple:
    """Apple's JWKS, token and revoke endpoints, as an `httpx` transport."""

    def __init__(self) -> None:
        self.keys = [_jwk(APPLE_KEY, "k1")]
        self.subject: str | None = None  # the exchanged id_token's `sub`; None: the code's
        self.token_status = 200
        self.revoke: int | type[Exception] = 200
        self.requests: list[httpx.Request] = []
        self.exchanges = 0

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        assert request.url.host == "appleid.apple.com"
        if request.url.path == "/auth/keys":
            return httpx.Response(200, json={"keys": self.keys})
        if request.url.path == "/auth/token":
            if self.token_status != 200:
                return httpx.Response(self.token_status, json={"error": "invalid_grant"})
            self.exchanges += 1
            code = parse_qs(request.content.decode())["code"][0]
            subject = self.subject or code.removeprefix("code-")
            id_token = jwt.encode({"iss": APPLE_ISSUER, "sub": subject}, "x" * 32)
            return httpx.Response(200, json={
                "access_token": "apple-access", "token_type": "bearer", "expires_in": 3600,
                "refresh_token": f"apple-refresh-{self.exchanges}", "id_token": id_token,
            })  # fmt: skip
        assert request.url.path == "/auth/revoke"
        if isinstance(self.revoke, type):
            raise self.revoke("Apple is down", request=request)
        return httpx.Response(self.revoke)

    def paths(self) -> list[str]:
        return [request.url.path for request in self.requests]

    def form(self, path: str) -> dict[str, str]:
        request = [request for request in self.requests if request.url.path == path][-1]
        return {k: v[0] for k, v in parse_qs(request.content.decode()).items()}


def _apple_app(**settings):
    client = _app(**(APPLE_SETTINGS | settings))
    fake = FakeApple()
    client.app.state.oauth.apple.transport = httpx.MockTransport(fake)
    return client, fake


def _sign_in(client, token: str | None = None, **form) -> httpx.Response:
    """Posts like the app; the fake code is `code-<the identity token's sub>`."""
    token = token or _identity_token()
    try:
        code = "code-" + str(jwt.decode(token, options={"verify_signature": False}).get("sub"))
    except jwt.PyJWTError:
        code = "code-none"
    body = {"client_id": "la-carte-ios", "identity_token": token,
            "authorization_code": code, "nonce": RAW_NONCE} | form  # fmt: skip
    return client.post("/oauth/apple", data=body)


def _identity(client, subject: str = "apple-001") -> Identity | None:
    with Session(client.app.state.engine) as session:
        return session.get(Identity, ("apple", subject))


def _verify_client_secret(secret: str, now: int) -> None:  # AC 6
    header = jwt.get_unverified_header(secret)
    assert (header["alg"], header["kid"]) == ("ES256", KEY_ID)
    claims = jwt.decode(secret, OUR_KEY.public_key(), algorithms=["ES256"], audience=APPLE_ISSUER)
    assert (claims["iss"], claims["sub"]) == (TEAM, BUNDLE)
    assert claims["iat"] <= now + 1 < claims["exp"] <= claims["iat"] + 180 * 24 * 3600


# --- AC 1-2, 4, 6: sign-in ----------------------------------------------------------------------


def test_a_new_apple_user_gets_tokens_and_a_deck():  # AC 1, 6
    client, fake = _apple_app()
    with client:
        response = _sign_in(client)
        assert response.status_code == 200, response.text
        tokens = response.json()
        assert set(tokens) == {"access_token", "token_type", "expires_in", "refresh_token", "scope"}
        assert (tokens["token_type"], tokens["expires_in"], tokens["scope"]) == (
            "Bearer",
            3600,
            "deck",
        )
        assert response.headers["cache-control"] == "no-store"
        access = tokens["access_token"]
        assert _mcp(client, access).json()["result"]["tools"]
        me = client.get("/me", headers=bearer(access)).json()
        assert (me["email"], me["provider"]) == ("ann@example.com", "apple")
        identity = _identity(client)
        assert identity.provider_token == "apple-refresh-1"
        assert identity.provider_client_id == BUNDLE
        with Session(client.app.state.engine) as session:
            rows = session.exec(select(ApiToken).where(ApiToken.user_id == identity.user_id))
            assert {row.client_id for row in rows} == {"la-carte-ios"}

        exchange = fake.form("/auth/token")
        assert exchange["client_id"] == BUNDLE and exchange["code"] == "code-apple-001"
        assert exchange["grant_type"] == "authorization_code"
        _verify_client_secret(exchange["client_secret"], int(time.time()))

        refreshed = client.post("/token", data={"grant_type": "refresh_token",
                                                "refresh_token": tokens["refresh_token"],
                                                "client_id": "la-carte-ios"})  # fmt: skip
        assert refreshed.status_code == 200, refreshed.text


def test_the_same_apple_user_comes_back():  # AC 2
    client, _ = _apple_app()
    with client:
        first = _sign_in(client).json()
        user_id = _identity(client).user_id
        second = _sign_in(client, _identity_token(email="new@example.com")).json()
        assert second["access_token"] != first["access_token"]
        assert _identity(client).user_id == user_id
        assert _identity(client).provider_token == "apple-refresh-2"
        me = client.get("/me", headers=bearer(second["access_token"])).json()
        assert me["id"] == str(user_id) and me["email"] == "new@example.com"


def test_verified_email_as_bool_or_string_and_private_relay():  # AC 4
    client, _ = _apple_app()
    relay = "x7k2abc@privaterelay.appleid.com"
    with client:
        assert _sign_in(client, _identity_token(email_verified=True)).status_code == 200
        token = _identity_token(sub="apple-002", email=relay, email_verified="true",
                                is_private_email="true")  # fmt: skip
        tokens = _sign_in(client, token).json()
        assert client.get("/me", headers=bearer(tokens["access_token"])).json()["email"] == relay


# --- AC 3: refusals -----------------------------------------------------------------------------


@pytest.mark.parametrize(
    "case",
    [
        "signature", "unknown kid", "issuer", "audience", "expired", "nonce", "no sub",
        "unverified bool", "unverified string", "no email", "exchange 400", "other subject",
        "garbage",
    ],
)  # fmt: skip
def test_a_refused_apple_sign_in_writes_nothing(case):  # AC 3
    client, fake = _apple_app()
    token = {
        "signature": _identity_token(key=OTHER_RSA),
        "unknown kid": _identity_token(kid="k9", key=OTHER_RSA),
        "issuer": _identity_token(iss="https://evil.example"),
        "audience": _identity_token(aud="com.example.other"),
        "expired": _identity_token(exp=int(time.time()) - 10),
        "nonce": _identity_token(nonce=hashlib.sha256(b"replayed").hexdigest()),
        "no sub": _identity_token(sub=""),
        "unverified bool": _identity_token(email_verified=False),
        "unverified string": _identity_token(email_verified="false"),
        "no email": _identity_token(email=None),
        "garbage": "not-a-jwt",
    }.get(case)
    with client:
        assert _sign_in(client, _identity_token(sub="warm-up")).status_code == 200
        fake.requests.clear()
        if case == "exchange 400":
            fake.token_status = 400
        if case == "other subject":
            fake.subject = "apple-999"
        before = _counts(client)
        response = _sign_in(client, token)
        assert response.status_code == 400
        assert response.json() == {"error": "invalid_grant", "error_description": "sign_in_failed"}
        assert _counts(client) == before
    if case == "unknown kid":
        assert fake.paths().count("/auth/keys") == 1  # cached, then one refetch
    if case not in ("exchange 400", "other subject"):
        assert "/auth/token" not in fake.paths()  # no code is spent on a bad identity token


def test_missing_fields_are_an_invalid_request():
    client, _ = _apple_app()
    with client:
        response = _sign_in(client, nonce="")
        assert (response.status_code, response.json()["error"]) == (400, "invalid_request")


# --- AC 5: the JWKS cache -----------------------------------------------------------------------


def test_the_jwks_is_cached_and_refetched_once_for_a_new_kid():  # AC 5
    client, fake = _apple_app()
    with client:
        for sub in ("a1", "a2", "a3"):
            assert (
                _sign_in(client, _identity_token(sub=sub, email=f"{sub}@example.com")).status_code
                == 200
            )
        assert fake.paths().count("/auth/keys") == 1
        fake.keys.append(_jwk(OTHER_RSA, "k2"))  # Apple rotates
        assert (
            _sign_in(
                client, _identity_token("k2", OTHER_RSA, sub="a4", email="a4@example.com")
            ).status_code
            == 200
        )
        assert fake.paths().count("/auth/keys") == 2
        assert _sign_in(client, _identity_token(sub="a1")).status_code == 200
        assert fake.paths().count("/auth/keys") == 2
        apple = client.app.state.oauth.apple  # a day later the cache expires
        apple.clock = lambda: time.time() + 24 * 3600 + 1
        assert (
            _sign_in(client, _identity_token(exp=int(time.time()) + 90_000, sub="a1")).status_code
            == 200
        )
        assert fake.paths().count("/auth/keys") == 3


# --- AC 7-9: accounts ---------------------------------------------------------------------------

GOOGLE = {"identity_provider": "google", "google_client_id": GOOGLE_ID,
          "google_client_secret": "secret"}  # fmt: skip


def _google_sign_in(client, email: str) -> httpx.Response:
    google = FakeGoogle(email=email)
    client.app.state.oauth.identity.transport = httpx.MockTransport(google)
    response, verifier = _authorize(client, "la-carte-ios", "lacarte://oauth")
    query = _query(response.headers["location"])
    google.claims |= {"nonce": query["nonce"], "sub": f"g-{email}"}
    callback = client.get("/oauth/callback", params={"code": "g", "state": query["state"]},
                          follow_redirects=False)  # fmt: skip
    return callback, verifier


def test_email_collisions_between_apple_and_google():  # AC 7
    client, _ = _apple_app(**GOOGLE)
    with client:
        callback, verifier = _google_sign_in(client, "ann@example.com")
        google = _exchange(client, "la-carte-ios", "lacarte://oauth", callback, verifier).json()
        before = _counts(client)
        response = _sign_in(client)  # Apple, same email
        assert response.status_code == 400
        assert response.json() == {"error": "access_denied", "error_description": "use_google"}
        assert _counts(client) == before
        me = client.get("/me", headers=bearer(google["access_token"])).json()
        assert (me["email"], me["provider"]) == ("ann@example.com", "google")

        assert (
            _sign_in(client, _identity_token(sub="a2", email="bob@example.com")).status_code == 200
        )
        callback, _ = _google_sign_in(client, "bob@example.com")
        location = callback.headers["location"]
        assert location.startswith("lacarte://oauth?")
        query = _query(location)
        assert (query["error"], query["error_description"]) == ("access_denied", "use_apple")


def test_the_owner_claims_the_migrated_deck_with_apple():  # AC 8
    client, _ = _apple_app(owner_email=OWNER)
    with client:
        with Session(client.app.state.engine) as session:
            owner_id = session.exec(select(User.id).where(User.email == OWNER)).one()
            deck.add_notes(session, owner_id, [NoteCreate(
                type="basic", fields={"front": "chien", "back": "dog"})])  # fmt: skip
        tokens = _sign_in(client, _identity_token(email=OWNER)).json()
        assert _identity(client).user_id == owner_id
        notes = client.get("/notes", headers=bearer(tokens["access_token"])).json()
        assert [note["fields"]["front"] for note in notes] == ["chien"]


def test_sign_up_mode_applies_to_apple():  # AC 9
    client, _ = _apple_app(signup="allowlist", allowed_emails="listed@example.com")
    with client:
        before = _counts(client)
        response = _sign_in(client)
        assert response.json() == {"error": "access_denied", "error_description": "not_allowed"}
        assert _counts(client) == before
        assert _sign_in(client, _identity_token(email="listed@example.com")).status_code == 200
    client, _ = _apple_app()  # `open`, the default
    with client:
        assert _sign_in(client).status_code == 200


# --- AC 10: revocation on deletion --------------------------------------------------------------


@pytest.mark.parametrize("revoke", [200, 500, httpx.ReadTimeout, httpx.ConnectError])
def test_deleting_an_apple_account_revokes_it(revoke, caplog):  # AC 10
    client, fake = _apple_app()
    fake.revoke = revoke
    with client:
        tokens = _sign_in(client).json()
        user_id = _identity(client).user_id
        with Session(client.app.state.engine) as session:
            deck.add_notes(session, user_id, [NoteCreate(
                type="basic", fields={"front": "chat", "back": "cat"})])  # fmt: skip
        response = client.delete("/me", headers=bearer(tokens["access_token"]))
        assert response.status_code == 204
        revoked = fake.form("/auth/revoke")
        assert revoked["token"] == "apple-refresh-1"
        assert revoked["token_type_hint"] == "refresh_token"
        assert revoked["client_id"] == BUNDLE
        _verify_client_secret(revoked["client_secret"], int(time.time()))
        assert _counts(client) == {"user": 0, "identity": 0, "apitoken": 0, "authcode": 0}
        assert client.get("/me", headers=bearer(tokens["access_token"])).status_code == 401
    if revoke != 200:
        assert "apple revoke failed" in caplog.text


def test_deleting_a_google_or_pat_account_calls_no_one():  # AC 10
    client, fake = _apple_app(**GOOGLE)
    with client:
        callback, verifier = _google_sign_in(client, "ann@example.com")
        google = _exchange(client, "la-carte-ios", "lacarte://oauth", callback, verifier).json()
        assert client.delete("/me", headers=bearer(google["access_token"])).status_code == 204
        assert fake.paths() == []


# --- AC 11: configuration and logs --------------------------------------------------------------


def test_unknown_client_and_unconfigured_apple():  # AC 11
    client, _ = _apple_app()
    with client:
        response = _sign_in(client, client_id="claude")
        assert (response.status_code, response.json()["error"]) == (400, "invalid_client")
    with _app() as client:
        response = _sign_in(client)
        assert (response.status_code, response.json()["error"]) == (400, "temporarily_unavailable")
        assert client.get("/health").status_code == 200


def test_apple_configurations_that_must_not_start():  # AC 11
    from la_carte_api.app import create_app
    from la_carte_api.config import Settings

    def start(**settings):
        create_app(Settings(database_url="sqlite://", _env_file=None, **settings))

    for missing, variable in (
        ("apple_team_id", "LA_CARTE_APPLE_TEAM_ID"),
        ("apple_key_id", "LA_CARTE_APPLE_KEY_ID"),
        ("apple_private_key_b64", "LA_CARTE_APPLE_PRIVATE_KEY_B64"),
        ("apple_bundle_id", "LA_CARTE_APPLE_BUNDLE_ID"),
    ):
        with pytest.raises(RuntimeError, match=variable) as error:
            start(**(APPLE_SETTINGS | {missing: ""}))
        assert OUR_KEY_B64 not in str(error.value)
    rsa_pem = APPLE_KEY.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )  # fmt: skip
    p384 = ec.generate_private_key(ec.SECP384R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )  # fmt: skip
    for bad in (base64.b64encode(rsa_pem), base64.b64encode(p384), b"bm90IGEga2V5"):
        with pytest.raises(RuntimeError, match="LA_CARTE_APPLE_PRIVATE_KEY_B64") as error:
            start(**(APPLE_SETTINGS | {"apple_private_key_b64": bad.decode()}))
        assert bad.decode() not in str(error.value)
    start(**APPLE_SETTINGS)
    start()  # none set: off


def test_no_log_line_holds_a_secret(caplog):  # AC 11
    caplog.set_level(logging.DEBUG)
    client, fake = _apple_app()
    secrets_ = [RAW_NONCE, hashlib.sha256(RAW_NONCE.encode()).hexdigest(), "code-apple-001",
                "apple-refresh", "ann@example.com", "Ann@Example.com", OUR_KEY_B64]  # fmt: skip
    with client:
        tokens = _sign_in(client).json()
        secrets_ += [tokens["access_token"], tokens["refresh_token"]]
        token = _identity_token(nonce="wrong")
        secrets_.append(token)
        _sign_in(client, token)
        fake.token_status = 400
        _sign_in(client)
        fake.token_status, fake.revoke = 200, 500
        client.delete("/me", headers=bearer(tokens["access_token"]))
    assert "apple revoke failed: 500" in caplog.text
    for secret in secrets_:
        assert secret not in caplog.text


# --- AC 12: Google keeps no grant ---------------------------------------------------------------


@pytest.mark.parametrize("revoke", ["ok", "500", "down"])
def test_google_sign_in_revokes_its_access_token_once(revoke):  # AC 12
    with _app(**GOOGLE) as client:
        google = FakeGoogle()

        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/revoke" and revoke == "down":
                google.requests.append(request)
                raise httpx.ConnectError("down", request=request)
            response = google(request)
            return (
                httpx.Response(500)
                if request.url.path == "/revoke" and revoke == "500"
                else response
            )

        client.app.state.oauth.identity.transport = httpx.MockTransport(handler)
        response, verifier = _authorize(client, "la-carte-ios", "lacarte://oauth")
        query = _query(response.headers["location"])
        google.claims = {"nonce": query["nonce"]}
        callback = client.get("/oauth/callback", params={"code": "g", "state": query["state"]},
                              follow_redirects=False)  # fmt: skip
        tokens = _exchange(client, "la-carte-ios", "lacarte://oauth", callback, verifier)
        assert tokens.status_code == 200, tokens.text
        revokes = [r for r in google.requests if r.url == "https://oauth2.googleapis.com/revoke"]
        assert len(revokes) == 1
        assert parse_qs(revokes[0].content.decode()) == {"token": ["ya29.google-access"]}
        with Session(client.app.state.engine) as session:
            assert all(row.provider_token is None for row in session.exec(select(Identity)))
