"""The coding agents' project folder names read back into workspace paths, on every OS: the
platform and the directory test are passed in, so the Unix and the Windows shapes both run on
each runner (test_coding.py as a whole is skipped on Windows for its posix shell scripts)."""

from __future__ import annotations

import sys
from pathlib import Path

from nanomuse.coding.agents import _slug_to_path


def test_unix_slugs_read_as_before() -> None:
    unix = {"/ssd", "/ssd/code", "/ssd/code/my-app", "/ssd/code/my-app/sub"}
    is_dir = unix.__contains__
    assert _slug_to_path("ssd-code-my-app-sub", "linux", is_dir) == "/ssd/code/my-app/sub"
    # the tail that does not exist on disk is kept as one name
    assert _slug_to_path("ssd-code-my-app-gone", "linux", is_dir) == "/ssd/code/my-app/gone"
    assert _slug_to_path("nope-code", "linux", is_dir) == "nope-code"
    # no drives on Unix: a one-letter first part is just a name
    assert _slug_to_path("c-Users-me", "darwin", is_dir) == "c-Users-me"
    assert _slug_to_path("", "linux", lambda p: p == "/") == "/"


def test_windows_slugs_start_with_the_drive() -> None:
    win = {"C:\\Users", "C:\\Users\\me", "C:\\Users\\me\\my-app", "D:\\work"}
    is_dir = win.__contains__
    cursor = _slug_to_path("C-Users-me-my-app", "win32", is_dir)
    assert cursor == "C:\\Users\\me\\my-app"
    claude = _slug_to_path("C--Users-me-my-app", "win32", is_dir)
    assert claude == "C:\\Users\\me\\my-app"
    assert _slug_to_path("c--Users-me-my-app", "win32", is_dir) == "C:\\Users\\me\\my-app"
    assert _slug_to_path("d-work-gone", "win32", is_dir) == "D:\\work\\gone"
    # a drive with nothing under it, or no drive at all: the slug comes back unchanged
    assert _slug_to_path("Z-nothing-here", "win32", is_dir) == "Z-nothing-here"
    assert _slug_to_path("Users-me", "win32", is_dir) == "Users-me"
    assert _slug_to_path("C", "win32", is_dir) == "C"


def test_the_real_disk_on_this_os(tmp_path: Path) -> None:
    """The slug the way the agents make it here: `/` as `-` on Unix; Cursor's `C-Users-…`
    and Claude Code's `C--Users-…` on Windows."""
    want = tmp_path / "my-project" / "sub"
    want.mkdir(parents=True)
    text = str(want)
    if sys.platform == "win32":
        drive, rest = text[0], text[3:]  # "C:\\Users\\..." → "C", "Users\\..."
        slug = drive + "-" + rest.replace("\\", "-")
        shapes = [slug, drive + "--" + rest.replace("\\", "-")]
    else:
        shapes = [text.lstrip("/").replace("/", "-")]
    for slug in shapes:
        got = _slug_to_path(slug)
        assert Path(got) == want and got.lower() == text.lower(), slug
    assert _slug_to_path("no-such-root-anywhere-xyz") == "no-such-root-anywhere-xyz"
