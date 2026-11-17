"""验证iOS源码下载的缓存、失败回退和哈希边界，不访问网络。"""

import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "android/deps/download_verified_archive.sh"


class VerifiedArchiveTests(unittest.TestCase):
    """用小文件和curl替身验证真实下载脚本。"""

    def setUp(self) -> None:
        """建立每个用例独立的源码包缓存和命令目录。"""
        self.bash = os.environ.get("TEST_BASH") or shutil.which("bash")
        if not self.bash:
            self.skipTest("需要Bash")
        self.temporary = tempfile.TemporaryDirectory(prefix="ios-download-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.archive = self.root / "cache/release.tar.xz"
        self.good = b"verified upstream release fixture\n"
        self.digest = hashlib.sha256(self.good).hexdigest()
        (self.root / "good").write_bytes(self.good)
        (self.root / "bad").write_bytes(b"untrusted response")
        self.log = self.root / "requests"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        curl = bin_dir / "curl"
        curl.write_text(
            "#!/bin/bash\n"
            'printf "%s\\n" "$*" >> "$FIXTURE_ROOT/requests"\n'
            'url="${@: -1}"\n'
            'while [ "$#" -gt 0 ]; do\n'
            '  if [ "$1" = "--output" ]; then output="$2"; shift; fi\n'
            "  shift\n"
            "done\n"
            'case "$url" in\n'
            '  */fail) printf "partial" > "$output"; exit 6 ;;\n'
            '  */bad) cp "$FIXTURE_ROOT/bad" "$output" ;;\n'
            '  *) cp "$FIXTURE_ROOT/good" "$output" ;;\n'
            "esac\n",
            encoding="utf-8",
            newline="\n",
        )
        curl.chmod(0o755)
        self.environment = dict(os.environ, FIXTURE_ROOT=self.root.as_posix())

    def run_download(self, *endpoints: str) -> subprocess.CompletedProcess[str]:
        """执行生产脚本并保留返回码与诊断。"""
        # 显式覆盖curl，避免Git Bash改写PATH时意外调用真实网络命令。
        wrapper = (
            'curl() { bash "$FIXTURE_ROOT/bin/curl" "$@"; }; '
            "if ! command -v shasum >/dev/null; then "
            'shasum() { shift 2; sha256sum "$@"; }; fi; '
            'source "$1" "${@:2}"'
        )
        return subprocess.run(
            [
                self.bash,
                "-c",
                wrapper,
                "download-fixture",
                SCRIPT.as_posix(),
                self.archive.as_posix(),
                self.digest,
                *endpoints,
            ],
            env=self.environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=15,
            check=False,
        )

    def test_valid_cache_avoids_network(self) -> None:
        self.archive.parent.mkdir()
        self.archive.write_bytes(self.good)
        result = self.run_download("https://upstream/fail")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())

    def test_corrupt_cache_is_replaced_by_verified_download(self) -> None:
        self.archive.parent.mkdir()
        self.archive.write_bytes(b"bad cache")
        result = self.run_download("https://upstream/good")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.archive.read_bytes(), self.good)

    def test_dns_failure_falls_back_and_keeps_retry_bounds(self) -> None:
        result = self.run_download("https://upstream/fail", "https://mirror/good")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.archive.read_bytes(), self.good)
        requests = self.log.read_text().splitlines()
        self.assertEqual(len(requests), 2)
        self.assertIn("--retry-all-errors", requests[0])
        self.assertIn("--connect-timeout 20", requests[0])
        self.assertIn("--retry-max-time 240", requests[0])

    def test_hash_mismatch_cannot_become_cached_source(self) -> None:
        result = self.run_download("https://upstream/bad", "https://mirror/fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.archive.exists())
        self.assertEqual(list(self.archive.parent.iterdir()), [])

    def test_invalid_primary_bytes_allow_verified_mirror(self) -> None:
        result = self.run_download("https://upstream/bad", "https://mirror/good")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.archive.read_bytes(), self.good)


if __name__ == "__main__":
    unittest.main()
