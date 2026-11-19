"""防止个人构建重新接入需要签名授权的内置iCloud服务。"""

from __future__ import annotations

import plistlib
import re
from pathlib import Path

IOS = Path(__file__).resolve().parents[1] / "android" / "src" / "ios"


def _source(path: Path) -> str:
    """忽略注释，检查实际Swift调用。"""
    return re.sub(r"//[^\n]*|/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S)


def test_no_icloud_container_or_ubiquity_download_calls() -> None:
    """所有入口包括调试RPC均不能重新构造云容器或自动下载云文件。"""
    forbidden = re.compile(
        r"\bCKContainer\s*(?:\(|\.\s*default\s*\()"
        r"|\burl\s*\(\s*forUbiquityContainerIdentifier\s*:"
        r"|\bstartDownloadingUbiquitousItem\s*\("
    )
    violations = [
        str(path.relative_to(IOS))
        for path in IOS.rglob("*.swift")
        if "MinisTests" not in path.parts and forbidden.search(_source(path))
    ]
    assert violations == []


def test_launch_and_settings_do_not_start_icloud() -> None:
    """旧开关即使为true，也不能恢复前台或冷启动的云同步。"""
    launch = _source(IOS / "MinisApp.swift")
    assert "SyncV2Bootstrap" not in launch
    assert "CloudSyncEngine" not in launch
    for relative in ("NanoMuse/NanoMuseSettings.swift", "Views/ContentView.swift"):
        settings = _source(IOS / relative)
        assert "CloudSyncSettingsV2View()" not in settings
        assert "CloudSyncSettingsView()" not in settings
        assert "BackupAndRestoreView()" in settings


def test_app_does_not_claim_icloud_or_remote_push_capabilities() -> None:
    """侧载包不再请求内置云容器与静默推送权限。"""
    entitlements = plistlib.loads((IOS / "Minis.entitlements").read_bytes())
    assert not any("icloud" in key or "ubiquity" in key for key in entitlements)
    info = plistlib.loads((IOS / "Info.plist").read_bytes())
    assert "remote-notification" not in info.get("UIBackgroundModes", [])
