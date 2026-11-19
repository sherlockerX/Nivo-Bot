"""约束旧目录迁移与iOS本地使用入口的启动顺序。"""

from pathlib import Path

IOS = Path(__file__).resolve().parents[1] / "android/src/ios"


def test_legacy_files_migrate_before_default_content_is_seeded():
    """默认身份和预置技能不能先占用旧用户数据的目标路径。"""
    account = (IOS / "NanoMuse/NanoMuseAccountData.swift").read_text("utf-8")
    startup = account.split("func recoverAtLaunch()", 1)[1].split("// MARK:", 1)[0]
    migration = startup.index("NivoLegacyStorageMigration.migrate")
    assert migration < startup.index("await sweepIfFreshInstall()")
    assert migration < startup.index("NanoMusePreset.apply()")
    assert migration < startup.index("SoulStore.ensureExists()")
    assert startup.index("NanoMusePreset.apply()") < startup.index("isReady = true")
    app = (IOS / "MinisApp.swift").read_text("utf-8")
    assert "NanoMusePreset.apply()" not in app
    assert "migrateSharedDirToAppGroup" not in app
    assert "SoulStore.ensureExists()" not in app


def test_foreground_skill_reload_waits_for_storage_recovery():
    """恢复失败不能经前台生命周期提前初始化默认技能。"""
    app = (IOS / "MinisApp.swift").read_text("utf-8")
    active = app.split("case .active:", 1)[1].split("case .background:", 1)[0]
    assert active.index("await NanoMuseAccountData.shared.start()") < active.index(
        "SkillStore.shared.reload()"
    )
    assert "guard NanoMuseAccountData.shared.isReady" in active


def test_skipped_model_setup_keeps_draft_and_has_configuration_entry():
    """缺少模型时先提供配置入口，不让发送动作清空草稿。"""
    chat = (IOS / "Views/Chat/AIChatView.swift").read_text("utf-8")
    send = chat.split("private func performSend()", 1)[1]
    assert send.index("guard vm.resolveCurrentEntry() != nil") < send.index("vm.send(")
    assert "NivoModelSetupNotice(" in chat
    assert "NanoMuseOwnKeySheet" in chat
    policy = (IOS / "NanoMuse/NivoFirstRunPolicy.swift").read_text("utf-8")
    assert "!done && !hasSessions" in policy


def test_local_chat_and_settings_do_not_offer_retired_promotions():
    """入口代码不再引用Star、旧额度、旧反馈和账号引导组件。"""
    for name in ("NanoMuse/NanoMuseShell.swift", "NanoMuse/NanoMuseFirstRun.swift"):
        source = (IOS / name).read_text("utf-8")
        for forbidden in ("NanoMuseStar", "NanoMuseAllowanceCard", "Use the nanoMuse Cloud model"):
            assert forbidden not in source
    about = (IOS / "NanoMuse/NivoAboutView.swift").read_text("utf-8")
    for forbidden in (
        "GitHub Repository",
        "Report an Issue",
        "Check for updates",
        "NanoMuseUpdateCheck",
    ):
        assert forbidden not in about
    consent = (IOS / "Views/Providers/AddProviderView.swift").read_text("utf-8")
    assert 'providerRow("OpenRouter"' not in consent
    assert "github.com/nano-muse" not in consent
