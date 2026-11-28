"""Spec 030b: la-carte as an OAuth 2.1 authorization server, Google sign-in, `POST /me/tokens`
(AC numbers in comments). The fake identity provider or an injected `httpx` transport: no test
calls Google."""

import base64
import json
import logging
import secrets
from datetime import timedelta
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from conftest import add_user, bearer, token_for
from fastapi.testclient import TestClient
from mcp.server.auth.provider import TokenError
from pydantic import ValidationError
from sqlalchemy import inspect, text
from sqlmodel import Session, select

from la_carte_api import deck
from la_carte_api.app import create_app
from la_carte_api.config import Settings
from la_carte_api.identity import GoogleProvider, IdentityError, pkce_challenge
from la_carte_api.models import (
    ApiToken,
    AuthCode,
    AuthRequest,
    Identity,
    NoteCreate,
    TokenKind,
    TokenScope,
    User,
    utcnow,
)

PUBLIC = "http://127.0.0.1:8000"
AGENT_REDIRECT = "http://127.0.0.1:33418/callback"
MCP_HEADERS = {"Accept": "application/json, text/event-stream"}
OWNER = "owner@example.com"


def _app(**settings) -> TestClient:
    options = {"public_url": PUBLIC, "identity_provider": "fake"} | settings
    return TestClient(create_app(Settings(database_url="sqlite://", _env_file=None, **options)))


def _path(url: str) -> str:
    """A redirect to this server, as a path the test client can follow."""
    assert url.startswith(PUBLIC), url
    return url.removeprefix(PUBLIC)


def _query(url: str) -> dict[str, str]:
    return {key: values[0] for key, values in parse_qs(urlparse(url).query).items()}


def _register(client: TestClient, name: str = "Claude", redirect: str = AGENT_REDIRECT) -> str:
    response = client.post("/register", json={
        "client_name": name, "redirect_uris": [redirect], "token_endpoint_auth_method": "none",
        "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
    })  # fmt: skip
    assert response.status_code == 201, response.text
    return response.json()["client_id"]


def _authorize(client: TestClient, client_id: str, redirect: str, **extra) -> tuple:
    """`GET /authorize` with a fresh PKCE pair → (response, verifier)."""
    verifier = secrets.token_urlsafe(48)
    params = {
        "response_type": "code", "client_id": client_id, "redirect_uri": redirect,
        "code_challenge": pkce_challenge(verifier), "code_challenge_method": "S256",
        "state": "client-state", "scope": "deck", "resource": f"{PUBLIC}/mcp",
    } | extra  # fmt: skip
    return client.get("/authorize", params=params, follow_redirects=False), verifier


def _sign_in(
    client: TestClient,
    client_id: str,
    redirect: str = AGENT_REDIRECT,
    email: str = "a@example.com",
    authorize_redirect: str | None = None,
) -> tuple[httpx.Response, str]:
    """Runs the browser part (consent for agents) up to the redirect back to the client, signing
    `email` in with the fake provider → (the callback's response, the PKCE verifier)."""
    response, verifier = _authorize(client, client_id, authorize_redirect or redirect)
    assert response.status_code == 302, response.text
    location = response.headers["location"]
    if "/oauth/consent" in location:
        request_id = _query(location)["request"]
        assert client.cookies.get("lc_auth") == request_id
        assert client.get(_path(location)).status_code == 200
        response = client.post("/oauth/consent", data={"request": request_id},
                               follow_redirects=False)  # fmt: skip
        assert response.status_code == 303
        location = response.headers["location"]
    fake = client.get(_path(location), follow_redirects=False)  # /oauth/fake/authorize
    state = _query(fake.headers["location"])["state"]
    callback = client.get("/oauth/callback", params={"code": email, "state": state},
                          follow_redirects=False)  # fmt: skip
    return callback, verifier


def _token(client: TestClient, **form) -> httpx.Response:
    return client.post("/token", data=form)


def _exchange(client, client_id, redirect, callback, verifier, **extra) -> httpx.Response:
    code = _query(callback.headers["location"])["code"]
    return _token(client, grant_type="authorization_code", code=code, redirect_uri=redirect,
                  client_id=client_id, code_verifier=verifier, **extra)  # fmt: skip


def _tokens(client, client_id=None, redirect=AGENT_REDIRECT, email="a@example.com") -> dict:
    client_id = client_id or _register(client)
    callback, verifier = _sign_in(client, client_id, redirect, email)
    response = _exchange(client, client_id, redirect, callback, verifier)
    assert response.status_code == 200, response.text
    return response.json() | {"client_id": client_id}


def _ios_tokens(client, email="a@example.com") -> dict:
    return _tokens(client, "la-carte-ios", "lacarte://oauth", email)


def _mcp(client, token, method="tools/list", params=None) -> httpx.Response:
    body = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}
    return client.post("/mcp", json=body, headers=MCP_HEADERS | bearer(token))


