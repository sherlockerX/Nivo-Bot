#!/usr/bin/env python3
"""将安卓每日点子与热点核实提示生成到iOS资源，保留唯一内容来源。"""

from __future__ import annotations

import argparse
import json
import re
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android/src/android/app/src/main"
OUTPUT = ROOT / "android/src/ios/NanoMuse/Resources"


def resources() -> dict[str, str]:
    """返回待打包的原始目录和提示，不另造一套点子内容。"""
    result = {}
    for language in ("en", "zh"):
        name = f"daily-ideas.{language}.json"
        text = (ANDROID / "assets/nanomuse" / name).read_text(encoding="utf-8")
        parsed = json.loads(text)
        if [section["id"] for section in parsed["sections"]] != [
            "ideas",
            "work",
            "life",
            "learn",
            "family",
            "media",
            "more",
        ]:
            raise ValueError("安卓每日点子分类发生变化，请同步核对iOS枚举")
        result[name] = text
    source = ANDROID / "java/io/github/nanomuse/ideas/DailyHotTopicPrompt.kt"
    prompts = re.findall(
        r'"""(.*?)"""\.trimIndent\(\)', source.read_text(encoding="utf-8"), re.S
    )
    if len(prompts) != 2 or any("$date" not in prompt for prompt in prompts):
        raise ValueError("安卓热点提示格式发生变化，请核对生成器")
    localized_prompts = dict(
        zip(
            ("zh", "en"),
            (textwrap.dedent(text).strip() for text in prompts),
            strict=True,
        )
    )
    result["daily-hot-topic.json"] = (
        json.dumps(localized_prompts, ensure_ascii=False, indent=2) + "\n"
    )
    return result


def main() -> int:
    """默认生成，检查模式仅报告资源是否与安卓一致。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    stale = []
    for name, text in resources().items():
        path = OUTPUT / name
        if arguments.check:
            if not path.is_file() or path.read_text(encoding="utf-8") != text:
                stale.append(name)
        else:
            path.write_text(text, encoding="utf-8", newline="\n")
            print(f"wrote {path.relative_to(ROOT)}")
    if stale:
        print("需要重新生成：" + ", ".join(stale))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
