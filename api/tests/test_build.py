import re
import shutil

from fastapi.testclient import TestClient

from la_carte_api.app import create_app
from la_carte_api.build import PACKAGE_ROOT, source_hash
from la_carte_api.config import Settings


def test_health_reports_the_source_build():
    app = create_app(
        Settings(
            database_url="sqlite://",
            api_token="secret",
            owner_email="owner@example.com",
            _env_file=None,
        )
    )
    with TestClient(app) as client:
        body = client.get("/health").json()
    assert body == {"status": "ok", "build": source_hash()}
    assert re.fullmatch(r"[0-9a-f]{12}", body["build"])


def test_build_is_stable_for_the_same_tree(tmp_path):
    copy = tmp_path / "la_carte_api"
    shutil.copytree(PACKAGE_ROOT, copy, ignore=shutil.ignore_patterns("__pycache__"))
    assert source_hash(copy) == source_hash(PACKAGE_ROOT)


def test_build_changes_when_a_source_file_changes(tmp_path):
    copy = tmp_path / "la_carte_api"
    shutil.copytree(PACKAGE_ROOT, copy, ignore=shutil.ignore_patterns("__pycache__"))
    before = source_hash(copy)
    (copy / "deck.py").write_text((copy / "deck.py").read_text() + "\n# changed\n")
    assert source_hash(copy) != before


def test_build_ignores_non_source_files(tmp_path):
    copy = tmp_path / "la_carte_api"
    shutil.copytree(PACKAGE_ROOT, copy, ignore=shutil.ignore_patterns("__pycache__"))
    before = source_hash(copy)
    (copy / "notes.txt").write_text("not source")
    assert source_hash(copy) == before
