"""校验多页产品站、静态资源和跨平台版本清单，阻止失效链接与伪下载。"""

from __future__ import annotations

import argparse
import json
import re
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urljoin, urlparse

CORE_FILES = {
    "index.html",
    "features.html",
    "models.html",
    "downloads.html",
    "developers.html",
    "privacy.html",
    "product.css",
    "product.js",
    "release.json",
    "releases.json",
    "brand-mark.svg",
    "sitemap.xml",
    "robots.txt",
}
SUFFIXES = {".html", ".css", ".js", ".json", ".svg", ".png", ".webp", ".xml", ".txt"}
VERIFICATION_FILES = {"google29070eb2e5de147a.html"}
SITE_ORIGIN = "https://nivo.8666886.xyz/"


def site_files(root: Path) -> list[str]:
    """只接受生成器明确列出的安全站内文件，不递归发布旧站与私有文件。"""
    manifest = json.loads((root / "site-manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1 or not isinstance(manifest.get("files"), list):
        raise ValueError("Invalid site manifest")
    files = manifest["files"]
    if len(files) != len(set(files)) or not CORE_FILES.issubset(files):
        raise ValueError("Site manifest duplicates or misses core files")
    for name in files:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name:
            raise ValueError("Unsafe site path")
        if path.suffix not in SUFFIXES or any(part.startswith(".") for part in path.parts):
            raise ValueError("Unexpected site file")
        if not (root / name).resolve().is_relative_to(root.resolve()):
            raise ValueError("Site file escapes source root")
    return files


def srcset_urls(value: str) -> list[str]:
    """提取本站逗号分隔候选的URL，不解析描述符或含未转义逗号的URL完整语法。"""
    urls = []
    for candidate in value.split(","):
        fields = candidate.split()
        if fields:
            urls.append(fields[0])
    return urls


class Page(HTMLParser):
    """收集独立页面的标识和资源，检查基本语义。"""

    def __init__(self) -> None:
        """初始化单页检查状态。"""
        super().__init__()
        self.ids: set[str] = set()
        self.links: list[str] = []
        self.preview_images: list[str] = []
        self.errors: list[str] = []
        self.headings = 0

    def handle_starttag(self, tag: str, attributes: list[tuple[str, str | None]]) -> None:
        """检查重复ID、图像替代文字和外链安全属性。"""
        attrs = dict(attributes)
        if attrs.get("id"):
            if attrs["id"] in self.ids:
                self.errors.append(f"Duplicate ID: {attrs['id']}")
            self.ids.add(attrs["id"])
        self.links.extend(attrs[key] for key in ("src", "href") if attrs.get(key))
        if tag in {"img", "source"} and attrs.get("srcset"):
            self.links.extend(srcset_urls(attrs["srcset"]))
        if tag == "meta" and (attrs.get("property") or "").lower() in {
            "og:image",
            "og:image:url",
            "og:image:secure_url",
        }:
            if (attrs.get("content") or "").strip():
                self.preview_images.append(attrs["content"].strip())
            else:
                self.errors.append("Open Graph image missing URL")
        if tag == "h1":
            self.headings += 1
        if tag == "img" and "alt" not in attrs:
            self.errors.append("Image missing alt")
        if attrs.get("target") == "_blank" and "noopener" not in attrs.get("rel", ""):
            self.errors.append("External window missing noopener")


def preview_image_errors(root: Path, name: str, images: list[str], files: list[str]) -> list[str]:
    """把同源绝对OG地址映射回发布根目录，查询参数不影响文件和白名单检查。"""
    errors = []
    for value in images:
        try:
            parsed = urlparse(urljoin(urljoin(SITE_ORIGIN, name), value))
            is_local = (
                parsed.scheme == "https"
                and parsed.hostname == "nivo.8666886.xyz"
                and parsed.port in {None, 443}
            )
        except ValueError:
            errors.append(f"{name}: Invalid Open Graph image URL: {value}")
            continue
        if not is_local:
            continue
        # 先解码再检查边界，拒绝编码后的父目录或Windows路径逃逸。
        target = (root / unquote(parsed.path).lstrip("/")).resolve()
        if not target.is_relative_to(root.resolve()) or not target.is_file():
            errors.append(f"{name}: Missing local Open Graph image: {value}")
        elif target.relative_to(root.resolve()).as_posix() not in files:
            errors.append(f"{name}: Open Graph image excluded from deployment: {value}")
    return errors


def migration_errors(release: dict) -> list[str]:
    """独立应用迁移只适用于带明确包名的Android APK记录。"""
    errors = []
    package_id = release.get("packageId")
    has_valid_package = isinstance(package_id, str) and bool(
        re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+", package_id)
    )
    is_android_apk = (
        release.get("platform") == "android" and release.get("distribution", "apk") == "apk"
    )
    if "packageId" in release and (not has_valid_package or not is_android_apk):
        errors.append("Android package ID requires a valid APK identity")
    if "migration" in release and (
        release["migration"] != "backup-restore" or not has_valid_package or not is_android_apk
    ):
        errors.append("Backup-restore migration requires an Android APK package ID")
    return errors


def validate_releases(data: dict) -> list[str]:
    """支持APK、IPA和官方商店入口，尚未发布的平台不得伪造发行记录。"""
    errors = []
    if data.get("schemaVersion") != 2:
        return ["Invalid release catalogue schema"]
    platforms = {p["id"]: p for p in data.get("platforms", [])}
    ids = set()
    for release in data.get("releases", []):
        errors.extend(migration_errors(release))
        if not release.get("id") or release["id"] in ids:
            errors.append("Duplicate or missing release ID")
        ids.add(release.get("id"))
        if "productName" in release and (
            not isinstance(release["productName"], str) or not release["productName"].strip()
        ):
            errors.append("Release product name must be a non-empty string")
        platform = platforms.get(release.get("platform"))
        if not platform or platform.get("status") != "available":
            errors.append("Release exists on an unavailable platform")
        if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", release.get("version", "")):
            errors.append("Invalid release version")
        if release.get("channel") not in {"stable", "beta"}:
            errors.append("Invalid release channel")
        for key in ("downloadUrl", "sourceUrl"):
            parsed = urlparse(release.get(key, ""))
            if parsed.scheme != "https" or not parsed.netloc:
                errors.append(f"Release requires HTTPS {key}")
        kind = release.get("distribution", "apk")
        if "checksumsUrl" in release:
            expected = f"{SITE_ORIGIN}downloads/SHA256SUMS-v{release.get('version')}.txt"
            if release["checksumsUrl"] != expected or kind not in {"apk", "ipa"}:
                errors.append("Checksum file must belong to this binary release")
        if kind not in {"apk", "ipa", "app-store", "testflight"}:
            errors.append("Invalid distribution method")
        if kind == "ipa" and release.get("signing") not in {"signed", "unsigned"}:
            errors.append("IPA release requires signing status")
        if release.get("signing") == "unsigned" and (
            kind != "ipa" or release.get("platform") != "ios"
        ):
            errors.append("Unsigned release must be an iOS IPA")
        if kind in {"apk", "ipa"}:
            if not re.fullmatch("[a-fA-F0-9]{64}", release.get("sha256", "")):
                errors.append("Binary release requires SHA256")
            if not isinstance(release.get("sizeBytes"), int) or release["sizeBytes"] <= 0:
                errors.append("Binary release requires file size")
        notes = PurePosixPath(release.get("notesUrl", ""))
        if notes.is_absolute() or ".." in notes.parts or notes.suffix != ".html":
            errors.append("Release notes must be a local HTML page")
    return errors


def check(root: Path, allow_local: bool = False) -> dict:
    """检查全部页、资源、锚点和公开下载元数据。"""
    errors = []
    try:
        files = site_files(root)
    except (ValueError, OSError) as failure:
        return {"passed": False, "errors": [str(failure)], "pages": 0}
    errors.extend(f"Missing file: {name}" for name in files if not (root / name).is_file())
    pages = {}
    for name in files:
        if name in VERIFICATION_FILES:
            expected = ("google-site-verification: " + name).encode()
            if (root / name).read_bytes() != expected:
                errors.append("Google verification file was changed")
            continue
        if not name.endswith(".html") or not (root / name).is_file():
            continue
        parser = Page()
        parser.feed((root / name).read_text(encoding="utf-8"))
        pages[name] = parser
        errors.extend(f"{name}: {error}" for error in parser.errors)
        if parser.headings != 1:
            errors.append(f"{name}: Expected exactly one h1")
    for name, page in pages.items():
        errors.extend(preview_image_errors(root, name, page.preview_images, files))
        for value in page.links:
            parsed = urlparse(value)
            if parsed.scheme:
                if parsed.scheme not in {"https", "http", "mailto"}:
                    errors.append(f"{name}: Invalid scheme")
                continue
            target = (root / name).parent / unquote(parsed.path) if parsed.path else root / name
            target = target.resolve()
            if not target.is_relative_to(root.resolve()) or not target.is_file():
                errors.append(f"{name}: Missing local target: {value}")
                continue
            relative = target.relative_to(root.resolve()).as_posix()
            if relative not in files:
                errors.append(f"{name}: Target excluded from deployment: {value}")
            if parsed.fragment and relative in pages and parsed.fragment not in pages[relative].ids:
                errors.append(f"{name}: Missing anchor: {value}")
    catalogue = json.loads((root / "releases.json").read_text(encoding="utf-8"))
    homepage = (root / "index.html").read_text(encoding="utf-8")
    if 'name="google-site-verification"' not in homepage:
        errors.append("Homepage is missing Google Search Console verification")
    if 'name="msvalidate.01" content="1BD387A09BAFE629130E03EFB5265857"' not in homepage:
        errors.append("Homepage is missing Bing Webmaster Tools verification")
    if '"@type":"SoftwareApplication"' not in homepage:
        errors.append("Homepage is missing SoftwareApplication structured data")
    if '"operatingSystem":"Android 8.0 and later"' not in homepage:
        errors.append("SoftwareApplication operating system is inaccurate")
    if "<lastmod>" not in (root / "sitemap.xml").read_text(encoding="utf-8"):
        errors.append("Sitemap is missing lastmod dates")
    errors.extend(validate_releases(catalogue))
    for release in catalogue.get("releases", []):
        if release.get("notesUrl") not in pages:
            errors.append("Release notes page is missing")
    legacy = json.loads((root / "release.json").read_text(encoding="utf-8"))
    if legacy.get("channel") == "local-preview" and not allow_local:
        errors.append("Local preview cannot be published")
    android = [r for r in catalogue.get("releases", []) if r.get("platform") == "android"]
    if android and legacy.get("downloadUrl") not in {r["downloadUrl"] for r in android}:
        errors.append("Legacy release URL is absent from release catalogue")
    return {
        "passed": not errors,
        "errors": errors,
        "pages": len(pages),
        "files": len(files),
        "release_channel": legacy.get("channel"),
    }


def main() -> None:
    """本地与CI共用检查入口。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("site"))
    parser.add_argument("--allow-local-preview", action="store_true")
    args = parser.parse_args()
    report = check(args.root, args.allow_local_preview)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    raise SystemExit(not report["passed"])


if __name__ == "__main__":
    main()
