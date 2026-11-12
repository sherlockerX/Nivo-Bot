"""验证CI签名隔离和APK误标防护，不使用真实密钥或Android设备。"""

from __future__ import annotations

import base64
import importlib.util
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


def load_helper(name: str):
    """载入独立CI脚本，避免引入应用运行时依赖。"""
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signing = load_helper("ci-signing")
artifacts = load_helper("ci-artifacts")


class SigningTests(unittest.TestCase):
    """确保错误或缺失Secrets不会破坏已有签名配置。"""

    def setUp(self) -> None:
        """为每个用例创建隔离的仓库和runner临时目录。"""
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name) / "repository"
        (self.root / "android").mkdir(parents=True)
        self.temp = Path(self.folder.name) / "runner"
        self.env = dict.fromkeys(signing.SECRET_NAMES, "test-value")
        self.env[signing.SECRET_NAMES[0]] = base64.b64encode(b"test fixture only").decode()

    def test_missing_secret_creates_nothing(self) -> None:
        """缺少口令时不得生成任何签名配置。"""
        del self.env[signing.SECRET_NAMES[1]]
        with self.assertRaisesRegex(ValueError, "Missing GitHub Secrets"):
            signing.prepare(self.root, self.temp, self.env)
        self.assertFalse((self.root / "android/keystore.properties").exists())

    def test_invalid_base64_creates_nothing(self) -> None:
        """非法密钥编码必须在写入前失败。"""
        self.env[signing.SECRET_NAMES[0]] = "invalid!"
        with self.assertRaises(ValueError):
            signing.prepare(self.root, self.temp, self.env)
        self.assertFalse(self.temp.exists())

    def test_existing_configuration_survives_prepare_and_cleanup(self) -> None:
        """已有本地配置不能被准备过程或无标记清理覆盖。"""
        config = self.root / "android/keystore.properties"
        config.write_text("existing configuration", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "overwrite"):
            signing.prepare(self.root, self.temp, self.env)
        signing.cleanup(self.root, self.temp)
        self.assertEqual(config.read_text(), "existing configuration")

    def test_passwords_never_enter_properties_and_cleanup_is_repeatable(self) -> None:
        """临时配置不保存口令，重复清理安全。"""
        signing.prepare(self.root, self.temp, self.env)
        key, marker, config = signing.signing_paths(self.root, self.temp)
        self.assertEqual(key.read_bytes(), b"test fixture only")
        self.assertNotIn("Password", config.read_text())
        self.assertNotIn(self.env[signing.SECRET_NAMES[1]], config.read_text().splitlines()[0])
        signing.cleanup(self.root, self.temp)
        signing.cleanup(self.root, self.temp)
        self.assertFalse(any(path.exists() for path in (key, marker, config)))


class ArtifactTests(unittest.TestCase):
    """拒绝缺少架构、损坏签名和缺失测试结果的产物。"""

    def test_reads_actual_package_version_and_abi(self) -> None:
        """APK身份来自aapt输出，版本号可随未来发行变化。"""
        result = artifacts.apk_identity(
            "package: name='io.github.nanomuse.app' versionCode='51' versionName='2.0.0'\n"
            "native-code: 'arm64-v8a'\n"
        )
        self.assertEqual(result["versionName"], "2.0.0")
        self.assertEqual(result["abis"], ["arm64-v8a"])

    def test_missing_native_libraries_is_rejected(self) -> None:
        """缺少必需原生载荷不能发布为完整APK。"""
        with self.assertRaisesRegex(ValueError, "native ABI"):
            artifacts.apk_identity("package: name='app' versionCode='1' versionName='1'\n")

    def test_v1_signature_cannot_be_labeled_unsigned(self) -> None:
        """即使签名校验失败，存在证书也不能标为无签名。"""
        with tempfile.TemporaryDirectory() as folder:
            apk = Path(folder) / "app.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("META-INF/CERT.RSA", b"invalid signature fixture")
            failure = subprocess.CompletedProcess([], 1, "DOES NOT VERIFY", "")
            with patch.object(artifacts, "run_tool", return_value=failure):
                with self.assertRaisesRegex(ValueError, "contains a signature"):
                    artifacts.verify_signature(apk, Path("apksigner"), False)

    def test_tool_error_is_not_mistaken_for_unsigned_apk(self) -> None:
        """执行环境错误不能被解释为正常的未签名结果。"""
        with tempfile.TemporaryDirectory() as folder:
            apk = Path(folder) / "app.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("AndroidManifest.xml", b"manifest fixture")
            failure = subprocess.CompletedProcess([], 1, "", "Java not found")
            with patch.object(artifacts, "run_tool", return_value=failure):
                with self.assertRaisesRegex(ValueError, "Unexpected unsigned"):
                    artifacts.verify_signature(apk, Path("apksigner"), False)

    def test_unit_tests_must_exist_and_pass(self) -> None:
        """没有执行测试或测试失败时不得生成通过声明。"""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaises(ValueError):
                artifacts.test_counts(root)
            report = root / "TEST-example.xml"
            report.write_text('<testsuite tests="3" failures="1" errors="0" skipped="0"/>')
            with self.assertRaises(ValueError):
                artifacts.test_counts(root)
            report.write_text('<testsuite tests="3" failures="0" errors="0" skipped="1"/>')
            self.assertEqual(artifacts.test_counts(root)["tests"], 3)


if __name__ == "__main__":
    unittest.main()
