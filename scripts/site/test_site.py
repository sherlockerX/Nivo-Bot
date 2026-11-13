"""验证多平台发行清单和发布边界，不请求任何真实模型服务。"""

from __future__ import annotations

import copy
import io
import json
import shutil
import tarfile
import tempfile
import unittest
from pathlib import Path

from build_site import build
from check_site import check, site_files, validate_releases
from content import PROVIDERS
from deploy_netcatty import unpack
from render_site import ROOT, generated


class ProductSiteTests(unittest.TestCase):
    """确保未来版本可扩展，未发布平台和私有文件不会被误展示。"""

    def setUp(self) -> None:
        """读取不含秘密的正式发行清单。"""
        self.catalogue = json.loads((ROOT / "releases.json").read_text(encoding="utf-8"))

    def test_current_site_has_no_broken_pages_or_assets(self) -> None:
        """所有公开页面、资源和片段均应能在白名单内解析。"""
        report = check(ROOT)
        self.assertTrue(report["passed"], report["errors"])
        self.assertGreaterEqual(report["pages"], 35)

    def test_all_app_catalogue_entries_have_dedicated_guides(self) -> None:
        """厂商目录覆盖实际App目录，而不是遗漏少数不熟悉的服务。"""
        catalogue = json.loads(
            (ROOT.parent / "nanomuse/llm/providers.json").read_text(encoding="utf-8")
        )
        self.assertEqual({p["id"] for p in PROVIDERS}, {p["id"] for p in catalogue["providers"]})

    def test_generated_pages_do_not_drift_from_content(self) -> None:
        """内容源重建的结果应与公开页面逐字节一致。"""
        for name, content in generated(ROOT).items():
            self.assertEqual((ROOT / name).read_bytes(), content.encode("utf-8"), name)

    def test_unreleased_ios_has_no_fabricated_download(self) -> None:
        """未发布iOS只保留状态和进度入口。"""
        self.assertFalse([r for r in self.catalogue["releases"] if r["platform"] == "ios"])
        invalid = copy.deepcopy(self.catalogue)
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


if __name__ == "__main__":
    unittest.main()
