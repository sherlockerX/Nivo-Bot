"""校验iOS正式素材和本地化与安卓同源，防止迁移后再次退回旧目录。"""

from __future__ import annotations

import importlib.util
import json
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android/src/android/app/src/main"
IOS = ROOT / "android/src/ios"


@pytest.mark.parametrize("language", ["en", "zh"])
def test_packaged_daily_pool_matches_android(language: str) -> None:
    name = f"daily-ideas.{language}.json"
    expected = (ANDROID / "assets/nanomuse" / name).read_text(encoding="utf-8")
    actual = (IOS / "NanoMuse/Resources" / name).read_text(encoding="utf-8")
    assert actual == expected
    sections = json.loads(actual)["sections"]
    assert [section["id"] for section in sections] == [
        "ideas",
        "work",
        "life",
        "learn",
        "family",
        "media",
        "more",
    ]
    assert all(len(section["ideas"]) == 14 for section in sections)
    assert len({idea["id"] for section in sections for idea in section["ideas"]}) == 98


def test_generated_hot_topic_template_preserves_android_prompt() -> None:
    spec = importlib.util.spec_from_file_location(
        "ios_daily_ideas", ROOT / "scripts/ios-daily-ideas.py"
    )
    assert spec is not None and spec.loader is not None
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    expected = generator.resources()["daily-hot-topic.json"]
    actual = (IOS / "NanoMuse/Resources/daily-hot-topic.json").read_text(
        encoding="utf-8"
    )
    assert actual == expected
    assert all("$date" in prompt for prompt in json.loads(actual).values())


def test_daily_ui_translations_cover_existing_ios_locales() -> None:
    strings = json.loads((IOS / "Localizable.xcstrings").read_text(encoding="utf-8"))
    locales = {
        "en": "values",
        "zh-Hans": "values-zh",
        "zh-Hant": "values-zh-rTW",
        "de": "values-de",
        "es": "values-es",
        "fr": "values-fr",
        "ja": "values-ja",
        "ko": "values-ko",
        "ru": "values-ru",
    }
    values = {}
    for locale, folder in locales.items():
        document = ET.parse(ANDROID / "res" / folder / "nm_daily_ideas_strings.xml")
        values[locale] = {
            element.attrib["name"]: "".join(element.itertext())
            for element in document.getroot()
        }
    keys = [
        "nm_daily_ideas_title",
        "nm_daily_ideas_all",
        "nm_daily_ideas_evergreen",
        "nm_daily_ideas_rotation",
        "nm_daily_ideas_check_hot_topic",
    ]
    for key in keys:
        translations = strings["strings"][values["en"][key]]["localizations"]
        assert set(translations) == set(locales)
        for locale in locales:
            assert translations[locale]["stringUnit"]["value"] == values[locale][key]
