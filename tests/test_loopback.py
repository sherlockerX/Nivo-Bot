"""The guarded socketpair: a timeout, the other loopback, an explanation (nanomuse/loopback.py)."""

from __future__ import annotations

import socket

import pytest

from nanomuse import loopback


@pytest.fixture(autouse=True)
def _fresh(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(loopback, "_preferred", None)
    monkeypatch.setattr(loopback, "_original", None)


def test_a_pair_is_connected_both_ways() -> None:
    a, b = loopback.socketpair()
    try:
        a.sendall(b"ping")
        assert b.recv(4) == b"ping"
        b.sendall(b"pong")
        assert a.recv(4) == b"pong"
        assert a.gettimeout() is None and b.gettimeout() is None  # blocking, as asyncio expects
    finally:
        a.close()
        b.close()
    assert loopback.preferred() == "127.0.0.1"


def test_an_intercepted_ipv4_falls_back_to_ipv6_once(monkeypatch: pytest.MonkeyPatch) -> None:
    tried: list[int] = []
    real = loopback._pair

    def pair(family: int, timeout: float) -> tuple[socket.socket, socket.socket]:
        tried.append(family)
        if family == socket.AF_INET:
            raise TimeoutError("timed out")
        return real(socket.AF_INET, timeout)  # stands in for ::1 on a box without IPv6

    monkeypatch.setattr(loopback, "_pair", pair)
    a, b = loopback.socketpair()
    a.close()
    b.close()
    assert tried == [socket.AF_INET, socket.AF_INET6]
    assert loopback.preferred() == "::1"
    # the next loop does not pay the timeout again
    a, b = loopback.socketpair()
    a.close()
    b.close()
    assert tried[2:] == [socket.AF_INET6]


def test_no_loopback_at_all_is_said_in_words(monkeypatch: pytest.MonkeyPatch) -> None:
    def pair(family: int, timeout: float) -> tuple[socket.socket, socket.socket]:
        raise TimeoutError("timed out")

    monkeypatch.setattr(loopback, "_pair", pair)
    with pytest.raises(loopback.LoopbackBlocked) as info:
        loopback.socketpair()
    text = str(info.value)
    assert text.startswith(loopback.MARKER)
    assert "Proxifier" in text and "TUN" in text and "127.0.0.1" in text
    assert isinstance(info.value, OSError)


def test_install_and_check_are_windows_only(monkeypatch: pytest.MonkeyPatch) -> None:
    before = socket.socketpair
    monkeypatch.setattr(loopback.os, "name", "posix")
    loopback.install()
    assert socket.socketpair is before
    assert loopback.check() == ""

    monkeypatch.setattr(loopback.os, "name", "nt")
    monkeypatch.setattr(socket, "socketpair", before)  # restored by monkeypatch afterwards
    loopback.install()
    assert socket.socketpair is loopback.socketpair
    loopback.install()  # idempotent
    assert loopback._original is before
    assert loopback.check() == ""

    def pair(family: int, timeout: float) -> tuple[socket.socket, socket.socket]:
        raise TimeoutError("timed out")

    monkeypatch.setattr(loopback, "_pair", pair)
    monkeypatch.setattr(loopback, "_preferred", None)
    assert loopback.check().startswith(loopback.MARKER)
