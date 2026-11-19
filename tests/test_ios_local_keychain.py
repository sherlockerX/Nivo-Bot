"""约束本机凭据保存入口，保留旧同步读取仅用于恢复和迁移。"""

import re
from pathlib import Path

IOS = Path(__file__).resolve().parents[1] / "android" / "src" / "ios"


def test_local_migration_and_new_write_paths_exist() -> None:
    migration = IOS / "NanoMuse/NivoLocalKeychainMigration.swift"
    assert migration.exists()
    assert "migrateDuringStartup" in migration.read_text(encoding="utf-8")
    for relative in (
        "NanoMuse/NivoCredentialSyncKeychain.swift",
        "NanoMuse/NivoProviderOAuthKeychain.swift",
    ):
        source = (IOS / relative).read_text(encoding="utf-8")
        assert "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly" in source


def test_anthropic_oauth_missing_configuration_throws_instead_of_trapping() -> None:
    source = (IOS / "Providers/Anthropic/AnthropicProvider.swift").read_text(encoding="utf-8")
    assert "fatalError(" not in source
    assert "func resolveSystemPrompt(_ userPrompt: String?) throws" in source
    calls = []
    for path in (IOS / "Providers/Anthropic").rglob("*.swift"):
        for line in path.read_text(encoding="utf-8").splitlines():
            if "resolveSystemPrompt(" not in line or "func resolveSystemPrompt" in line:
                continue
            calls.append(line)
    assert len(calls) == 4
    assert all(re.search(r"\btry\s+(?:provider\.)?resolveSystemPrompt\(", line) for line in calls)


def test_new_credential_write_methods_target_device_only_items() -> None:
    """仅检查实际写入函数，兼容读取或历史清理仍允许访问同步条目。"""
    methods = (
        (
            "NanoMuse/NivoCredentialSyncKeychain.swift",
            "private static func install(",
            "private static func match(",
        ),
        (
            "NanoMuse/NivoProviderOAuthKeychain.swift",
            "private static func write(",
            "private static func match(",
        ),
        (
            "NanoMuse/NivoCredentialRestore.swift",
            "private static func insert(",
            "private static func existing(",
        ),
        (
            "NanoMuse/NivoLocalKeychainMigration.swift",
            "private static func insert(",
            "private static func remove(",
        ),
    )
    for relative, start, end in methods:
        source = (IOS / relative).read_text(encoding="utf-8")
        method = source.split(start, 1)[1].split(end, 1)[0]
        assert "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly" in method, relative
        assert "synchronizable: false" in method or "let isSync = false" in method, relative
        assert "synchronizable: true" not in method, relative


def test_key_rotation_writes_local_and_legacy_recovery_never_reuploads_secret() -> None:
    source = (IOS / "NanoMuse/NivoProviderKeyRotationKeychain.swift").read_text(encoding="utf-8")
    apply = source.split("static func apply(", 1)[1].split("static func rollback(", 1)[0]
    assert "secretQuery(instanceID: receipt.instanceID, synchronizable: false)" in apply
    legacy = source.split("private static func rollbackLegacy(", 1)[1].split(
        "private static func preserveLegacyLocally(", 1
    )[0]
    assert "preserveLegacyLocally(previous" in legacy
    assert "SecItemDelete" in legacy
    assert "SecItemAdd" not in legacy
    assert "SecItemUpdate" not in legacy
