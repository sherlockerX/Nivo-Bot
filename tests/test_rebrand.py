"""Rebranding keeps Soul's default-name round-trip test valid after an upstream pull."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "rebrand.py"


@pytest.fixture()
def rebrand() -> ModuleType:
    spec = importlib.util.spec_from_file_location("rebrand", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize("include_test", [True, False])
def test_soul_default_round_trip_survives_rebranding(
    rebrand: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    include_test: bool,
) -> None:
    app = tmp_path / "android" / "src" / "android" / "app"
    java = app / "src" / "main" / "java" / "com" / "openminis" / "app"
    monkeypatch.setattr(rebrand, "ROOT", tmp_path)
    monkeypatch.setattr(rebrand, "APP", app)
    monkeypatch.setattr(rebrand, "JAVA", java)
    monkeypatch.setattr(rebrand, "RES", app / "src" / "main" / "res")
    soul = java / "agent" / "SoulStore.kt"
    soul.parent.mkdir(parents=True)
    soul.write_text('name = "Minis"\nconst val DISPLAY_EMOJI = "✨"\n', encoding="utf-8")
    edge = app / "src" / "test" / "java" / "com" / "openminis" / "app" / "agent"
    edge /= "SoulIconConfigEdgeTest.kt"
    if include_test:
        edge.parent.mkdir(parents=True)
        edge.write_text(
            '    assertEquals("Minis", back.metadata.name)\n'
            '    assertEquals("Minis", explicitlyNamed.metadata.name)\n',
            encoding="utf-8",
        )

    rebrand.product_name()
    rebrand.soul_defaults()

    assert f'name = "{rebrand.NAME}"' in soul.read_text(encoding="utf-8")
    assert 'DISPLAY_EMOJI = "🐾"' in soul.read_text(encoding="utf-8")
    if include_test:
        text = edge.read_text(encoding="utf-8")
        assert "assertEquals(SoulMetadata.DEFAULT.name, back.metadata.name)" in text
        assert "// nanoMuse:" in text
        # A stored name supplied by the test is independent of the product's default.
        assert 'assertEquals("Minis", explicitlyNamed.metadata.name)' in text

    before = {p: p.read_bytes() for p in tmp_path.rglob("*.kt")}
    rebrand.product_name()
    rebrand.soul_defaults()
    assert {p: p.read_bytes() for p in tmp_path.rglob("*.kt")} == before


def test_ios_brand_preserves_versions_identifiers_and_is_idempotent(
    rebrand: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """本地品牌更新不能隐式发布新版本或改动用户目录及协议标识。"""
    ios = tmp_path / "ios"
    monkeypatch.setattr(rebrand, "ROOT", tmp_path)
    monkeypatch.setattr(rebrand, "IOS", ios)
    samples = {
        "Minis.xcodeproj/project.pbxproj": (
            "MARKETING_VERSION = 1.0.6;\nCURRENT_PROJECT_VERSION = 49;\n"
            "INFOPLIST_KEY_CFBundleDisplayName = nanoMuse;\n"
            'INFOPLIST_KEY_CFBundleDisplayName = "Share to nanoMuse";\n'
            "PRODUCT_BUNDLE_IDENTIFIER = io.github.nanomuse.app;\n"
        ),
        "Views/Settings/AboutView.swift": 'Text("nanoMuse")\n',
        "NanoMuse/NanoMuseSettings.swift": 'AppLocalized("About nanoMuse")\n',
        "Info.plist": "<string>nanoMuse Backup</string>\n<string>io.github.nanomuse.app</string>\n",
        "ShareExtension/Info.plist": "<string>io.github.nanomuse.app.share</string>\n",
        "FileProvider/Info.plist": "<string>/var/minis</string>\n",
    }
    for name, value in samples.items():
        path = ios / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")
    rebrand.ios_brand_only()
    project = (ios / "Minis.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    assert 'INFOPLIST_KEY_CFBundleDisplayName = "Nivo Bot";' in project
    assert "MARKETING_VERSION = 1.0.6;" in project
    assert "CURRENT_PROJECT_VERSION = 49;" in project
    assert "PRODUCT_BUNDLE_IDENTIFIER = io.github.nanomuse.app;" in project
    assert "<string>/var/minis</string>" in (ios / "FileProvider/Info.plist").read_text()
    before = {path: path.read_bytes() for path in ios.rglob("*") if path.is_file()}
    rebrand.ios_brand_only()
    assert {path: path.read_bytes() for path in before} == before
