"""统一管理独立Android模拟器实拍截图及其网页展示。"""

from __future__ import annotations

from html import escape

SCREENSHOT_WIDTH = 1080
SCREENSHOT_HEIGHT = 2400
SCREENSHOT_NOTE = "当前维护版本的Android模拟器截图，内容为演示数据。"
SCREENSHOTS = {
    "chat": {
        "path": "media/screenshots/chat.png",
        "name": "AI对话",
        "alt": "Android模拟器中的AI对话界面，输入框保留尚未发送的阅读计划草稿",
    },
    "tasks": {
        "path": "media/screenshots/tasks.png",
        "name": "个人待办",
        "alt": "Android模拟器中的个人待办界面，展示阅读任务的演示记录",
    },
    "focus": {
        "path": "media/screenshots/focus.png",
        "name": "沉浸专注",
        "alt": "Android模拟器中的沉浸专注界面，阅读任务正在计时",
    },
    "fragments": {
        "path": "media/screenshots/fragments.png",
        "name": "生活碎片",
        "alt": "Android模拟器中的生活碎片界面，展示阅读心得和3分25秒专注的演示记录",
    },
    "coach": {
        "path": "media/screenshots/coach.png",
        "name": "成长教练",
        "alt": "Android模拟器中的成长教练界面",
    },
    "ideas": {
        "path": "media/screenshots/ideas.png",
        "name": "每日点子",
        "alt": "Android模拟器中的每日点子界面",
    },
}


def screenshot_url(identifier: str, prefix: str = "", version: str = "") -> str:
    """返回同一张完整原图的地址，版本由包含截图字节的资源哈希提供。"""
    suffix = f"?v={version}" if version else ""
    return f"{prefix}{SCREENSHOTS[identifier]['path']}{suffix}"


def screenshot_link(
    identifier: str, prefix: str = "", version: str = "", is_priority: bool = False
) -> str:
    """展示保持原比例的截图，并提供无需脚本的完整原图入口。"""
    screenshot = SCREENSHOTS[identifier]
    source = escape(screenshot_url(identifier, prefix, version), quote=True)
    priority = 'fetchpriority="high"' if is_priority else 'loading="lazy"'
    return (
        f'<a class="app-screenshot" href="{source}" '
        f'aria-label="查看{screenshot["name"]}的完整截图">'
        f'<img src="{source}" width="{SCREENSHOT_WIDTH}" height="{SCREENSHOT_HEIGHT}" '
        f'alt="{escape(screenshot["alt"], quote=True)}" {priority} decoding="async">'
        '<span class="screenshot-open" aria-hidden="true">查看完整截图</span></a>'
    )
