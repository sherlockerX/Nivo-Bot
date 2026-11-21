"""验证CI签名隔离和APK误标防护，不使用真实密钥或Android设备。"""

from __future__ import annotations

import base64
import importlib.util
import io
import json
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

    def test_new_install_identity_is_required_for_each_variant(self) -> None:
        """正式包与隔离包分别校验，旧身份不能混入新发行。"""
        configured = {
            "package": "io.github.sherlockerx.nelan",
            "versionName": "2.0.9",
            "versionCode": "60",
        }
        for variant, suffix in (("release", ""), ("debug", ".uitest")):
            identity = {
                **configured,
                "package": "io.github.sherlockerx.nelan" + suffix,
                "abis": ["arm64-v8a"],
            }
            artifacts.validate_identity(identity, variant, configured)
            for rejected in (
                "io.github.nanomuse.app" + suffix,
                "unrelated.app",
                "io.github.sherlockerx.nelan" + ("" if suffix else ".uitest"),
            ):
                with self.subTest(variant=variant, rejected=rejected):
                    with self.assertRaisesRegex(ValueError, "identity"):
                        artifacts.validate_identity(
                            {**identity, "package": rejected}, variant, configured
                        )

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


class ArtifactBuildIdentityTests(unittest.TestCase):
    """从实际CI入口核对产物与构建配置，不调用Android工具或读取签名密钥。"""

    def setUp(self) -> None:
        """准备新包名的独立源码、两种构建产物及通过的测试结果。"""
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "android/src/android/app"
        self.actual = {}
        for variant in ("debug", "release"):
            apk = self.app / f"build/outputs/apk/{variant}/app.apk"
            apk.parent.mkdir(parents=True)
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("AndroidManifest.xml", b"fixture")
        reports = self.app / "build/test-results/testDebugUnitTest"
        reports.mkdir(parents=True)
        (reports / "TEST-fixture.xml").write_text(
            '<testsuite tests="1" failures="0" errors="0" skipped="0"/>', encoding="utf-8"
        )
        self.configure_build("io.github.sherlockerx.nelan", "2.0.9", "60")

    def configure_build(self, package: str, version: str, code: str) -> None:
        """将源码声明与默认模拟产物设为同一身份。"""
        (self.app / "build.gradle.kts").write_text(
            f'applicationId = "{package}"\nversionName = "{version}"\nversionCode = {code}\n',
            encoding="utf-8",
        )
        self.actual = {
            variant: {
                "package": package + (".uitest" if variant == "debug" else ""),
                "versionName": version,
                "versionCode": code,
            }
            for variant in ("debug", "release")
        }

    def run_ci(self) -> None:
        """仅替换外部工具返回值，执行真实校验与发布元数据生成。"""

        def tool_result(command: list[str]) -> subprocess.CompletedProcess[str]:
            """模拟aapt的逐包信息与成功验签结果。"""
            if command[1] != "dump":
                return subprocess.CompletedProcess(command, 0, "Verifies", "")
            identity = self.actual[Path(command[-1]).parent.name]
            output = (
                f"package: name='{identity['package']}' "
                f"versionCode='{identity['versionCode']}' "
                f"versionName='{identity['versionName']}'\n"
                "native-code: 'arm64-v8a'\n"
            )
            return subprocess.CompletedProcess(command, 0, output, "")

        with (
            patch.object(artifacts, "ROOT", self.root),
            patch.object(artifacts, "run_tool", side_effect=tool_result),
            patch.dict(
                artifacts.os.environ,
                {
                    "ANDROID_HOME": str(self.root / "sdk"),
                    "BUILD_TOOLS_VERSION": "36.1.0",
                    "SIGNED_RELEASE": "true",
                },
                clear=True,
            ),
            patch("sys.stdout", new_callable=io.StringIO),
        ):
            artifacts.main()

    def test_new_android_identity_is_recorded_from_both_build_variants(self) -> None:
        """正式包严格使用新包名，Debug必须使用其独立uitest后缀。"""
        self.run_ci()
        metadata = json.loads((self.root / "build/ci-android/build-info.json").read_text())
        self.assertEqual(
            [package["package"] for package in metadata["packages"]],
            ["io.github.sherlockerx.nelan.uitest", "io.github.sherlockerx.nelan"],
        )

    def test_historical_build_keeps_its_original_identity(self) -> None:
        """旧版源码配置仍仅接受该版本的旧包名，避免破坏历史构建复查。"""
        self.configure_build("io.github.nanomuse.app", "2.0.8", "59")
        self.run_ci()
        metadata = json.loads((self.root / "build/ci-android/build-info.json").read_text())
        self.assertEqual(metadata["packages"][1]["package"], "io.github.nanomuse.app")

    def test_historical_configuration_rejects_new_package_identity(self) -> None:
        """旧版源码不能因为新包名已知而接受不同安装身份。"""
        self.configure_build("io.github.nanomuse.app", "2.0.8", "59")
        self.actual["debug"]["package"] = "io.github.sherlockerx.nelan.uitest"
        with self.assertRaisesRegex(ValueError, "APK identity"):
            self.run_ci()
        self.assertFalse((self.root / "build/ci-android/build-info.json").exists())

    def test_matching_stale_variants_still_fail_source_version_check(self) -> None:
        """两个APK版本相同也不够，均旧于本次源码时必须拒绝。"""
        for identity in self.actual.values():
            identity.update(versionName="2.0.8", versionCode="59")
        with self.assertRaisesRegex(ValueError, "APK identity"):
            self.run_ci()
        self.assertFalse((self.root / "build/ci-android/build-info.json").exists())

    def test_wrong_package_or_stale_version_cannot_produce_build_metadata(self) -> None:
        """新构建不能混入旧包名、未隔离Debug、测试正式包或旧版本。"""
        for variant, field, value in (
            ("debug", "package", "io.github.nanomuse.app.uitest"),
            ("release", "package", "io.github.nanomuse.app"),
            ("debug", "package", "io.github.sherlockerx.nelan"),
            ("release", "package", "io.github.sherlockerx.nelan.uitest"),
            ("debug", "versionName", "2.0.8"),
            ("release", "versionCode", "59"),
        ):
            self.configure_build("io.github.sherlockerx.nelan", "2.0.9", "60")
            self.actual[variant][field] = value
            with self.subTest(variant=variant, field=field), self.assertRaises(ValueError):
                self.run_ci()
            self.assertFalse((self.root / "build/ci-android/build-info.json").exists())

    def test_missing_or_ambiguous_source_identity_is_rejected_before_inspection(self) -> None:
        """无法唯一读取构建声明时不从产物反推预期身份。"""
        config = self.app / "build.gradle.kts"
        original = config.read_text(encoding="utf-8")
        for text in ("", original + 'applicationId = "other.app"\n'):
            config.write_text(text, encoding="utf-8")
            with (
                patch.object(artifacts, "run_tool") as command,
                patch.object(artifacts, "ROOT", self.root),
                self.assertRaisesRegex(ValueError, "build identity"),
            ):
                artifacts.main()
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
