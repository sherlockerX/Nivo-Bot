#!/usr/bin/env python3
"""从明确提交生成Android对应源码ZIP，不读取工作树文件或下载依赖。

归档展开提交固定的proot源码，保留其他已提交源码；iSH及其嵌套子模块不展开。
既有Termux loader只有固定二进制，当前树不能完整重建；本工具不宣称APK字节复现。
"""

from __future__ import annotations

import argparse
from collections import deque
from contextlib import ExitStack
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unicodedata
import zipfile

from source_audit import SECRET_PATTERNS, is_forbidden

PROOT_PATH = "android/deps/proot"
ISH_PATH = "android/deps/ish"
MANIFEST_NAME = "SOURCE_RELEASE.json"
ZIP_TIME = (1980, 1, 1, 0, 0, 0)
MAX_BLOB_BYTES = 256 * 1024 * 1024
PRIVATE_PARTS = {"private-signing", ".ssh", ".aws", "notes", ".cxx"}
PRIVATE_SUFFIXES = {".p12", ".pfx", ".pem", ".mobileprovision", ".provisionprofile"}
PRIVATE_NAMES = {
    "signing-credential.xml",
    "credentials.json",
    "credentials.xml",
    "service-account.json",
    "id_rsa",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
}
EXTRA_SECRET_PATTERNS = (
    ("private-key", re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----")),
    ("putty-private-key", re.compile(rb"PuTTY-User-Key-File-[23]:")),
)


@dataclass(frozen=True)
class Entry:
    """一项Git对象及其目标路径，不引用工作树文件。"""

    path: str
    mode: str
    oid: str
    repository: Path


def git_command(root: Path, *arguments: str) -> list[str]:
    """禁用本机replace引用，确保固定SHA始终代表原始对象。"""
    return [
        "git",
        "--no-replace-objects",
        "-c",
        f"safe.directory={root}",
        "-C",
        str(root),
        *arguments,
    ]


def git_object(root: Path, *arguments: str) -> bytes:
    """读取Git元数据，不输出可能含本机路径的错误内容。"""
    return subprocess.run(
        git_command(root, *arguments),
        check=True,
        capture_output=True,
    ).stdout


def checked_path(relative: str) -> None:
    """拒绝目录穿越、Windows别名及跨平台不可安全提取的路径。"""
    if not relative or "\\" in relative or ":" in relative:
        raise ValueError(f"Unsafe archive path: {relative!r}")
    for part in relative.split("/"):
        reserved = part.split(".", 1)[0].upper()
        if (
            part in ("", ".", "..")
            or part.endswith((".", " "))
            or any(ord(character) < 32 for character in part)
            or any(character in '<>"|?*' for character in part)
            or reserved in {"CON", "PRN", "AUX", "NUL"}
            or re.fullmatch(r"(?:COM|LPT)[1-9]", reserved)
        ):
            raise ValueError(f"Unsafe archive path: {relative!r}")


def forbidden_path(relative: str) -> bool:
    """补充本机凭据、内部笔记和运行目录，禁止从提交读取这些内容。"""
    lower = relative.lower()
    parts = lower.split("/")
    if is_forbidden(relative) or any(part in PRIVATE_PARTS for part in parts):
        return True
    if parts[-1] in PRIVATE_NAMES or Path(lower).suffix in PRIVATE_SUFFIXES:
        return True
    return lower.startswith(
        ("site/downloads/", "workspace/", "sessions/", "cloud/data/")
    )


def validate_entries(entries: list[Entry]) -> None:
    """写入前检查完整命名空间，拒绝大小写别名、冲突及不支持的模式。"""
    names = {MANIFEST_NAME.casefold(): MANIFEST_NAME}
    files = {MANIFEST_NAME}
    directories = set()
    for entry in entries:
        checked_path(entry.path)
        if forbidden_path(entry.path):
            raise ValueError(f"Forbidden archive path: {entry.path}")
        if entry.mode not in ("100644", "100755", "120000"):
            raise ValueError(f"Unsupported Git mode at {entry.path}")
        parts = entry.path.split("/")
        for index in range(1, len(parts) + 1):
            prefix = "/".join(parts[:index])
            folded = unicodedata.normalize("NFC", prefix).casefold()
            if folded in names and names[folded] != prefix:
                raise ValueError(f"Case-folded archive collision: {entry.path}")
            names[folded] = prefix
        if entry.path in files or entry.path == MANIFEST_NAME:
            raise ValueError(f"Duplicate archive path: {entry.path}")
        files.add(entry.path)
        directories.update("/".join(parts[:index]) for index in range(1, len(parts)))
    if files & directories:
        raise ValueError("Archive file and directory paths collide")


def check_secrets(relative: str, data: bytes) -> None:
    """仅返回命中类别与行号；二进制也不能靠NUL前缀绕过扫描。"""
    for category, pattern in SECRET_PATTERNS + EXTRA_SECRET_PATTERNS:
        match = pattern.search(data)
        if match is not None:
            line = data.count(b"\n", 0, match.start()) + 1
            raise ValueError(f"Suspected secret: {relative}:{line} ({category})")


def link_parts(path: str, data: bytes) -> list[str]:
    """链接目标只允许相对POSIX路径，不输出目标内容。"""
    try:
        target = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"Unsafe symlink encoding: {path}") from error
    if (
        not target
        or target.startswith("/")
        or "\\" in target
        or ":" in target
        or any(ord(character) < 32 for character in target)
    ):
        raise ValueError(f"Unsafe symlink target: {path}")
    return target.split("/")


