"""保存不含凭据的探活结果，配置变化或超时后不再阻断重试。"""
import hashlib
import json
import os
import threading
import time
from utils import config

_LOCK = threading.Lock()


def record(server, response):
    """原子保存状态码和检查时间，不保存请求头、地址或响应正文。"""
    if not server:
        return
    try:
        with open(config.CONFIG_PATH, "rb") as source:
            signature = hashlib.sha256(source.read()).hexdigest()
        state = "connected" if response.get("ok") else (
            "auth_required" if response.get("code") == "AUTH_REQUIRED" else "unavailable")
        directory = os.path.join(config.CONFIG_DIR, "health")
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, hashlib.sha256(server.encode()).hexdigest() + ".json")
        payload = {"server_id": server, "status": state, "checked_at_ms": int(time.time() * 1000), "signature": signature}
        with _LOCK:
            with open(path + ".tmp", "w", encoding="utf-8") as target:
                json.dump(payload, target)
            os.replace(path + ".tmp", path)
    except OSError:
        return