def _counts(client) -> dict[str, int]:
    with Session(client.app.state.engine) as session:
        return {
            table.__tablename__: len(session.exec(select(table)).all())
            for table in (User, Identity, ApiToken, AuthCode)
        }


def _later(client, minutes: float) -> None:
    """Moves the OAuth server's clock forward."""
    start = utcnow()
    client.app.state.oauth.clock = lambda: start + timedelta(minutes=minutes)


# --- AC 1-3: discovery and registration ---------------------------------------------------------


def test_protected_resource_metadata_and_the_401_challenge():  # AC 1
    with _app() as client:
        for path in ("/.well-known/oauth-protected-resource/mcp",
                     "/.well-known/oauth-protected-resource"):  # fmt: skip
            metadata = client.get(path).json()
            assert metadata["resource"] == f"{PUBLIC}/mcp"
            assert metadata["authorization_servers"] == [PUBLIC]
            assert metadata["scopes_supported"] == ["deck"]
        response = client.post("/mcp", json={}, headers=MCP_HEADERS)
        assert response.status_code == 401
        challenge = response.headers["www-authenticate"]
        assert f'resource_metadata="{PUBLIC}/.well-known/oauth-protected-resource/mcp"' in challenge
        assert challenge.endswith('scope="deck"')


def test_authorization_server_metadata():  # AC 2
    with _app() as client:
        metadata = client.get("/.well-known/oauth-authorization-server").json()
        assert metadata["issuer"] == PUBLIC
        for name in ("authorization", "token", "registration", "revocation"):
            assert metadata[f"{name}_endpoint"].startswith(PUBLIC + "/")
        assert "none" in metadata["token_endpoint_auth_methods_supported"]
        assert metadata["code_challenge_methods_supported"] == ["S256"]
        assert metadata["authorization_response_iss_parameter_supported"] is True


def test_dynamic_client_registration():  # AC 3
    with _app() as client:
        assert _register(client)
        assert _register(client, redirect="https://claude.ai/api/mcp/auth_callback")
        for redirect in ("http://evil.example/cb", "lacarte://oauth"):
            response = client.post("/register", json={
                "redirect_uris": [redirect], "token_endpoint_auth_method": "none",
            })  # fmt: skip
            assert response.status_code == 400, redirect
            assert response.json()["error"] == "invalid_redirect_uri"


def test_registration_limits():  # security review
    with _app() as client:
        for metadata in (
            {"client_name": "x" * 101, "redirect_uris": [AGENT_REDIRECT]},
            {"redirect_uris": [f"https://a.example/{i}" for i in range(11)]},
        ):
            response = client.post("/register", json=metadata | {
                "token_endpoint_auth_method": "none"})  # fmt: skip
            assert response.status_code == 400
            assert response.json()["error"] == "invalid_client_metadata"
        assert _register(client, name="x" * 100)


def test_authorize_errors_carry_the_issuer():  # RFC 9207, security review
    with _app() as client:
        response, _ = _authorize(client, _register(client), AGENT_REDIRECT, scope="admin")
        assert response.headers["location"].startswith(AGENT_REDIRECT)
        query = _query(response.headers["location"])
        assert query["error"] == "invalid_scope" and query["iss"] == PUBLIC
        assert query["state"] == "client-state"


# --- AC 4-6: the browser flows ------------------------------------------------------------------


def test_full_agent_flow():  # AC 4
    with _app() as client:
        client_id = _register(client, name="<b>Claude</b>")
        response, _ = _authorize(client, client_id, AGENT_REDIRECT)
        cookie = response.headers["set-cookie"]
        assert cookie.startswith("lc_auth=") and "Max-Age=600" in cookie
        assert "HttpOnly" in cookie and "Path=/oauth" in cookie and "SameSite=lax" in cookie
        assert "Secure" not in cookie  # loopback only; any other public URL gets Secure
        consent = client.get(_path(response.headers["location"]))
        assert "&lt;b&gt;Claude&lt;/b&gt;" in consent.text and "<b>Claude" not in consent.text
        assert "you'll return to <strong>127.0.0.1</strong>" in consent.text
        assert 'id="continue"' in consent.text
        assert consent.headers["content-security-policy"] == "frame-ancestors 'none'"

        other_port = "http://127.0.0.1:50123/callback"  # loopback: any port (RFC 8252)
        callback, verifier = _sign_in(client, client_id, other_port)
        location = callback.headers["location"]
        assert location.startswith(other_port + "?")
        query = _query(location)
        assert query["code"].startswith("lc_ac_")
        assert query["state"] == "client-state" and query["iss"] == PUBLIC
        assert "lc_auth=" in callback.headers["set-cookie"]  # cleared

        tokens = _exchange(client, client_id, other_port, callback, verifier,
                           resource=f"{PUBLIC}/mcp").json()  # fmt: skip
        assert tokens["access_token"].startswith("lc_at_")
        assert tokens["refresh_token"].startswith("lc_rt_")
        assert (tokens["token_type"], tokens["expires_in"], tokens["scope"]) == (
            "Bearer",
            3600,
            "deck",
        )
        engine = client.app.state.engine
        with Session(engine) as session:
            user = session.exec(select(User).where(User.email == "a@example.com")).one()
            deck.add_notes(session, user.id, [NoteCreate(
                type="basic", fields={"front": "chat", "back": "cat"})])  # fmt: skip
        listed = _mcp(client, tokens["access_token"])
        assert "find_notes" in {tool["name"] for tool in listed.json()["result"]["tools"]}
        found = _mcp(client, tokens["access_token"], "tools/call",
                     {"name": "find_notes", "arguments": {"query": "chat"}})  # fmt: skip
        assert '"chat"' in json.dumps(found.json()["result"])


