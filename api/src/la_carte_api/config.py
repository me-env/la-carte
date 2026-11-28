from typing import Literal
from urllib.parse import urlparse

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

LOOPBACK = {"127.0.0.1", "localhost", "::1"}


class Settings(BaseSettings):
    """Configuration, read from `LA_CARTE_*` environment variables (or `api/.env`)."""

    model_config = SettingsConfigDict(env_prefix="LA_CARTE_", env_file=".env")

    database_url: str = "sqlite:///./la-carte.db"
    # The email of the owner's account (spec 030a): owns the deck of a pre-030 database, and reads
    # every user's feedback over MCP. Required when the database has pre-030 data or `api_token`.
    owner_email: str | None = None
    # Legacy static token: imported as the owner's personal access token `legacy` on the start
    # that creates the accounts tables only, then ignored (spec 030a). Every request needs
    # `Authorization: Bearer <a token of a user>`.
    api_token: str | None = None
    # The API's public base URL (e.g. https://carte.example.com): the OAuth issuer and MCP
    # resource (`<public_url>/mcp`), and where MCP serverInfo lists the icon (/icon.png).
    public_url: str | None = None
    host: str = "127.0.0.1"
    port: int = 8000
    # Sign-in (spec 030b). Google "Web application" client; neither set and not `fake`: the
    # server runs with personal access tokens only.
    google_client_id: str | None = None
    google_client_secret: str | None = None
    identity_provider: Literal["google", "fake"] = "google"  # `fake`: tests and e2e only
    fake_email: str = "e2e@example.com"  # who the fake provider signs in
    # `open`: any verified account gets a deck; `allowlist`: only `allowed_emails` + the owner.
    signup: Literal["open", "allowlist"] = "open"
    allowed_emails: str = ""  # comma-separated; read only in `allowlist` mode

    @field_validator("owner_email")
    @classmethod
    def _casefolded(cls, email: str | None) -> str | None:
        return (email or "").strip().casefold() or None

    @property
    def allowed(self) -> set[str]:
        """Who may create an account in `allowlist` mode: the listed emails and the owner."""
        listed = {email.strip().casefold() for email in self.allowed_emails.split(",")}
        return {email for email in listed | {self.owner_email} if email}

    @property
    def is_loopback(self) -> bool:
        """The server is reached on this machine only (tests, e2e, local dev)."""
        return urlparse(self.base_url).hostname in LOOPBACK

    @property
    def base_url(self) -> str:
        """`public_url`, else this server's local address."""
        return (self.public_url or f"http://{self.host}:{self.port}").rstrip("/")
