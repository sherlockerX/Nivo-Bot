#!/usr/bin/env python3
"""核对CI的APK身份和签名，输出下载包、SHA256与可追溯的构建信息。"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run_tool(command: list[str]) -> subprocess.CompletedProcess[str]:
    """执行不含秘密的Android校验命令并保留失败诊断。"""
    return subprocess.run(command, capture_output=True, text=True, check=False)


def apk_identity(badging: str) -> dict[str, str | list[str]]:
    """读取aapt提供的实际包名、版本和原生架构。"""
    match = re.search(
        r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging, re.M
    )
    native = re.search(r"^native-code: (.+)$", badging, re.M)
    if not match or not native:
        raise ValueError("APK package metadata or native ABI is missing")
    return {
        "package": match[1],
        "versionCode": match[2],
        "versionName": match[3],
        "abis": re.findall(r"'([^']+)'", native[1]),
    }


def has_signature(apk: Path) -> bool:
    """检查v1证书与v2/v3签名块，防止错误签名包被标为未签名。"""
    with zipfile.ZipFile(apk) as archive:
        if any(
            re.match(r"META-INF/[^/]+\.(RSA|DSA|EC)$", name, re.I) for name in archive.namelist()
        ):
            return True
    with apk.open("rb") as stream:
        tail_size = min(apk.stat().st_size, 65557)
        stream.seek(-tail_size, 2)
        tail = stream.read()
        end = tail.rfind(b"PK\x05\x06")
        if end < 0:
            raise ValueError("APK ZIP end record missing")
        directory_offset = struct.unpack_from("<I", tail, end + 16)[0]
        if directory_offset < 16:
            return False
        stream.seek(directory_offset - 16)
        return stream.read(16) == b"APK Sig Block 42"


def verify_signature(apk: Path, signer: Path, signed: bool) -> str:
    """有签名必须完整验证，未签名必须同时没有签名块与v1证书。"""
    result = run_tool([str(signer), "verify", "--verbose", "--print-certs", str(apk)])
    output = result.stdout + result.stderr
    if signed and result.returncode != 0:
        raise ValueError(f"APK signature verification failed: {apk.name}\n{output}")
    if not signed and (result.returncode == 0 or has_signature(apk)):
        raise ValueError("Unsigned release unexpectedly contains a signature")
    if not signed and not any(
        text in output for text in ("DOES NOT VERIFY", "Missing META-INF/MANIFEST.MF")
    ):
        raise ValueError(f"Unexpected unsigned-APK verifier failure:\n{output}")
    return output


def test_counts(folder: Path) -> dict[str, int]:
    """汇总JUnit结果，避免把仅编译测试源码描述成执行测试。"""
    counts = dict.fromkeys(("tests", "failures", "errors", "skipped"), 0)
    for report in folder.glob("TEST-*.xml"):
        suite = ET.parse(report).getroot()
        for key in counts:
            counts[key] += int(suite.get(key, "0"))
    if counts["tests"] == 0 or counts["failures"] or counts["errors"]:
        raise ValueError(f"Expected passing unit test results, received {counts}")
    return counts


def main() -> None:
    """验证实际APK并生成不包含签名私钥的下载目录和任务摘要。"""
    app = ROOT / "android/src/android/app"
    tools = Path(os.environ["ANDROID_HOME"]) / "build-tools" / os.environ["BUILD_TOOLS_VERSION"]
    output = ROOT / "build/ci-android"
    output.mkdir(parents=True, exist_ok=True)
    expected_signed = os.environ.get("SIGNED_RELEASE") == "true"
    packages = []
    for variant, signed in (("debug", True), ("release", expected_signed)):
        candidates = list((app / f"build/outputs/apk/{variant}").glob("*.apk"))
        if len(candidates) != 1:
            raise ValueError(f"Expected one {variant} APK, found {len(candidates)}")
        source = candidates[0]
        result = run_tool([str(tools / "aapt"), "dump", "badging", str(source)])
        if result.returncode:
            raise ValueError(result.stderr)
        identity = apk_identity(result.stdout)
        expected_package = "io.github.nanomuse.app" + (".uitest" if variant == "debug" else "")
        if identity["package"] != expected_package or identity["abis"] != ["arm64-v8a"]:
            raise ValueError(f"Unexpected APK identity: {identity}")
        signature = verify_signature(source, tools / "apksigner", signed)
        signing = (
            "debug-signed" if variant == "debug" else "release-signed" if signed else "unsigned"
        )
        filename = f"Nivo-{identity['versionName']}-{identity['versionCode']}-arm64-{signing}.apk"
        target = output / filename
        shutil.copyfile(source, target)
        with target.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        (output / f"{filename}.signature.txt").write_text(signature, encoding="utf-8")
        packages.append({**identity, "file": filename, "sha256": digest, "signing": signing})
    if any(packages[0][key] != packages[1][key] for key in ("versionName", "versionCode")):
        raise ValueError("Debug and Release version mismatch")
    counts = test_counts(app / "build/test-results/testDebugUnitTest")
    metadata = {
        "commit": os.environ.get("GITHUB_SHA"),
        "run": f"{os.environ.get('GITHUB_SERVER_URL')}/{os.environ.get('GITHUB_REPOSITORY')}/actions/runs/{os.environ.get('GITHUB_RUN_ID')}",
        "packages": packages,
        "unitTests": counts,
        "deviceTests": "Instrumentation sources compiled; no emulator or physical device tests run.",
    }
    (output / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    checksums = "".join(f"{item['sha256']}  {item['file']}\n" for item in packages)
    (output / "SHA256SUMS").write_text(checksums, encoding="ascii")
    summary = "## Nivo Android APK\n\n"
    summary += f"Commit: `{metadata['commit']}`\n\n"
    summary += "|APK|Package|Signing|\n|---|---|---|\n"
    summary += "".join(
        f"|{item['file']}|`{item['package']}`|{item['signing']}|\n" for item in packages
    )
    summary += f"\nUnit tests: {counts}.\n\n"
    summary += "Debug uses a separate .uitest application ID. Unsigned Release APKs require local signing before installation.\n\n"
    summary += "Instrumentation sources compiled. No emulator or physical device tests were run.\n"
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as stream:
            stream.write(summary)
    print(summary)


if __name__ == "__main__":
    main()