def test_ios_flow_skips_consent():  # AC 5
    with _app() as client:
        response, _ = _authorize(client, "la-carte-ios", "lacarte://oauth")
        assert response.headers["location"].startswith(f"{PUBLIC}/oauth/fake/authorize?")
        assert "lc_auth" not in client.cookies
        callback, verifier = _sign_in(client, "la-carte-ios", "lacarte://oauth")
        location = callback.headers["location"]
        assert location.startswith("lacarte://oauth?")
        assert {"code", "state", "iss"} <= set(_query(location))
        tokens = _exchange(client, "la-carte-ios", "lacarte://oauth", callback, verifier)
        assert tokens.status_code == 200 and "access_token" in tokens.json()  # no client_secret

        for redirect in ("lacarte://other", "https://evil.example/cb"):
            response, _ = _authorize(client, "la-carte-ios", redirect)
            assert response.status_code == 400 and "location" not in response.headers


def test_consent_needs_the_browser_that_started_it():  # AC 6
    with _app() as client:
        response, _ = _authorize(client, _register(client), AGENT_REDIRECT)
        request_id = _query(response.headers["location"])["request"]
        for cookie in (None, "another-request"):
            client.cookies.clear()
            if cookie:
                client.cookies.set("lc_auth", cookie, path="/oauth")
            posted = client.post("/oauth/consent", data={"request": request_id},
                                 follow_redirects=False)  # fmt: skip
            assert posted.status_code == 400 and "location" not in posted.headers
            assert "This sign-in expired" in posted.text


# --- AC 7-9: tokens -----------------------------------------------------------------------------


def test_codes_are_checked():  # AC 7
    with _app() as client:
        client_id = _register(client)

        def code_and_verifier():
            return _sign_in(client, client_id)

        callback, verifier = code_and_verifier()
        wrong = _exchange(client, client_id, AGENT_REDIRECT, callback, "x" * 50)
        assert wrong.json()["error"] == "invalid_grant"
        reused = _exchange(client, client_id, AGENT_REDIRECT, callback, verifier)
        assert reused.json()["error"] == "invalid_grant"  # the wrong try spent it

        callback, verifier = code_and_verifier()
        assert _exchange(client, client_id, AGENT_REDIRECT, callback, verifier).status_code == 200
        again = _exchange(client, client_id, AGENT_REDIRECT, callback, verifier)
        assert again.json()["error"] == "invalid_grant"

        callback, verifier = code_and_verifier()
        _later(client, 5.1)
        old = _exchange(client, client_id, AGENT_REDIRECT, callback, verifier)
        assert old.json()["error"] == "invalid_grant"
        _later(client, 0)

        callback, verifier = code_and_verifier()
        other = _register(client, name="Other")
        stolen = _exchange(client, other, AGENT_REDIRECT, callback, verifier)
        assert stolen.json()["error"] == "invalid_grant"

        callback, verifier = code_and_verifier()
        target = _exchange(client, client_id, AGENT_REDIRECT, callback, verifier,
                           resource=PUBLIC)  # fmt: skip
        assert (target.status_code, target.json()["error"]) == (400, "invalid_target")

        response, _ = _authorize(client, client_id, AGENT_REDIRECT,
                                 resource="https://other.example/mcp")  # fmt: skip
        assert _query(response.headers["location"])["error"] == "invalid_target"
        with Session(client.app.state.engine) as session:  # only the one good exchange
            assert len(session.exec(select(ApiToken)).all()) == 2


