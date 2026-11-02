"""在独立验收包中比较折叠标题的实际绘制帧，不读取正式应用数据。"""

import argparse
import json
import re
import subprocess
import time
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path


def adb(*arguments: str) -> str:
    """仅操作指定模拟器，失败时停止验收。"""
    result = subprocess.run(
        ["F:/Andriod/platform-tools/adb.exe", "-s", "emulator-5554", *arguments],
        check=True, capture_output=True, text=True, encoding="utf-8",
    )
    return result.stdout


def rpc(method: str, **parameters: object) -> dict:
    """通过验收包的本地调试端口调用离线探针。"""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": parameters}).encode()
    request = urllib.request.Request(
        "http://127.0.0.1:15322/rpc", body, {"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError(result["error"])
    return result["result"]


def header_center() -> tuple[int, int]:
    """只接受本次成功导出的界面，避免读取转场时残留的旧快照。"""
    for attempt in range(15):
        remote = f"/sdcard/nm-fold-{uuid.uuid4().hex}.xml"
        output = adb("shell", "uiautomator", "dump", remote)
        if "dumped to" not in output:
            time.sleep(1)
            continue
        document = adb("exec-out", "cat", remote)
        adb("shell", "rm", remote)
        nodes = ET.fromstring(document).iter("node")
        for node in nodes:
            text = node.get("text", "")
            if text.startswith(("▸", "▾")) and ("execution" in text or "执行" in text):
                left, top, right, bottom = map(int, re.findall(r"\d+", node.get("bounds", "")))
                return (left + right) // 2, (top + bottom) // 2
        time.sleep(1)
    raise RuntimeError("未找到合成对话的过程标题")


def main() -> None:
    """生成测试对话，连续点击并保存全部中间帧。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=400)
    parser.add_argument("--tools", type=int, default=12)
    parser.add_argument("--reasoning-repeats", type=int, default=40)
    parser.add_argument("--toggles", type=int, default=4)
    parser.add_argument("--interval", type=float, default=0.8)
    parser.add_argument("--max-deviation", type=float)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    fixture = rpc("debug.uiFixture", count=options.count, tools=options.tools,
                  reasoning_repeats=options.reasoning_repeats)
    adb("shell", "am", "start", "-W", "-n",
        "io.github.nanomuse.app.uitest/com.openminis.app.MainActivity",
        "-a", "android.intent.action.VIEW", "-d", f"minis://session/{fixture['session_id']}")
    time.sleep(3)
    center = header_center()
    rpc("debug.uiFoldTrace", action="start")
    for _ in range(options.toggles):
        adb("shell", "input", "tap", str(center[0]), str(center[1]))
        time.sleep(options.interval)
    result = rpc("debug.uiFoldTrace", action="stop")
    summaries = []
    for trace in result["traces"]:
        frames = trace["frames"]
        deviations = [abs(frame["y"] - trace["beforeY"]) for frame in frames if frame["y"] is not None]
        summaries.append({"frames": len(frames), "missing": sum(frame["y"] is None for frame in frames),
                          "max_deviation_px": max(deviations, default=None),
                          "first_draw_ms": frames[0]["ms"] if frames else None})
    result.update(fixture=fixture, summaries=summaries, center=center)
    options.output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summaries, ensure_ascii=False))
    if len(summaries) != options.toggles:
        raise RuntimeError("并非每次点击都命中了折叠标题，不能据此宣称通过")
    if options.max_deviation is not None:
        for summary in summaries:
            deviation = summary["max_deviation_px"]
            if summary["missing"] or deviation is None or deviation > options.max_deviation:
                raise RuntimeError(f"实际绘制帧的标题位置不稳定: {summary}")


if __name__ == "__main__":
    main()
