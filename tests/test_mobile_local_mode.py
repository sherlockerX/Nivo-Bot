"""检查移动应用移除自有云服务的构建边界，保留第三方提供商实现。"""

from pathlib import Path

IOS_ROOT = Path(__file__).resolve().parents[1] / "android/src/ios"


def test_legacy_account_adapter_contains_no_network_transport():
    """历史身份兼容层只能读取本地数据，不能再创建登录或校验请求。"""
    source = (IOS_ROOT / "NanoMuse/NanoMuseCloud.swift").read_text("utf-8")
    for forbidden in ("URLSession", "URLRequest", "/v1/auth/", '"/v1/me"'):
        assert forbidden not in source, forbidden


def test_remote_device_adapter_contains_no_websocket_transport():
    """旧设备记录兼容接口不能重连自有中继。"""
    source = (IOS_ROOT / "NanoMuse/NanoMuseHub.swift").read_text("utf-8")
    for forbidden in ("URLSession", "URLRequest", "webSocketTask", '"/v1/hub"'):
        assert forbidden not in source, forbidden


def test_legacy_profile_adapter_cannot_upload_or_download():
    """移除头像、名称和连接器的旧账号自动上传通路。"""
    source = (IOS_ROOT / "NanoMuse/NanoMuseProfile.swift").read_text("utf-8")
    for forbidden in ("URLSession", "URLRequest", "/v1/me/", "data(for:"):
        assert forbidden not in source, forbidden


def test_provider_list_does_not_offer_retired_cloud_sign_in():
    """全部提供商设置入口均只进入用户自己的提供商。"""
    source = (IOS_ROOT / "Views/Providers/ProviderInstancesView.swift").read_text("utf-8")
    assert "NanoMuseCloudView()" not in source
    assert "NanoMuseCloudRow()" not in source
    assert not (IOS_ROOT / "NanoMuse/NanoMuseCloudView.swift").exists()
    assert not (IOS_ROOT / "NanoMuse/NanoMuseRelayPicker.swift").exists()


def test_startup_does_not_schedule_retired_cloud_services():
    """冷启动不再注册原账号中继、头像同步或会话同步的后台工作。"""
    app = (IOS_ROOT / "MinisApp.swift").read_text("utf-8")
    shell = (IOS_ROOT / "NanoMuse/NanoMuseShell.swift").read_text("utf-8")
    assert "NanoMuseHub.shared.autoStart()" not in app
    assert "NanoMuseProfileSync.shared.start()" not in shell
    assert "NanoMuseSync.shared.start()" not in shell


def test_historical_chat_mapping_has_no_remote_work():
    """保留历史来源与归属映射，聊天操作不再安排远程轮询或上传。"""
    source = (IOS_ROOT / "NanoMuse/NanoMuseSync.swift").read_text("utf-8")
    for forbidden in (
        "NanoMuseCloud.call",
        "Timer.scheduledTimer",
        "URLSession",
        "addObserver",
        "NanoMuseCloud.account",
    ):
        assert forbidden not in source, forbidden
    assert "NanoMuseAccountData.shared.current" in source


def test_local_migration_waits_for_authoritative_provider_configuration():
    """旧JSON镜像不能触发凭据清理或覆盖SQLite中的真实提供商。"""
    account = (IOS_ROOT / "NanoMuse/NanoMuseAccountData.swift").read_text("utf-8")
    startup = account.split("func recoverAtLaunch()", 1)[1].split("// MARK:", 1)[0]
    baseline = startup.index("nmWaitForMigrationBaseline")
    assert baseline < startup.index("await sweepIfFreshInstall()")
    assert baseline < startup.index("NivoLocalKeychainMigration.migrateDuringStartup()")
    host = (IOS_ROOT / "NanoMuse/NivoLocalModeHost.swift").read_text("utf-8")
    assert host.index("nmWaitForMigrationBaseline") < host.index("store.instances.filter")


def test_restored_cloud_providers_cannot_be_selected_or_refreshed():
    """从旧备份恢复也不能把退役云实例重新用于请求。"""
    store = (IOS_ROOT / "Providers/ProviderConfigStore.swift").read_text("utf-8")
    for method in (
        "func instance(for",
        "func fetchModelsForInstance",
        "func fetchModelsWithFallback",
    ):
        block = store.split(method, 1)[1].split("\n    func ", 1)[0]
        assert "nmIsRetiredCloudProvider" in block
    provider = (IOS_ROOT / "Providers/ProviderInstance.swift").read_text("utf-8")
    assert "!nmIsRetiredCloudProvider && ProviderCredentialCache" in provider


def test_voice_services_use_the_same_retired_provider_policy():
    """恢复旧备份的启用标志不能让退役服务重新显示在语音设置。"""
    store = (IOS_ROOT / "Providers/ProviderConfigStore.swift").read_text("utf-8")
    voice = store.split("func shadowVoiceProviders()", 1)[1].split("// Fold", 1)[0]
    assert "let candidates = instances.filter" in voice
    assert "config.instances.filter" not in voice
