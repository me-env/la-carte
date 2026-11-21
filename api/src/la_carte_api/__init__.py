"""la-carte API: one flashcard deck, over REST (iOS app) and MCP (agents)."""


def main() -> None:
    import uvicorn

    from la_carte_api.config import Settings

    settings = Settings()
    uvicorn.run("la_carte_api.app:create_app", factory=True, host=settings.host, port=settings.port)
