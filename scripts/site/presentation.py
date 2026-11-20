"""官网的阅读案例与图标，应用画面来自独立Android模拟器实拍。"""

from __future__ import annotations

from screenshots import SCREENSHOT_NOTE, screenshot_link


def icon(name: str, css: str = "") -> str:
    """生成装饰用线形图标，文字标签承担无障碍命名。"""
    paths = {
        "chat": '<path d="M5 5h14v11H9l-4 4V5Z"/><path d="M9 9h6m-6 3h4"/>',
        "tasks": '<rect x="5" y="3" width="14" height="18" rx="2"/><path d="m8 9 2 2 5-5m-7 9h8m-8 3h5"/>',
        "focus": '<circle cx="12" cy="13" r="8"/><path d="M9 2h6m-3 3v3m0 5 3-3m3-5 2-2"/>',
        "fragments": '<path d="M5 3h11l3 3v15H5V3Z"/><path d="M15 3v4h4M8 11h8m-8 4h8m-8 3h5"/>',
        "coach": '<path d="M12 5C9 3 5 3 3 4v15c3-1 6-1 9 1 3-2 6-2 9-1V4c-3-1-6-1-9 1Zm0 0v15M6 8h3m-3 4h3m6-4h3m-3 4h3"/>',
        "ideas": '<path d="M9 18h6m-6 3h6M8 14a6 6 0 1 1 8 0c-1 1-1 2-1 2H9s0-1-1-2ZM12 1v1M2 8h1m18 0h1"/>',
        "model": '<rect x="7" y="7" width="10" height="10" rx="2"/><path d="M9 3v4m6-4v4M9 17v4m6-4v4M3 9h4m-4 6h4m10-6h4m-4 6h4"/>',
        "download": '<path d="M12 3v12m-4-4 4 4 4-4M4 16v5h16v-5"/>',
    }
    return (
        f'<svg class="icon {css}" viewBox="0 0 24 24" fill="none" '
        'stroke="currentColor" stroke-width="1.5" stroke-linecap="round" '
        f'stroke-linejoin="round" aria-hidden="true">{paths[name]}</svg>'
    )


def day_story(version: str = "") -> str:
    """用阅读主题串起四个真实界面，明确草稿、计时和演示记录的状态。"""
    scenes = [
        (
            "chat",
            "聊清楚",
            "从一个小念头开始。",
            "先把今天想读一章书的念头写下来。",
            "AI对话",
            "先写下，再发送",
            "把阅读计划写进聊天，再和AI一起拆出下一步。图中保留的是未发送草稿。",
        ),
        (
            "tasks",
            "放进待办",
            "给想法一个位置。",
            "把读一章书记成一条具体的待办。",
            "个人待办",
            "从这件事出发",
            "为阅读加上分组和标签。点击任务旁的计时按钮，就能带着它开始专注。",
        ),
        (
            "focus",
            "留点时间",
            "这一会儿，留给阅读。",
            "关联阅读任务，开始计时，把注意力放回书里。",
            "沉浸专注",
            "这一段正在进行",
            "计时页只留下当前任务。结束后保存实际时长，再接着记录心得。",
        ),
        (
            "fragments",
            "留下心得",
            "把做过的事，留下来。",
            "写一句阅读感受，让今天多一点可以回看的东西。",
            "生活碎片",
            "积累可以回看",
            "心得回到生活拼图，和刚才的阅读任务、专注时段一起保存，之后可以随时回看。",
        ),
    ]
    tabs, panels = [], []
    for index, (key, label, title, text, name, note_title, note) in enumerate(scenes):
        active = index == 0
        tabs.append(
            f'<button type="button" role="tab" id="day-tab-{key}" '
            f'aria-controls="day-{key}" aria-selected="{str(active).lower()}" '
            f'tabindex="{0 if active else -1}" data-story-tab="{index}">'
            f"{icon(key)}<span>{label}</span></button>"
        )
        panels.append(
            f'<div class="story-panel" id="day-{key}" role="tabpanel" '
            f'aria-labelledby="day-tab-{key}" tabindex="0"{chr(32) + "hidden" if not active else ""}>'
            f'<div class="story-context"><h2>{title}</h2><p>{text}</p></div>'
            '<div class="story-scene">'
            f'<aside class="story-note">{icon(key)}<strong>{note_title}</strong><p>{note}</p>'
            f'<a href="features/{key}.html">了解{name}</a></aside>'
            f"{screenshot_link(key, version=version, is_priority=active)}"
            "</div></div>"
        )
    return (
        '<section class="day-story" aria-label="阅读主题的应用截图" data-story>'
        '<div class="story-topline"><span>今天，从读一章书开始</span><span class="story-example">Android实拍</span></div>'
        f'<div class="story-tabs" role="tablist" aria-label="查看日常案例的不同阶段">{"".join(tabs)}</div>'
        f'<div class="story-panels">{"".join(panels)}</div>'
        f'<p class="story-provenance">{SCREENSHOT_NOTE}</p>'
        '<noscript><p class="story-fallback">查看<a href="features.html">功能画廊</a>，了解其他功能。</p></noscript>'
        "</section>"
    )