def test_refresh_rotation_and_reuse():  # AC 8
    with _app() as client:
        first = _tokens(client)
        refresh = {"grant_type": "refresh_token", "client_id": first["client_id"]}
        second = _token(client, **refresh, refresh_token=first["refresh_token"]).json()
        assert second["refresh_token"] != first["refresh_token"]
        assert _mcp(client, second["access_token"]).status_code == 200
        assert _token(client, **refresh, refresh_token=second["refresh_token"],
                      scope="stats").json()["error"] == "invalid_scope"  # fmt: skip

        replay = _token(client, **refresh, refresh_token=first["refresh_token"])
        assert replay.json()["error"] == "invalid_grant"
        assert _mcp(client, second["access_token"]).status_code == 401  # the family is dead
        dead = _token(client, **refresh, refresh_token=second["refresh_token"])
        assert dead.json()["error"] == "invalid_grant"

        fresh = _tokens(client, first["client_id"])
        assert _mcp(client, fresh["access_token"]).status_code == 200
        assert client.get("/notes", headers=bearer(fresh["access_token"])).status_code == 200
        _later(client, 61)
        assert _mcp(client, fresh["access_token"]).status_code == 401  # expired by `now`


def test_revoking_a_refresh_token_revokes_its_family():  # AC 9
    with _app() as client:
        tokens = _tokens(client)
        unknown = client.post("/revoke", data={"token": "lc_rt_unknown",
                                               "client_id": tokens["client_id"]})  # fmt: skip
        assert unknown.status_code == 200
        revoke = {"token": tokens["refresh_token"], "client_id": tokens["client_id"]}
        assert client.post("/revoke", data=revoke).status_code == 200
        assert _mcp(client, tokens["access_token"]).status_code == 401

        other = _tokens(client, tokens["client_id"])
        client.post("/revoke", data={"token": other["access_token"],
                                     "client_id": tokens["client_id"]})  # fmt: skip
        assert _mcp(client, other["access_token"]).status_code == 401
        refreshed = _token(client, grant_type="refresh_token", client_id=tokens["client_id"],
                           refresh_token=other["refresh_token"])  # fmt: skip
        assert refreshed.status_code == 200  # an access token goes alone


# --- AC 10-12, 14: accounts ---------------------------------------------------------------------


def _refused(callback: httpx.Response) -> str:
    query = _query(callback.headers["location"])
    assert query["error"] == "access_denied" and query["state"] == "client-state", query
    assert query["iss"] == PUBLIC
    return query["error_description"]


def test_allowlist_mode():  # AC 10
    allowed = "listed@example.com, Friend@Example.com"
    with _app(signup="allowlist", allowed_emails=allowed, owner_email=OWNER) as client:
        client_id = _register(client)
        before = _counts(client)
        callback, _ = _sign_in(client, client_id, email="stranger@example.com")
        assert _refused(callback) == "not_allowed"
        assert _counts(client) == before
        for email in ("friend@example.com", OWNER):
            callback, _ = _sign_in(client, client_id, email=email)
            assert "code" in _query(callback.headers["location"]), email
    with _app(signup="allowlist", owner_email=OWNER) as client:  # empty list: the owner only
        client_id = _register(client)
        assert _refused(_sign_in(client, client_id, email="listed@example.com")[0]) == "not_allowed"
        assert "code" in _query(_sign_in(client, client_id, email=OWNER)[0].headers["location"])
    for settings in ({}, {"signup": "open", "allowed_emails": "listed@example.com"}):
        with _app(**settings) as client:
            tokens = _tokens(client, email="anyone@example.com")
            assert client.get("/me", headers=bearer(tokens["access_token"])).json()["email"] == (
                "anyone@example.com"
            )
    with pytest.raises(ValidationError):
        Settings(_env_file=None, signup="closed")


def test_an_allowlist_refuses_an_existing_account_no_longer_listed():  # decision 6
    with _app(signup="allowlist", allowed_emails="a@example.com") as client:
        tokens = _tokens(client)
        oauth = client.app.state.oauth
        oauth.settings = oauth.settings.model_copy(update={"allowed_emails": "b@example.com"})
        callback, _ = _sign_in(client, tokens["client_id"])
        assert _refused(callback) == "not_allowed"
        me = client.get("/me", headers=bearer(tokens["access_token"]))
        assert me.status_code == 200  # tokens issued before keep working until revoked


def test_no_page_or_reply_mentions_invites():  # AC 10
    with _app(signup="allowlist") as client:
        client_id = _register(client)
        response, _ = _authorize(client, client_id, AGENT_REDIRECT)
        pages = [client.get(_path(response.headers["location"]))]
        callback, _ = _sign_in(client, client_id)
        pages += [callback, client.get("/oauth/callback", params={"state": "nope"})]
        for page in pages:
            text_ = (page.text + page.headers.get("location", "")).lower()
            assert "invite" not in text_ and "list" not in text_.replace("allowlist", "")


