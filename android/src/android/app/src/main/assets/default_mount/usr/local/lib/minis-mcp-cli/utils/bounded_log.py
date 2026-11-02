"""跨进程串行追加有限大小的诊断日志。"""
import os
try:
    import fcntl
except ImportError:
    fcntl = None
import time


def append(path, message):
    """保留当前日志和上一份，避免长期使用时无限增长。"""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".lock", "a", encoding="utf-8") as lock:
            if fcntl is not None:
                fcntl.flock(lock, fcntl.LOCK_EX)
            if os.path.exists(path) and os.path.getsize(path) >= 1048576:
                os.replace(path, path + ".1")
            with open(path, "a", encoding="utf-8") as target:
                target.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), str(message)[:2000]))
    except OSError:
        pass