def validate_link(
    path: str, links: dict[str, list[str]], directories: set[str], files: set[str]
) -> None:
    """按真实路径顺序展开链接，确保链接链不能利用父目录跳出根目录。"""
    resolved = path.split("/")[:-1]
    pending = deque(links[path])
    expansions = 0
    while pending:
        part = pending.popleft()
        if part in ("", "."):
            continue
        if part == "..":
            if not resolved:
                raise ValueError(f"Unsafe symlink escape: {path}")
            resolved.pop()
            continue
        resolved.append(part)
        current = "/".join(resolved)
        if current in links:
            expansions += 1
            if expansions > 40:
                raise ValueError(f"Unsafe symlink cycle: {path}")
            resolved.pop()
            pending.extendleft(reversed(links[current]))
        elif current not in directories and (pending or current not in files):
            raise ValueError(f"Unsafe symlink missing target: {path}")


def validate_links(entries: list[Entry], links: dict[str, list[str]]) -> None:
    """仅依据归档成员验证链接，不解析主机文件系统中的同名路径。"""
    files = {entry.path for entry in entries}
    directories = {""}
    for path in files:
        parts = path.split("/")
        directories.update("/".join(parts[:index]) for index in range(1, len(parts)))
    for path in links:
        validate_link(path, links, directories, files)


def tree_entries(root: Path, commit: str, prefix: str = "") -> list[Entry]:
    """读取固定提交树，使用NUL分隔避免特殊文件名破坏解析。"""
    entries = []
    for record in git_object(root, "ls-tree", "-r", "-z", commit).split(b"\0"):
        if not record:
            continue
        header, raw_path = record.split(b"\t", 1)
        mode, _, oid = header.decode("ascii").split()
        entries.append(Entry(prefix + raw_path.decode("utf-8"), mode, oid, root))
    return entries


def collect_entries(root: Path, commit: str) -> tuple[list[Entry], list[dict]]:
    """只展开Android必需的proot，其他平台依赖明确记录为未展开。"""
    entries, submodules = [], []
    for entry in tree_entries(root, commit):
        if entry.mode != "160000":
            entries.append(entry)
            continue
        if entry.path not in (PROOT_PATH, ISH_PATH):
            raise ValueError(f"Unreviewed submodule: {entry.path}")
        expanded = entry.path == PROOT_PATH
        submodules.append(
            {"path": entry.path, "commit": entry.oid, "expanded": expanded}
        )
        if expanded:
            repository = (root / entry.path).resolve()
            if not repository.is_relative_to(root):
                raise ValueError("Submodule checkout escapes source root")
            entries.extend(tree_entries(repository, entry.oid, entry.path + "/"))
    if not any(item["path"] == PROOT_PATH for item in submodules):
        raise ValueError("Pinned proot submodule is required")
    return sorted(entries, key=lambda entry: entry.path), submodules


