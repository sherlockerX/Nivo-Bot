#!/usr/bin/env python3
"""从安卓已审阅的逐单元侧车生成iOS课程资源，拒绝标点位置推断。"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android/src/android/app/src/main"
COACH = ANDROID / "java/io/github/nanomuse/coach"
OUTPUT = ROOT / "android/src/ios/NanoMuse/Resources/coach-curriculum.json"
STRING = r'"(?:[^"\\]|\\.)*"'
ENTRY = re.compile(
    rf'({STRING})\s+to Entry\(({STRING}),\s*'
    rf'Target\(({STRING}),\s*({STRING}),\s*({STRING}),\s*(true|false)\)\)'
)
UNIT = re.compile(r"^\s*-\s+(\d+\.\d+(?:\.\d+)*)[ \t]+(.+?)\s*$")


def sha256(text: str) -> str:
    """用UTF-8原文计算与安卓一致的指纹。"""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def reviewed_targets(text: str) -> dict[str, dict[str, str | bool]]:
    """逐项读取显式字段，未知Kotlin语法触发数量检查而不是忽略。"""
    matches = list(ENTRY.finditer(text))
    expected = len(re.findall(r'"[a-z]+:[\d.]+"\s+to Entry', text))
    if len(matches) != expected or not matches:
        raise ValueError("安卓课程侧车格式变化，请检查生成器")
    targets: dict[str, dict[str, str | bool]] = {}
    for match in matches:
        key, digest, principle, scenario, practice = map(json.loads, match.groups()[:5])
        if key in targets:
            raise ValueError(f"重复的课程单元：{key}")
        targets[key] = {
            "sourceHash": digest,
            "principle": principle,
            "scenario": scenario,
            "practice": practice,
            "requiresRealAction": match[6] == "true",
        }
    return targets


def unit_title(heading: str) -> str:
    """只移除框架或书目引用，保留标题中有含义的括号。"""
    match = re.search(r"\s*[（(]([^）)]*)[）)]\s*$", heading)
    if match is None:
        return heading
    reference = match[1].strip()
    if "；" in reference or ";" in reference or re.fullmatch(
        r"(?:[A-H][ A-H、,]*|全部|B\d+(?:\s+B\d+)*)", reference
    ):
        return heading[: match.start()].strip()
    return heading


def kotlin_templates(text: str, start: str, end: str) -> dict[str, str]:
    """复用安卓教学方法和评价文案，生成器不另写一套教学要求。"""
    section = text.split(start, 1)[1].split(end, 1)[0]
    return {
        kind.lower(): json.loads(value)
        for kind, value in re.findall(rf"CoachKind\.([A-Z]+)\s*->\s*({STRING})", section)
    }


def build_unit(
    course_id: str,
    kind: str,
    line: str,
    targets: dict[str, dict[str, str | bool]],
    methods: dict[str, str],
    applications: dict[str, str],
    source_limit: str,
) -> dict:
    """源行必须与已审阅侧车指纹一致，否则停止生成。"""
    match = UNIT.fullmatch(line)
    if match is None:
        raise ValueError("不是课程单元行")
    unit_id, body = match.groups()
    key = f"{course_id}:{unit_id}"
    target = targets[key]
    if sha256(line) != target["sourceHash"]:
        raise ValueError(f"{key}原文已变化，需要先审阅安卓结构侧车")
    heading, description = re.split(r"[：:]", body, maxsplit=1)
    title = unit_title(heading.strip())
    principle = str(target["principle"])
    scenario = str(target["scenario"])
    practice = str(target["practice"])
    application = applications[kind]
    for name, value in {"title": title, "principle": principle, "scenario": scenario}.items():
        application = application.replace(f"${name}", value)
    if not scenario:
        application = (
            f"「{title}」未提供独立情景；先与学习者确认一个可演练的情景，再应用「{principle}」，"
            "不要把实践任务冒充为情景。"
        )
    practice_description = (
        f"完成「{title}」的任务：{practice}。报告实际做了什么、发生时间或次数、观察结果与障碍；"
        "仅有计划不能通过此项。"
        if target["requiresRealAction"]
        else f"提交「{title}」要求的产出：{practice}。区分情境演练、本人实际完成的行动与尚未发生的计划。"
    )
    descriptions = [
        ("understanding", f"用自己的话准确说明「{title}」的具体目标：{principle}"),
        ("application", application),
        ("practice", practice_description),
    ]
    criteria = [
        {
            "id": identifier,
            "description": value,
            "requiresRealAction": identifier == "practice" and target["requiresRealAction"],
            "dimension": "understanding" if identifier == "understanding" else "application",
        }
        for identifier, value in descriptions
    ]
    return {
        "id": unit_id,
        "title": title,
        "focus": description.strip() or title,
        "method": methods[kind] + source_limit,
        "criteria": criteria,
        "source": line,
        "needsCriteriaReview": False,
        **target,
    }


def generate() -> dict:
    """六门课程的顺序、版本和原文均由当前安卓源码确定。"""
    repository = (COACH / "CoachCurriculumRepository.kt").read_text(encoding="utf-8")
    sidecar = (COACH / "CoachBuiltInUnits.kt").read_text(encoding="utf-8")
    targets = reviewed_targets(sidecar)
    protocol = re.search(r'const val PROTOCOL = "([^"]+)"', sidecar)[1]
    definitions = re.findall(
        rf"BuiltInCourse\(({STRING}),\s*CoachKind\.([A-Z]+),\s*({STRING}),\s*({STRING})\)",
        repository,
    )
    methods = kotlin_templates(repository, "private fun teachingMethod", "private fun criteria")
    applications = kotlin_templates(repository, "private fun applicationCriterion", "private fun declaredVersion")
    source_limit = json.loads(re.search(rf"SOURCE_LIMIT\s*=\s*({STRING})", repository)[1])
    courses = []
    covered = set()
    for encoded_id, raw_kind, encoded_title, encoded_place in definitions:
        course_id, title, place = map(json.loads, (encoded_id, encoded_title, encoded_place))
        kind = raw_kind.lower()
        source = (ANDROID / f"assets/preset/skills/growth-{course_id}/SKILL.md").read_text(encoding="utf-8")
        lines = [line for line in source.splitlines() if UNIT.fullmatch(line)]
        units = [build_unit(course_id, kind, line, targets, methods, applications, source_limit) for line in lines]
        covered.update(f"{course_id}:{unit['id']}" for unit in units)
        title_match = re.search(r"^# (.+)$", source, re.MULTILINE)
        declared = re.search(r"^version:\s*(.+)$", source, re.MULTILINE)
        version = ([declared[1].strip().strip("\"'")] if declared else []) + ["local-" + sha256(source)[:12], protocol]
        courses.append({
            "id": course_id, "title": title_match[1].strip() if title_match else title,
            "place": place, "kind": kind, "units": units, "version": "+".join(version),
            "source": source, "importProtocol": protocol, "builtInSourceId": course_id,
            "needsCriteriaReview": False,
        })
    if covered != targets.keys():
        raise ValueError("课程与结构侧车的单元集合不一致")
    return {"protocol": protocol, "courses": courses}


def main() -> int:
    """生成或检查资源，检查模式不会修改文件。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = generate()
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
            print("iOS课程资源与安卓源不一致，请运行生成器")
            return 1
    else:
        OUTPUT.write_text(encoded, encoding="utf-8", newline="\n")
    count = sum(len(course["units"]) for course in result["courses"])
    print(f"{len(result['courses'])}门课程，{count}个已审阅单元")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
