"""使用本地替身覆盖认证分类、配置恢复和无凭据健康记录。"""
import json
import os
import tempfile
import threading
import unittest
from unittest.mock import patch, MagicMock

import httpx
from transport.http import HTTPTransport, MCPError
from daemon import MCPPool
from utils import config, health


class RuntimeFixesTest(unittest.TestCase):
    """不连接服务、不安装依赖、不使用真实令牌。"""

    def test_unauthorized_is_explicit_and_response_body_is_not_exposed(self):
        transport = HTTPTransport({"url": "https://example.invalid/mcp"}, "fixture")
        with patch("transport.http.httpx.post", return_value=httpx.Response(401, text="private-response")):
            with self.assertRaises(MCPError) as error:
                transport.initialize()
        self.assertEqual("AUTH_REQUIRED", error.exception.code)
        self.assertNotIn("private-response", error.exception.message)

    def test_pool_reloads_changed_configuration(self):
        first = {"url": "https://example.invalid/one", "enabled": True}
        second = {"url": "https://example.invalid/two", "enabled": True}
        pool = MCPPool(lambda: None)
        session = MagicMock()
        session.is_alive.return_value = True
        replacement = MagicMock()
        with patch.object(config, "get_server", side_effect=[first, first, second, second]), patch.object(pool, "_make_session", side_effect=[session, replacement]):
            self.assertIs(session, pool.get("fixture"))
            self.assertIs(replacement, pool.get("fixture"))
        session.stop.assert_called_once()

    def test_health_sidecar_contains_only_status_and_config_fingerprint(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "servers.json")
            with open(path, "w", encoding="utf-8") as target:
                json.dump({"mcpServers": {}}, target)
            with patch.object(config, "CONFIG_DIR", directory), patch.object(config, "CONFIG_PATH", path):
                health.record("fixture", {"ok": False, "code": "AUTH_REQUIRED", "error": "private-response"})
            files = os.listdir(os.path.join(directory, "health"))
            with open(os.path.join(directory, "health", files[0]), encoding="utf-8") as source:
                saved = json.load(source)
            self.assertEqual("auth_required", saved["status"])
            self.assertNotIn("private-response", str(saved))
            self.assertEqual(64, len(saved["signature"]))

    def test_refresh_waits_for_inflight_tool(self):
        pool = MCPPool(lambda: None)
        entered = threading.Event()
        release = threading.Event()
        session = MagicMock()
        session.is_alive.return_value = True
        configuration = {"url": "https://example.invalid/mcp"}
        def tool(current):
            entered.set()
            release.wait(2)
        with patch.object(config, "get_server", return_value=configuration), patch.object(pool, "_make_session", return_value=session):
            caller = threading.Thread(target=lambda: pool.call_with_retry("fixture", tool), daemon=True)
            caller.start()
            self.assertTrue(entered.wait(1))
            checker = threading.Thread(target=lambda: pool.call_with_retry("fixture", lambda current: None, refresh=True), daemon=True)
            checker.start()
            try:
                self.assertFalse(session.stop.called)
            finally:
                release.set()
                caller.join(2)
                checker.join(2)
        self.assertFalse(caller.is_alive())
        self.assertFalse(checker.is_alive())


if __name__ == "__main__":
    unittest.main()
