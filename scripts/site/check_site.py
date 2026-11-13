"""校验多页产品站、静态资源和跨平台版本清单，阻止失效链接与伪下载。"""

from __future__ import annotations

import argparse
import json
import re
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlparse

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
}
SUFFIXES = {".html", ".css", ".js", ".json", ".svg", ".xml", ".txt"}


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


class Page(HTMLParser):
    """收集独立页面的标识和资源，检查基本语义。"""

    def __init__(self) -> None:
        """初始化单页检查状态。"""
        super().__init__()
        self.ids: set[str] = set()
        self.links: list[str] = []
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
        if tag == "h1":
            self.headings += 1
        if tag == "img" and "alt" not in attrs:
            self.errors.append("Image missing alt")
        if attrs.get("target") == "_blank" and "noopener" not in attrs.get("rel", ""):
            self.errors.append("External window missing noopener")


def validate_releases(data: dict) -> list[str]:
    """支持APK、IPA和官方商店入口，尚未发布的平台不得伪造发行记录。"""
    errors = []
    if data.get("schemaVersion") != 2:
        return ["Invalid release catalogue schema"]
    platforms = {p["id"]: p for p in data.get("platforms", [])}
    ids = set()
    for release in data.get("releases", []):
        if not release.get("id") or release["id"] in ids:
            errors.append("Duplicate or missing release ID")
        ids.add(release.get("id"))
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
        if kind not in {"apk", "ipa", "app-store", "testflight"}:
            errors.append("Invalid distribution method")
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
        if not name.endswith(".html") or not (root / name).is_file():
            continue
        parser = Page()
        parser.feed((root / name).read_text(encoding="utf-8"))
        pages[name] = parser
        errors.extend(f"{name}: {error}" for error in parser.errors)
        if parser.headings != 1:
            errors.append(f"{name}: Expected exactly one h1")
    for name, page in pages.items():
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
