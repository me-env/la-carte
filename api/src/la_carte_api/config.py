import re
from ipaddress import ip_address
from typing import Literal
from urllib.parse import urlparse, urlsplit

from pydantic import SecretStr, field_validator
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
    # The SQLCipher key of the whole database file (spec 032a): 64 hex characters. Required for a
    # database file on a production server (`public_url` set and not loopback); unset elsewhere =
    # plain SQLite. `db_key_new` rekeys the file at start (rotation). Never logged.
    db_key: SecretStr | None = None
    db_key_new: SecretStr | None = None
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
    # Sign in with Apple (spec 030e): all four or none. The key is the `.p8` file, base64 on one
    # line (secret, never logged); the bundle id is the `aud` of the app's identity tokens.
    apple_team_id: str = ""
    apple_key_id: str = ""
    apple_private_key_b64: SecretStr | None = None
    apple_bundle_id: str = ""

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

    @property
    def is_production(self) -> bool:
        """`public_url` is set and not a loopback address (set without a parseable host, e.g. no
        scheme, counts as production: the safe side)."""
        if not self.public_url:
            return False
        host = urlsplit(self.public_url).hostname
        if not host:
            return True
        if host == "localhost":
            return False
        try:
            return not ip_address(host).is_loopback
        except ValueError:  # a domain name
            return True

    def database_keys(self) -> tuple[str | None, str | None]:
        """(`db_key`, `db_key_new`), checked (spec 032a): each unset or 64 hex characters, and
        `db_key` set for a database file in production. Raises `RuntimeError` otherwise (the
        message never holds a key)."""
        key, new_key = (_secret(value) for value in (self.db_key, self.db_key_new))
        file_database = self.database_url != "sqlite://"
        if any(value and not HEX_KEY.fullmatch(value) for value in (key, new_key)) or (
            file_database and self.is_production and not key
        ):
            raise RuntimeError(DB_KEY_HELP)
        if new_key and not key:
            raise RuntimeError("LA_CARTE_DB_KEY_NEW is set: set LA_CARTE_DB_KEY to the current key")
        return key, new_key


HEX_KEY = re.compile(r"[0-9a-fA-F]{64}")
DB_KEY_HELP = "Set LA_CARTE_DB_KEY: 64 hex characters, e.g. openssl rand -hex 32"


def _secret(value: SecretStr | None) -> str | None:
    """The value, `None` when unset or empty (Docker Compose passes unset variables as "")."""
    return (value.get_secret_value().strip() if value else "") or None
