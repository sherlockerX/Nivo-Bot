#!/usr/bin/env python3
"""从标签内的官网清单校验实际发行平台与源码，再创建或补全GitHub移动端发行。"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote
from urllib.request import HTTPRedirectHandler, Request, build_opener

REPOSITORY = "sherlockerX/Nivo-Bot"
ORIGIN = "https://nivo.8666886.xyz/downloads/"
LEGACY_ANDROID_PACKAGE_ID = "io.github.nanomuse.app"
ANDROID_PACKAGE_ID = "io.github.sherlockerx.nelan"
ANDROID_PACKAGE_SWITCH_VERSION = (2, 0, 9)
IOS_BUNDLE_ID = "io.github.nanomuse.app"
MAX_SIZE = 2 * 1024 * 1024 * 1024


@dataclass(frozen=True)
class Artifact:
    """一份文件的固定下载地址与发布前必须匹配的身份。"""

    name: str
    url: str
    sha256: str
    size: int


@dataclass(frozen=True)
class ReleasePlan:
    """只包含当前标签的发布说明、构建身份及实际平台与源码附件。"""

    tag: str
    version: str
    code: int
    title: str
    notes: Path
    artifacts: tuple[Artifact, ...]


def one_match(pattern: str, text: str) -> str:
    """版本源必须恰好声明一次，避免静默选择重复常量。"""
    values = re.findall(pattern, text, re.M)
    if len(values) != 1:
        raise ValueError(f"Expected one version declaration: {pattern}")
    return values[0]


def artifact(name: str, url: object, digest: object, size: object) -> Artifact:
    """精确固定URL，拒绝端口、凭据、查询、片段、转义路径和其他域名。"""
    if url != ORIGIN + name:
        raise ValueError(f"Unexpected download URL for {name}")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
        raise ValueError(f"Missing or invalid SHA256 for {name}")
    if type(size) is not int or not 0 < size <= MAX_SIZE:
        raise ValueError(f"Missing or invalid size for {name}")
    return Artifact(name, str(url), digest.lower(), size)


def mobile_artifact(tag: str, suffix: str, url: object, digest: object, size: object) -> Artifact:
    """仅接受新旧品牌的完整固定地址，继续共用哈希与大小校验。"""
    for prefix in ("Nelan", "Nivo-Bot"):
        name = f"{prefix}-{tag}-{suffix}"
        if url == ORIGIN + name:
            return artifact(name, url, digest, size)
    raise ValueError(f"Unexpected download URL for {tag}-{suffix}")


def release_artifacts(selected: list[dict], tag: str, code: int) -> tuple[Artifact, ...]:
    """当前实际发行的平台必须共享一份源码，并符合各自分发约束。"""
    artifacts = []
    sources = []
    for row in sorted(selected, key=lambda item: item["platform"]):
        platform = row["platform"]
        if type(row.get("versionCode")) is not int or row["versionCode"] != code:
            raise ValueError(f"Build code mismatch: {platform}")
        distribution = "apk" if platform == "android" else "ipa"
        if row.get("channel") != "stable" or row.get("distribution") != distribution:
            raise ValueError(f"Unexpected release channel or distribution: {platform}")
        if platform == "ios" and row.get("signing") != "unsigned":
            raise ValueError("Expected an explicitly unsigned iOS IPA")
        suffix = "arm64.apk" if platform == "android" else "unsigned.ipa"
        artifacts.append(
            mobile_artifact(
                tag,
                suffix,
                row.get("downloadUrl"),
                row.get("sha256"),
                row.get("sizeBytes"),
            )
        )
        sources.append(
            mobile_artifact(
                tag,
                "source.zip",
                row.get("sourceUrl"),
                row.get("sourceSha256"),
                row.get("sourceSizeBytes"),
            )
        )
    if any(source != sources[0] for source in sources[1:]):
        raise ValueError("Platform source archive identities disagree")
    return tuple(artifacts + [sources[0]])


def load_plan(root: Path, tag: str) -> ReleasePlan:
    """读取检出标签内的版本与清单，历史版本既不修改也不要求新增字段。"""
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError("Expected a stable version tag vX.Y.Z")
    version = tag[1:]
    rebrand = (root / "scripts/rebrand.py").read_text(encoding="utf-8")
    if one_match(r'^VERSION_NAME = "([^"]+)"$', rebrand) != version:
        raise ValueError("Tag and rebrand.VERSION_NAME disagree")
    code = int(one_match(r"^VERSION_CODE = (\d+)$", rebrand))
    catalogue = json.loads((root / "site/releases.json").read_text(encoding="utf-8"))
    if catalogue.get("schemaVersion") != 2:
        raise ValueError("Expected release catalogue schema 2")
    selected = [row for row in catalogue.get("releases", []) if row.get("version") == version]
    platforms = [row.get("platform") for row in selected]
    if (
        not platforms
        or any(platform not in ("android", "ios") for platform in platforms)
        or len(set(platforms)) != len(platforms)
    ):
        raise ValueError("Expected one or both supported platforms without duplicates")
    artifacts = release_artifacts(selected, tag, code)
    notes = root / "docs/releases" / f"{tag}.md"
    lines = notes.read_text(encoding="utf-8").splitlines()
    title = lines[0].removeprefix("# ") if lines else ""
    brands = "|".join(re.escape(name) for name in ("Nivo Bot", "念步", "Nelan"))
    if not re.fullmatch(rf"(?:{brands}) {re.escape(version)} · [A-Z][A-Za-z]+", title):
        raise ValueError("Release notes heading does not match the tag")
    return ReleasePlan(tag, version, code, title, notes, artifacts)


class NoRedirect(HTTPRedirectHandler):
    """下载不跟随重定向，域名限制在整个请求期间保持有效。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        """任何重定向均要求先修正官网文件，不能隐式更换下载源。"""
        raise ValueError("Release downloads must not redirect")


