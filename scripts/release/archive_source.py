#!/usr/bin/env python3
"""从明确提交生成移动端对应源码ZIP，不读取工作树文件或下载依赖。

默认保留Android归档范围；iOS模式还展开固定的iSH及其递归子模块。
外部工具链和下载依赖仍需另行准备，本工具不宣称安装包字节复现。
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
MAX_SUBMODULE_DEPTH = 16
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
    # 内联文档可提及头标记；独立头行（含NUL前缀）仍需阻止。
    (
        "private-key",
        re.compile(
            rb"(?:^|\x00)[ \t]*-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----[ \t\r]*$",
            re.MULTILINE,
        ),
    ),
    # 即使头标记前有普通文本，后随多行base64及对应尾标记仍视为密钥块。
    (
        "private-key",
        re.compile(
            rb"-----BEGIN (?P<kind>(?:[A-Z0-9]+ )?PRIVATE KEY)-----[ \t\r]*\n"
            rb"(?:[ \t]*[A-Za-z0-9+/=]+[ \t\r]*\n)+"
            rb"[ \t]*-----END (?P=kind)-----",
        ),
    ),
    ("putty-private-key", re.compile(rb"PuTTY-User-Key-File-[23]:")),
)


# 仅允许已审查的上游固定源码字节，不放开任何日志后缀或build目录。
# libapps b8cacae35e5b11d64bb736a053921c16ca7faf9e：VT测试数据与BSD构建脚本。
# libarchive fc6563f5130d8a7ee1fc27c0e55baef35119f26c：提交中的构建源码与许可证。
REVIEWED_PUBLIC_FILES = {
    ISH_PATH + "/deps/" + relative: digest
    for relative, digest in (
        (
            "libapps/hterm/test_data/charsets.log",
            "009fbdd735339cf516e9452ab52120adede4a5a4cc4a285742747b306ee68ed4",
        ),
        (
            "libapps/hterm/test_data/vttest-01.log",
            "a8c7283e6acc3cf1aabe694be8f15c7781435966d8d014f12b85dfd898ba8d68",
        ),
        (
            "libapps/hterm/test_data/vttest-02.log",
            "21a25b030202600a7e1d064a9d08ea328a0b7e92076f35a80f615fdeb19af770",
        ),
        (
            "libapps/kokoro/build",
            "9546ef8c031ea60d9febdef1be45e69ce527391e640e59adfd1d7c04bb07ecea",
        ),
        (
            "libapps/ssh_client/third_party/bazel-0.17/build",
            "29975cd60d0416d08befe646e8fcce0bd3d1881f3bd567c28995776dbaf0f17b",
        ),
        (
            "libapps/ssh_client/third_party/binaryen/build",
            "8b99bb43ad3dc85905a56edbe92e352c6ac25bd961ece332ceb827712f14f6cd",
        ),
        (
            "libapps/ssh_client/third_party/glibc-compat/build",
            "d1b8ac7d64af116ca3871d90f144a66530247af5fa3195b298d00641b7c55413",
        ),
        (
            "libapps/ssh_client/third_party/gnuconfig/build",
            "58be83c2a0660a8db452a7fc5c516de9a2427aa8492f6c57e62cc751b5b512e0",
        ),
        (
            "libapps/ssh_client/third_party/ldns/build",
            "4407fb0a411e35ac87425feb2ed0946d2c8de63db9c8e9806c8f3b646340ccc6",
        ),
        (
            "libapps/ssh_client/third_party/mandoc/build",
            "bb444677067036300176498c71ddbfa1043884a8518c79ac4c838ef8d9c419cb",
        ),
        (
            "libapps/ssh_client/third_party/mosh-chrome/build",
            "ead559b19bf7857ea8b53fa406c26e9ad2ba262848557fb7c433ddd0ce5e8801",
        ),
        (
            "libapps/ssh_client/third_party/naclsdk/build",
            "53555790850f7530fa1416c95e5f108d2fd2fd0af9367b1a7725f5a2018cc871",
        ),
        (
            "libapps/ssh_client/third_party/openssh-7.8/build",
            "c1b16104cce5656085e907606fc3a7a57f26cc8dd38b91ade7e0429325221ad0",
        ),
        (
            "libapps/ssh_client/third_party/openssh-7.9/build",
            "c1b16104cce5656085e907606fc3a7a57f26cc8dd38b91ade7e0429325221ad0",
        ),
        (
            "libapps/ssh_client/third_party/openssh-8.0/build",
            "e0e1f2022a48701319f74a41e6a2f04a926f7732e6d704cc4e5ce9975b8b29a7",
        ),
        (
            "libapps/ssh_client/third_party/openssh-8.1/build",
            "e0e1f2022a48701319f74a41e6a2f04a926f7732e6d704cc4e5ce9975b8b29a7",
        ),
        (
            "libapps/ssh_client/third_party/openssh-8.2/build",
            "22e02f1bbae7d28b5b98694cd224031a25988c95fbf4288f65061ccd5385c49b",
        ),
        (
            "libapps/ssh_client/third_party/openssh-8.3/build",
            "22e02f1bbae7d28b5b98694cd224031a25988c95fbf4288f65061ccd5385c49b",
        ),
        (
            "libapps/ssh_client/third_party/openssh-8.4/build",
            "f90572fab6bedd808f1e6c233fc072d83dd2eaf6f4188e3a0dd5becda74b98ba",
        ),
        (
            "libapps/ssh_client/third_party/openssl/build",
            "58f9863bd8395ba0168da96a7942cb376029f16a6253624cad5453da8388f197",
        ),
        (
            "libapps/ssh_client/third_party/wabt/build",
            "a0e27a6815a61fdd4bfe32956a55600e01657d23fc634a87a2f113691032ed7c",
        ),
        (
            "libapps/ssh_client/third_party/wasi-sdk/build",
            "dc9189c51e9f342b4220f9685f30f482292c4c65d3af81e0ee51b2ae37395a3f",
        ),
        (
            "libapps/ssh_client/third_party/wasmtime/build",
            "1ad83ae2dbcd37bc2043bfd1c0b9f51be2a1e974d7b5dc8fd1eed2c99f6dfd2a",
        ),
        (
            "libapps/ssh_client/third_party/zlib/build",
            "c67a855c1534c36ed54c96c087b58b6424dca93f35cde024bcdbc59c3999d63d",
        ),
        (
            "libapps/ssh_client/wassh-libc-sup/build",
            "5601a207fb5191d8320bdb4b5ab7c67bb00e37f21132ff30db82244316056150",
        ),
        (
            "libarchive/build/README.txt",
            "a5534d73f814383965808711f1761f9a03f060e32548a78cbee5ba20a85c2e1d",
        ),
        (
            "libarchive/build/autoconf/ax_append_compile_flags.m4",
            "2656ade6869755820f76469efc3bfcfe22b8fc74270ed186a273fc33bb0d5551",
        ),
        (
            "libarchive/build/autoconf/ax_append_flag.m4",
            "bed01218a63fcb69e0a15381ee2dc31ffabbb98db76bc581edada69912c646d8",
        ),
        (
            "libarchive/build/autoconf/ax_check_compile_flag.m4",
            "75f03045fde15ef1e901f17246812fcc751c1a5b070f7f88d482ef336435da87",
        ),
        (
            "libarchive/build/autoconf/ax_require_defined.m4",
            "25e2ea9b1b89e3bf5f5ea205f979e8719b9f37770f0cc0053f23093108b32bce",
        ),
        (
            "libarchive/build/autoconf/check_stdcall_func.m4",
            "aafcf13d9cbee84fc993b2f841472895fdf9b986c5af2985e7730fce240cbd47",
        ),
        (
            "libarchive/build/autoconf/config.rpath",
            "20a1a3c13a3d2b5699ed91af6e889d071e671fc87646f0a363446ae6a8d75f77",
        ),
        (
            "libarchive/build/autoconf/iconv.m4",
            "16bc5a5d8e491491a490d15272c69f39338327a4cb1b58e4f9bbbb2834ec6798",
        ),
        (
            "libarchive/build/autoconf/la_uid_t.m4",
            "39851f4fc1c80c12a620f7bece8de8819889185d833d4862d08069476328b76d",
        ),
        (
            "libarchive/build/autoconf/lib-ld.m4",
            "b2039908bfbcebaaf5196ecc713a071c9c576ce385894c8c0f50d2d3134cbb29",
        ),
        (
            "libarchive/build/autoconf/lib-link.m4",
            "fc77cd337cee5bff4acd760ddabe2cbd63b67c69c39e2ff166998f11619286b0",
        ),
        (
            "libarchive/build/autoconf/lib-prefix.m4",
            "3f5d64b0b167fcb54829d8d0f40aaeacd34408c90e5a51708540b87baeab2c0a",
        ),
        (
            "libarchive/build/autogen.sh",
            "229d5c738239ce1adb8b586a21866081a30518e48f64b86d04532b9ec5ed0dc3",
        ),
        (
            "libarchive/build/bump-version.sh",
            "230401c85e30ae37ccbe7263f84ec98325ce667027c2c98754d67ee13461c791",
        ),
        (
            "libarchive/build/ci/build.sh",
            "f10dd1d10a8a6cd8a6b732e6ed8017e2fce96ca1f85337e53635ad499da8c49e",
        ),
        (
            "libarchive/build/ci/cirrus_ci/Dockerfile.cygwin",
            "d5897211e4176bd6383ee64ff3e7cd5dfa7a6a5312e5e2e3dadaa428d2077dd4",
        ),
        (
            "libarchive/build/ci/cirrus_ci/Dockerfile.fc31",
            "613713bd0fd92f57047940beb715c44cdf881f67eae69406f2ad3b7041753c1c",
        ),
        (
            "libarchive/build/ci/cirrus_ci/Dockerfile.fc31.distcheck",
            "07563a2ec9a5e609363861f941eb8edf613ca76050a1f76c7b7d0f5fb7a9410e",
        ),
        (
            "libarchive/build/ci/cirrus_ci/Dockerfile.mingw",
            "589bb85f4d5c7c500e9bef15b0985793d4bd3fa8761e0f5f40f3e97adaecff72",
        ),
        (
            "libarchive/build/ci/cirrus_ci/Dockerfile.msvc",
            "429e65c0741ecac261398cfa06bbdc6889027871c88e7536e06ec883439debd7",
        ),
        (
            "libarchive/build/ci/cirrus_ci/Dockerfile.windows",
            "86a431d2b41ccd4443ecc63f614a1732d000f6a0d122950f9c050904a20f5208",
        ),
        (
            "libarchive/build/ci/cirrus_ci/ci.cmd",
            "f8e9ee72201741ed8811601ee1e0a4e4080f99755b0ece0f382b8f8d4bfe0f9b",
        ),
        (
            "libarchive/build/ci/cirrus_ci/ci.sh",
            "7a0e2ed57a21eed37c405987d4c4051b093a282d288b33a68d74cff13fbc91f9",
        ),
        (
            "libarchive/build/ci/github_actions/ci.cmd",
            "447eb06592fc2cca25852cf02043ec982f1ca4fa3b6bf4daa120998f4b34b3e6",
        ),
        (
            "libarchive/build/ci/github_actions/macos.sh",
            "295318dd400c6a5f61d76319154902bd62149ddf8304bed1fcbfa01bfa0cb3bb",
        ),
        (
            "libarchive/build/ci/test_driver",
            "1cebd36d55ec3555defeeef936c60738213ff0652e5484424660a8ea23a33362",
        ),
        (
            "libarchive/build/ci/travis_ci.sh",
            "13d68f372cd17d3a6dc2946b10310ddec4524b9384f1c40ee31a9d85574fedef",
        ),
        (
            "libarchive/build/clean.sh",
            "cfd507aa377854ed0b96ce6705edb43af1a8e9499d7adeed0a8976fd4eb077cc",
        ),
        (
            "libarchive/build/cmake/CheckFileOffsetBits.c",
            "88d1eea7d7f4b5876616eaa244e99c29975c1bdda0291f4ae4cc313bd621369b",
        ),
        (
            "libarchive/build/cmake/CheckFileOffsetBits.cmake",
            "b718d9c4be6d19e5573a48a610110b70e8e68e880d939f7a2ffdceef1b373e2d",
        ),
        (
            "libarchive/build/cmake/CheckFuncs.cmake",
            "861a941a11c51a4850d3ad6dd494ed95eaf0bf54f504c9102a6b20a10e8da306",
        ),
        (
            "libarchive/build/cmake/CheckFuncs_stub.c.in",
            "32f18b0b8e4cd29fb70e07d5ad1873f6a930caf3816f3f2cc379eb550460bcf4",
        ),
        (
            "libarchive/build/cmake/CheckHeaderDirent.cmake",
            "12ce2b49ec7052852a849802065c0a9ec04c4aadc33728343fb86a4781a80f33",
        ),
        (
            "libarchive/build/cmake/CheckTypeExists.cmake",
            "0ff6b78e538713e558e009a6ebae3f9dfa1acb8c21cf757bf8f585bb2941f510",
        ),
        (
            "libarchive/build/cmake/CreatePkgConfigFile.cmake",
            "4bc32992bf08cb8d6daa3f7f595aaf6cb63284a596c818c8d099c0ed8a0b878a",
        ),
        (
            "libarchive/build/cmake/FindLibGCC.cmake",
            "ac2329527789a25e8bcb6e72381974679ad2981b259d714efad51e329f0698ec",
        ),
        (
            "libarchive/build/cmake/FindMbedTLS.cmake",
            "9d5384598fa006b6da359f805dd891eb55b4c0b7e6d9a8d81ee889095c532c46",
        ),
        (
            "libarchive/build/cmake/FindNettle.cmake",
            "3180a84ce70b105de00fab38a81f3204658a33431ef66bec6e04aef396ba5438",
        ),
        (
            "libarchive/build/cmake/FindPCREPOSIX.cmake",
            "5c363bcece206d4e86d27e88c1a1e1b0de7fa1bb1fe2f1dbedc8bfc73523b708",
        ),
        (
            "libarchive/build/cmake/LibarchiveCodeCoverage.cmake",
            "a68d52be86a93bc3daeeb330ceae9ccb6e2f146a540588224784e38047c12abe",
        ),
        (
            "libarchive/build/cmake/config.h.in",
            "e2dea4468b12a0ae46f13a17fc48c5cffe1fdf8e1b2021c206b56e5d2376edf8",
        ),
        (
            "libarchive/build/makerelease.sh",
            "aa169063fdafe8fd0452e359caf2a5a31e0f6e3d8f2e884a4e50bf9daaec5119",
        ),
        (
            "libarchive/build/pkgconfig/libarchive.pc.in",
            "2a102b2a8c27b9c0a6a967f6e4d41350d19fbcf73a40d764de68bde01b695609",
        ),
        (
            "libarchive/build/release/Dockerfile",
            "6ffbabefcc2a866088259e4b16a50a974af322b124c6823e158488246621e55c",
        ),
        (
            "libarchive/build/release/release.sh",
            "bc15081e0949230e0fe0bb1f6824628d9bf4bb726ea4526937f124216df9a89c",
        ),
        (
            "libarchive/build/utils/gen_archive_string_composition_h.sh",
            "a523081eb14b692457b8c9f6c6896030d0d3b8f313fdf37154b70ab00bf107fa",
        ),
        (
            "libarchive/build/version",
            "936abae03373cc5058fd31c281ab14c350a1863dfd42bdffef5c35083b577ead",
        ),
    )
}

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
        reviewed_regular = (
            entry.path in REVIEWED_PUBLIC_FILES and entry.mode in ("100644", "100755")
        )
        if forbidden_path(entry.path) and not reviewed_regular:
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


def check_reviewed_source(relative: str, data: bytes) -> None:
    """命中精确路径还不够，原始Git对象字节必须匹配已审查的SHA256。"""
    expected = REVIEWED_PUBLIC_FILES.get(relative)
    if expected is not None and hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"Reviewed public source checksum mismatch: {relative}")


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


def submodule_repository(root: Path, entry: Entry) -> Path:
    """核对独立子仓库及固定对象，禁止Git从空目录回退到父仓库。"""
    checked_path(entry.path)
    if forbidden_path(entry.path):
        raise ValueError(f"Forbidden archive path: {entry.path}")
    repository = (root / entry.path).resolve()
    if not repository.is_relative_to(root):
        raise ValueError("Submodule checkout escapes source root")
    try:
        top = git_object(repository, "rev-parse", "--show-toplevel")
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"Submodule repository is not initialized: {entry.path}") from error
    if Path(os.fsdecode(top).strip()).resolve() != repository:
        raise ValueError(f"Submodule repository is not initialized: {entry.path}")
    try:
        kind = git_object(repository, "cat-file", "-t", entry.oid).strip()
    except subprocess.CalledProcessError as error:
        raise ValueError(
            f"Missing pinned submodule commit: {entry.path}@{entry.oid}"
        ) from error
    if kind != b"commit":
        raise ValueError(f"Pinned submodule object is not a commit: {entry.path}")
    return repository


def is_optional_linux(
    root: Path, source_commit: str, repository: Path, parent_commit: str, entry: Entry
) -> bool:
    """仅跳过固定配置明确排除的备选Linux内核，不泛化忽略其他缺失子模块。"""
    if entry.path != ISH_PATH + "/deps/linux":
        return False
    try:
        update = git_object(
            repository, "config", "--no-includes", "--blob",
            parent_commit + ":.gitmodules", "--get", "submodule.deps/linux.update",
        ).strip()
        script = git_object(root, "show", source_commit + ":android/deps/build_ish.sh")
    except subprocess.CalledProcessError:
        return False
    kernels = re.findall(rb"(?m)^[ \t]*-Dkernel=(\w+)[ \t]*\\?[ \t]*$", script)
    return update == b"none" and kernels == [b"ish"]


def expand_submodule(
    root: Path, entry: Entry, source_commit: str, depth: int = 0
) -> tuple[list[Entry], list[dict]]:
    """递归读取gitlink固定提交，所有叶子仍执行相同路径、链接和秘密校验。"""
    if depth >= MAX_SUBMODULE_DEPTH:
        raise ValueError("Submodule nesting exceeds source archive limit")
    repository = submodule_repository(root, entry)
    entries = []
    submodules = [{"path": entry.path, "commit": entry.oid, "expanded": True}]
    for child in tree_entries(repository, entry.oid, entry.path + "/"):
        if child.mode != "160000":
            entries.append(child)
            continue
        if is_optional_linux(root, source_commit, repository, entry.oid, child):
            submodules.append({
                "path": child.path, "commit": child.oid, "expanded": False,
                "reason": "Committed build uses kernel=ish; pinned Linux alternative has update=none.",
            })
            continue
        nested_entries, nested_submodules = expand_submodule(
            root, child, source_commit, depth + 1
        )
        entries.extend(nested_entries)
        submodules.extend(nested_submodules)
    return entries, submodules


def collect_entries(
    root: Path, commit: str, platform: str = "android"
) -> tuple[list[Entry], list[dict]]:
    """保留Android范围，iOS另按每层固定gitlink递归展开iSH。"""
    entries, submodules = [], []
    for entry in tree_entries(root, commit):
        if entry.mode != "160000":
            entries.append(entry)
            continue
        if entry.path not in (PROOT_PATH, ISH_PATH):
            raise ValueError(f"Unreviewed submodule: {entry.path}")
        if platform in {"ios", "mobile"} and entry.path == ISH_PATH:
            nested_entries, nested_submodules = expand_submodule(root, entry, commit)
            entries.extend(nested_entries)
            submodules.extend(nested_submodules)
            continue
        expanded = entry.path == PROOT_PATH
        submodules.append(
            {"path": entry.path, "commit": entry.oid, "expanded": expanded}
        )
        if expanded:
            repository = submodule_repository(root, entry)
            entries.extend(tree_entries(repository, entry.oid, entry.path + "/"))
    if not any(item["path"] == PROOT_PATH for item in submodules):
        raise ValueError("Pinned proot submodule is required")
    if platform in {"ios", "mobile"} and not any(item["path"] == ISH_PATH for item in submodules):
        raise ValueError("Pinned iSH submodule is required")
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
            check_reviewed_source(entry.path, data)
            check_secrets(entry.path, data)
            if entry.mode == "120000":
                links[entry.path] = link_parts(entry.path, data)
            manifest["files"].append(write_member(archive, entry, data))
        validate_links(entries, links)
        data = (
            json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"
        )
        write_member(archive, Entry(MANIFEST_NAME, "100644", "", Path()), data)


def archive_source(
    root: Path, commit: str, output: Path, platform: str = "android"
) -> dict:
    """从不可变提交生成新ZIP；拒绝覆盖已有输出，不修改源仓库。"""
    if platform not in {"android", "ios", "mobile"}:
        raise ValueError("Unsupported source platform")
    root = root.resolve()
    if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", commit):
        raise ValueError("An explicit full commit SHA is required")
    commit = commit.lower()
    if git_object(root, "cat-file", "-t", commit).strip() != b"commit":
        raise ValueError("Source object must be a commit")
    entries, submodules = collect_entries(root, commit, platform)
    validate_entries(entries)
    manifest = {
        "schemaVersion": 1,
        "status": f"{platform}-release-source",
        "sourceCommit": commit,
        "scope": {"mobile": "Android and iOS corresponding source", "ios": "iOS corresponding source", "android": "Android corresponding source"}[platform],
        "submodules": submodules,
        "files": [],
        "limitations": [
            "External dependencies and Apple toolchains are required; byte-identical IPA reproduction is not verified.",
            "The archive contains committed source only, without signing identities or downloaded build dependencies.",
            "The optional Linux kernel remains pinned but unexpanded only when committed configuration excludes it from the iSH build.",
        ] if platform in {"ios", "mobile"} else [
            "iSH and its nested iOS submodules are not expanded.",
            "Pinned Termux loaders cannot be rebuilt completely from this tree.",
            "External dependencies and toolchains are required; byte-identical APK reproduction is not verified.",
        ],
    }
    if platform == "mobile":
        manifest["limitations"].append("Pinned Termux loaders cannot be rebuilt completely from this tree; byte-identical APK reproduction is not verified.")
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
    parser.add_argument("--platform", choices=("android", "ios", "mobile"), default="android")
    arguments = parser.parse_args()
    try:
        result = archive_source(
            arguments.root, arguments.commit, arguments.output, arguments.platform
        )
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
