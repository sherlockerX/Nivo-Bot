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
from dataclasses import replace
from itertools import product
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
            "id": 123,
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

    def test_nelan_artifacts_preserve_historical_records(self) -> None:
        """新品牌的APK、IPA和共享源码可发布，历史记录保持原样。"""
        for row in self.catalogue["releases"]:
            for field in ("downloadUrl", "sourceUrl"):
                row[field] = row[field].replace("Nivo-Bot-", "Nelan-")
        self.catalogue["releases"].append({"version": "2.0.0", "platform": "android"})
        self.save_catalogue()
        before = copy.deepcopy(self.catalogue)

        plan = self.plan()

        self.assertEqual(
            [item.name for item in plan.artifacts],
            [
                "Nelan-v2.0.5-arm64.apk",
                "Nelan-v2.0.5-unsigned.ipa",
                "Nelan-v2.0.5-source.zip",
            ],
        )
        self.assertEqual(json.loads((self.root / "site/releases.json").read_text()), before)

    def test_nelan_android_release_uses_exact_new_names_and_keeps_ios_history(self) -> None:
        """2.0.9仅交付新名称的Android与源码，旧iOS记录不成为新附件。"""
        self.tag = "v2.0.9"
        self.catalogue["releases"][0].update(
            version="2.0.9",
            versionCode=60,
            downloadUrl=publisher.ORIGIN + "Nelan-v2.0.9-arm64.apk",
            sourceUrl=publisher.ORIGIN + "Nelan-v2.0.9-source.zip",
        )
        self.write("scripts/rebrand.py", 'VERSION_NAME = "2.0.9"\nVERSION_CODE = 60\n')
        self.write("docs/releases/v2.0.9.md", "# 念步 2.0.9 · Renewal\n")
        self.save_catalogue()
        before = copy.deepcopy(self.catalogue)
        plan = self.plan()
        self.assertEqual(plan.code, 60)
        with patch.object(publisher, "run") as command:
            publisher.publish(plan, self.commit, self.root, None)
        arguments = command.call_args.args[0]
        self.assertEqual(
            arguments[:6],
            [
                "gh",
                "release",
                "create",
                "v2.0.9",
                str(self.root / "Nelan-v2.0.9-arm64.apk"),
                str(self.root / "Nelan-v2.0.9-source.zip"),
            ],
        )
        self.assertEqual(arguments[arguments.index("--title") + 1], "念步 2.0.9 · Renewal")
        self.assertEqual(arguments[arguments.index("--target") + 1], self.commit)
        self.assertIn("--verify-tag", arguments)
        self.assertEqual(json.loads((self.root / "site/releases.json").read_text()), before)

        release = self.release()
        release["assets"][0]["name"] = "Nivo-Bot-v2.0.9-arm64.apk"
        with (
            patch.object(publisher, "run") as command,
            self.assertRaisesRegex(ValueError, "unexpected or duplicate assets"),
        ):
            publisher.publish(plan, self.commit, self.root, release)
        command.assert_not_called()

    def test_wrong_tags_are_rejected(self):
        """标签必须是当前公共版本的完整v前缀版本号。"""
        for tag in ("v2.0.4", "2.0.5", "v2.0.5-beta", "v2.0.5/other"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                publisher.load_plan(self.root, tag)

    def test_single_platform_plan_preserves_other_platform_history(self):
        """仅发布一个平台时保留另一平台历史，不补造同版本安装包。"""
        original = copy.deepcopy(self.catalogue)
        for platform, suffix in (("android", "arm64.apk"), ("ios", "unsigned.ipa")):
            self.catalogue = copy.deepcopy(original)
            for row in self.catalogue["releases"]:
                if row["platform"] != platform:
                    row["version"] = "2.0.4"
            self.save_catalogue()
            before = copy.deepcopy(self.catalogue)
            with self.subTest(platform=platform):
                plan = self.plan()
                self.assertEqual(plan.code, 56)
                self.assertEqual(
                    [item.name for item in plan.artifacts],
                    [f"Nivo-Bot-v2.0.5-{suffix}", "Nivo-Bot-v2.0.5-source.zip"],
                )
                self.assertEqual(json.loads((self.root / "site/releases.json").read_text()), before)

    def test_empty_duplicate_or_unknown_platform_is_rejected(self):
        """当前版本至少发布一个已知平台，空值、重复和未知平台均拒绝。"""
        original = copy.deepcopy(self.catalogue)
        rows = original["releases"]
        variants = [[], rows * 2, [rows[0], rows[0]], [rows[1], rows[1]]]
        for platform in ("desktop", "", None, 1, {}, ["android"]):
            variants.append([{**rows[0], "platform": platform}])
            variants.append([rows[0], {**rows[1], "platform": platform}])
        variants.append([{key: value for key, value in rows[0].items() if key != "platform"}])
        for releases in variants:
            self.catalogue["releases"] = releases
            self.save_catalogue()
            with (
                self.subTest(platforms=[row.get("platform") for row in releases]),
                self.assertRaises(ValueError),
            ):
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

    def test_workflow_verifies_only_present_platforms(self):
        """实际入口仅下载并校验本次平台，iOS单独发行不依赖Android SDK。"""
        original = copy.deepcopy(self.catalogue)
        self.write("sdk/build-tools/35.0.0/aapt", "")
        for platforms in (("android",), ("ios",), ("ios", "android")):
            self.catalogue["releases"] = [
                copy.deepcopy(row)
                for platform in platforms
                for row in original["releases"]
                if row["platform"] == platform
            ]
            self.save_catalogue()
            environment = {
                "GITHUB_REPOSITORY": publisher.REPOSITORY,
                "GITHUB_EVENT_NAME": "push",
                "GITHUB_REF": "refs/tags/" + self.tag,
                "GITHUB_SHA": self.commit,
            }
            if "android" in platforms:
                environment["ANDROID_HOME"] = str(self.root / "sdk")
            with (
                self.subTest(platforms=platforms),
                patch.dict(publisher.os.environ, environment, clear=True),
                patch("sys.argv", ["publish_mobile.py", "--tag", self.tag]),
                patch.object(
                    publisher, "__file__", str(self.root / "scripts/release/publish_mobile.py")
                ),
                patch.object(publisher, "verify_checkout") as checkout,
                patch.object(publisher, "download") as download,
                patch.object(publisher, "verify_apk") as verify_apk,
                patch.object(publisher, "verify_ipa") as verify_ipa,
                patch.object(publisher, "get_release", side_effect=[None, self.release()]),
                patch.object(publisher, "run") as command,
                patch("sys.stdout", new_callable=io.StringIO) as output,
            ):
                publisher.main()
                names = []
                if "android" in platforms:
                    names.append("Nivo-Bot-v2.0.5-arm64.apk")
                    verify_apk.assert_called_once()
                    self.assertEqual(verify_apk.call_args.args[0].name, names[-1])
                else:
                    verify_apk.assert_not_called()
                if "ios" in platforms:
                    names.append("Nivo-Bot-v2.0.5-unsigned.ipa")
                    verify_ipa.assert_called_once()
                    self.assertEqual(verify_ipa.call_args.args[0].name, names[-1])
                else:
                    verify_ipa.assert_not_called()
                names.append("Nivo-Bot-v2.0.5-source.zip")
                self.assertEqual([call.args[0].name for call in download.call_args_list], names)
                self.assertEqual(checkout.call_count, 2)
                args = command.call_args.args[0]
                self.assertEqual(command.call_count, 1)
                self.assertEqual(args[:3], ["gh", "release", "create"])
                self.assertEqual([Path(value).name for value in args[4 : 4 + len(names)]], names)
                self.assertIn(f"with {len(names)} verified assets", output.getvalue())

    def test_single_platform_keeps_release_identity_checks(self):
        """单平台也必须满足构建号、渠道、文件地址、哈希与源码大小约束。"""
        original = copy.deepcopy(self.catalogue)
        for platform in ("android", "ios"):
            base = next(row for row in original["releases"] if row["platform"] == platform)
            variants = [
                ("versionCode", 55),
                ("versionCode", True),
                ("channel", "beta"),
                ("distribution", "testflight"),
                ("sha256", "pending"),
                ("sizeBytes", True),
                ("sourceSizeBytes", 0),
                ("sourceSha256", "z" * 64),
                ("sourceUrl", publisher.ORIGIN + "Nivo-Bot-v2.0.4-source.zip"),
                ("downloadUrl", "https://other.invalid/app.apk"),
            ]
            if platform == "ios":
                variants.append(("signing", "signed"))
            for field, value in variants:
                self.catalogue["releases"] = [{**base, field: value}]
                self.save_catalogue()
                with self.subTest(platform=platform, field=field), self.assertRaises(ValueError):
                    self.plan()

    def test_single_platform_identity_failure_stops_before_publish(self):
        """APK或IPA实际身份校验失败后，不读取或修改GitHub发行。"""
        original = copy.deepcopy(self.catalogue)
        self.write("sdk/build-tools/35.0.0/aapt", "")
        for platform in ("android", "ios"):
            self.catalogue["releases"] = [
                copy.deepcopy(row) for row in original["releases"] if row["platform"] == platform
            ]
            self.save_catalogue()
            environment = {
                "GITHUB_REPOSITORY": publisher.REPOSITORY,
                "GITHUB_EVENT_NAME": "push",
                "GITHUB_REF": "refs/tags/" + self.tag,
                "GITHUB_SHA": self.commit,
                "ANDROID_HOME": str(self.root / "sdk"),
            }
            verifier = "verify_apk" if platform == "android" else "verify_ipa"
            with (
                self.subTest(platform=platform),
                patch.dict(publisher.os.environ, environment, clear=True),
                patch("sys.argv", ["publish_mobile.py", "--tag", self.tag]),
                patch.object(
                    publisher, "__file__", str(self.root / "scripts/release/publish_mobile.py")
                ),
                patch.object(publisher, "verify_checkout"),
                patch.object(publisher, "download"),
                patch.object(
                    publisher, verifier, side_effect=ValueError("Package identity differs")
                ),
                patch.object(publisher, "get_release") as get_release,
                patch.object(publisher, "run") as command,
                patch("sys.stdout", new_callable=io.StringIO),
                self.assertRaisesRegex(ValueError, "Package identity differs"),
            ):
                publisher.main()
            get_release.assert_not_called()
            command.assert_not_called()

    def test_android_package_still_requires_available_aapt(self):
        """Android单平台发行缺少校验工具时明确失败，不能跳过包身份检查。"""
        self.catalogue["releases"] = self.catalogue["releases"][:1]
        self.save_catalogue()
        for environment in ({}, {"ANDROID_HOME": str(self.root / "missing-sdk")}):
            with (
                self.subTest(environment=environment),
                patch.dict(publisher.os.environ, environment, clear=True),
                patch.object(publisher, "verify_apk") as verify_apk,
                self.assertRaisesRegex(ValueError, "aapt is required"),
            ):
                publisher.verify_packages(self.root, self.plan())
            verify_apk.assert_not_called()

    def test_single_platform_retry_only_uploads_missing_source(self):
        """单平台发行中断后只补源码，完整重跑不改已发布附件。"""
        original = copy.deepcopy(self.catalogue)
        for platform in ("android", "ios"):
            self.catalogue["releases"] = [
                row for row in original["releases"] if row["platform"] == platform
            ]
            self.save_catalogue()
            complete = self.release()
            partial = copy.deepcopy(complete)
            partial["assets"].pop()
            with self.subTest(platform=platform), patch.object(publisher, "run") as command:
                publisher.publish(self.plan(), self.commit, self.root, partial)
                args = command.call_args.args[0]
                self.assertEqual(args[:3], ["gh", "release", "upload"])
                self.assertIn(str(self.root / "Nivo-Bot-v2.0.5-source.zip"), args)
                self.assertNotIn(str(self.root / complete["assets"][0]["name"]), args)
                self.assertNotIn("--clobber", args)
                command.reset_mock()
                publisher.publish(self.plan(), self.commit, self.root, complete)
                command.assert_not_called()

    def test_single_platform_rejects_unplanned_second_binary(self):
        """已有发行混入本次未计划的平台时拒绝修改，不把旧附件算作新发行。"""
        original = copy.deepcopy(self.catalogue)
        original_assets = self.release()["assets"]
        for platform, other_suffix in (("android", ".ipa"), ("ios", ".apk")):
            self.catalogue["releases"] = [
                row for row in original["releases"] if row["platform"] == platform
            ]
            self.save_catalogue()
            release = self.release()
            release["assets"].append(
                next(item for item in original_assets if item["name"].endswith(other_suffix))
            )
            with (
                self.subTest(platform=platform),
                patch.object(publisher, "run") as command,
                self.assertRaisesRegex(ValueError, "unexpected or duplicate assets"),
            ):
                publisher.publish(self.plan(), self.commit, self.root, release)
            command.assert_not_called()

    def test_unsafe_urls_and_unexpected_names_are_rejected(self):
        """只接受正式域名的固定版本文件，不接受重定向来源或编码路径。"""
        original = copy.deepcopy(self.catalogue)
        for prefix, (index, field, suffix) in product(
            ("Nelan", "Nivo-Bot"),
            (
                (0, "downloadUrl", "arm64.apk"),
                (1, "downloadUrl", "unsigned.ipa"),
                (0, "sourceUrl", "source.zip"),
            ),
        ):
            name = f"{prefix}-v2.0.5-{suffix}"
            for url in (
                "http://nivo.8666886.xyz/downloads/" + name,
                "https://evil.invalid/downloads/" + name,
                "https://nivo.8666886.xyz.evil.invalid/downloads/" + name,
                "https://user@nivo.8666886.xyz/downloads/" + name,
                "https://nivo.8666886.xyz:443/downloads/" + name,
                publisher.ORIGIN + name + "?token=secret",
                publisher.ORIGIN + name + "#fragment",
                publisher.ORIGIN + "../" + name,
                publisher.ORIGIN + name.replace("N", "%4E", 1),
                publisher.ORIGIN + name.replace("2.0.5", "2.0.4"),
                publisher.ORIGIN + name.replace(prefix, "Other", 1),
                publisher.ORIGIN + name.lower(),
                publisher.ORIGIN + name + ".bak",
            ):
                self.catalogue = copy.deepcopy(original)
                self.catalogue["releases"][index][field] = url
                self.save_catalogue()
                with self.subTest(field=field, url=url), self.assertRaises(ValueError):
                    self.plan()

    def test_platforms_cannot_disagree_on_source_archive(self):
        """双平台源码必须同时满足URL、校验和及字节大小一致。"""
        original = copy.deepcopy(self.catalogue)
        for field, value in (
            ("sourceSha256", "b" * 64),
            ("sourceSizeBytes", len(self.content) + 1),
            ("sourceUrl", publisher.ORIGIN + "Nivo-Bot-v2.0.4-source.zip"),
            ("sourceUrl", publisher.ORIGIN + "Nelan-v2.0.5-source.zip"),
        ):
            self.catalogue = copy.deepcopy(original)
            self.catalogue["releases"][1][field] = value
            self.save_catalogue()
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.plan()

    def test_wrong_release_notes_title_is_rejected(self):
        """发行说明必须对应当前版本，标题由文件确定。"""
        for brand, ending in product(
            ("Nivo Bot", "念步", "Nelan"),
            ("2.0.4 · Other", "2.0.5 · cadence", "2.0.5 · Cadence extra", "2.0.5"),
        ):
            self.write("docs/releases/v2.0.5.md", f"# {brand} {ending}\n")
            with self.subTest(brand=brand, ending=ending), self.assertRaises(ValueError):
                self.plan()
        for brand in ("Other", "nelan", "Nelan-Bot", "念步Nelan"):
            self.write("docs/releases/v2.0.5.md", f"# {brand} 2.0.5 · Cadence\n")
            with self.subTest(brand=brand), self.assertRaises(ValueError):
                self.plan()

    def test_new_brand_titles_keep_exact_version_and_codename(self) -> None:
        """中文与英文新品牌标题沿用精确版本及英文代号格式。"""
        for title in ("念步 2.0.5 · Cadence", "Nelan 2.0.5 · Cadence"):
            with self.subTest(title=title):
                self.write("docs/releases/v2.0.5.md", f"# {title}\n")
                self.assertEqual(self.plan().title, title)

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

    def test_android_package_switch_is_bound_to_release_version(self) -> None:
        """2.0.9起只接受新Android包名，历史版本只能接受原包名。"""
        for version, code, expected_package in (
            ("2.0.8", 59, "io.github.nanomuse.app"),
            ("2.0.9", 60, "io.github.sherlockerx.nelan"),
            ("2.0.10", 61, "io.github.sherlockerx.nelan"),
            ("2.1.0", 62, "io.github.sherlockerx.nelan"),
        ):
            plan = replace(self.plan(), tag=f"v{version}", version=version, code=code)
            for package in (
                "io.github.nanomuse.app",
                "io.github.sherlockerx.nelan",
                "io.github.nanomuse.app.uitest",
                "io.github.sherlockerx.nelan.uitest",
            ):
                badging = (
                    f"package: name='{package}' versionCode='{code}' versionName='{version}'\n"
                )
                with (
                    self.subTest(version=version, package=package),
                    patch.object(publisher, "run", return_value=badging),
                ):
                    if package == expected_package:
                        publisher.verify_apk(self.root / "app.apk", plan, "aapt")
                    else:
                        with self.assertRaisesRegex(ValueError, "APK package"):
                            publisher.verify_apk(self.root / "app.apk", plan, "aapt")

    def test_ios_bundle_identity_does_not_follow_android_package_switch(self) -> None:
        """新旧版本IPA均保留原bundle ID，Android新包名不能用于iOS。"""
        ipa = self.root / "app.ipa"
        for version, code in (("2.0.8", 59), ("2.0.9", 60), ("2.0.10", 61)):
            plan = replace(self.plan(), tag=f"v{version}", version=version, code=code)
            for package in ("io.github.nanomuse.app", "io.github.sherlockerx.nelan"):
                with zipfile.ZipFile(ipa, "w") as archive:
                    archive.writestr(
                        "Payload/Nelan.app/Info.plist",
                        plistlib.dumps(
                            {
                                "CFBundleIdentifier": package,
                                "CFBundleShortVersionString": version,
                                "CFBundleVersion": str(code),
                            }
                        ),
                    )
                with self.subTest(version=version, package=package):
                    if package == "io.github.nanomuse.app":
                        publisher.verify_ipa(ipa, plan)
                    else:
                        with self.assertRaisesRegex(ValueError, "IPA bundle"):
                            publisher.verify_ipa(ipa, plan)

    def test_release_absence_requires_actual_404(self):
        """鉴权或网络失败不能被误判为尚未创建发布。"""
        for status in ("404", "403", "500"):
            result = subprocess.CompletedProcess([], 1, "", f"gh: failure (HTTP {status})")
            with (
                patch.object(publisher.subprocess, "run", return_value=result),
                patch.object(publisher, "run", return_value="[[]]") as command,
            ):
                if status == "404":
                    self.assertIsNone(publisher.get_release(self.tag))
                    self.assertIn("--paginate", command.call_args.args[0])
                else:
                    with self.assertRaises(RuntimeError):
                        publisher.get_release(self.tag)
                    command.assert_not_called()

    def test_404_finds_exact_draft_tag_across_all_pages(self):
        """标签接口隐藏草稿时，分页列表仍能定位当前版本。"""
        draft = {**self.release(), "draft": True}
        result = subprocess.CompletedProcess([], 1, "", "gh: Not Found (HTTP 404)")
        pages = [[{**draft, "tag_name": "v2.0.4"}], [draft]]
        with (
            patch.object(publisher.subprocess, "run", return_value=result),
            patch.object(publisher, "run", return_value=json.dumps(pages)) as command,
        ):
            self.assertEqual(publisher.get_release(self.tag), draft)
        self.assertIn("--paginate", command.call_args.args[0])
        self.assertIn("--slurp", command.call_args.args[0])
        self.assertIn("?per_page=100", command.call_args.args[0][2])
        self.assertNotIn("--field", command.call_args.args[0])

    def test_duplicate_draft_tags_are_rejected(self):
        """分页中出现两个同标签记录时不能任选其一。"""
        draft = {**self.release(), "draft": True}
        result = subprocess.CompletedProcess([], 1, "", "gh: Not Found (HTTP 404)")
        with (
            patch.object(publisher.subprocess, "run", return_value=result),
            patch.object(publisher, "run", return_value=json.dumps([[draft], [draft]])),
            self.assertRaises(ValueError),
        ):
            publisher.get_release(self.tag)

    def test_release_list_failure_cannot_be_treated_as_absence(self):
        """草稿列表查询失败时停止，不能继续创建同标签发行。"""
        result = subprocess.CompletedProcess([], 1, "", "gh: Not Found (HTTP 404)")
        with (
            patch.object(publisher.subprocess, "run", return_value=result),
            patch.object(publisher, "run", side_effect=subprocess.CalledProcessError(1, "gh")),
            self.assertRaises(subprocess.CalledProcessError),
        ):
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

    def test_branch_target_is_resolved_without_modifying_published_release(self):
        """合法分支目标解析到已核验提交时，仅查询而不修改已发布内容。"""
        release = {**self.release(), "target_commitish": "master"}
        with patch.object(publisher, "run", return_value=self.commit) as command:
            publisher.publish(self.plan(), self.commit, self.root, release)
        self.assertEqual(command.call_count, 1)
        self.assertEqual(
            command.call_args.args[0],
            ["gh", "api", f"repos/{publisher.REPOSITORY}/commits/master", "--jq", ".sha"],
        )

    def test_different_branch_target_is_rejected_without_mutation(self):
        """分支解析到其他提交时拒绝，含斜杠的引用按URL片段编码。"""
        release = {**self.release(), "target_commitish": "release/mobile"}
        with (
            patch.object(publisher, "run", return_value="b" * 40) as command,
            self.assertRaises(ValueError),
        ):
            publisher.publish(self.plan(), self.commit, self.root, release)
        self.assertEqual(command.call_count, 1)
        self.assertIn("commits/release%2Fmobile", command.call_args.args[0][2])

    def test_draft_uploads_rechecks_then_publishes(self):
        """真实中间态：标签404、分页找到草稿、补齐、复核，再转为正式发行。"""
        draft = {**self.release(), "draft": True}
        missing = draft["assets"].pop()
        complete = {**self.release(), "draft": True}
        result = subprocess.CompletedProcess([], 1, "", "gh: Not Found (HTTP 404)")
        sequence = []

        def simulate(args):
            sequence.append(args[:3])
            if args[:2] == ["gh", "api"]:
                pages = [[draft]] if len(sequence) == 1 else [[complete]]
                return json.dumps(pages)
            return ""

        with (
            patch.object(publisher.subprocess, "run", return_value=result),
            patch.object(publisher, "run", side_effect=simulate) as command,
        ):
            existing = publisher.get_release(self.tag)
            publisher.publish(self.plan(), self.commit, self.root, existing)
        self.assertEqual(
            [entry[:2] if entry[1] == "api" else entry for entry in sequence],
            [["gh", "api"], ["gh", "release", "upload"], ["gh", "api"], ["gh", "release", "edit"]],
        )
        upload = command.call_args_list[1].args[0]
        self.assertIn(str(self.root / missing["name"]), upload)
        self.assertNotIn("--clobber", upload)
        edit = command.call_args_list[-1].args[0]
        self.assertIn("--draft=false", edit)
        self.assertIn("--latest", edit)
        self.assertNotIn("--notes-file", edit)

    def test_complete_draft_publishes_without_upload(self):
        """附件齐全的草稿只在再次确认身份后发布。"""
        draft = {**self.release(), "draft": True}
        with (
            patch.object(publisher, "get_release", return_value=draft),
            patch.object(publisher, "run") as command,
        ):
            publisher.publish(self.plan(), self.commit, self.root, draft)
        self.assertEqual(command.call_count, 1)
        self.assertEqual(command.call_args.args[0][:3], ["gh", "release", "edit"])

    def test_interrupted_create_resumes_draft_without_recreating_release(self):
        """create上传中断留下草稿，下一次仅补齐后发布，不重复create。"""
        with (
            patch.object(
                publisher, "run", side_effect=subprocess.CalledProcessError(1, "gh")
            ) as command,
            self.assertRaises(subprocess.CalledProcessError),
        ):
            publisher.publish(self.plan(), self.commit, self.root, None)
        self.assertEqual(command.call_count, 1)
        self.assertEqual(command.call_args.args[0][:3], ["gh", "release", "create"])
        draft = {**self.release(), "draft": True}
        draft["assets"].pop()
        completed = {**self.release(), "draft": True}
        with (
            patch.object(publisher, "get_release", side_effect=[draft, completed]),
            patch.object(publisher, "run") as command,
        ):
            publisher.publish(self.plan(), self.commit, self.root, publisher.get_release(self.tag))
        self.assertEqual(
            [call.args[0][:3] for call in command.call_args_list],
            [["gh", "release", "upload"], ["gh", "release", "edit"]],
        )

    def test_failed_draft_upload_never_publishes(self):
        """补传网络失败后保留草稿，下次仍可按同一规则恢复。"""
        draft = {**self.release(), "draft": True}
        draft["assets"].pop()
        with (
            patch.object(
                publisher, "run", side_effect=subprocess.CalledProcessError(1, "gh")
            ) as command,
            self.assertRaises(subprocess.CalledProcessError),
        ):
            publisher.publish(self.plan(), self.commit, self.root, draft)
        self.assertEqual(command.call_count, 1)
        self.assertEqual(command.call_args.args[0][:3], ["gh", "release", "upload"])

    def test_inconsistent_draft_never_uploads_or_publishes(self):
        """不同目标或已有损坏附件的草稿保持原样。"""
        for field in ("target", "asset"):
            draft = {**self.release(), "draft": True}
            if field == "target":
                draft["target_commitish"] = "b" * 40
            else:
                draft["assets"][0]["digest"] = "sha256:" + "f" * 64
            with patch.object(publisher, "run") as command, self.assertRaises(ValueError):
                publisher.publish(self.plan(), self.commit, self.root, draft)
            command.assert_not_called()

    def test_incomplete_or_replaced_draft_is_not_published(self):
        """上传后仍不完整或草稿已换身份时，绝不提前发布。"""
        draft = {**self.release(), "draft": True}
        draft["assets"].pop()
        for refreshed in (None, draft, {**self.release(), "id": 456, "draft": True}):
            with (
                patch.object(publisher, "get_release", return_value=refreshed),
                patch.object(publisher, "run") as command,
                self.assertRaises(ValueError),
            ):
                publisher.publish(self.plan(), self.commit, self.root, draft)
            self.assertEqual(command.call_count, 1)
            self.assertEqual(command.call_args.args[0][:3], ["gh", "release", "upload"])

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
