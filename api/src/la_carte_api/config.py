from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Configuration, read from `LA_CARTE_*` environment variables (or `api/.env`)."""

    model_config = SettingsConfigDict(env_prefix="LA_CARTE_", env_file=".env")

    database_url: str = "sqlite:///./la-carte.db"
    # When set, every request (REST and MCP) must send `Authorization: Bearer <token>`.
    api_token: str | None = None
    host: str = "127.0.0.1"
    port: int = 8000