def verify_file(path: Path, expected: Artifact) -> None:
    """重新检查实际落盘字节，供下载与既有附件比较共用。"""
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if path.stat().st_size != expected.size or digest != expected.sha256:
        raise ValueError(f"Size or SHA256 mismatch: {expected.name}")


def download(expected: Artifact, destination: Path) -> None:
    """流式下载并限制总大小，不覆盖当前运行已存在的文件。"""
    request = Request(
        expected.url, headers={"User-Agent": "Nivo-release", "Accept-Encoding": "identity"}
    )
    total = 0
    with (
        build_opener(NoRedirect()).open(request, timeout=60) as response,
        destination.open("xb") as output,
    ):
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > expected.size:
                raise ValueError(f"Download exceeds declared size: {expected.name}")
            output.write(chunk)
    verify_file(destination, expected)


def run(arguments: list[str]) -> str:
    """执行参数数组，命令失败时停止后续发布步骤。"""
    result = subprocess.run(arguments, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def verify_checkout(root: Path, tag: str, commit: str) -> None:
    """远端标签、检出提交与事件提交必须一致，拒绝移动过的标签。"""
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid GitHub event commit")
    head = run(["git", "-C", str(root), "rev-parse", "HEAD"])
    tagged = run(["git", "-C", str(root), "rev-parse", f"refs/tags/{tag}^{{commit}}"])
    remote = run(["gh", "api", f"repos/{REPOSITORY}/commits/{tag}", "--jq", ".sha"])
    if {head, tagged, remote} != {commit}:
        raise ValueError("Checkout, local tag, remote tag and event commit disagree")


def verify_apk(path: Path, plan: ReleasePlan, aapt: str) -> None:
    """读取APK真实包名、版本和构建号，拒绝测试包或旧安装包。"""
    output = run([aapt, "dump", "badging", str(path)])
    match = re.search(
        r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", output, re.M
    )
    # Android从2.0.9建立独立安装身份，不能因文件名换品牌而接受其他版本的包名。
    version_parts = tuple(int(part) for part in plan.version.split("."))
    package_id = (
        ANDROID_PACKAGE_ID
        if version_parts >= ANDROID_PACKAGE_SWITCH_VERSION
        else LEGACY_ANDROID_PACKAGE_ID
    )
    if not match or match.groups() != (package_id, str(plan.code), plan.version):
        raise ValueError("APK package, version or build code mismatch")


def verify_ipa(path: Path, plan: ReleasePlan) -> None:
    """只读主应用Info.plist，不解压或执行IPA内容。"""
    with zipfile.ZipFile(path) as archive:
        candidates = [
            name
            for name in archive.namelist()
            if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)
        ]
        if len(candidates) != 1 or archive.getinfo(candidates[0]).file_size > 1024 * 1024:
            raise ValueError("Expected one bounded main-app Info.plist in IPA")
        info = plistlib.loads(archive.read(candidates[0]))
    actual = (
        info.get("CFBundleIdentifier"),
        info.get("CFBundleShortVersionString"),
        info.get("CFBundleVersion"),
    )
    if actual != (IOS_BUNDLE_ID, plan.version, str(plan.code)):
        raise ValueError("IPA bundle, version or build code mismatch")