def test_the_owner_claims_the_migrated_deck():  # AC 11
    with _app(owner_email=OWNER) as client:
        engine = client.app.state.engine
        with Session(engine) as session:
            owner_id = session.exec(select(User.id).where(User.email == OWNER)).one()
            deck.add_notes(session, owner_id, [NoteCreate(
                type="basic", fields={"front": "chien", "back": "dog"})])  # fmt: skip
        client_id = _register(client)
        tokens = _tokens(client, client_id, email=OWNER)
        notes = client.get("/notes", headers=bearer(tokens["access_token"])).json()
        assert [note["fields"]["front"] for note in notes] == ["chien"]
        assert client.get("/me", headers=bearer(tokens["access_token"])).json()["provider"] == (
            "fake"
        )

        with Session(engine) as session:  # another `sub` with the owner's email
            session.add(Identity(provider="fake", subject="fake-other", user_id=owner_id))
            identity = session.get(Identity, ("fake", f"fake-{OWNER}"))
            identity.subject = "fake-original"
            session.add(identity)
            session.commit()
        before = _counts(client)
        assert _refused(_sign_in(client, client_id, email=OWNER)[0]) == "email_in_use"
        assert _counts(client) == before

        with Session(engine) as session:  # the known `sub` comes back with a new email
            session.add(Identity(provider="fake", subject="fake-new@example.com",
                                 user_id=owner_id))  # fmt: skip
            session.commit()
        _sign_in(client, client_id, email="new@example.com")
        with Session(engine) as session:
            assert session.get(User, owner_id).email == "new@example.com"


def test_another_provider_with_the_same_email_is_told_which_to_use(session, engine):  # decision 6
    from la_carte_api.identity import VerifiedIdentity
    from la_carte_api.oauth import SignInRefused, resolve_account

    settings = Settings(_env_file=None)
    google = resolve_account(session, VerifiedIdentity("google", "g1", "x@example.com"), settings)
    with pytest.raises(SignInRefused) as refused:
        resolve_account(session, VerifiedIdentity("apple", "a1", "x@example.com"), settings)
    assert refused.value.reason == "use_google"
    resolve_account(session, VerifiedIdentity("google", "g2", "y@example.com"), settings)
    with pytest.raises(SignInRefused):  # a known identity keeps its email on a collision
        resolve_account(session, VerifiedIdentity("apple", "a2", "y@example.com"), settings)
    assert (
        resolve_account(session, VerifiedIdentity("google", "g1", "y@example.com"), settings)
        == google
    )
    assert session.get(User, google).email == "x@example.com"


def test_an_unverified_email_is_refused():  # AC 12
    with _app() as client:
        client_id = _register(client)
        before = _counts(client)
        callback, _ = _sign_in(client, client_id, email="unverified@example.com")
        assert _refused(callback) == "unverified_email"
        assert _counts(client) == before


def test_a_cancelled_sign_in_goes_back_to_the_client():  # decision 6
    with _app() as client:
        response, _ = _authorize(client, "la-carte-ios", "lacarte://oauth")
        state = _query(response.headers["location"])["state"]
        callback = client.get("/oauth/callback", params={"error": "access_denied",
                                                         "state": state},
                              follow_redirects=False)  # fmt: skip
        assert callback.headers["location"].startswith("lacarte://oauth?")
        assert _refused(callback) == "cancelled"


def test_an_unknown_or_expired_state_gets_a_page():  # AC 14
    with _app() as client:
        unknown = client.get("/oauth/callback", params={"code": "a@example.com", "state": "x"})
        response, _ = _authorize(client, "la-carte-ios", "lacarte://oauth")
        state = _query(response.headers["location"])["state"]
        _later(client, 10.1)
        late = client.get("/oauth/callback", params={"code": "a@example.com", "state": state},
                          follow_redirects=False)  # fmt: skip
        for page in (unknown, late):
            assert page.status_code == 400 and "location" not in page.headers
            assert page.headers["content-type"].startswith("text/html")
            assert "This sign-in expired. Start again from your app." in page.text
        _later(client, 0)
        client.cookies.set("lc_auth", "another-request", path="/oauth")  # not this request's
        agent, _ = _authorize(client, _register(client), AGENT_REDIRECT)
        agent_state = _query(agent.headers["location"])["request"]
        client.cookies.clear()
        client.cookies.set("lc_auth", "another-request", path="/oauth")
        assert client.get("/oauth/callback", params={"code": "a@example.com",
                                                     "state": agent_state},
                          follow_redirects=False).status_code == 400  # fmt: skip
        # The app skips consent: a stale cookie from an abandoned agent sign-in doesn't matter.
        ios = client.get("/oauth/callback", params={"code": "a@example.com", "state": state},
                         follow_redirects=False)  # fmt: skip
        assert ios.headers["location"].startswith("lacarte://oauth?code=")


