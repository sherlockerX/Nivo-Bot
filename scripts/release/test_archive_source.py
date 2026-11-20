"""用临时Git对象验证正式源码归档，不访问项目的运行文件。"""

from __future__ import annotations

import hashlib
import base64
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
import zipfile

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