def verify_packages(folder: Path, plan: ReleasePlan) -> None:
    """按已校验文件名选择实际平台，只有包含APK才要求Android校验工具。"""
    for item in plan.artifacts:
        if item.name.endswith(".apk"):
            android_home = os.environ.get("ANDROID_HOME")
            tools = (
                sorted((Path(android_home) / "build-tools").glob("*/aapt")) if android_home else []
            )
            if not tools:
                raise ValueError("Android SDK aapt is required to verify the APK")
            verify_apk(folder / item.name, plan, str(tools[-1]))
        elif item.name.endswith(".ipa"):
            verify_ipa(folder / item.name, plan)


def get_release(tag: str) -> dict | None:
    """读取正式发行，404时分页寻找隐藏的草稿，其他错误必须中止。"""
    result = subprocess.run(
        ["gh", "api", f"repos/{REPOSITORY}/releases/tags/{tag}"], capture_output=True, text=True
    )
    if result.returncode == 0:
        return json.loads(result.stdout)
    if "(HTTP 404)" in result.stderr:
        pages = json.loads(
            run(
                [
                    "gh",
                    "api",
                    f"repos/{REPOSITORY}/releases?per_page=100",
                    "--paginate",
                    "--slurp",
                ]
            )
        )
        if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
            raise ValueError("GitHub release list has an invalid shape")
        releases = [
            release
            for page in pages
            for release in page
            if isinstance(release, dict) and release.get("tag_name") == tag
        ]
        if len(releases) > 1:
            raise ValueError(f"Multiple GitHub releases use tag {tag}")
        return releases[0] if releases else None
    raise RuntimeError(f"Cannot inspect existing release: {result.stderr.strip()}")


def verify_release_target(release: dict, commit: str) -> None:
    """校验现有Release目标，兼容SHA和合法分支名但不接受错误提交。"""
    target = release.get("target_commitish")
    if not isinstance(target, str) or not target:
        raise ValueError("Existing release has no target commit")
    if re.fullmatch(r"[0-9a-f]{40}", target):
        if target != commit:
            raise ValueError("Existing release target commit differs")
        return
    resolved = run(
        [
            "gh",
            "api",
            f"repos/{REPOSITORY}/commits/{quote(target, safe='')}",
            "--jq",
            ".sha",
        ]
    )
    if resolved != commit:
        raise ValueError("Existing release branch target resolves to a different commit")