def test_an_agent_callback_needs_the_consenting_browser():  # security review; amends decision 6
    """Confused deputy: an attacker consents to their own request, then sends the provider URL
    to a victim. The victim's browser has no `lc_auth` cookie for it: no code is minted."""
    with _app() as client:
        response, _ = _authorize(client, _register(client), AGENT_REDIRECT)
        request_id = _query(response.headers["location"])["request"]
        posted = client.post("/oauth/consent", data={"request": request_id},
                             follow_redirects=False)  # fmt: skip
        state = _query(client.get(_path(posted.headers["location"]),
                                  follow_redirects=False).headers["location"])["state"]  # fmt: skip
        client.cookies.clear()  # the victim's browser
        victim = client.get("/oauth/callback", params={"code": "victim@example.com",
                                                       "state": state},
                            follow_redirects=False)  # fmt: skip
        assert victim.status_code == 400 and "location" not in victim.headers
        assert "This sign-in expired" in victim.text
        assert _counts(client)["authcode"] == 0 and _counts(client)["user"] == 0


def test_deleting_the_account_deletes_its_pending_codes():
    with _app() as client:
        callback, _ = _sign_in(client, "la-carte-ios", "lacarte://oauth")
        with Session(client.app.state.engine) as session:
            user = session.exec(select(AuthCode.user_id)).one()
        token = token_for(client.app.state.engine, user)
        assert client.delete("/me", headers=bearer(token)).status_code == 204
        assert _counts(client)["authcode"] == 0


# --- AC 13: Google ------------------------------------------------------------------------------

GOOGLE_ID = "google-client.apps.example"


def _id_token(**claims) -> str:
    payload = {"iss": "https://accounts.google.com", "aud": GOOGLE_ID, "exp": 2_000_000_000,
               "nonce": "n", "sub": "g-123", "email": "Ann@Example.com",
               "email_verified": True} | claims  # fmt: skip
    part = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    return f"eyJhbGciOiJSUzI1NiJ9.{part}.signature"


class FakeGoogle:
    """Google's token and revocation endpoints, as an `httpx` transport."""

    def __init__(self, **claims) -> None:
        self.claims = claims
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if request.url.path == "/token":
            return httpx.Response(200, json={
                "access_token": "ya29.google-access", "id_token": _id_token(**self.claims),
                "expires_in": 3599, "token_type": "Bearer", "scope": "openid email",
            })  # fmt: skip
        return httpx.Response(200)

    def form(self, index: int) -> dict[str, str]:
        return {k: v[0] for k, v in parse_qs(self.requests[index].content.decode()).items()}


def _google(fake: FakeGoogle) -> GoogleProvider:
    return GoogleProvider(GOOGLE_ID, "secret", PUBLIC, transport=httpx.MockTransport(fake))


def test_google_authorization_url():  # AC 13
    url = _google(FakeGoogle()).authorization_url(state="s", nonce="n", code_challenge="c")
    assert url.startswith("https://accounts.google.com/o/oauth2/v2/auth?")
    query = _query(url)
    assert query["scope"] == "openid email" and query["prompt"] == "select_account"
    assert (query["code_challenge"], query["code_challenge_method"]) == ("c", "S256")
    assert (query["state"], query["nonce"], query["client_id"]) == ("s", "n", GOOGLE_ID)
    assert query["redirect_uri"] == f"{PUBLIC}/oauth/callback"


@pytest.mark.anyio
@pytest.mark.parametrize("anyio_backend", ["asyncio"])
async def test_google_verify(anyio_backend):  # AC 13
    fake = FakeGoogle()
    who = await _google(fake).verify(code="google-code", code_verifier="v", nonce="n")
    assert (who.provider, who.subject, who.email) == ("google", "g-123", "ann@example.com")
    exchange = fake.form(0)
    assert exchange["code_verifier"] == "v" and exchange["client_secret"] == "secret"
    assert exchange["redirect_uri"] == f"{PUBLIC}/oauth/callback"
    assert fake.requests[1].url == "https://oauth2.googleapis.com/revoke"
    assert fake.form(1) == {"token": "ya29.google-access"}

    for claims, reason in (
        ({"iss": "https://evil.example"}, "sign_in_failed"),
        ({"aud": "someone-else"}, "sign_in_failed"),
        ({"exp": 1_000}, "sign_in_failed"),
        ({"nonce": "replayed"}, "sign_in_failed"),
        ({"email_verified": False}, "unverified_email"),
        ({"email_verified": "true"}, "unverified_email"),
    ):
        fake = FakeGoogle(**claims)
        with pytest.raises(IdentityError) as error:
            await _google(fake).verify(code="google-code", code_verifier="v", nonce="n")
        assert error.value.reason == reason, claims
        assert fake.requests[-1].url.path == "/revoke"  # revoked even when refused

    def failing(request):
        return httpx.Response(400, json={"error": "invalid_grant"})

    provider = GoogleProvider(GOOGLE_ID, "secret", PUBLIC, transport=httpx.MockTransport(failing))
    with pytest.raises(IdentityError):
        await provider.verify(code="bad", code_verifier="v", nonce="n")


