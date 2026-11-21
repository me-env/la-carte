"""Fingerprint of the API's source, so anyone can check which code is live (see docs/deploy.md)."""

import hashlib
from pathlib import Path

PACKAGE_ROOT = Path(__file__).parent


def source_hash(root: Path = PACKAGE_ROOT) -> str:
    """First 12 hex of sha256 over every .py under `root` (relative path + bytes, sorted)."""
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*.py"), key=lambda p: p.relative_to(root).as_posix()):
        digest.update(path.relative_to(root).as_posix().encode() + b"\0")
        digest.update(path.read_bytes() + b"\0")
    return digest.hexdigest()[:12]
