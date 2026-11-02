"""Where the runtime's TLS finds its trust roots (a bundled Python has none of its own)."""

from __future__ import annotations

import ssl
from pathlib import Path

import pytest

from nanomuse import certs


def test_an_empty_store_is_pointed_at_certifi(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("SSL_CERT_FILE", raising=False)
    monkeypatch.delenv("SSL_CERT_DIR", raising=False)
    monkeypatch.setattr(certs.os, "name", "posix")
    missing = tmp_path / "gone"
    paths = ssl.DefaultVerifyPaths(
        str(missing / "cert.pem"),
        str(missing / "certs"),
        "SSL_CERT_FILE",
        str(missing / "cert.pem"),
        "SSL_CERT_DIR",
        str(missing / "certs"),
    )
    monkeypatch.setattr(certs.ssl, "get_default_verify_paths", lambda: paths)
    bundle = certs.ensure_ca_bundle()
    assert bundle.endswith("cacert.pem")
    assert certs.os.environ["SSL_CERT_FILE"] == bundle
    # and an SSL context made afterwards does verify with it
    assert ssl.create_default_context().cert_store_stats()["x509_ca"] > 0


def test_a_system_store_is_left_alone(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.delenv("SSL_CERT_FILE", raising=False)
    monkeypatch.delenv("SSL_CERT_DIR", raising=False)
    monkeypatch.setattr(certs.os, "name", "posix")
    present = tmp_path / "cert.pem"
    present.write_text("")
    paths = ssl.DefaultVerifyPaths(
        str(present), None, "SSL_CERT_FILE", str(present), "SSL_CERT_DIR", None
    )
    monkeypatch.setattr(certs.ssl, "get_default_verify_paths", lambda: paths)
    assert certs.ensure_ca_bundle() == ""
    assert "SSL_CERT_FILE" not in certs.os.environ


def test_an_explicit_choice_wins(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SSL_CERT_FILE", "/etc/my/roots.pem")
    assert certs.ensure_ca_bundle() == "/etc/my/roots.pem"


def test_windows_reads_its_own_store(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("SSL_CERT_FILE", raising=False)
    monkeypatch.delenv("SSL_CERT_DIR", raising=False)
    monkeypatch.setattr(certs.os, "name", "nt")
    assert certs.ensure_ca_bundle() == ""