def test_google_sign_in_keeps_no_google_token():  # AC 13
    settings = {"identity_provider": "google", "google_client_id": GOOGLE_ID,
                "google_client_secret": "secret"}  # fmt: skip
    with _app(**settings) as client:
        fake = FakeGoogle()
        identity = client.app.state.oauth.identity
        identity.transport = httpx.MockTransport(fake)
        response, verifier = _authorize(client, "la-carte-ios", "lacarte://oauth")
        query = _query(response.headers["location"])
        assert response.headers["location"].startswith("https://accounts.google.com/")
        fake.claims = {"nonce": query["nonce"]}
        callback = client.get("/oauth/callback", params={"code": "g", "state": query["state"]},
                              follow_redirects=False)  # fmt: skip
        tokens = _exchange(client, "la-carte-ios", "lacarte://oauth", callback, verifier).json()
        me = client.get("/me", headers=bearer(tokens["access_token"])).json()
        assert (me["email"], me["provider"]) == ("ann@example.com", "google")
        exchange = fake.form(0)
        assert exchange["code_verifier"] != verifier  # our own PKCE pair towards Google
        assert pkce_challenge(exchange["code_verifier"]) == query["code_challenge"]

        engine = client.app.state.engine
        with engine.connect() as connection:
            for table in inspect(engine).get_table_names():
                rows = connection.execute(text(f'SELECT * FROM "{table}"')).fetchall()
                assert "ya29" not in repr(rows) and "eyJ" not in repr(rows), table


# --- AC 15: personal access tokens from the app -------------------------------------------------


def test_the_app_creates_personal_access_tokens():  # AC 15
    with _app() as client:
        app_token = _ios_tokens(client)["access_token"]
        created = client.post("/me/tokens", headers=bearer(app_token),
                              json={"name": "  Scripts  ", "expires_in_days": 30})  # fmt: skip
        assert created.status_code == 201, created.text
        body = created.json()
        assert body["token"].startswith("lc_pat_") and body["name"] == "Scripts"
        assert body["scope"] == "deck" and body["last_used_at"] is None
        from datetime import datetime

        lifetime = datetime.fromisoformat(body["expires_at"]) - datetime.fromisoformat(
            body["created_at"]
        )
        assert lifetime == timedelta(days=30)
        listed = client.get("/me/tokens", headers=bearer(app_token)).json()
        assert [t["id"] for t in listed] == [body["id"]] and "token" not in listed[0]

        pat = body["token"]
        assert client.get("/notes", headers=bearer(pat)).status_code == 200
        assert _mcp(client, pat).status_code == 200

        stats = client.post("/me/tokens", headers=bearer(app_token),
                            json={"name": "Widget", "scope": "stats"}).json()  # fmt: skip
        assert stats["expires_at"] is None
        assert client.get("/stats", headers=bearer(stats["token"])).status_code == 200
        assert client.get("/notes", headers=bearer(stats["token"])).status_code == 403
        assert _mcp(client, stats["token"]).status_code == 403

        agent = _tokens(client)
        for token in (pat, agent["access_token"]):
            refused = client.post("/me/tokens", headers=bearer(token), json={"name": "x"})
            assert refused.status_code == 403
            assert refused.json() == {"detail": "Create access tokens from the la-carte app"}
        refresh = client.post("/me/tokens", headers=bearer(agent["refresh_token"]),
                              json={"name": "x"})  # fmt: skip
        assert refresh.status_code == 401  # a refresh token is no bearer token at all (030a)

        for body_ in ({"name": ""}, {"name": " "}, {"name": "x" * 61},
                      {"name": "x", "expires_in_days": 0}, {"name": "x", "expires_in_days": 366},
                      {"name": "x", "scope": "admin"}):  # fmt: skip
            assert client.post("/me/tokens", headers=bearer(app_token),
                               json=body_).status_code == 422, body_  # fmt: skip


def test_at_most_twenty_live_personal_tokens():  # decision 8
    with _app() as client:
        app_token = _ios_tokens(client)["access_token"]
        for index in range(18):  # + the two below = 20
            client.post("/me/tokens", headers=bearer(app_token), json={"name": f"t{index}"})
        engine = client.app.state.engine
        with Session(engine) as session:
            user = session.exec(select(User)).one()
            expired = token_for(engine, user.id)
            row = session.exec(select(ApiToken).where(ApiToken.kind == TokenKind.pat)).first()
            row.revoked_at = utcnow()  # a revoked one doesn't count
            session.add(row)
            session.commit()
        assert expired
        for name in ("t18", "t19"):
            assert client.post("/me/tokens", headers=bearer(app_token),
                               json={"name": name}).status_code == 201  # fmt: skip
        full = client.post("/me/tokens", headers=bearer(app_token), json={"name": "t20"})
        assert full.status_code == 422


