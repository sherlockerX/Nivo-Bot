"""在独立验收包中执行一次基于新鲜UI快照的操作，不配置模型或访问正式应用。"""

import argparse
import json
import re
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET


def adb(*arguments: str) -> str:
    """仅操作指定模拟器，所有参数独立传递。"""
    result = subprocess.run(
        ["F:/Andriod/platform-tools/adb.exe", "-s", "emulator-5554", *arguments],
        check=True, capture_output=True, text=True, encoding="utf-8", timeout=30,
    )
    return result.stdout


def snapshot() -> list[ET.Element]:
    """只读取本次成功导出的快照，拒绝正式应用或锁屏界面。"""
    for _ in range(5):
        remote = f"/sdcard/nm-six-{uuid.uuid4().hex}.xml"
        output = adb("shell", "uiautomator", "dump", remote)
        if "dumped to" not in output:
            time.sleep(1)
            continue
        document = adb("exec-out", "cat", remote)
        adb("shell", "rm", remote)
        nodes = list(ET.fromstring(document).iter("node"))
        packages = {node.get("package") for node in nodes}
        if "io.github.nanomuse.app.uitest" not in packages:
            raise RuntimeError("隔离验收应用不在前台，拒绝操作")
        return nodes
    raise RuntimeError("没有取得当前UI快照")


def main() -> None:
    """每次只进行一个动作，再观察结果；未指定动作则仅查看。"""
    parser = argparse.ArgumentParser()
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--tap-label")
    actions.add_argument("--tap-class")
    actions.add_argument("--tap-checkbox", type=int)
    actions.add_argument("--input")
    actions.add_argument("--back", action="store_true")
    parser.add_argument("--occurrence", type=int)
    options = parser.parse_args()
    nodes = snapshot()
    candidates = []
    if options.tap_label is not None:
        candidates = [node for node in nodes if options.tap_label in
                      (node.get("text"), node.get("content-desc"))]
    if options.tap_class is not None:
        candidates = [node for node in nodes if node.get("class") == options.tap_class]
    if options.tap_checkbox is not None:
        candidates = [node for node in nodes if node.get("checkable") == "true"]
        options.occurrence = options.tap_checkbox
    if candidates:
        if len(candidates) != 1 and options.occurrence is None:
            raise RuntimeError(f"目标不唯一，共{len(candidates)}项，必须明确序号")
        target = candidates[options.occurrence or 0]
        left, top, right, bottom = map(int, re.findall(r"\d+", target.get("bounds", "")))
        adb("shell", "input", "tap", str((left + right) // 2), str((top + bottom) // 2))
    elif options.tap_label is not None or options.tap_class is not None or options.tap_checkbox is not None:
        raise RuntimeError("当前快照中没有请求的目标")
    if options.input is not None:
        if not re.fullmatch(r"[A-Za-z0-9_ -]+", options.input):
            raise RuntimeError("测试输入只允许合成ASCII文字")
        adb("shell", "input", "text", options.input.replace(" ", "%s"))
    if options.back:
        adb("shell", "input", "keyevent", "KEYCODE_BACK")
    if candidates or options.input is not None or options.back:
        time.sleep(0.4)
        nodes = snapshot()
    rows = [
        {"text": node.get("text"), "description": node.get("content-desc"),
         "class": node.get("class"), "bounds": node.get("bounds"),
         "checked": node.get("checked"), "enabled": node.get("enabled")}
        for node in nodes if node.get("text") or node.get("content-desc")
        or node.get("checkable") == "true" or node.get("class") == "android.widget.EditText"
    ]
    print(json.dumps(rows, ensure_ascii=False))


if __name__ == "__main__":
    main()
