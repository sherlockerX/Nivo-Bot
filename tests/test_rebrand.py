"""Rebranding keeps Soul's default-name round-trip test valid after an upstream pull."""

from __future__ import annotations

import importlib.util
import json
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

    # 产品显示名与助手名独立，生成器不能重写用户身份的代码来源。
    assert 'name = "Minis"' in soul.read_text(encoding="utf-8")
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
        "NanoMuse/NanoMuseConnectors.swift": (
            'throw Failure(message: "The authorization server refused to register nanoMuse")\n'
        ),
        "Info.plist": "<string>nanoMuse Backup</string>\n<string>io.github.nanomuse.app</string>\n",
        "ShareExtension/Info.plist": "<string>io.github.nanomuse.app.share</string>\n",
        "FileProvider/Info.plist": "<string>/var/minis</string>\n",
    }
    for name, value in samples.items():
        path = ios / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")
    connector_key = (
        "Signs in with your %@ account in the browser; nanoMuse registers itself with the "
        "service, so there is nothing to type. The token stays on this phone."
    )
    catalogue = ios / "Localizable.xcstrings"
    catalogue.write_text(
        json.dumps(
            {
                "strings": {
                    connector_key: {
                        "localizations": {
                            "en": {"stringUnit": {"state": "translated", "value": connector_key}},
                            "zh-Hans": {
                                "stringUnit": {
                                    "state": "translated",
                                    "value": "nanoMuse向服务注册。",
                                }
                            },
                        }
                    }
                }
            }
        ),
        encoding="utf-8",
    )
    rebrand.ios_brand_only()
    project = (ios / "Minis.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    assert 'INFOPLIST_KEY_CFBundleDisplayName = "Nelan";' in project
    assert "MARKETING_VERSION = 1.0.6;" in project
    assert "CURRENT_PROJECT_VERSION = 49;" in project
    assert "PRODUCT_BUNDLE_IDENTIFIER = io.github.nanomuse.app;" in project
    assert "<string>/var/minis</string>" in (ios / "FileProvider/Info.plist").read_text()
    connector = (ios / "NanoMuse/NanoMuseConnectors.swift").read_text(encoding="utf-8")
    assert "register nanoMuse" not in connector
    assert r"\(NivoProduct.name)" in connector
    translated = json.loads(catalogue.read_text(encoding="utf-8"))["strings"][connector_key]
    for locale, localization in translated["localizations"].items():
        assert "nanoMuse" not in localization["stringUnit"]["value"]
        assert ("念步" if locale.startswith("zh") else "Nelan") in localization["stringUnit"][
            "value"
        ]
    before = {path: path.read_bytes() for path in ios.rglob("*") if path.is_file()}
    rebrand.ios_brand_only()
    assert {path: path.read_bytes() for path in before} == before


def test_ios_privacy_links_use_current_product_without_recreating_removed_ui(
    rebrand: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """再次品牌化不会恢复旧隐私地址或新增仓库、更新和反馈按钮。"""
    ios = tmp_path / "ios"
    monkeypatch.setattr(rebrand, "ROOT", tmp_path)
    monkeypatch.setattr(rebrand, "IOS", ios)
    content = ios / "Views/ContentView.swift"
    provider = ios / "Views/Providers/AddProviderView.swift"
    content.parent.mkdir(parents=True)
    provider.parent.mkdir(parents=True)
    content.write_text(
        'Link(destination: URL(string: "https://github.com/nano-muse/nanoMuse/blob/main/docs/privacy.md")!) {}',
        encoding="utf-8",
    )
    provider.write_text(
        'Link(destination: URL(string: "https://openminis.github.io/privacy-policy.html")!) {}',
        encoding="utf-8",
    )
    rebrand.ios_links()
    before = {path: path.read_bytes() for path in (content, provider)}
    for text in before.values():
        assert b"NivoProduct.privacy" in text
        assert b"github.com" not in text
        assert b"Check for updates" not in text
        assert b"Report a Bug" not in text
    rebrand.ios_links()
    assert {path: path.read_bytes() for path in before} == before


def test_ios_version_only_updates_versions_preserves_other_files_and_is_idempotent(
    rebrand: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """显式版本入口只对齐iOS版本，不改品牌、标识、图像或其他平台。"""
    ios = tmp_path / "ios"
    monkeypatch.setattr(rebrand, "ROOT", tmp_path)
    monkeypatch.setattr(rebrand, "IOS", ios)
    # 本用例只固定iOS读取的版本常量，不验证导入时绑定的Android版本别名。
    monkeypatch.setattr(rebrand, "VERSION_NAME", "9.8.7")
    monkeypatch.setattr(rebrand, "VERSION_CODE", 987)
    project = ios / "Minis.xcodeproj/project.pbxproj"
    project.parent.mkdir(parents=True)
    original = (
        "MARKETING_VERSION = 1.0.6;\nCURRENT_PROJECT_VERSION = 49;\n"
        'INFOPLIST_KEY_CFBundleDisplayName = "Personal brand";\n'
        "PRODUCT_BUNDLE_IDENTIFIER = io.github.nanomuse.app;\n"
        "MARKETING_VERSION = 1.13;\nCURRENT_PROJECT_VERSION = 1;\n"
        "PRODUCT_BUNDLE_IDENTIFIER = io.github.nanomuse.app.share;\n"
    )
    project.write_text(original, encoding="utf-8")
    image = ios / "custom-icon.png"
    image.write_bytes(b"unchanged-image-fixture")
    android = tmp_path / "android.gradle"
    android.write_text('versionName = "2.0.0"\nversionCode = 51\n', encoding="utf-8")
    assert rebrand.main(["--ios-version-only"]) == 0
    expected = (
        original.replace("MARKETING_VERSION = 1.0.6;", "MARKETING_VERSION = 9.8.7;")
        .replace("MARKETING_VERSION = 1.13;", "MARKETING_VERSION = 9.8.7;")
        .replace("CURRENT_PROJECT_VERSION = 49;", "CURRENT_PROJECT_VERSION = 987;")
        .replace("CURRENT_PROJECT_VERSION = 1;", "CURRENT_PROJECT_VERSION = 987;")
    )
    assert project.read_text(encoding="utf-8") == expected
    assert image.read_bytes() == b"unchanged-image-fixture"
    assert android.read_text(encoding="utf-8") == 'versionName = "2.0.0"\nversionCode = 51\n'
    before = {path: path.read_bytes() for path in (project, image, android)}
    assert rebrand.main(["--ios-version-only"]) == 0
    assert {path: path.read_bytes() for path in before} == before
    rebrand.ios_project()
    assert project.read_text(encoding="utf-8") == expected


def test_android_brand_only_localizes_names_without_changing_install_identity(
    rebrand: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """显示品牌按语言更新，安装身份、历史名称和已发布版本不受影响。"""
    app = tmp_path / "app"
    main = app / "src/main"
    res = main / "res"
    for key, value in {"ROOT": tmp_path, "APP": app, "MAIN": main, "RES": res}.items():
        monkeypatch.setattr(rebrand, key, value)
    java = main / "java/com/openminis/app"
    monkeypatch.setattr(rebrand, "JAVA", java)
    java.mkdir(parents=True)
    gradle = app / "build.gradle.kts"
    gradle.write_text(
        'applicationId = "private.existing.app"\nversionCode = 12\nversionName = "1.2.0"\n',
        encoding="utf-8",
    )
    soul = java / "SoulStore.kt"
    soul.write_text('val oldNames = setOf("Nivo Bot", "Nicholasx", "Minis")\n', encoding="utf-8")
    protected = {p: p.read_bytes() for p in (gradle, soul)}
    for locale in ("values", "values-zh", "values-zh-rTW", "values-ja"):
        path = res / locale / "strings.xml"
        path.parent.mkdir(parents=True)
        path.write_text(
            '<resources>\n<string name="app_name">Nivo Bot</string>\n'
            '<string name="message">Welcome to Nicholasx</string>\n'
            '<string name="service">Nivo Bot Cloud</string>\n'
            '<string name="source">https://github.com/sherlockerX/Nicholasx</string>\n'
            '<string name="credit">Built on nanoMuse and OpenMinis</string>\n'
            "<!-- nanoMuse: 历史署名。 -->\n</resources>",
            encoding="utf-8",
        )
    rebrand.android_brand_only()
    for path in res.glob("values*/strings.xml"):
        text = path.read_text(encoding="utf-8")
        expected = "念步" if "zh" in path.parent.name else "Nelan"
        assert f'<string name="app_name">{expected}</string>' in text
        assert f"Welcome to {expected}" in text
        assert "nanoMuse Cloud" in text
        assert "Built on nanoMuse and OpenMinis" in text
        assert "https://github.com/sherlockerX/Nicholasx" in text
        assert "<!-- nanoMuse: 历史署名。 -->" in text
    assert {p: p.read_bytes() for p in protected} == protected
    before = {p: p.read_bytes() for p in app.rglob("*") if p.is_file()}
    rebrand.android_brand_only()
    rebrand.product_name()
    assert {p: p.read_bytes() for p in before} == before


@pytest.mark.parametrize(
    "source, expected",
    [
        ("Open Nivo Bot.", "Open Nelan."),
        ("nanoMuse is ready.", "Nelan is ready."),
        ("io.github.nanomuse.app", "io.github.nanomuse.app"),
        ("https://github.com/sherlockerX/Nicholasx", "https://github.com/sherlockerX/Nicholasx"),
        ("/var/minis/files/nanoMuse.md", "/var/minis/files/nanoMuse.md"),
        ("X-Minis-Token", "X-Minis-Token"),
        ("https://example.org/?app=Minis", "https://example.org/?app=Minis"),
        ("Nivo-Dateien", "Nelan-Dateien"),
        ("No early exit in Nivo.", "No early exit in Nelan."),
        ("https://nivo.8666886.xyz/", "https://nivo.8666886.xyz/"),
        ("Nivo Bot builds on nanoMuse and OpenMinis.", "Nelan builds on nanoMuse and OpenMinis."),
        ("Nivo Bot Cloud에", "nanoMuse Cloud에"),
    ],
)
def test_display_brand_preserves_technical_tokens(
    rebrand: ModuleType, source: str, expected: str
) -> None:
    """普通句末可以换品牌，网址、文件名、协议和署名不可误改。"""
    assert rebrand.mobile_brand_text(source, "en") == expected


@pytest.mark.parametrize(
    "source, locale, expected",
    [
        ("Nivo-Dateien", "de", "Nelan-Dateien"),
        ("No early exit in Nivo.", "en", "No early exit in Nelan."),
        ("nanoMuse Cloud", "en", "nanoMuse Cloud"),
        ("nanoMuse Cloud", "zh-Hans", "nanoMuse Cloud"),
        ("Nivo-Cloud-Modelle", "de", "nanoMuse Cloud-Modelle"),
        ("nanoMuse Desktop", "en", "nanoMuse Desktop"),
        ("nanoMuse://share?app=Nivo", "en", "nanoMuse://share?app=Nivo"),
        ("https://example.org/?app=Minis#Nivo", "en", "https://example.org/?app=Minis#Nivo"),
        ("Run `Minis --help` or minis-config", "en", "Run `Minis --help` or minis-config"),
        ("OpenMinis and nanoMuse", "en", "OpenMinis and nanoMuse"),
        ("Nelan 与 OpenMinis、nanoMuse", "zh-Hans", "念步与 OpenMinis、nanoMuse"),
    ],
)
def test_mobile_copy_keeps_real_commands_and_original_service_names(
    rebrand: ModuleType, source: str, locale: str, expected: str
) -> None:
    """功能文案另按入口更新，真实服务名称、命令、协议、网址与致谢仍保留。"""
    actual = rebrand.mobile_brand_text(source, locale)
    assert actual == expected
    assert rebrand.mobile_brand_text(actual, locale) == expected


def test_local_resource_copy_covers_all_phone_languages_and_keeps_lookup_keys(
    rebrand: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """本地形象与文件文案覆盖两端全部语言，原资源键和技术说明保持兼容。"""
    android_locales = (
        "values",
        "values-de",
        "values-es",
        "values-fil",
        "values-fr",
        "values-in",
        "values-ja",
        "values-ko",
        "values-ms",
        "values-pl",
        "values-pt-rBR",
        "values-ro",
        "values-ru",
        "values-th",
        "values-tr",
        "values-zh",
        "values-zh-rTW",
    )
    monkeypatch.setattr(rebrand, "ROOT", tmp_path)
    monkeypatch.setattr(rebrand, "RES", tmp_path / "res")
    monkeypatch.setattr(rebrand, "IOS", tmp_path / "ios")
    for locale in android_locales:
        path = tmp_path / "res" / locale / "strings.xml"
        path.parent.mkdir(parents=True)
        path.write_text(
            '<resources><string name="storage_no_minis_files">No minis files</string>'
            '<string name="nm_avatar_footer">Old account sync promise</string>'
            '<string name="perm_allow_minis_config">Allow minis-config</string>'
            '<string name="command_help">Run minis-config under /var/minis</string></resources>',
            encoding="utf-8",
        )
        (path.parent / "nm_strings.xml").write_text("<resources></resources>", encoding="utf-8")
    catalogue = tmp_path / "ios" / "Localizable.xcstrings"
    catalogue.parent.mkdir()
    catalogue.write_text(
        json.dumps(
            {
                "strings": {
                    "No minis files": {},
                    "Providers, model groups, skills, appearance and the rest of the OpenMinis settings.": {},
                }
            }
        ),
        encoding="utf-8",
    )
    rebrand.android_brand_only()
    rebrand.ios_catalogue_brand()
    for path in (tmp_path / "res").glob("*/strings.xml"):
        text = path.read_text(encoding="utf-8")
        assert "No minis files" not in text
        assert "Old account sync promise" not in text
        assert "Allow minis-config" not in text
        assert "Run minis-config under /var/minis" in text
        storage_text = (path.parent / "nm_strings.xml").read_text(encoding="utf-8")
        for resource_key in (
            "nm_storage_location",
            "nm_about_upstream_credit_title",
            "nm_about_upstream_credit_body",
            "nm_config_permission_title",
            "nm_config_permission_detail",
        ):
            assert storage_text.count(f'name="{resource_key}"') == 1
        assert "nanoMuse" in storage_text and "OpenMinis" in storage_text
        assert "minis-config" in storage_text
        assert "\\'" in storage_text or "'" not in storage_text
        if path.parent.name == "values":
            assert "Allow the assistant to manage settings" in storage_text
            assert "Changes require your confirmation." in storage_text
        if path.parent.name == "values-zh":
            assert "允许助手管理设置" in storage_text
            assert "修改需要你确认" in storage_text
    data = json.loads(catalogue.read_text(encoding="utf-8"))["strings"]
    for key in (
        "No minis files",
        "Providers, model groups, skills, appearance and the rest of the OpenMinis settings.",
    ):
        assert set(data[key]["localizations"]) == {
            "en",
            "zh-Hans",
            "zh-Hant",
            "ja",
            "ko",
            "fr",
            "de",
            "es",
            "ru",
        }
    assert (
        data["No minis files"]["localizations"]["en"]["stringUnit"]["value"] == "No session files"
    )
    assert (
        data["No minis files"]["localizations"]["zh-Hans"]["stringUnit"]["value"] == "暂无会话文件"
    )
    before = {path: path.read_bytes() for path in tmp_path.rglob("*") if path.is_file()}
    rebrand.android_brand_only()
    rebrand.ios_catalogue_brand()
    assert {path: path.read_bytes() for path in before} == before


@pytest.mark.parametrize(
    "key, expected_en, expected_zh",
    [
        ("nanoMuse Computer", "Tool workspace", "工具工作区"),
        ("nanoMuse is using Shell", "Running a command", "运行命令"),
        ("nanoMuse is reading File", "Reading a file", "读取文件"),
        ("nanoMuse is using Editor", "Writing a file", "写入文件"),
        ("nanoMuse is editing File", "Editing a file", "编辑文件"),
        ("nanoMuse is using Browser", "Using the browser", "使用浏览器"),
        ("nanoMuse is reading Image", "Reading an image", "读取图片"),
        ("nanoMuse is using Memory", "Using memory", "使用记忆"),
        ("Models nanoMuse Can Call at Runtime", "Models available for tasks", "任务可调用的模型"),
        ("No minis files", "No session files", "暂无会话文件"),
        (
            "Only the requests to the providers you added with your own key, and to the ChatGPT plan, go through it. nanoMuse Cloud, your computers and the local network never do. Kept on this phone only.",
            "Requests to your configured providers and ChatGPT plan use this proxy. Local network requests bypass it. These settings stay on this phone.",
            "发往你配置的服务商和ChatGPT套餐的请求使用此代理，局域网请求不经过代理。设置仅保存在这台手机上。",
        ),
        (
            "Muse home is the chat with the feed, ideas, goals and library as tabs. Off, the app opens on the classic OpenMinis chat list. The second switch puts the face and the name in the title of side chats; off, they show the model.",
            "The home layout puts chat and personal tools in tabs. Turn it off to open the classic chat list. The second switch shows the assistant's face and name in side chats; otherwise the model is shown.",
            "主页布局用标签页呈现对话和个人工具。关闭后打开经典对话列表。第二个开关在旁聊标题中显示助手形象和名字；关闭时显示模型。",
        ),
        (
            "Muse home is the chat with Feed, Ideas, Goals and Library beside it, on iPhone and iPad. Off, the app opens on the OpenMinis layout; the drawer still has it.",
            "The home layout puts chat and personal tools in tabs. Turn it off to open the classic chat list.",
            "主页布局用标签页呈现对话和个人工具。关闭后打开经典对话列表。",
        ),
        (
            "During a nanoMuse task, the agent calls these models for sub-tasks such as generating an image or summarizing text — work its own model can't do. Also callable from the terminal via minis-model-use. Only these are visible to the agent.",
            "The assistant can call these models for tasks such as generating an image or summarizing text. They can also be called from the terminal with minis-model-use. Only the listed models are available to the assistant.",
            "助手可调用这些模型完成生图、总结等任务，也可通过终端命令minis-model-use调用。助手只能使用此处列出的模型。",
        ),
    ],
)
def test_ios_task_copy_preserves_keys_commands_and_android_resources(
    rebrand: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    key: str,
    expected_en: str,
    expected_zh: str,
) -> None:
    """操作页使用功能文案，九种语言齐全，实际命令及Android资源不受影响。"""
    monkeypatch.setattr(rebrand, "ROOT", tmp_path)
    monkeypatch.setattr(rebrand, "IOS", tmp_path / "ios")
    catalogue = tmp_path / "ios" / "Localizable.xcstrings"
    catalogue.parent.mkdir()
    catalogue.write_text(json.dumps({"strings": {key: {}}}), encoding="utf-8")
    android = tmp_path / "android.xml"
    android.write_text(
        '<string name="storage_no_minis_files">No Nelan files</string>', encoding="utf-8"
    )
    before_android = android.read_bytes()
    rebrand.ios_catalogue_brand()
    translations = json.loads(catalogue.read_text(encoding="utf-8"))["strings"][key][
        "localizations"
    ]
    assert set(translations) == {"en", "zh-Hans", "zh-Hant", "de", "es", "fr", "ja", "ko", "ru"}
    assert translations["en"]["stringUnit"]["value"] == expected_en
    assert translations["zh-Hans"]["stringUnit"]["value"] == expected_zh
    if "minis-model-use" in key:
        assert all(
            "minis-model-use" in unit["stringUnit"]["value"] for unit in translations.values()
        )
    before = catalogue.read_bytes()
    rebrand.ios_catalogue_brand()
    assert catalogue.read_bytes() == before
    assert android.read_bytes() == before_android


def test_ios_brand_localizes_system_surfaces_and_preserves_source_keys(
    rebrand: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """系统名称、权限和扩展均有打包资源，翻译查找键和兼容字段不被更名。"""
    ios = tmp_path / "ios"
    monkeypatch.setattr(rebrand, "ROOT", tmp_path)
    monkeypatch.setattr(rebrand, "IOS", ios)
    project = ios / "Minis.xcodeproj/project.pbxproj"
    project.parent.mkdir(parents=True)
    # 使用实际工程结构验证资源归属，避免测试只验证没有加入target的孤立文件。
    project.write_bytes(
        (SCRIPT.parents[1] / "android/src/ios/Minis.xcodeproj/project.pbxproj").read_bytes()
    )
    source = ios / "Agent/Session/SoulStore.swift"
    source.parent.mkdir(parents=True)
    source.write_text('let legacyNames = ["Minis", "nanoMuse", "Nivo Bot"]\n', encoding="utf-8")
    for locale in ("en", "zh-Hans", "zh-Hant", "fr"):
        info = ios / f"{locale}.lproj/InfoPlist.strings"
        info.parent.mkdir(parents=True)
        info.write_text(
            '"NSCameraUsageDescription" = "nanoMuse needs camera access.";\n', encoding="utf-8"
        )
    catalogue = ios / "Localizable.xcstrings"
    catalogue.write_text(
        json.dumps(
            {
                "sourceLanguage": "en",
                "strings": {
                    "About Nivo Bot": {
                        "localizations": {
                            "en": {
                                "stringUnit": {"state": "translated", "value": "About Nivo Bot"}
                            },
                            "zh-Hans": {
                                "stringUnit": {"state": "translated", "value": "关于Nivo Bot"}
                            },
                        }
                    },
                    "Nivo Bot builds on nanoMuse and OpenMinis. Their licenses and attribution are preserved.": {
                        "localizations": {
                            "en": {
                                "stringUnit": {
                                    "state": "translated",
                                    "value": "Nivo Bot builds on nanoMuse and OpenMinis. Their licenses and attribution are preserved.",
                                }
                            }
                        },
                    },
                    "nanoMuse is Locked": {},
                },
            }
        ),
        encoding="utf-8",
    )
    original_source = source.read_bytes()
    rebrand.ios_brand_only()
    for locale in ("en", "zh-Hans", "zh-Hant", "fr"):
        name = "念步" if locale.startswith("zh") else "Nelan"
        info_text = (ios / f"{locale}.lproj/InfoPlist.strings").read_text(encoding="utf-8")
        assert f'"CFBundleDisplayName" = "{name}";' in info_text
        assert "nanoMuse needs" not in info_text
        for target in ("ShareExtension", "FileProvider", "AgentWidget"):
            extension = ios / target / f"{locale}.lproj/InfoPlist.strings"
            assert name in extension.read_text(encoding="utf-8")
    data = json.loads(catalogue.read_text(encoding="utf-8"))["strings"]
    assert "About Nivo Bot" in data
    assert data["About Nivo Bot"]["localizations"]["zh-Hans"]["stringUnit"]["value"] == "关于念步"
    assert (
        data["nanoMuse is Locked"]["localizations"]["en"]["stringUnit"]["value"]
        == "Nelan is Locked"
    )
    credit = data[
        "Nivo Bot builds on nanoMuse and OpenMinis. Their licenses and attribution are preserved."
    ]
    assert credit["localizations"]["en"]["stringUnit"]["value"].startswith(
        "Nelan builds on nanoMuse and OpenMinis"
    )
    assert source.read_bytes() == original_source
    text = project.read_text(encoding="utf-8")
    for phase in ("E5E000042", "E5FP00042", "E5H000042"):
        body = text.split(f"\t\t{phase} /* Resources */ = {{", 1)[1].split("\n\t\t};", 1)[0]
        assert "InfoPlist.strings in Resources" in body
    before = {p: p.read_bytes() for p in ios.rglob("*") if p.is_file()}
    rebrand.ios_brand_only()
    rebrand.ios_product_name()
    assert {p: p.read_bytes() for p in before} == before


def test_ios_extension_resources_attach_to_each_target_on_first_generation(
    rebrand: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """首次生成与再次生成都要验证，不能只使用已经添加成员的当前工程。"""
    monkeypatch.setattr(rebrand, "ROOT", tmp_path)
    monkeypatch.setattr(rebrand, "IOS", tmp_path / "ios")
    sections = [
        f"/* Begin {section} section */\n/* End {section} section */"
        for section in ("PBXBuildFile", "PBXFileReference", "PBXVariantGroup")
    ]
    for prefix in ("E5E0000", "E5FP000", "E5H0000"):
        sections.append(f"\t\t{prefix}30 /* Group */ = {{\n\t\t\tchildren = (\n\t\t\t);\n\t\t}};")
        sections.append(f"\t\t{prefix}42 /* Resources */ = {{\n\t\t\tfiles = (\n\t\t\t);\n\t\t}};")
    initial = "\n".join(sections)
    result = rebrand.ios_extension_labels(initial)
    for target in ("ShareExtension", "FileProvider", "AgentWidget"):
        build_id = rebrand.ios_brand_resource_id(f"{target}.build")
        assert result.count(f"{build_id} /* InfoPlist.strings in Resources */") == 2
        assert (tmp_path / "ios" / target / "zh-Hans.lproj/InfoPlist.strings").is_file()
    assert rebrand.ios_extension_labels(result) == result