# --- AC 16: configuration -----------------------------------------------------------------------


def test_configurations_that_must_not_start():  # AC 16
    def start(**settings):
        create_app(Settings(database_url="sqlite://", _env_file=None, **settings))

    with pytest.raises(RuntimeError, match="fake"):
        start(identity_provider="fake", public_url="https://example.com")
    with pytest.raises(RuntimeError, match="CLIENT_SECRET"):
        start(google_client_id=GOOGLE_ID, public_url="https://example.com")
    with pytest.raises(RuntimeError, match="https"):
        start(google_client_id=GOOGLE_ID, google_client_secret="s",
              public_url="http://example.com")  # fmt: skip
    start(identity_provider="fake")  # unset public URL: loopback
    start(google_client_id=GOOGLE_ID, google_client_secret="s", public_url="https://example.com")


def test_without_a_provider_sign_in_is_unavailable_and_pats_work():  # AC 16
    with _app(identity_provider="google") as client:
        response, _ = _authorize(client, "la-carte-ios", "lacarte://oauth")
        query = _query(response.headers["location"])
        assert response.headers["location"].startswith("lacarte://oauth?")
        assert query["error"] == "temporarily_unavailable"
        engine = client.app.state.engine
        pat = token_for(engine, add_user(engine, "a@example.com"), TokenScope.deck)
        assert client.get("/notes", headers=bearer(pat)).status_code == 200
        assert _mcp(client, pat).status_code == 200
        assert client.get("/oauth/fake/authorize").status_code in (401, 404, 405)


def test_the_consent_cookie_is_secure_on_a_public_url():  # decision 3
    settings = {
        "identity_provider": "google",
        "google_client_id": GOOGLE_ID,
        "google_client_secret": "secret",
        "public_url": "https://carte.example.com",
    }
    with _app(**settings) as client:
        response, _ = _authorize(client, _register(client), AGENT_REDIRECT,
                                 resource="https://carte.example.com/mcp")  # fmt: skip
        assert response.headers["location"].startswith("https://carte.example.com/oauth/consent")
        assert "Secure" in response.headers["set-cookie"]


# --- Security review ----------------------------------------------------------------------------


@pytest.mark.anyio
@pytest.mark.parametrize("anyio_backend", ["asyncio"])
async def test_concurrent_refreshes_count_as_reuse(anyio_backend):
    """Two requests that both loaded the same live refresh token: only the first rotates it;
    the second finds it spent (compare-and-set) and revokes the family."""
    with _app() as client:
        tokens = _tokens(client)
        oauth = client.app.state.oauth
        agent = await oauth.get_client(tokens["client_id"])
        loaded = await oauth.load_refresh_token(agent, tokens["refresh_token"])
        winner = await oauth.exchange_refresh_token(agent, loaded, ["deck"])
        with pytest.raises(TokenError) as error:
            await oauth.exchange_refresh_token(agent, loaded, ["deck"])
        assert error.value.error == "invalid_grant"
        assert _mcp(client, winner.access_token).status_code == 401  # the family is dead


def test_a_non_object_google_reply_refuses_the_sign_in():
    settings = {"identity_provider": "google", "google_client_id": GOOGLE_ID,
                "google_client_secret": "secret"}  # fmt: skip
    with _app(**settings) as client:
        reply = httpx.MockTransport(lambda request: httpx.Response(200, json=["not", "an object"]))
        client.app.state.oauth.identity.transport = reply
        response, _ = _authorize(client, "la-carte-ios", "lacarte://oauth")
        state = _query(response.headers["location"])["state"]
        callback = client.get("/oauth/callback", params={"code": "g", "state": state},
                              follow_redirects=False)  # fmt: skip
        assert _refused(callback) == "sign_in_failed"
        with Session(client.app.state.engine) as session:
            assert session.exec(select(AuthRequest)).all() == []
        assert _counts(client)["authcode"] == 0


def test_the_access_log_has_no_query_strings(caplog):
    with _app():  # installs the filter
        pass
    access = logging.getLogger("uvicorn.access")
    with caplog.at_level(logging.INFO, logger="uvicorn.access"):
        access.info('%s - "%s %s HTTP/%s" %d', "127.0.0.1:5000", "GET",
                    "/oauth/callback?code=a%40example.com&state=s", "1.1", 302)  # fmt: skip
        access.info('%s - "%s %s HTTP/%s" %d', "127.0.0.1:5000", "GET", "/notes", "1.1", 200)
    assert [r.getMessage() for r in caplog.records] == [
        '127.0.0.1:5000 - "GET /oauth/callback HTTP/1.1" 302',
        '127.0.0.1:5000 - "GET /notes HTTP/1.1" 200',
    ]
