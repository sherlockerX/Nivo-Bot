"""核对安卓审阅源与iOS实际打包资源，防止课程语义再次错位。"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ios-coach-curriculum.py"
SPEC = importlib.util.spec_from_file_location("ios_coach_curriculum", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


@pytest.fixture(scope="module")
def courses() -> dict[str, dict]:
    """直接读取应用打包的资源，避免只验证生成函数的临时返回值。"""
    resource = json.loads(GENERATOR.OUTPUT.read_text(encoding="utf-8"))
    return {course["id"]: course for course in resource["courses"]}


def test_resource_matches_current_reviewed_android_source() -> None:
    actual = json.loads(GENERATOR.OUTPUT.read_text(encoding="utf-8"))
    assert actual == GENERATOR.generate()


def test_all_six_courses_preserve_order_and_121_unique_units(courses: dict) -> None:
    assert list(courses) == ["principles", "lenses", "english", "expression", "leadership", "habits"]
    assert sum(len(course["units"]) for course in courses.values()) == 121
    for course in courses.values():
        ids = [unit["id"] for unit in course["units"]]
        assert len(ids) == len(set(ids))
        assert all(unit["source"] in course["source"] for unit in course["units"])


def test_anchoring_theory_is_not_used_as_the_sellers_scene(courses: dict) -> None:
    unit = next(unit for unit in courses["principles"]["units"] if unit["id"] == "2.1")
    assert "最常见的是锚定、可得性和忽略基础率" in unit["principle"]
    assert unit["scenario"] == "二手卖家先报高价再让利"
    assert "最常见的是" not in unit["criteria"][1]["description"]


@pytest.mark.parametrize(
    ("course_id", "practice"),
    [("principles", "请教 3 位"), ("english", "发出"), ("expression", "周报")],
)
def test_actual_actions_are_explicitly_gated_across_courses(
    courses: dict, course_id: str, practice: str
) -> None:
    units = [unit for unit in courses[course_id]["units"] if practice in unit["practice"]]
    assert units
    assert all(unit["criteria"][2]["requiresRealAction"] for unit in units)
    assert all(unit["criteria"][2]["dimension"] == "application" for unit in units)


def test_source_edit_cannot_silently_reuse_reviewed_sidecar(courses: dict) -> None:
    unit = courses["principles"]["units"][0]
    targets = {"principles:" + unit["id"]: unit}
    with pytest.raises(ValueError, match="原文已变化"):
        GENERATOR.build_unit("principles", "judgment", unit["source"] + "修改", targets, {}, {}, "")


def test_draft_only_practice_does_not_become_real_action_by_course_kind(courses: dict) -> None:
    unit = next(unit for unit in courses["principles"]["units"] if unit["id"] == "1.4")
    assert not unit["requiresRealAction"]
    assert not unit["criteria"][2]["requiresRealAction"]
