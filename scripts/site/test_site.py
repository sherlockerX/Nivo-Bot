"""验证多平台发行清单和发布边界，不请求任何真实模型服务。"""

from __future__ import annotations

import copy
import hashlib
import io
import json
import os
import shutil
import tarfile
import tempfile
import unittest
import xml.etree.ElementTree as ET
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

from build_site import build
from check_site import check, site_files, validate_releases
from content import FEATURES, PROVIDERS
from deploy_netcatty import deploy, unpack
from render_site import (
    ROOT,
    application_metadata,
    downloads,
    generated,
    release_card,
    release_detail,
)


class ProductSiteTests(unittest.TestCase):
    """确保未来版本可扩展，未发布平台和私有文件不会被误展示。"""

    def setUp(self) -> None:
        """读取不含秘密的正式发行清单。"""
        self.catalogue = json.loads((ROOT / "releases.json").read_text(encoding="utf-8"))

    def test_current_site_has_no_broken_pages_or_assets(self) -> None:
        """所有公开页面、资源和片段均应能在白名单内解析。"""
        report = check(ROOT)
        self.assertTrue(report["passed"], report["errors"])
        self.assertEqual(
            report["pages"], 9 + len(FEATURES) + len(PROVIDERS) + len(self.catalogue["releases"])
        )

    def test_all_app_catalogue_entries_have_dedicated_guides(self) -> None:
        """厂商目录覆盖实际App目录，而不是遗漏少数不熟悉的服务。"""
        catalogue = json.loads(
            (ROOT.parent / "nanomuse/llm/providers.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            {p["id"] for p in PROVIDERS},
            {p["id"] for p in catalogue["providers"] if not p.get("is_relay", False)},
        )

    def test_model_guides_keep_custom_endpoints_without_relay_recommendations(self) -> None:
        """移除预设中转商推荐，仍说明用户自己的兼容服务如何接入。"""
        catalogue = json.loads(
            (ROOT.parent / "nanomuse/llm/providers.json").read_text(encoding="utf-8")
        )
        relay_ids = {
            "siliconflow",
            "openrouter",
            "opencode-zen",
            "opencode-go",
            "standardcompute",
            "cheaperinference",
        }
        self.assertEqual({p["id"] for p in catalogue["providers"] if p.get("is_relay")}, relay_ids)
        pages = generated(ROOT)
        self.assertIn("models/custom.html", pages)
        self.assertIn("暂时跳过", pages["getting-started.html"])
        self.assertIn("本机", pages["privacy.html"])
        for identifier in relay_ids:
            self.assertNotIn("models/" + identifier + ".html", pages)

    def test_generated_pages_do_not_drift_from_content(self) -> None:
        """内容源重建的结果应与公开页面逐字节一致。"""
        for name, content in generated(ROOT).items():
            self.assertEqual((ROOT / name).read_bytes(), content.encode("utf-8"), name)

    def test_search_verification_is_not_a_content_page(self) -> None:
        """验证文件保留原始字节，不加入搜索内容页清单。"""
        name = "google29070eb2e5de147a.html"
        self.assertEqual((ROOT / name).read_bytes(), ("google-site-verification: " + name).encode())
        sitemap = ET.fromstring((ROOT / "sitemap.xml").read_bytes())
        namespace = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}
        urls = [item.text for item in sitemap.findall("s:url/s:loc", namespace)]
        self.assertEqual(
            len(urls), 9 + len(FEATURES) + len(PROVIDERS) + len(self.catalogue["releases"])
        )
        self.assertTrue(
            all(
                "https://nivo.8666886.xyz/" + release["notesUrl"] in urls
                for release in self.catalogue["releases"]
            )
        )
        self.assertFalse(any(name in url for url in urls))
        self.assertTrue(all(url.startswith("https://nivo.8666886.xyz/") for url in urls))

    def test_unreleased_ios_has_no_fabricated_download(self) -> None:
        """未发布iOS只保留状态和进度入口。"""
        invalid = copy.deepcopy(self.catalogue)
        invalid["platforms"][1]["status"] = "unreleased"
        invalid["releases"] = [r for r in invalid["releases"] if r["platform"] != "ios"]
        fake = copy.deepcopy(invalid["releases"][0])
        fake.update(id="ios-fake", platform="ios")
        invalid["releases"].append(fake)
        self.assertIn("Release exists on an unavailable platform", validate_releases(invalid))

    def test_binary_release_requires_hash_and_size(self) -> None:
        """APK地址本身不足以发布，必须提供文件校验信息。"""
        invalid = copy.deepcopy(self.catalogue)
        del invalid["releases"][0]["sha256"]
        invalid["releases"][0]["sizeBytes"] = 0
        self.assertIn("Binary release requires SHA256", validate_releases(invalid))
        self.assertIn("Binary release requires file size", validate_releases(invalid))

    def test_future_ios_store_release_does_not_require_binary_hash(self) -> None:
        """商店分发没有直链IPA时，不能强迫填虚假的文件哈希。"""
        future = copy.deepcopy(self.catalogue)
        future["platforms"][1]["status"] = "available"
        release = copy.deepcopy(future["releases"][0])
        release.update(
            id="ios-test-fixture",
            platform="ios",
            distribution="app-store",
            downloadUrl="https://apps.apple.com/",
            notesUrl="releases/ios-2.0.0.html",
        )
        del release["sha256"]
        del release["sizeBytes"]
        future["releases"].append(release)
        self.assertEqual(validate_releases(future), [])

    def unsigned_ios_catalogue(self) -> dict:
        """构造仅用于测试的未签名IPA，不写入真实发行清单。"""
        catalogue = copy.deepcopy(self.catalogue)
        catalogue["platforms"][1]["status"] = "available"
        catalogue["releases"] = [r for r in catalogue["releases"] if r["platform"] != "ios"]
        release = copy.deepcopy(catalogue["releases"][0])
        release.update(
            id="ios-unsigned-fixture",
            platform="ios",
            version="9.0.0",
            versionCode=90,
            distribution="ipa",
            signing="unsigned",
            minimumOs="16.0",
            downloadUrl="https://example.com/nivo-unsigned.ipa",
            notesUrl="releases/ios-unsigned-fixture.html",
        )
        release.pop("certificateSha256", None)
        catalogue["releases"].append(release)
        return catalogue

    def test_unsigned_ipa_requires_explicit_signing_metadata(self) -> None:
        """IPA必须标明签名状态，未签名状态不能错误用于Android包。"""
        catalogue = self.unsigned_ios_catalogue()
        self.assertEqual(validate_releases(catalogue), [])
        release = catalogue["releases"][-1]
        del release["signing"]
        self.assertIn("IPA release requires signing status", validate_releases(catalogue))
        release.update(signing="unsigned", platform="android", distribution="apk")
        self.assertIn("Unsigned release must be an iOS IPA", validate_releases(catalogue))

    def test_unsigned_ipa_installation_requirements_survive_without_javascript(self) -> None:
        """静态卡、版本说明与禁用脚本入口都必须保留签名要求。"""
        catalogue = self.unsigned_ios_catalogue()
        release = catalogue["releases"][-1]
        for content in (release_card(release), release_detail(release)):
            self.assertIn("下载未签名IPA", content)
            self.assertIn("不能下载后直接安装到iPhone", content)
            self.assertIn("本文件没有TestFlight或App Store安装入口", content)
            self.assertNotIn("打开官方安装入口", content)
        fallback = downloads(catalogue).split("<noscript>")[1].split("</noscript>")[0]
        self.assertIn(release["downloadUrl"], fallback)
        self.assertIn("需要使用自己的Apple开发签名", fallback)

    def test_application_metadata_uses_latest_platform_release(self) -> None:
        """搜索结构化数据读取各平台版本，并保留未签名IPA的安装限制。"""
        catalogue = self.unsigned_ios_catalogue()
        applications = application_metadata(catalogue)
        ios = next(app for app in applications if app["operatingSystem"].startswith("iOS"))
        self.assertEqual(ios["softwareVersion"], "9.0.0")
        self.assertIn("未签名IPA", ios["description"])
        catalogue["platforms"][1]["status"] = "unreleased"
        self.assertFalse(
            any(app["operatingSystem"].startswith("iOS") for app in application_metadata(catalogue))
        )

    def test_duplicate_releases_and_insecure_downloads_are_rejected(self) -> None:
        """阻止选择器出现重名项或不安全下载协议。"""
        invalid = copy.deepcopy(self.catalogue)
        invalid["releases"].append(copy.deepcopy(invalid["releases"][0]))
        invalid["releases"][0]["downloadUrl"] = "javascript:alert(1)"
        errors = validate_releases(invalid)
        self.assertIn("Duplicate or missing release ID", errors)
        self.assertIn("Release requires HTTPS downloadUrl", errors)

    def test_manifest_cannot_escape_site_or_publish_private_files(self) -> None:
        """白名单仍需路径约束，防止部署目录夹带本机资料。"""
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            files = site_files(ROOT) + ["../private.json"]
            (folder / "site-manifest.json").write_text(
                json.dumps({"schemaVersion": 1, "files": files}), encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, "Unsafe site path"):
                site_files(folder)

    def test_build_preserves_structure_and_excludes_extra_files(self) -> None:
        """发布包只复制白名单，额外的凭据文件绝不随站点打包。"""
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            source = folder / "source"
            shutil.copytree(ROOT, source)
            (source / "private.txt").write_text("not for deployment", encoding="utf-8")
            output = folder / "output"
            manifest = build(source, output)
            self.assertTrue((output / "models/gemini.html").is_file())
            self.assertFalse((output / "private.txt").exists())
            self.assertEqual(set(manifest), set(site_files(ROOT)))

    def test_deployment_archive_preserves_nested_files(self) -> None:
        """允许普通静态文件的子目录，不需要不受限解包。"""
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            archive = folder / "site.tar.gz"
            payload = b"<html>public guide</html>"
            with tarfile.open(archive, "w:gz") as bundle:
                member = tarfile.TarInfo("models/example.html")
                member.size = len(payload)
                bundle.addfile(member, io.BytesIO(payload))
            destination = folder / "release"
            unpack(archive, destination)
            self.assertEqual((destination / "models/example.html").read_bytes(), payload)

    def test_deployment_archive_rejects_paths_before_writing(self) -> None:
        """恶意条目不能穿越目录或覆盖既有安装包，发现后不写任何文件。"""
        for unsafe in ("../escape.html", "/absolute.html", "downloads/app.apk"):
            with self.subTest(path=unsafe), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                archive = folder / "site.tar.gz"
                with tarfile.open(archive, "w:gz") as bundle:
                    bundle.addfile(tarfile.TarInfo("index.html"), io.BytesIO(b""))
                    bundle.addfile(tarfile.TarInfo(unsafe), io.BytesIO(b""))
                destination = folder / "release"
                with self.assertRaises(ValueError):
                    unpack(archive, destination)
                self.assertFalse(destination.exists())

    def test_deployment_archive_rejects_symbolic_links(self) -> None:
        """禁止归档链接把后续写入引向发布目录之外。"""
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            archive = folder / "site.tar.gz"
            with tarfile.open(archive, "w:gz") as bundle:
                member = tarfile.TarInfo("models")
                member.type = tarfile.SYMTYPE
                member.linkname = "../../private"
                bundle.addfile(member)
            with self.assertRaisesRegex(ValueError, "Unexpected deployment archive entry"):
                unpack(archive, folder / "release")


