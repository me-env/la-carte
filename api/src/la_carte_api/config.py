from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Configuration, read from `LA_CARTE_*` environment variables (or `api/.env`)."""

    model_config = SettingsConfigDict(env_prefix="LA_CARTE_", env_file=".env")

    database_url: str = "sqlite:///./la-carte.db"
    # When set, every request (REST and MCP) must send `Authorization: Bearer <token>`.
    api_token: str | None = None
    # The API's public base URL (e.g. https://carte.example.com). When set, the MCP serverInfo lists
    # the la-carte icon at <public_url>/icon.png so clients can show it.
    public_url: str | None = None
    host: str = "127.0.0.1"
    port: int = 8000