class GitBlobs:
    """通过单个只读Git进程批量读取对象，避免逐文件启动进程。"""

    def __init__(self, root: Path) -> None:
        """保存对象库位置，尚不访问任何工作树文件。"""
        self.root = root

    def __enter__(self) -> GitBlobs:
        """启动仅返回对象内容的cat-file进程。"""
        self.process = subprocess.Popen(
            git_command(self.root, "cat-file", "--batch"),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return self

    def read(self, oid: str) -> bytes:
        """限制对象大小，输出仅用于校验和归档。"""
        self.process.stdin.write(oid.encode("ascii") + b"\n")
        self.process.stdin.flush()
        header = self.process.stdout.readline().split()
        if len(header) != 3 or header[1] != b"blob":
            raise ValueError("Missing Git blob")
        size = int(header[2])
        if not 0 <= size <= MAX_BLOB_BYTES:
            raise ValueError("Git blob exceeds archive size limit")
        data = self.process.stdout.read(size)
        if len(data) != size or self.process.stdout.read(1) != b"\n":
            raise ValueError("Truncated Git blob")
        return data

    def __exit__(self, error_type, error, traceback) -> None:
        """关闭对象进程，不把Git诊断或对象内容写进日志。"""
        if error_type is not None:
            self.process.kill()
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.stderr.close()
        status = self.process.wait()
        if status and error_type is None:
            raise ValueError("Git object reader failed")


def write_member(archive: zipfile.ZipFile, entry: Entry, data: bytes) -> dict:
    """固定时间与权限，记录原始对象内容的校验和。"""
    member = zipfile.ZipInfo(entry.path, ZIP_TIME)
    member.create_system = 3
    mode = "120777" if entry.mode == "120000" else entry.mode
    member.external_attr = int(mode, 8) << 16
    member.compress_type = zipfile.ZIP_DEFLATED
    archive.writestr(member, data, compresslevel=9)
    return {
        "path": entry.path,
        "mode": entry.mode,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def write_archive(temporary: Path, entries: list[Entry], manifest: dict) -> None:
    """只读提交对象，写入临时ZIP后由调用者发布到目标路径。"""
    with ExitStack() as stack:
        archive = stack.enter_context(zipfile.ZipFile(temporary, "w"))
        readers = {}
        links = {}
        for entry in entries:
            if entry.repository not in readers:
                readers[entry.repository] = stack.enter_context(
                    GitBlobs(entry.repository)
                )
            data = readers[entry.repository].read(entry.oid)
            check_secrets(entry.path, data)
            if entry.mode == "120000":
                links[entry.path] = link_parts(entry.path, data)
            manifest["files"].append(write_member(archive, entry, data))
        validate_links(entries, links)
        data = (
            json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"
        )
        write_member(archive, Entry(MANIFEST_NAME, "100644", "", Path()), data)


def archive_source(root: Path, commit: str, output: Path) -> dict:
    """从不可变提交生成新ZIP；拒绝覆盖已有输出，不修改源仓库。"""
    root = root.resolve()
    if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", commit):
        raise ValueError("An explicit full commit SHA is required")
    commit = commit.lower()
    if git_object(root, "cat-file", "-t", commit).strip() != b"commit":
        raise ValueError("Source object must be a commit")
    entries, submodules = collect_entries(root, commit)
    validate_entries(entries)
    manifest = {
        "schemaVersion": 1,
        "status": "android-release-source",
        "sourceCommit": commit,
        "scope": "Android corresponding source",
        "submodules": submodules,
        "files": [],
        "limitations": [
            "iSH and its nested iOS submodules are not expanded.",
            "Pinned Termux loaders cannot be rebuilt completely from this tree.",
            "External dependencies and toolchains are required; byte-identical APK reproduction is not verified.",
        ],
    }
    if output.exists():
        raise ValueError("Refusing to overwrite an existing archive")
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".source-",
        suffix=".partial",
        dir=output.parent,
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        write_archive(temporary, entries, manifest)
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise ValueError("Archive CRC failed")
        # 同目录硬链接以原子方式创建新文件，已有文件不会被替换。
        os.link(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    with output.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {
        "sourceCommit": commit,
        "files": len(entries),
        "size": output.stat().st_size,
        "sha256": digest,
    }


def main() -> None:
    """命令行只接受仓库、明确提交和新输出路径，不处理签名材料。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        result = archive_source(arguments.root, arguments.commit, arguments.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        message = (
            "Git operation failed"
            if isinstance(error, subprocess.CalledProcessError)
            else str(error)
        )
        parser.exit(2, message + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