class DeploymentEvidenceTests(unittest.TestCase):
    """使用真实临时文件和模拟链接、Docker命令验证发布记录与回滚。"""

    def setUp(self) -> None:
        """准备已有搜索与公网验收证据的独立服务器目录。"""
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.previous = self.root / "www/releases/site-old"
        self.previous.mkdir(parents=True)
        (self.previous / "downloads").mkdir()
        (self.previous / "downloads/old.apk").write_bytes(b"original download")
        (self.root / "Caddyfile").write_bytes(b"original configuration")
        self.previous_manifest = {
            "site_release": "site-old",
            "release": str(self.previous),
            "deployed_at": "2026-11-13T00:00:00Z",
            "public_verified": True,
            "search_submission": {
                "google": {"verified": True, "submitted_at": "2026-11-13"},
                "bing": {"verified": True, "submitted_at": "2026-11-13"},
            },
            "public_verification": {"checked_at": "2026-11-13", "checks": ["downloads", "browser"]},
            "public_verification_history": [
                {"site_release": "site-earlier", "public_verified": True}
            ],
        }
        self.manifest_path = self.root / "deployment-manifest.json"
        self.manifest_path.write_text(json.dumps(self.previous_manifest), encoding="utf-8")
        self.manifest_bytes = self.manifest_path.read_bytes()
        self.archive = self.root / "site.tar.gz"
        files = {
            "index.html": b"<h1>Nivo Bot</h1>",
            "release.json": json.dumps({"version": "2.0.5", "versionCode": 56}).encode(),
        }
        files["files.json"] = json.dumps(
            {
                "files": {
                    name: hashlib.sha256(content).hexdigest() for name, content in files.items()
                }
            }
        ).encode()
        with tarfile.open(self.archive, "w:gz") as bundle:
            for name, content in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(content)
                bundle.addfile(member, io.BytesIO(content))
        self.links = {self.root / "www/current": self.previous}
        original_resolve = Path.resolve
        original_replace = os.replace

        def resolve(path: Path, strict: bool = False) -> Path:
            """只模拟本次测试的链接解析，其余路径仍使用真实文件系统。"""
            return original_resolve(self.links.get(path, path), strict=strict)

        def symlink(path: Path, target: str, target_is_directory: bool = False) -> None:
            """记录链接目标，不依赖Windows创建符号链接的系统权限。"""
            if path in self.links or path.exists():
                raise FileExistsError(path)
            self.links[path] = original_resolve(path.parent / target)

        def replace(source: Path, destination: Path) -> None:
            """链接切换更新测试映射，普通文件替换仍执行真实操作。"""
            if source in self.links:
                self.links[destination] = self.links.pop(source)
            else:
                original_replace(source, destination)

        patches = ExitStack()
        self.addCleanup(patches.close)
        patches.enter_context(patch.object(Path, "resolve", resolve))
        patches.enter_context(patch.object(Path, "is_symlink", lambda path: path in self.links))
        patches.enter_context(patch.object(Path, "symlink_to", symlink))
        patches.enter_context(patch("deploy_netcatty.os.replace", replace))
        self.command = patches.enter_context(
            patch("deploy_netcatty.command", return_value="Nivo Bot")
        )

    def test_publish_preserves_search_and_archives_previous_public_verification(self) -> None:
        """新版本继承搜索记录，并保留带版本身份的旧公网验收历史。"""
        result = deploy(self.root, self.archive, "site-new")
        persisted = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(persisted, result)
        self.assertEqual(result["search_submission"], self.previous_manifest["search_submission"])
        self.assertFalse(result["public_verified"])
        self.assertNotIn("public_verification", result)
        history = result["public_verification_history"]
        self.assertEqual(history[0], self.previous_manifest["public_verification_history"][0])
        self.assertEqual(history[-1]["site_release"], "site-old")
        self.assertEqual(
            history[-1]["public_verification"], self.previous_manifest["public_verification"]
        )
        self.assertTrue(history[-1]["public_verified"])
        self.assertEqual(
            (self.root / "backups/site-new/deployment-manifest.json").read_bytes(),
            self.manifest_bytes,
        )
        second = deploy(self.root, self.archive, "site-next")
        self.assertEqual(second["search_submission"], result["search_submission"])
        self.assertEqual(second["public_verification_history"], history)
        self.assertFalse(second["public_verified"])
        self.assertEqual((self.previous / "downloads/old.apk").read_bytes(), b"original download")

    def test_failed_origin_check_preserves_manifest_and_rolls_back(self) -> None:
        """源站检查失败恢复旧链接和配置，原始证据清单保持字节不变。"""
        self.command.side_effect = ["valid", "reloaded", "unexpected page", "rollback reloaded"]
        with self.assertRaisesRegex(ValueError, "Published page is not the expected document"):
            deploy(self.root, self.archive, "site-failed")
        self.assertEqual((self.root / "www/current").resolve(), self.previous)
        self.assertEqual((self.root / "Caddyfile").read_bytes(), b"original configuration")
        self.assertEqual(self.manifest_path.read_bytes(), self.manifest_bytes)
        self.assertEqual((self.previous / "downloads/old.apk").read_bytes(), b"original download")
        self.assertFalse((self.root / "backups/site-failed/completed.json").exists())
        self.assertEqual(self.command.call_count, 4)

    def test_missing_manifest_does_not_invent_verification_history(self) -> None:
        """没有旧清单时不补造搜索记录或公网验收结论。"""
        self.manifest_path.unlink()
        result = deploy(self.root, self.archive, "site-first")
        self.assertFalse(result["public_verified"])
        self.assertNotIn("search_submission", result)
        self.assertNotIn("public_verification", result)
        self.assertNotIn("public_verification_history", result)

    def test_invalid_history_stops_before_switching_or_overwriting_evidence(self) -> None:
        """旧历史格式损坏时提前失败，不能用空历史覆盖原始证据。"""
        invalid = {**self.previous_manifest, "public_verification_history": {"unexpected": True}}
        self.manifest_path.write_text(json.dumps(invalid), encoding="utf-8")
        original = self.manifest_path.read_bytes()
        with self.assertRaisesRegex(ValueError, "Invalid public verification history"):
            deploy(self.root, self.archive, "site-invalid")
        self.assertEqual(self.manifest_path.read_bytes(), original)
        self.assertEqual((self.root / "www/current").resolve(), self.previous)
        self.assertFalse((self.root / "www/releases/site-invalid").exists())
        self.command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
