"""用临时Git对象验证正式源码归档，不访问项目的运行文件。"""

from __future__ import annotations

import hashlib
import base64
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import archive_source as archive_module
from archive_source import archive_source


class ArchiveSourceTest(unittest.TestCase):
    """从小型真实提交验证ZIP、子模块固定点及秘密拦截。"""

    def setUp(self) -> None:
        """创建独立主仓库与proot仓库，不继承用户Git配置。"""
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.root = self.folder / "source"
        self.root.mkdir()
        self.environment = dict(os.environ)
        # fixture不继承调用方临时注入的Git配置，避免空值破坏git init。
        for name in list(self.environment):
            if name == "GIT_CONFIG_COUNT" or name.startswith(
                ("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")
            ):
                self.environment.pop(name)
        self.environment.update(
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_AUTHOR_NAME="Fixture",
            GIT_AUTHOR_EMAIL="fixture@example.invalid",
            GIT_COMMITTER_NAME="Fixture",
            GIT_COMMITTER_EMAIL="fixture@example.invalid",
        )
        self.git(self.root, "init", "-q")
        self.proot = self.root / "android/deps/proot"
        self.proot.mkdir(parents=True)
        self.git(self.proot, "init", "-q")
        (self.proot / "COPYING").write_bytes(b"fixture native licence\n")
        (self.proot / "native.c").write_bytes(b"/* pinned native source */\n")
        self.git(self.proot, "add", "COPYING", "native.c")
        self.git(self.proot, "commit", "-qm", "native fixture")
        self.proot_commit = self.git(self.proot, "rev-parse", "HEAD").decode().strip()
        self.write("LICENSE", b"fixture licence\n")
        self.write("hello.sh", b"#!/bin/sh\nprintf hello\n")
        self.write(
            ".gitmodules",
            b'[submodule "native"]\n\tpath = android/deps/proot\n'
            b"\turl = https://example.invalid/proot.git\n",
        )
        self.git(self.root, "add", "LICENSE", "hello.sh", ".gitmodules")
        self.git(self.root, "update-index", "--chmod=+x", "hello.sh")
        self.git(
            self.root,
            "update-index",
            "--add",
            "--cacheinfo",
            f"160000,{self.proot_commit},android/deps/proot",
        )
        self.commit = self.commit_index()

    def git(self, root: Path, *arguments: str, data: bytes | None = None) -> bytes:
        """只对临时仓库调用Git，失败时保留fixture诊断。"""
        result = subprocess.run(
            ["git", "-C", str(root), *arguments],
            input=data,
            capture_output=True,
            env=self.environment,
            check=False,
        )
        if result.returncode:
            self.fail(result.stderr.decode("utf-8", errors="replace"))
        return result.stdout

    def write(self, relative: str, data: bytes) -> None:
        """创建测试文件，不经过真实工作树。"""
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def commit_index(self) -> str:
        """提交当前临时索引并返回不可变标识。"""
        self.git(self.root, "commit", "-qm", "archive fixture")
        return self.git(self.root, "rev-parse", "HEAD").decode().strip()

    def add_blob(self, relative: str, data: bytes, mode: str = "100644") -> None:
        """直接创建fixture对象，支持Windows不能检出的文件名和链接。"""
        oid = (
            self.git(self.root, "hash-object", "-w", "--stdin", data=data)
            .decode()
            .strip()
        )
        self.git(
            self.root,
            "update-index",
            "--add",
            "--cacheinfo",
            f"{mode},{oid},{relative}",
        )

    def add_repository(self, relative: str, files: dict[str, bytes]) -> tuple[Path, str]:
        """创建真正独立的子模块对象库，不用工作树内容替代提交对象。"""
        repository = self.root / relative
        repository.mkdir(parents=True, exist_ok=True)
        self.git(repository, "init", "-q")
        for name, data in files.items():
            target = repository / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            self.git(repository, "add", name)
        self.git(repository, "commit", "-qm", "nested source fixture")
        commit = self.git(repository, "rev-parse", "HEAD").decode().strip()
        return repository, commit

    def pin_submodule(self, repository: Path, relative: str, commit: str) -> str:
        """把指定gitlink写入fixture提交，不依赖当前子模块HEAD。"""
        self.git(
            repository, "update-index", "--add", "--cacheinfo",
            f"160000,{commit},{relative}",
        )
        self.git(repository, "commit", "-qm", "pin nested source fixture")
        return self.git(repository, "rev-parse", "HEAD").decode().strip()

    def ios_fixture(self) -> tuple[str, Path, Path, Path]:
        """准备iSH、一级和二级依赖，模拟固定递归源码树。"""
        ish, _ = self.add_repository(
            "android/deps/ish", {"kernel.c": b"pinned kernel\n"}
        )
        library, _ = self.add_repository(
            "android/deps/ish/deps/libapps", {"terminal.js": b"pinned terminal\n"}
        )
        nested, nested_commit = self.add_repository(
            "android/deps/ish/deps/libapps/vendor/helper",
            {"helper.c": b"pinned helper\n"},
        )
        library_commit = self.pin_submodule(library, "vendor/helper", nested_commit)
        ish_commit = self.pin_submodule(ish, "deps/libapps", library_commit)
        commit = self.pin_submodule(self.root, "android/deps/ish", ish_commit)
        return commit, ish, library, nested

    def test_ios_expands_recursive_pinned_objects_and_records_scope(self) -> None:
        """iOS递归展开固定gitlink，子模块HEAD和工作树变化不改变源码。"""
        commit, ish, library, nested = self.ios_fixture()
        for repository, filename in [
            (ish, "kernel.c"), (library, "terminal.js"), (nested, "helper.c")
        ]:
            (repository / filename).write_bytes(b"later committed source\n")
            self.git(repository, "add", filename)
            self.git(repository, "commit", "-qm", "later nested revision")
            (repository / filename).write_bytes(b"private uncommitted bytes\n")
        output = self.folder / "ios.zip"
        archive_source(self.root, commit, output, platform="ios")
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read("android/deps/ish/kernel.c"), b"pinned kernel\n")
            self.assertEqual(
                archive.read("android/deps/ish/deps/libapps/terminal.js"),
                b"pinned terminal\n",
            )
            self.assertEqual(
                archive.read("android/deps/ish/deps/libapps/vendor/helper/helper.c"),
                b"pinned helper\n",
            )
            manifest = json.loads(archive.read("SOURCE_RELEASE.json"))
            self.assertEqual(manifest["status"], "ios-release-source")
            self.assertEqual(manifest["scope"], "iOS corresponding source")
            self.assertEqual(len(manifest["submodules"]), 4)
            self.assertTrue(all(item["expanded"] for item in manifest["submodules"]))
            self.assertNotIn("APK", " ".join(manifest["limitations"]))

    def test_ios_missing_nested_checkout_cannot_fall_back_to_parent_repository(self) -> None:
        """空子目录中的Git会回退父仓库，归档器必须识别并拒绝。"""
        ish, ish_commit = self.add_repository(
            "android/deps/ish", {"kernel.c": b"pinned kernel\n"}
        )
        (ish / "deps/missing").mkdir(parents=True)
        ish_commit = self.pin_submodule(ish, "deps/missing", ish_commit)
        commit = self.pin_submodule(self.root, "android/deps/ish", ish_commit)
        output = self.folder / "missing-nested.zip"
        with self.assertRaisesRegex(ValueError, "Submodule repository is not initialized"):
            archive_source(self.root, commit, output, platform="ios")
        self.assertFalse(output.exists())

    def test_ios_reports_missing_pinned_object_in_initialized_repository(self) -> None:
        """存在子仓库也不允许用HEAD补足缺失的固定提交。"""
        _, ish_commit = self.add_repository(
            "android/deps/ish", {"kernel.c": b"pinned kernel\n"}
        )
        self.assertNotEqual(ish_commit, self.proot_commit)
        commit = self.pin_submodule(self.root, "android/deps/ish", self.proot_commit)
        with self.assertRaisesRegex(ValueError, "Missing pinned submodule commit"):
            archive_source(self.root, commit, self.folder / "missing-object.zip", platform="ios")

    def test_ios_requires_ish_and_rejects_unknown_platform(self) -> None:
        """iOS不能仅因主仓库可读就生成缺少内核源码的成功包。"""
        with self.assertRaisesRegex(ValueError, "Pinned iSH submodule is required"):
            archive_source(self.root, self.commit, self.folder / "no-ish.zip", platform="ios")
        with self.assertRaisesRegex(ValueError, "Unsupported source platform"):
            archive_source(self.root, self.commit, self.folder / "unknown.zip", platform="other")

    def test_ios_nested_secrets_are_scanned_and_partial_output_removed(self) -> None:
        """递归源码沿用严格秘密扫描，失败不能留下可发布产物。"""
        commit, ish, _, nested = self.ios_fixture()
        token = b"ghp_" + b"a" * 36
        (nested / "helper.c").write_bytes(token)
        self.git(nested, "add", "helper.c")
        self.git(nested, "commit", "-qm", "synthetic secret fixture")
        nested_commit = self.git(nested, "rev-parse", "HEAD").decode().strip()
        library = nested.parent.parent
        library_commit = self.pin_submodule(library, "vendor/helper", nested_commit)
        ish_commit = self.pin_submodule(ish, "deps/libapps", library_commit)
        commit = self.pin_submodule(self.root, "android/deps/ish", ish_commit)
        output = self.folder / "nested-secret.zip"
        with self.assertRaisesRegex(ValueError, "Suspected secret") as failure:
            archive_source(self.root, commit, output, platform="ios")
        self.assertNotIn(token.decode(), str(failure.exception))
        self.assertFalse(output.exists())
        self.assertFalse(list(self.folder.glob(".source-*.partial")))

    def test_ios_rejects_nested_private_paths(self) -> None:
        """子模块中的私密文件名同样必须阻止归档，不能静默省略。"""
        ish, _ = self.add_repository(
            "android/deps/ish", {"kernel.c": b"pinned kernel\n"}
        )
        _, nested_commit = self.add_repository(
            "android/deps/ish/deps/library", {"credentials.json": b"synthetic fixture"}
        )
        ish_commit = self.pin_submodule(ish, "deps/library", nested_commit)
        commit = self.pin_submodule(self.root, "android/deps/ish", ish_commit)
        with self.assertRaisesRegex(ValueError, "Forbidden archive path"):
            archive_source(self.root, commit, self.folder / "private.zip", platform="ios")

    def test_android_default_output_remains_byte_identical(self) -> None:
        """新增平台参数不能改变既有Android默认输出及固定元数据。"""
        commit, _, _, _ = self.ios_fixture()
        default = self.folder / "default.zip"
        explicit = self.folder / "android.zip"
        archive_source(self.root, commit, default)
        archive_source(self.root, commit, explicit, platform="android")
        self.assertEqual(default.read_bytes(), explicit.read_bytes())
        with zipfile.ZipFile(default) as archive:
            self.assertNotIn("android/deps/ish/kernel.c", archive.namelist())
            manifest = json.loads(archive.read("SOURCE_RELEASE.json"))
            self.assertEqual(manifest["status"], "android-release-source")

    def optional_linux_fixture(self, kernel: str = "ish") -> str:
        """固定声明不参与iSH内核构建的Linux备选gitlink及源码中的构建选择。"""
        ish, ish_commit = self.add_repository(
            "android/deps/ish", {
                "kernel.c": b"pinned kernel\n",
                ".gitmodules": (
                    b'[submodule "deps/linux"]\n\tpath = deps/linux\n'
                    b'\turl = https://example.invalid/linux.git\n\tupdate = none\n'
                ),
            },
        )
        ish_commit = self.pin_submodule(ish, "deps/linux", ish_commit)
        self.add_blob(
            "android/deps/build_ish.sh",
            f"meson setup build-ios \\\n    -Dkernel={kernel} \\\n    -Dengine=asbestos\n".encode(),
        )
        return self.pin_submodule(self.root, "android/deps/ish", ish_commit)

    def test_ios_records_optional_linux_pin_when_committed_build_uses_ish(self) -> None:
        """只在固定配置声明update=none且构建明确用iSH时保留Linux固定点。"""
        commit = self.optional_linux_fixture()
        self.write("android/deps/build_ish.sh", b"uncommitted replacement\n")
        output = self.folder / "ios-with-optional-linux.zip"
        archive_source(self.root, commit, output, platform="ios")
        with zipfile.ZipFile(output) as archive:
            manifest = json.loads(archive.read("SOURCE_RELEASE.json"))
            linux = next(
                item for item in manifest["submodules"] if item["path"].endswith("/linux")
            )
            self.assertFalse(linux["expanded"])
            self.assertIn("kernel=ish", linux["reason"])
            self.assertEqual(len(linux["commit"]), 40)
            self.assertIn("Linux", " ".join(manifest["limitations"]))

    def test_ios_cannot_omit_linux_if_committed_build_selects_it(self) -> None:
        """Linux变成实际构建输入后，即使update=none也必须有固定对象。"""
        commit = self.optional_linux_fixture(kernel="linux")
        with self.assertRaisesRegex(ValueError, "Submodule repository is not initialized"):
            archive_source(self.root, commit, self.folder / "needs-linux.zip", platform="ios")

    def test_ios_cannot_omit_linux_based_on_uncommitted_gitmodules(self) -> None:
        """工作树临时加入的update=none不能减少归档输入。"""
        ish, ish_commit = self.add_repository(
            "android/deps/ish", {"kernel.c": b"pinned kernel\n"}
        )
        ish_commit = self.pin_submodule(ish, "deps/linux", ish_commit)
        self.add_blob("android/deps/build_ish.sh", b"meson setup build-ios \\\n    -Dkernel=ish\n")
        commit = self.pin_submodule(self.root, "android/deps/ish", ish_commit)
        (ish / ".gitmodules").write_bytes(
            b'[submodule "deps/linux"]\n\tpath = deps/linux\n\tupdate = none\n'
        )
        with self.assertRaisesRegex(ValueError, "Submodule repository is not initialized"):
            archive_source(self.root, commit, self.folder / "untrusted-omit.zip", platform="ios")

    def test_ios_cli_accepts_platform_and_preserves_default_android(self) -> None:
        """真实命令行必须传递平台选择，不能只有可导入函数支持iOS。"""
        commit, _, _, _ = self.ios_fixture()
        script = Path(__file__).with_name("archive_source.py")
        for platform in ["ios", "android", "mobile"]:
            output = self.folder / f"cli-{platform}.zip"
            arguments = [
                sys.executable, str(script), "--root", str(self.root),
                "--commit", commit, "--output", str(output),
            ]
            if platform != "android":
                arguments.extend(["--platform", platform])
            result = subprocess.run(arguments, capture_output=True, env=self.environment)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(json.loads(result.stdout)["sourceCommit"], commit)
            with zipfile.ZipFile(output) as archive:
                manifest = json.loads(archive.read("SOURCE_RELEASE.json"))
                self.assertEqual(manifest["status"], f"{platform}-release-source")
                if platform == "mobile":
                    expanded = {item["path"] for item in manifest["submodules"] if item["expanded"]}
                    self.assertTrue({"android/deps/ish", "android/deps/proot"} <= expanded)

    def test_ios_recursive_symlinks_keep_existing_escape_and_dangling_checks(self) -> None:
        """子模块文件也按最终归档命名空间核对链接，不能越界或指向缺失文件。"""
        for index, target in enumerate([b"../../../../../outside", b"missing"]):
            with self.subTest(target=target):
                relative = f"android/deps/ish/fixture-{index}"
                repository, _ = self.add_repository(relative, {"source.c": b"fixture\n"})
                oid = self.git(repository, "hash-object", "-w", "--stdin", data=target).decode().strip()
                self.git(repository, "update-index", "--add", "--cacheinfo", f"120000,{oid},link")
                self.git(repository, "commit", "-qm", "unsafe link fixture")
                commit = self.git(repository, "rev-parse", "HEAD").decode().strip()
                # 主iSH仓库与实际checkout路径必须一致，固定gitlink不能借用父仓库。
                ish = self.root / "android/deps/ish"
                if index == 0:
                    self.git(ish, "init", "-q")
                    (ish / "kernel.c").write_bytes(b"fixture kernel\n")
                    self.git(ish, "add", "kernel.c")
                    self.git(ish, "commit", "-qm", "kernel fixture")
                else:
                    self.git(ish, "update-index", "--force-remove", "fixture-0")
                ish_commit = self.pin_submodule(ish, f"fixture-{index}", commit)
                source_commit = self.pin_submodule(self.root, "android/deps/ish", ish_commit)
                with self.assertRaisesRegex(ValueError, "Unsafe symlink"):
                    archive_source(self.root, source_commit, self.folder / f"link-ios-{index}.zip", platform="ios")

    def test_ios_archive_is_deterministic_and_refuses_existing_output(self) -> None:
        """递归归档同样可重复生成且不能覆盖既有源码文件。"""
        commit, _, _, _ = self.ios_fixture()
        first, second = self.folder / "ios-one.zip", self.folder / "ios-two.zip"
        archive_source(self.root, commit, first, platform="ios")
        archive_source(self.root, commit, second, platform="ios")
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with self.assertRaisesRegex(ValueError, "overwrite"):
            archive_source(self.root, commit, first, platform="ios")

    def reviewed_fixture(self, content: bytes, mode: str = "100644") -> tuple[str, str]:
        """创建人工公开测试数据，例外策略只在隔离测试中按明确哈希替换。"""
        relative = "android/deps/ish/deps/libapps/hterm/test_data/charsets.log"
        self.add_blob(relative, content, mode)
        return self.commit_index(), relative

    def test_reviewed_public_fixture_requires_exact_path_and_content_hash(self) -> None:
        """明确审查的测试日志可归档，同路径内容改动或旁边新日志仍被拒绝。"""
        content = b"@@ HEADER_START\nsynthetic terminal fixture\n@@ HEADER_END\n"
        commit, relative = self.reviewed_fixture(content)
        policy = {relative: hashlib.sha256(content).hexdigest()}
        with patch.dict(archive_module.REVIEWED_PUBLIC_FILES, policy, clear=True):
            output = self.folder / "reviewed.zip"
            archive_source(self.root, commit, output)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(archive.read(relative), content)
            changed, _ = self.reviewed_fixture(content + b"unreviewed bytes")
            with self.assertRaisesRegex(ValueError, "Reviewed public source checksum mismatch"):
                archive_source(self.root, changed, self.folder / "changed.zip")
            self.git(self.root, "read-tree", commit)
            self.add_blob(relative.replace("charsets", "personal"), content)
            unknown = self.commit_index()
            with self.assertRaisesRegex(ValueError, "Forbidden archive path"):
                archive_source(self.root, unknown, self.folder / "unknown-log.zip")
        self.assertFalse((self.folder / "changed.zip").exists())
        self.assertFalse(list(self.folder.glob(".source-*.partial")))

    def test_reviewed_public_fixture_cannot_bypass_secret_scanning_or_link_rules(self) -> None:
        """即使误把敏感内容或符号链接加入哈希表，其他拦截仍然生效。"""
        content = b"ghp_" + b"b" * 36
        commit, relative = self.reviewed_fixture(content)
        policy = {relative: hashlib.sha256(content).hexdigest()}
        with patch.dict(archive_module.REVIEWED_PUBLIC_FILES, policy, clear=True):
            with self.assertRaisesRegex(ValueError, "Suspected secret"):
                archive_source(self.root, commit, self.folder / "reviewed-secret.zip")
        commit, relative = self.reviewed_fixture(b"../../../../../../LICENSE", "120000")
        policy = {relative: hashlib.sha256(b"../../../../../../LICENSE").hexdigest()}
        with patch.dict(archive_module.REVIEWED_PUBLIC_FILES, policy, clear=True):
            with self.assertRaisesRegex(ValueError, "Forbidden archive path"):
                archive_source(self.root, commit, self.folder / "reviewed-link.zip")

    def test_reviewed_build_source_does_not_allow_arbitrary_build_paths(self) -> None:
        """公开build源码按文件哈希逐一确认，不把整个build目录变成白名单。"""
        relative = "android/deps/ish/deps/libarchive/build/README.txt"
        content = b"synthetic upstream build documentation\n"
        self.add_blob(relative, content)
        commit = self.commit_index()
        with patch.dict(
            archive_module.REVIEWED_PUBLIC_FILES,
            {relative: hashlib.sha256(content).hexdigest()}, clear=True,
        ):
            archive_source(self.root, commit, self.folder / "build-source.zip")
            self.add_blob(relative.replace("README.txt", "private.txt"), content)
            changed = self.commit_index()
            with self.assertRaisesRegex(ValueError, "Forbidden archive path"):
                archive_source(self.root, changed, self.folder / "build-private.zip")

    def test_reviewed_policy_has_only_exact_public_submodule_source_paths(self) -> None:
        """实际例外表不能含通配符、根日志或其他来源的文件。"""
        self.assertTrue(archive_module.REVIEWED_PUBLIC_FILES)
        for relative, digest in archive_module.REVIEWED_PUBLIC_FILES.items():
            self.assertTrue(relative.startswith((
                "android/deps/ish/deps/libapps/", "android/deps/ish/deps/libarchive/",
            )))
            self.assertNotIn("*", relative)
            self.assertNotIn("debug.log", relative)
            self.assertRegex(digest, r"^[0-9a-f]{64}$")

    def test_reads_commit_and_pinned_proot_without_worktree_files(self) -> None:
        """工作树及子模块HEAD后来变化，不得改变所指定提交的内容。"""
        self.write("LICENSE", b"uncommitted change\n")
        self.write("debug.log", b"untracked log must not be read\n")
        (self.proot / "native.c").write_bytes(b"later native revision\n")
        self.git(self.proot, "add", "native.c")
        self.git(self.proot, "commit", "-qm", "later native fixture")
        output = self.folder / "source.zip"

        archive_source(self.root, self.commit, output)

        with zipfile.ZipFile(output) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(archive.read("LICENSE"), b"fixture licence\n")
            self.assertEqual(
                archive.read("android/deps/proot/native.c"),
                b"/* pinned native source */\n",
            )
            self.assertNotIn("debug.log", archive.namelist())
            mode = archive.getinfo("hello.sh").external_attr >> 16
            self.assertEqual(stat.S_IMODE(mode), 0o755)
            manifest = json.loads(archive.read("SOURCE_RELEASE.json"))
            self.assertEqual(manifest["sourceCommit"], self.commit)
            self.assertEqual(manifest["submodules"][0]["commit"], self.proot_commit)
            item = next(item for item in manifest["files"] if item["path"] == "LICENSE")
            self.assertEqual(
                item["sha256"], hashlib.sha256(b"fixture licence\n").hexdigest()
            )
            self.assertEqual(item["size"], 16)
            self.assertEqual(item["mode"], "100644")

    def test_rejects_sensitive_paths_without_creating_output(self) -> None:
        """已提交的日志、凭据及运行文件必须阻止发布，不能静默漏扫。"""
        paths = [
            "debug.log",
            "android/keystore.properties",
            "signing-credential.xml",
            "credentials.json",
            "private.p12",
            "private.pfx",
            "key.pem",
            "notes/private.md",
            "site/downloads/file.txt",
            "config/config.toml",
        ]
        for index, path in enumerate(paths):
            with self.subTest(path=path):
                self.git(self.root, "read-tree", self.commit)
                self.add_blob(path, b"fixture, no real credential\n")
                commit = self.commit_index()
                output = self.folder / f"blocked-{index}.zip"
                with self.assertRaisesRegex(ValueError, "Forbidden archive path"):
                    archive_source(self.root, commit, output)
                self.assertFalse(output.exists())
                self.assertFalse(list(self.folder.glob(".source-*.partial")))

    def test_rejects_secret_patterns_without_disclosing_match(self) -> None:
        """模式命中只能报告类别与位置，包括带NUL前缀的对象。"""
        token = b"ghp_" + b"a" * 36
        private_header = b"-----BEGIN " + b"ENCRYPTED PRIVATE KEY-----"
        for index, content in enumerate([token, b"\0" + token, private_header]):
            with self.subTest(index=index):
                self.git(self.root, "read-tree", self.commit)
                self.add_blob("fixture.txt", content)
                commit = self.commit_index()
                output = self.folder / f"secret-{index}.zip"
                with self.assertRaisesRegex(ValueError, "Suspected secret") as failure:
                    archive_source(self.root, commit, output)
                self.assertNotIn(token.decode(), str(failure.exception))
                self.assertNotIn(private_header.decode(), str(failure.exception))
                self.assertFalse(output.exists())
                self.assertFalse(list(self.folder.glob(".source-*.partial")))

    def test_allows_inline_pem_header_documentation_without_key_body(self) -> None:
        """说明表格中的单独头标记没有密钥体，必须正常归档。"""
        header = b"-----BEGIN " + b"PRIVATE KEY-----"
        documentation = (
            b"| APP_STORE_CONNECT_KEY_P8 | The full text of AuthKey_<ID>.p8, `"
            + header
            + b"` ... |\n"
        )
        self.add_blob("docs/ios.md", documentation)
        commit = self.commit_index()
        output = self.folder / "documented-header.zip"
        archive_source(self.root, commit, output)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read("docs/ios.md"), documentation)

    def test_rejects_multiline_pem_blocks_including_binary_prefix(self) -> None:
        """真实格式的多行base64块不能借内联前缀或NUL逃过检查。"""
        encoded = base64.b64encode(b"synthetic fixture bytes, not a private key" * 4)
        body = b"\n".join(
            encoded[index : index + 64] for index in range(0, len(encoded), 64)
        )
        header = b"-----BEGIN " + b"PRIVATE KEY-----"
        footer = b"-----END " + b"PRIVATE KEY-----"
        block = header + b"\n" + body + b"\n" + footer + b"\n"
        for index, prefix in enumerate([b"", b"\0", b"inline payload: "]):
            with self.subTest(prefix=prefix):
                self.git(self.root, "read-tree", self.commit)
                self.add_blob("payload.txt", prefix + block)
                commit = self.commit_index()
                output = self.folder / f"pem-{index}.zip"
                with self.assertRaisesRegex(ValueError, "Suspected secret") as failure:
                    archive_source(self.root, commit, output)
                self.assertNotIn(encoded[:32].decode(), str(failure.exception))
                self.assertFalse(output.exists())
                self.assertFalse(list(self.folder.glob(".source-*.partial")))

    def test_preserves_internal_symlinks_without_following_worktree(self) -> None:
        """提交中的相对链接和内部链接链按链接保存，不读取本机同名文件。"""
        self.add_blob("docs/licence", b"../LICENSE", "120000")
        self.add_blob("licence-link", b"docs/licence", "120000")
        commit = self.commit_index()
        self.write("licence-link", b"this worktree file must not be read")
        output = self.folder / "links.zip"
        archive_source(self.root, commit, output)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read("docs/licence"), b"../LICENSE")
            self.assertTrue(
                stat.S_ISLNK(archive.getinfo("licence-link").external_attr >> 16)
            )

    def test_rejects_escaping_dangling_and_cyclic_symlinks(self) -> None:
        """外部链接、悬空链接和循环不能进入公开归档。"""
        targets = [
            b"../outside",
            b"/outside",
            b"C:/private",
            b"..\\private",
            b"missing",
            b"link",
            b"docs/licence/../../outside",
        ]
        for index, target in enumerate(targets):
            with self.subTest(target=target):
                self.git(self.root, "read-tree", self.commit)
                self.add_blob("link", target, "120000")
                self.add_blob("docs/licence", b"../LICENSE", "120000")
                commit = self.commit_index()
                output = self.folder / f"link-{index}.zip"
                with self.assertRaisesRegex(ValueError, "Unsafe symlink"):
                    archive_source(self.root, commit, output)
                self.assertFalse(output.exists())

    def test_rejects_case_collisions_and_reserved_manifest(self) -> None:
        """跨平台同名路径及覆盖生成清单的路径必须拒绝。"""
        path_pairs = [
            ("Readme", "README"),
            ("Docs/a", "docs/b"),
            ("SOURCE_RELEASE.json", "other"),
            ("source_release.JSON", "other"),
        ]
        for index, paths in enumerate(path_pairs):
            with self.subTest(paths=paths):
                self.git(self.root, "read-tree", self.commit)
                for path in paths:
                    self.add_blob(path, b"fixture")
                commit = self.commit_index()
                with self.assertRaises(ValueError):
                    archive_source(
                        self.root, commit, self.folder / f"collision-{index}.zip"
                    )

    def test_rejects_traversal_from_malformed_git_tree(self) -> None:
        """即使对象库含Git未校验的畸形路径，也不能逃出归档根目录。"""
        tree = (
            self.git(self.root, "rev-parse", self.commit + "^{tree}").decode().strip()
        )
        original = self.git(self.root, "cat-file", "tree", tree)
        oid = self.git(
            self.root, "hash-object", "-w", "--stdin", data=b"fixture"
        ).strip()
        for index, name in enumerate([b"../escape", b"/absolute", b"C:drive", b"CON"]):
            with self.subTest(name=name):
                malformed = (
                    original + b"100644 " + name + b"\0" + bytes.fromhex(oid.decode())
                )
                bad_tree = (
                    self.git(
                        self.root,
                        "hash-object",
                        "-w",
                        "-t",
                        "tree",
                        "--literally",
                        "--stdin",
                        data=malformed,
                    )
                    .decode()
                    .strip()
                )
                commit = (
                    self.git(self.root, "commit-tree", bad_tree, "-m", "unsafe fixture")
                    .decode()
                    .strip()
                )
                with self.assertRaisesRegex(ValueError, "Unsafe archive path"):
                    archive_source(
                        self.root, commit, self.folder / f"unsafe-{index}.zip"
                    )

    def test_identical_commit_has_identical_zip_and_no_overwrite(self) -> None:
        """输出名称不影响字节，同名旧产物不能被静默覆盖。"""
        first, second = self.folder / "one.zip", self.folder / "two.zip"
        first_report = archive_source(self.root, self.commit, first)
        second_report = archive_source(self.root, self.commit, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(first_report["sha256"], second_report["sha256"])
        before = first.read_bytes()
        with self.assertRaisesRegex(ValueError, "overwrite"):
            archive_source(self.root, self.commit, first)
        self.assertEqual(first.read_bytes(), before)

    def test_local_git_replace_cannot_change_committed_bytes(self) -> None:
        """本地replace引用不能把已声明的提交替换成另一份源码。"""
        self.add_blob("LICENSE", b"replacement content")
        replacement = self.commit_index()
        self.git(self.root, "replace", self.commit, replacement)
        output = self.folder / "immutable.zip"
        archive_source(self.root, self.commit, output)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read("LICENSE"), b"fixture licence\n")

    def test_ish_is_explicitly_unexpanded_without_reading_checkout(self) -> None:
        """Android范围记录iSH固定点，不要求读取或下载iOS子模块。"""
        self.git(
            self.root,
            "update-index",
            "--add",
            "--cacheinfo",
            f"160000,{self.proot_commit},android/deps/ish",
        )
        commit = self.commit_index()
        output = self.folder / "scope.zip"
        archive_source(self.root, commit, output)
        with zipfile.ZipFile(output) as archive:
            self.assertFalse(
                any(path.startswith("android/deps/ish/") for path in archive.namelist())
            )
            manifest = json.loads(archive.read("SOURCE_RELEASE.json"))
            ish = next(
                item for item in manifest["submodules"] if item["path"].endswith("/ish")
            )
            self.assertEqual(ish["commit"], self.proot_commit)
            self.assertFalse(ish["expanded"])
            self.assertIn("iSH", " ".join(manifest["limitations"]))
            self.assertIn("Termux", " ".join(manifest["limitations"]))

    def test_requires_full_commit_and_rejects_new_submodule(self) -> None:
        """浮动引用、树对象及未经审查的子模块都不能静默进入发行。"""
        for revision in ["HEAD", self.commit[:12], self.commit + "^{tree}"]:
            with self.subTest(revision=revision), self.assertRaises(ValueError):
                archive_source(self.root, revision, self.folder / "not-created.zip")
        self.git(
            self.root,
            "update-index",
            "--add",
            "--cacheinfo",
            f"160000,{self.proot_commit},unexpected",
        )
        commit = self.commit_index()
        with self.assertRaisesRegex(ValueError, "Unreviewed submodule"):
            archive_source(self.root, commit, self.folder / "new-submodule.zip")


if __name__ == "__main__":
    unittest.main()