def missing_artifacts(plan: ReleasePlan, commit: str, release: dict) -> list[Artifact]:
    """先核对所有已有内容，再决定能否补传，任何差异均拒绝覆盖。"""
    if release.get("tag_name") != plan.tag:
        raise ValueError("Existing release tag differs")
    verify_release_target(release, commit)
    if release.get("draft") is not False and release.get("draft") is not True:
        raise ValueError("Existing release draft state is invalid")
    if release.get("prerelease") is not False:
        raise ValueError("Existing release is not a stable release")
    assets = release.get("assets", [])
    existing = {item["name"]: item for item in assets}
    expected = {item.name: item for item in plan.artifacts}
    if len(existing) != len(assets) or set(existing) - set(expected):
        raise ValueError("Existing release contains unexpected or duplicate assets")
    for name, uploaded in existing.items():
        item = expected[name]
        if uploaded.get("state") != "uploaded" or uploaded.get("size") != item.size:
            raise ValueError(f"Existing asset state or size differs: {name}")
        digest = uploaded.get("digest")
        if digest is None:
            with tempfile.TemporaryDirectory() as folder:
                run(
                    [
                        "gh",
                        "release",
                        "download",
                        plan.tag,
                        "--repo",
                        REPOSITORY,
                        "--pattern",
                        name,
                        "--dir",
                        folder,
                    ]
                )
                verify_file(Path(folder) / name, item)
        elif digest != "sha256:" + item.sha256:
            raise ValueError(f"Existing asset SHA256 differs: {name}")
    return [item for item in plan.artifacts if item.name not in existing]


def publish(plan: ReleasePlan, commit: str, folder: Path, release: dict | None) -> None:
    """一次创建并附文件；重跑只补缺失内容，永不使用clobber。"""
    if release is None:
        run(
            [
                "gh",
                "release",
                "create",
                plan.tag,
                *[str(folder / item.name) for item in plan.artifacts],
                "--repo",
                REPOSITORY,
                "--verify-tag",
                "--target",
                commit,
                "--title",
                plan.title,
                "--notes-file",
                str(plan.notes),
                "--latest",
            ]
        )
        return
    was_draft = release.get("draft") is True
    missing = missing_artifacts(plan, commit, release)
    if was_draft and (type(release.get("id")) is not int or release["id"] <= 0):
        raise ValueError("Existing draft has no valid release ID")
    if missing:
        run(
            [
                "gh",
                "release",
                "upload",
                plan.tag,
                *[str(folder / item.name) for item in missing],
                "--repo",
                REPOSITORY,
            ]
        )
    if was_draft:
        publish_draft(plan, commit, release["id"])
    elif not missing:
        print(f"Release and all {len(plan.artifacts)} assets already match; nothing changed")


def publish_draft(plan: ReleasePlan, commit: str, release_id: int) -> None:
    """草稿补全后重读身份与附件，验证完整才转为正式发行。"""
    refreshed = get_release(plan.tag)
    if refreshed is None or refreshed.get("id") != release_id:
        raise ValueError("Existing draft changed or disappeared during upload")
    if missing_artifacts(plan, commit, refreshed):
        raise ValueError("Existing draft is still missing verified assets")
    if refreshed.get("draft") is True:
        run(
            [
                "gh",
                "release",
                "edit",
                plan.tag,
                "--repo",
                REPOSITORY,
                "--draft=false",
                "--latest",
            ]
        )


def main() -> None:
    """仅正式仓库的标签工作流能够使用GITHUB_TOKEN发布。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    if (
        os.environ.get("GITHUB_REPOSITORY") != REPOSITORY
        or os.environ.get("GITHUB_EVENT_NAME") != "push"
    ):
        raise ValueError("Publishing is restricted to this repository's push workflow")
    if os.environ.get("GITHUB_REF") != "refs/tags/" + args.tag:
        raise ValueError("GitHub event does not match the requested tag")
    root = Path(__file__).resolve().parents[2]
    plan = load_plan(root, args.tag)
    commit = os.environ.get("GITHUB_SHA", "")
    verify_checkout(root, args.tag, commit)
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        for item in plan.artifacts:
            download(item, folder / item.name)
            print(f"Verified {item.name}: {item.size} bytes, SHA256 {item.sha256}")
        verify_packages(folder, plan)
        verify_checkout(root, args.tag, commit)
        publish(plan, commit, folder, get_release(plan.tag))
        completed = get_release(plan.tag)
        if completed is None or completed.get("draft") is not False:
            raise ValueError("Release is still unpublished; retry the same workflow")
        if missing_artifacts(plan, commit, completed):
            raise ValueError("Release upload incomplete; retry the same workflow")
    print(f"Published {REPOSITORY} {plan.tag} with {len(plan.artifacts)} verified assets")


if __name__ == "__main__":
    main()
