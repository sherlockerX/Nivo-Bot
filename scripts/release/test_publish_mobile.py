"""离线验证标签发布的身份、下载校验和安全重跑边界。"""

import copy
import hashlib
import io
import json
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import publish_mobile as publisher


class MobilePublishTest(unittest.TestCase):
    """全部下载和GitHub调用由本地字节与模拟响应替代。"""

    def setUp(self):
        """准备具有真实哈希的两平台目录和源码包。"""
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tag = "v2.0.5"
        self.commit = "a" * 40
        self.content = b"verified fixture"
        self.digest = hashlib.sha256(self.content).hexdigest()
        self.catalogue = {"schemaVersion": 2, "releases": []}
        for platform, distribution, suffix in (
            ("android", "apk", "arm64.apk"),
            ("ios", "ipa", "unsigned.ipa"),
        ):
            self.catalogue["releases"].append(
                {
                    "platform": platform,
                    "version": "2.0.5",
                    "versionCode": 56,
                    "channel": "stable",
                    "distribution": distribution,
                    "signing": "unsigned" if platform == "ios" else "signed",
                    "downloadUrl": publisher.ORIGIN + f"Nivo-Bot-v2.0.5-{suffix}",
                    "sizeBytes": len(self.content),
                    "sha256": self.digest,
                    "sourceUrl": publisher.ORIGIN + "Nivo-Bot-v2.0.5-source.zip",
                    "sourceSha256": self.digest,
                    "sourceSizeBytes": len(self.content),
                }
            )
        self.write("scripts/rebrand.py", 'VERSION_NAME = "2.0.5"\nVERSION_CODE = 56\n')
        self.write("docs/releases/v2.0.5.md", "# Nivo Bot 2.0.5 · Cadence\n\nRelease notes.\n")
        self.save_catalogue()

    def write(self, name, text):
        """写入隔离测试目录，不修改真实仓库。"""
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def save_catalogue(self):
        """保存当前用例的发布清单。"""
        self.write("site/releases.json", json.dumps(self.catalogue))

    def plan(self):
        """读取真实发布配置解析器。"""
        return publisher.load_plan(self.root, self.tag)

    def release(self):
        """构造已完整发布且内容一致的GitHub响应。"""
        return {
            "tag_name": self.tag,
            "target_commitish": self.commit,
            "draft": False,
            "prerelease": False,
            "assets": [
                {
                    "name": item.name,
                    "size": item.size,
                    "digest": "sha256:" + item.sha256,
                    "state": "uploaded",
                }
                for item in self.plan().artifacts
            ],
        }

    def test_valid_plan_ignores_historical_records(self):
        """旧版缺少新字段不会阻止本次发布，也不被修改。"""
        self.catalogue["releases"].append({"version": "2.0.0", "platform": "android"})
        self.save_catalogue()
        before = copy.deepcopy(self.catalogue)
        plan = self.plan()
        self.assertEqual(plan.title, "Nivo Bot 2.0.5 · Cadence")
        self.assertEqual(plan.code, 56)
        self.assertEqual(len(plan.artifacts), 3)
        self.assertEqual(json.loads((self.root / "site/releases.json").read_text()), before)

    def test_wrong_tags_are_rejected(self):
        """标签必须是当前公共版本的完整v前缀版本号。"""
        for tag in ("v2.0.4", "2.0.5", "v2.0.5-beta", "v2.0.5/other"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                publisher.load_plan(self.root, tag)

    def test_missing_or_duplicate_platform_is_rejected(self):
        """每个平台恰好选择一条同版本记录。"""
        original = copy.deepcopy(self.catalogue)
        for releases in (original["releases"][:1], original["releases"] * 2):
            self.catalogue["releases"] = releases
            self.save_catalogue()
            with self.assertRaises(ValueError):
                self.plan()

    def test_wrong_version_code_or_distribution_is_rejected(self):
        """标签、构建号、稳定渠道和未签名IPA身份必须一致。"""
        original = copy.deepcopy(self.catalogue)
        for field, value in (
            ("versionCode", 55),
            ("versionCode", True),
            ("channel", "beta"),
            ("distribution", "testflight"),
            ("signing", "signed"),
        ):
            self.catalogue = copy.deepcopy(original)
            self.catalogue["releases"][1][field] = value
            self.save_catalogue()
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.plan()

    def test_missing_hashes_and_sizes_are_rejected(self):
        """源码和二进制都要求可信的哈希与精确大小。"""
        original = copy.deepcopy(self.catalogue)
        for field in ("sha256", "sizeBytes", "sourceSha256", "sourceSizeBytes"):
            self.catalogue = copy.deepcopy(original)
            del self.catalogue["releases"][0][field]
            self.save_catalogue()
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.plan()

    def test_malformed_hashes_and_sizes_are_rejected(self):
        """占位值、零大小和布尔值不能作为最终文件身份。"""
        original = copy.deepcopy(self.catalogue)
        for field, value in (
            ("sha256", "pending"),
            ("sourceSha256", "z" * 64),
            ("sizeBytes", True),
            ("sourceSizeBytes", 0),
            ("sourceSizeBytes", publisher.MAX_SIZE + 1),
        ):
            self.catalogue = copy.deepcopy(original)
            self.catalogue["releases"][0][field] = value
            self.save_catalogue()
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.plan()

    def test_checkout_and_remote_tag_must_match_event(self):
        """检出、标签和远端任一提交不同都不能继续发布。"""
        for values in (
            [self.commit] * 3,
            ["b" * 40, self.commit, self.commit],
            [self.commit, "b" * 40, self.commit],
            [self.commit, self.commit, "b" * 40],
        ):
            with patch.object(publisher, "run", side_effect=values):
                if values == [self.commit] * 3:
                    publisher.verify_checkout(self.root, self.tag, self.commit)
                else:
                    with self.assertRaises(ValueError):
                        publisher.verify_checkout(self.root, self.tag, self.commit)

    def test_wrong_workflow_repository_or_ref_never_calls_github(self):
        """错误仓库、事件或引用在读取和发布之前停止。"""
        environment = {
            "GITHUB_REPOSITORY": publisher.REPOSITORY,
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REF": "refs/tags/v2.0.5",
        }
        for field, value in (
            ("GITHUB_REPOSITORY", "somebody/fork"),
            ("GITHUB_EVENT_NAME", "pull_request"),
            ("GITHUB_REF", "refs/heads/master"),
        ):
            with (
                patch.dict(publisher.os.environ, {**environment, field: value}),
                patch("sys.argv", ["publish_mobile.py", "--tag", self.tag]),
                patch.object(publisher, "run") as command,
                self.assertRaises(ValueError),
            ):
                publisher.main()
            command.assert_not_called()

    def test_unsafe_urls_and_unexpected_names_are_rejected(self):
        """只接受正式域名的固定版本文件，不接受重定向来源或编码路径。"""
        name = "Nivo-Bot-v2.0.5-arm64.apk"
        for url in (
            "http://nivo.8666886.xyz/downloads/" + name,
            "https://evil.invalid/downloads/" + name,
            "https://nivo.8666886.xyz.evil.invalid/downloads/" + name,
            "https://user@nivo.8666886.xyz/downloads/" + name,
            "https://nivo.8666886.xyz:443/downloads/" + name,
            publisher.ORIGIN + name + "?token=secret",
            publisher.ORIGIN + name + "#fragment",
            publisher.ORIGIN + "../" + name,
            publisher.ORIGIN + name.replace("Nivo", "%4Eivo"),
            publisher.ORIGIN + "Nivo-Bot-v2.0.4-arm64.apk",
        ):
            self.catalogue["releases"][0]["downloadUrl"] = url
            self.save_catalogue()
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.plan()

    def test_platforms_cannot_disagree_on_source_archive(self):
        """相同源码URL不能对应两个不同的校验和。"""
        self.catalogue["releases"][1]["sourceSha256"] = "b" * 64
        self.save_catalogue()
        with self.assertRaises(ValueError):
            self.plan()

    def test_wrong_release_notes_title_is_rejected(self):
        """发行说明必须对应当前版本，标题由文件确定。"""
        self.write("docs/releases/v2.0.5.md", "# Nivo Bot 2.0.4 · Other\n")
        with self.assertRaises(ValueError):
            self.plan()

    def test_download_verifies_hash_and_exact_size(self):
        """字节完整通过，损坏、截断和多余数据全部拒绝。"""
        artifact = self.plan().artifacts[0]
        for payload, accepted in (
            (self.content, True),
            (b"x" * len(self.content), False),
            (self.content[:-1], False),
            (self.content + b"x", False),
        ):
            destination = self.root / ("download-" + hashlib.sha256(payload).hexdigest())
            with self.subTest(payload=payload), patch.object(publisher, "build_opener") as opener:
                response = io.BytesIO(payload)
                opener.return_value.open.return_value = response
                if accepted:
                    publisher.download(artifact, destination)
                    self.assertEqual(destination.read_bytes(), payload)
                else:
                    with self.assertRaises(ValueError):
                        publisher.download(artifact, destination)

    def test_redirect_handler_refuses_even_same_origin_redirect(self):
        """下载过程中不跟随任何重定向，避免绕过URL边界。"""
        with self.assertRaises(ValueError):
            publisher.NoRedirect().redirect_request(
                None, None, 302, "redirect", {}, publisher.ORIGIN
            )

    def test_ipa_metadata_matches_version_and_build(self):
        """读取实际IPA主应用Info.plist，不执行包内内容。"""
        plan = self.plan()
        ipa = self.root / "app.ipa"
        for version, code in (("2.0.5", "56"), ("2.0.4", "56"), ("2.0.5", "55")):
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr(
                    "Payload/Nivo.app/Info.plist",
                    plistlib.dumps(
                        {
                            "CFBundleIdentifier": "io.github.nanomuse.app",
                            "CFBundleShortVersionString": version,
                            "CFBundleVersion": code,
                        }
                    ),
                )
            with self.subTest(version=version, code=code):
                if (version, code) == (plan.version, str(plan.code)):
                    publisher.verify_ipa(ipa, plan)
                else:
                    with self.assertRaises(ValueError):
                        publisher.verify_ipa(ipa, plan)

    def test_apk_metadata_matches_version_code_and_package(self):
        """使用aapt输出验证APK实际身份，测试本身不调用Android工具。"""
        for package, version, code in (
            ("io.github.nanomuse.app", "2.0.5", "56"),
            ("io.github.nanomuse.app.uitest", "2.0.5", "56"),
            ("io.github.nanomuse.app", "2.0.5", "55"),
        ):
            output = f"package: name='{package}' versionCode='{code}' versionName='{version}'\n"
            with (
                patch.object(publisher, "run", return_value=output),
                self.subTest(package=package, code=code),
            ):
                if package == "io.github.nanomuse.app" and code == "56":
                    publisher.verify_apk(self.root / "app.apk", self.plan(), "aapt")
                else:
                    with self.assertRaises(ValueError):
                        publisher.verify_apk(self.root / "app.apk", self.plan(), "aapt")

    def test_release_absence_requires_actual_404(self):
        """鉴权或网络失败不能被误判为尚未创建发布。"""
        for status in ("404", "403", "500"):
            result = subprocess.CompletedProcess([], 1, "", f"gh: failure (HTTP {status})")
            with patch.object(publisher.subprocess, "run", return_value=result):
                if status == "404":
                    self.assertIsNone(publisher.get_release(self.tag))
                else:
                    with self.assertRaises(RuntimeError):
                        publisher.get_release(self.tag)

    def test_new_release_creates_with_all_verified_files(self):
        """一次create附带全部文件、明确目标提交与正式发行设置。"""
        with patch.object(publisher, "run") as command:
            publisher.publish(self.plan(), self.commit, self.root, None)
        args = command.call_args.args[0]
        self.assertEqual(args[:3], ["gh", "release", "create"])
        self.assertIn("--verify-tag", args)
        self.assertIn("--latest", args)
        self.assertEqual(args[args.index("--target") + 1], self.commit)
        for artifact in self.plan().artifacts:
            self.assertIn(str(self.root / artifact.name), args)

    def test_identical_existing_release_is_skipped(self):
        """完整相同发布不改说明、不覆写附件。"""
        with patch.object(publisher, "run") as command:
            publisher.publish(self.plan(), self.commit, self.root, self.release())
        command.assert_not_called()

    def test_mismatched_existing_release_never_mutates(self):
        """目标、标签或附件不同则立即拒绝，禁止clobber。"""
        original = self.release()
        variants = []
        for field, value in (
            ("target_commitish", "b" * 40),
            ("tag_name", "v2.0.4"),
            ("draft", True),
            ("prerelease", True),
        ):
            release = copy.deepcopy(original)
            release[field] = value
            variants.append(release)
        release = copy.deepcopy(original)
        release["assets"][0]["digest"] = "sha256:" + "f" * 64
        variants.append(release)
        for release in variants:
            with patch.object(publisher, "run") as command, self.assertRaises(ValueError):
                publisher.publish(self.plan(), self.commit, self.root, release)
            command.assert_not_called()

    def test_partial_release_uploads_only_missing_files(self):
        """中断后的重跑先核对已有附件，再补传缺失文件。"""
        release = self.release()
        missing = release["assets"].pop()
        with patch.object(publisher, "run") as command:
            publisher.publish(self.plan(), self.commit, self.root, release)
        args = command.call_args.args[0]
        self.assertEqual(args[:3], ["gh", "release", "upload"])
        self.assertIn(str(self.root / missing["name"]), args)
        self.assertNotIn("--clobber", args)
        self.assertNotIn(str(self.root / release["assets"][0]["name"]), args)

    def test_legacy_asset_without_digest_is_downloaded_and_checked(self):
        """旧API没有digest时下载已有附件比较，不假设同名同尺寸就是相同内容。"""
        release = self.release()
        release["assets"][0]["digest"] = None

        def supply_file(args):
            destination = Path(args[args.index("--dir") + 1])
            (destination / args[args.index("--pattern") + 1]).write_bytes(self.content)
            return ""

        with patch.object(publisher, "run", side_effect=supply_file) as command:
            publisher.publish(self.plan(), self.commit, self.root, release)
        self.assertEqual(command.call_args.args[0][:3], ["gh", "release", "download"])


if __name__ == "__main__":
    unittest.main()
