"""离线验证fakefsify宿主配置只选择当前iSH源码支持的架构组合。"""

import os
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "android/deps/fakefsify_guest_arch.sh"
ISH = ROOT / "android/deps/ish"


class FakefsifyGuestArchTests(unittest.TestCase):
    """执行真实选择脚本并核对Meson将引用的源码，不构建也不联网。"""

    def setUp(self) -> None:
        """使用显式Bash或本机Bash。"""
        self.bash = os.environ.get("TEST_BASH") or shutil.which("bash")
        if not self.bash:
            self.skipTest("需要Bash")

    def select_guest(self, *architectures: str) -> subprocess.CompletedProcess[str]:
        """保留实际脚本的退出码和输出，未知架构不能静默成功。"""
        return subprocess.run(
            [self.bash, SCRIPT.as_posix(), *architectures],
            capture_output=True,
            encoding="utf-8",
            timeout=10,
            check=False,
        )

    def assert_guest(self, architecture: str, guest: str) -> None:
        """不依赖子模块，核对真实脚本的宿主架构映射。"""
        result = self.select_guest(architecture)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), guest)

    def test_intel_selects_x86_guest(self) -> None:
        """Intel宿主必须避开不存在的ARM64 guest与x86_64宿主组合。"""
        self.assert_guest("x86_64", "x86")

    def test_apple_silicon_keeps_arm64_guest(self) -> None:
        """Apple Silicon继续选择已有ARM64 guest实现。"""
        self.assert_guest("arm64", "arm64")

    def test_aarch64_alias_selects_arm64_guest(self) -> None:
        """其他uname实现的aarch64名称映射到同一受支持组合。"""
        self.assert_guest("aarch64", "arm64")

    def test_selected_guests_have_gadgets_in_checked_out_ish(self) -> None:
        """子模块已检出才核对固定源码；缺失gadget仍须失败，不能当作未检出。"""
        if not (ISH / "meson.build").is_file():
            self.skipTest("iSH子模块未检出：仅跳过gadget源码覆盖检查")
        for architecture, cpu_family in [
            ("x86_64", "x86_64"),
            ("arm64", "aarch64"),
            ("aarch64", "aarch64"),
        ]:
            with self.subTest(architecture=architecture):
                result = self.select_guest(architecture)
                self.assertEqual(result.returncode, 0, result.stderr)
                guest = result.stdout.strip()
                directory = ISH / f"asbestos/guest-{guest}/gadgets-{cpu_family}"
                self.assertTrue((directory / "entry.S").is_file(), directory)

    def test_unknown_host_is_rejected_before_meson(self) -> None:
        """不支持的宿主明确失败，不能回退到错误架构。"""
        result = self.select_guest("riscv64")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("Unsupported fakefsify host architecture", result.stderr)

    def test_missing_architecture_is_rejected(self) -> None:
        """调用方必须提供实际宿主架构。"""
        result = self.select_guest()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("Usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
