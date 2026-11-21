import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session

from la_carte_api.app import create_app
from la_carte_api.config import Settings
from la_carte_api.db import make_engine


@pytest.fixture
def engine():
    return make_engine("sqlite://")


@pytest.fixture
def session(engine):
    with Session(engine) as session:
        yield session


@pytest.fixture
def client():
    with TestClient(create_app(Settings(database_url="sqlite://", _env_file=None))) as client:
        yield client
