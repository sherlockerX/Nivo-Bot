"""验证发布版本推进，以及源码打包的秘密拦截、路径边界和候选恢复。"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

from prepare_source import checked_path, prepare
from source_audit import is_forbidden, secret_findings


class ReleaseVersionsTest(unittest.TestCase):
    """在隔离目录验证版本推进、零写预检和仅版本生成。"""

    def setUp(self):
        """准备公共版本落后于手机版本的最小发布树。"""
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bash = os.environ.get("RELEASE_TEST_BASH")
        if not self.bash and os.name == "nt":
            git = shutil.which("git")
            candidate = Path(git).resolve().parents[1] / "bin/bash.exe" if git else None
            self.bash = str(candidate) if candidate and candidate.is_file() else None
        elif not self.bash:
            self.bash = shutil.which("bash")
        if not self.bash:
            self.skipTest("发布脚本测试需要Git Bash或RELEASE_TEST_BASH")
        source = Path(__file__).resolve().parents[2]
        for name in ("scripts/release-bump.sh", "scripts/rebrand.py"):
            self.write(name, (source / name).read_text(encoding="utf-8"))
        rebrand = (self.root / "scripts/rebrand.py").read_text(encoding="utf-8")
        rebrand = re.sub(r"^VERSION_NAME = .*$", 'VERSION_NAME = "2.0.0"', rebrand, flags=re.M)
        rebrand = re.sub(r"^VERSION_CODE = .*$", "VERSION_CODE = 51", rebrand, flags=re.M)
        self.write("scripts/rebrand.py", rebrand)
        for name in ("nanomuse/__init__.py", "pyproject.toml"):
            key = "__version__" if name.endswith("__init__.py") else "version"
            self.write(name, f'{key} = "1.0.6"\n')
        self.write("CITATION.cff", "version: 1.0.6\ndate-released: 2026-10-23\n")
        self.write("cloud/nanomuse_cloud/console/app.js", '  const VERSION = "1.0.6";\n')
        self.write("cloud/pyproject.toml", 'version = "0.27.0"\n')
        self.write("cloud/nanomuse_cloud/__init__.py", '__version__ = "0.27.0"\n')
        for folder in ("web", "harness/desktop", "harness/dsh-nanomuse"):
            self.write(
                f"{folder}/package.json", '{\n  "version": "1.0.6",\n  "name": "fixture"\n}\n'
            )
            if folder != "harness/dsh-nanomuse":
                lock = {
                    "name": "fixture",
                    "version": "1.0.6",
                    "lockfileVersion": 3,
                    "packages": {
                        "": {"name": "fixture", "version": "1.0.6", "license": "GPL-3.0"},
                        "node_modules/fixture": {"version": "1.0.6", "license": "MIT"},
                    },
                }
                self.write(f"{folder}/package-lock.json", json.dumps(lock, indent=2) + "\n")
        self.write(
            "android/src/android/app/build.gradle.kts",
            'applicationId = "keep.custom.id"\nversionCode = 55\nversionName = "2.0.4"\n',
        )
        self.write(
            "android/src/ios/Minis.xcodeproj/project.pbxproj",
            "PRODUCT_NAME = Keep;\nCURRENT_PROJECT_VERSION = 51;\nMARKETING_VERSION = 2.0.0;\n",
        )

    def write(self, name, text):
        """创建UTF-8测试文件。"""
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")

    def snapshot(self):
        """按字节比较，确保预检不改日期、换行或其他内容。"""
        return {
            str(path.relative_to(self.root)): path.read_bytes()
            for path in self.root.rglob("*")
            if path.is_file()
        }

    def bump(self, *options):
        """运行真实发布脚本并显式指定当前Python解释器。"""
        environment = dict(os.environ, PYTHON=Path(sys.executable).as_posix())
        return subprocess.run(
            [self.bash, "scripts/release-bump.sh", *options, "1.0.6", "2.0.5", "51", "56"],
            cwd=self.root,
            env=environment,
            text=True,
            capture_output=True,
        )

    def test_explicit_mobile_baseline_check_writes_nothing(self):
        """显式声明异步基线的预检通过且零写入。"""
        before = self.snapshot()
        result = self.bump("--check", "--rebrand-old", "2.0.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_unexpected_baseline_writes_nothing(self):
        """未显式声明的手机版本差异继续拒绝。"""
        before = self.snapshot()
        result = self.bump()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_duplicate_pattern_writes_nothing(self):
        """任意文件重复匹配时不允许部分推进。"""
        self.write("pyproject.toml", 'version = "1.0.6"\nversion = "1.0.6"\n')
        before = self.snapshot()
        result = self.bump("--rebrand-old", "2.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("2 lines match", result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_invalid_lockfile_writes_nothing(self):
        """锁文件基线异常也必须在所有版本写入之前拒绝。"""
        path = self.root / "web/package-lock.json"
        self.write("web/package-lock.json", path.read_text().replace('"1.0.6"', '"1.0.7"'))
        before = self.snapshot()
        result = self.bump("--rebrand-old", "2.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("0 own version lines found", result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_next_release_uses_default_shared_baseline(self):
        """基线对齐后恢复原命令，不再需要额外手机版本参数。"""
        result = self.bump("--rebrand-old", "2.0.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        environment = dict(os.environ, PYTHON=Path(sys.executable).as_posix())
        result = subprocess.run(
            [self.bash, "scripts/release-bump.sh", "2.0.5", "2.0.6", "56", "57"],
            cwd=self.root,
            env=environment,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = subprocess.run(
            [sys.executable, "scripts/rebrand.py", "--versions-only"],
            cwd=self.root,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            'versionName = "2.0.6"',
            (self.root / "android/src/android/app/build.gradle.kts").read_text(),
        )
        self.assertIn(
            "versionCode = 57", (self.root / "android/src/android/app/build.gradle.kts").read_text()
        )

    def test_release_alignment_preserves_relay_and_dependency_versions(self):
        """仅推进客户端版本，不更改relay或同号依赖。"""
        result = self.bump("--rebrand-old", "2.0.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in ("web/package-lock.json", "harness/desktop/package-lock.json"):
            lock = json.loads((self.root / name).read_text())
            self.assertEqual(lock["version"], "2.0.5")
            self.assertEqual(lock["packages"][""]["version"], "2.0.5")
            self.assertEqual(lock["packages"]["node_modules/fixture"]["version"], "1.0.6")
        self.assertIn('version = "0.27.0"', (self.root / "cloud/pyproject.toml").read_text())
        self.assertIn(
            '__version__ = "0.27.0"', (self.root / "cloud/nanomuse_cloud/__init__.py").read_text()
        )
        self.assertIn(
            'VERSION = "2.0.5"', (self.root / "cloud/nanomuse_cloud/console/app.js").read_text()
        )

    def test_versions_only_updates_both_phones_without_rebranding(self):
        """仅版本模式保留包名与品牌，二次运行完全幂等。"""
        result = self.bump("--rebrand-old", "2.0.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        command = [sys.executable, "scripts/rebrand.py", "--versions-only"]
        result = subprocess.run(command, cwd=self.root, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.root / "android/src/android/app/build.gradle.kts").read_text(),
            'applicationId = "keep.custom.id"\nversionCode = 56\nversionName = "2.0.5"\n',
        )
        self.assertEqual(
            (self.root / "android/src/ios/Minis.xcodeproj/project.pbxproj").read_text(),
            "PRODUCT_NAME = Keep;\nCURRENT_PROJECT_VERSION = 56;\nMARKETING_VERSION = 2.0.5;\n",
        )
        before = self.snapshot()
        result = subprocess.run(command, cwd=self.root, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)


class ReleaseToolsTest(unittest.TestCase):
    """临时仓库检验真实归档行为，不接触用户项目。"""

    def test_android_session_sources_are_not_ignored(self):
        """同名运行记录继续忽略，Android会话源码必须可提交。"""
        rules = Path(__file__).resolve().parents[2] / ".gitignore"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".gitignore").write_bytes(rules.read_bytes())
            for path, ignored in [
                ("sessions/private.json", True),
                (
                    "android/src/android/app/src/main/java/com/openminis/app/ui/sessions/SessionListViewModel.kt",
                    False,
                ),
                (
                    "android/src/android/app/src/test/java/com/openminis/app/ui/sessions/GroupRunningRingTest.kt",
                    False,
                ),
            ]:
                source = root / path
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text("fixture", encoding="utf-8")
                result = subprocess.run(["git", "-C", str(root), "check-ignore", "-q", path])
                self.assertEqual(result.returncode == 0, ignored, path)

    def test_block_private_files(self):
        for path in [
            ".env",
            "config/config.toml",
            "android/keystore.properties",
            "x/node_modules/a.js",
            "private.jks",
            "local.properties",
            "x.db",
        ]:
            self.assertTrue(is_forbidden(path), path)
        self.assertFalse(is_forbidden(".env.example"))
        self.assertFalse(is_forbidden("app/schemas/database/1.json"))

    def test_secret_report_never_contains_value(self):
        token = b"ghp_" + b"a" * 36
        findings = secret_findings("test.txt", b"line\n" + token)
        self.assertEqual(2, findings[0]["line"])
        self.assertNotIn(token.decode(), json.dumps(findings))

    def test_reject_traversal(self):
        for path in ["../key", "/secret", "C:/secret", "x\\..\\key"]:
            with self.assertRaises(ValueError):
                checked_path(path)

    def test_restore_only_in_archive_and_keep_worktree_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            overlay = Path(directory) / "overlay"
            root.mkdir()
            overlay.mkdir()
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "LICENSE").write_text("license", encoding="utf-8")
            (root / "app.txt").write_text("base", encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "-c",
                    "user.name=Test",
                    "-c",
                    "user.email=test@example.invalid",
                    "commit",
                    "-qm",
                    "fixture",
                ],
                check=True,
            )
            (root / "LICENSE").unlink()
            (root / "app.txt").write_text("local edit", encoding="utf-8")
            (overlay / "site").mkdir()
            (overlay / "site/index.html").write_text("new page", encoding="utf-8")
            archive = Path(directory) / "source.zip"
            report = prepare(root, overlay, archive, True)
            self.assertEqual(["LICENSE"], report["restored_from_head"])
            self.assertFalse((root / "LICENSE").exists())
            with zipfile.ZipFile(archive) as source:
                self.assertEqual(b"local edit", source.read("app.txt"))
                self.assertEqual(b"license", source.read("LICENSE"))
                self.assertEqual(b"new page", source.read("site/index.html"))


if __name__ == "__main__":
    unittest.main()
