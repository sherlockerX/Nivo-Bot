"""从可审查内容源生成独立产品页面和原创SVG功能图，不请求模型或远程素材。"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
from pathlib import Path

from content import FEATURES, PROVIDERS

ROOT = Path(__file__).resolve().parents[2] / "site"
ORIGIN = "https://nivo.8666886.xyz/"
REPO = "https://github.com/sherlockerX/Nivo-Bot"
ASSET_HASH = ""


def esc(value: object) -> str:
    """转义写入HTML和SVG的内容。"""
    return html.escape(str(value), quote=True)


def link(url: str, label: str, css: str = "") -> str:
    """为外部文档添加明确的新窗口安全属性。"""
    external = ' target="_blank" rel="noopener noreferrer"' if url.startswith("https://") else ""
    return f'<a href="{esc(url)}" class="{esc(css)}"{external}>{label}</a>'


def page(path: str, title: str, description: str, body: str, section: str) -> str:
    """生成具有统一导航、元信息和无障碍入口的真实独立页面。"""
    prefix = "../" * (len(Path(path).parts) - 1)
    navigation = [
        ("index.html", "认识Nivo", "home"),
        ("features.html", "功能画廊", "features"),
        ("models.html", "模型接入", "models"),
        ("developers.html", "开放项目", "developers"),
        ("downloads.html", "下载应用", "downloads"),
    ]
    nav = "".join(
        f'<a href="{prefix}{url}"{(" aria-current=" + chr(34) + "page" + chr(34)) if section == key else ""}>{name}</a>'
        for url, name, key in navigation
    )
    return f'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#f4f3ec"><meta name="description" content="{esc(description)}">
<meta property="og:title" content="{esc(title)} · Nivo Bot"><meta property="og:description" content="{esc(description)}"><meta property="og:type" content="website">
<meta property="og:image" content="{ORIGIN}media/chat.svg"><link rel="canonical" href="{ORIGIN}{path if path != "index.html" else ""}">
<title>{esc(title)} · Nivo Bot</title><link rel="icon" href="{prefix}brand-mark.svg" type="image/svg+xml">
<link rel="stylesheet" href="{prefix}product.css?v={ASSET_HASH}"><script src="{prefix}product.js?v={ASSET_HASH}" defer></script></head>
<body data-root="{prefix or "./"}" data-page="{section}"><a class="skip" href="#main">跳到正文</a>
<header class="header"><a class="brand" href="{prefix}index.html"><img src="{prefix}brand-mark.svg" width="32" height="32" alt=""><span>Nivo Bot<span class="accent">.</span></span></a>
<button class="menu-button" type="button" aria-controls="navigation" aria-expanded="false">导航<span aria-hidden="true">＋</span></button><nav id="navigation" aria-label="主导航">{nav}</nav></header>
<main id="main">{body}</main>
<footer class="footer wrap"><div class="footer-intro"><a class="brand" href="{prefix}index.html">Nivo Bot<span class="accent">.</span></a><p>让对话走向行动，<br>让日常留下积累。</p></div>
<div><strong>开始使用</strong><a href="{prefix}features.html">看看它能做什么</a><a href="{prefix}models.html">连接你的模型</a><a href="{prefix}downloads.html">下载与版本记录</a></div>
<div><strong>开放项目</strong>{link(REPO, "GitHub ↗")}<a href="{prefix}developers.html">构建与贡献</a><a href="{prefix}privacy.html">数据与隐私</a></div>
<div class="footer-bottom"><span>GPL-3.0-or-later · 致谢nanoMuse与OpenMinis</span><span>A little more intentional.</span></div></footer>
<p class="sr-only" id="page-status" role="status" aria-live="polite"></p></body></html>'''


def title_block(kicker: str, title: str, summary: str) -> str:
    """生成紧凑的页面引言。"""
    return f'<div class="page-intro wrap"><p class="eyebrow">{kicker}</p><h1>{title}</h1><p class="lead">{summary}</p></div>'


def carousel(prefix: str = "") -> str:
    """输出有静态首帧和独立详情链接的可访问图片轮播。"""
    slides, tabs = [], []
    for index, feature in enumerate(FEATURES):
        active = index == 0
        slides.append(f'''<article class="slide" id="slide-{feature["id"]}" role="tabpanel" aria-labelledby="slide-tab-{feature["id"]}"{"" if active else " hidden"}>
<img src="{prefix}media/{feature["id"]}.svg?v={ASSET_HASH}" width="1280" height="800" alt="{feature["name"]}功能示意：{esc(feature["summary"])}" {'fetchpriority="high"' if active else 'loading="lazy"'}>
<div class="slide-caption"><div><span class="eyebrow">{index + 1:02d} / 06</span><h3>{feature["name"]}</h3><p>{feature["summary"]}</p></div><a class="text-link" href="{prefix}features/{feature["id"]}.html">了解这个功能 <span>↗</span></a></div></article>''')
        tabs.append(
            f'<button role="tab" id="slide-tab-{feature["id"]}" aria-controls="slide-{feature["id"]}" aria-selected="{str(active).lower()}" tabindex="{0 if active else -1}" data-slide="{index}">{feature["name"]}</button>'
        )
    return f"""<section class="gallery" aria-label="Nivo Bot功能轮播" aria-roledescription="图片轮播" tabindex="0" data-carousel>
<div class="gallery-tabs" role="tablist" aria-label="选择要了解的功能">{"".join(tabs)}</div><div class="gallery-stage">{"".join(slides)}</div>
<div class="gallery-controls"><span class="muted">原创功能示意，使用示例内容，并非手机截图</span><div><span data-carousel-count aria-live="polite" aria-atomic="true">01 / 06</span><button type="button" data-carousel-prev aria-label="上一个功能">←</button><button type="button" data-carousel-play aria-label="暂停自动轮播">暂停</button><button type="button" data-carousel-next aria-label="下一个功能">→</button></div></div></section>"""


def home() -> str:
    """用产品定位、功能图与清楚的下一步解释软件。"""
    return (
        """<section class="hero wrap"><div><p class="eyebrow"><span class="live-dot"></span>开源AI日常工作台</p><h1>想法说出来，<br>生活<span class="serif accent">动起来。</span></h1>
<p class="hero-copy">一个把AI对话、日常行动和个人成长连起来的App。<br>聊清一件事，安排一个任务，留一段专注，<br>再把经历变成看得见的积累。</p>
<div class="actions"><a class="button primary" href="downloads.html">下载Android版 <span>↗</span></a><a class="text-link" href="models.html">先了解如何接入模型 →</a></div>
<div class="hero-facts"><span>Android 8.0+</span><span>自主选择模型</span><span>免费开源客户端</span></div></div>
<aside class="hero-note"><span class="eyebrow">A MORE INTENTIONAL DAY</span><div class="note-sun" aria-hidden="true">☼</div><p>不必一次改变很多。<br>从今天的<br><em>一件小事</em>开始。</p><div class="note-rule"></div><small>聊天 → 待办 → 专注 → 记录</small></aside></section>
<section class="wrap section" id="experience"><div class="section-heading"><div><p class="eyebrow">MEET YOUR EVERYDAY WORKSPACE</p><h2>生活的几条线，<br>终于连在了一起。</h2></div><p>六个入口，同一个日常。<br>选择一张图，看看它怎样工作。</p></div>"""
        + carousel()
        + """</section>
<section class="wash section"><div class="wrap"><div class="section-heading"><h2>从一个念头，<br>走到一次真实行动。</h2><p>你决定想做什么，<br>Nivo帮你把事情连起来。</p></div><ol class="journey"><li><b>01</b><h3>在对话里想清楚</h3><p>把目标、限制和卡住的地方告诉AI。</p></li><li><b>02</b><h3>落成可以做的任务</h3><p>明确动作，再通过工具保存为待办。</p></li><li><b>03</b><h3>给行动一段时间</h3><p>关联任务，进入自己的专注时段。</p></li><li><b>04</b><h3>把经历留给以后</h3><p>在生活碎片和教练档案中回看。</p></li></ol></div></section>
<section class="wrap section"><div class="split-story"><div><p class="eyebrow">YOUR MODEL. YOUR CHOICE.</p><h2>模型由你选择，<br>开始不必复杂。</h2><p>先连接一个能稳定对话的模型就够了。接入指南按厂商拆开，带你从创建Key走到App里的第一条回复。</p><a class="text-link" href="models.html">打开模型接入指南 ↗</a></div><div class="model-cloud"><span>DeepSeek</span><span>千问</span><span>OpenAI</span><span>Claude</span><span>Gemini</span><span>Kimi</span><span>GLM</span><span>本地模型</span><p>客户端开源，模型调用费用以所选服务商为准。<br>教程网页不收集密钥，也不发起模型请求。</p></div></div></section>
<section class="cta wrap" id="download"><p class="eyebrow">START WITH SOMETHING SMALL</p><h2>今天，留一点时间<br>给你真正<span class="accent">想做的事。</span></h2><a class="button primary" href="downloads.html">选择你的版本 ↗</a><a class="text-link" href="features.html">继续逛逛功能画廊 →</a></section>"""
    )


def feature_index() -> str:
    """生成可视化功能目录。"""
    cards = "".join(
        f"""<a class="feature-link" href="features/{f["id"]}.html"><span class="feature-number">{i + 1:02d}</span><span class="feature-glyph" style="background:{f["color"]}">{f["icon"]}</span><h2>{f["name"]}</h2><p>{f["summary"]}</p><span class="text-link">看看具体怎么用 ↗</span></a>"""
        for i, f in enumerate(FEATURES)
    )
    return (
        title_block(
            "THE EVERYDAY COLLECTION",
            "不止把事记下来。<br>让每一步<span class='accent'>接得上。</span>",
            "六个相互连接的功能入口，也保留各自清楚的页面与档案。",
        )
        + f'<div class="wrap">{carousel()}</div><section class="wrap section feature-grid">{cards}</section>'
    )


def feature_detail(feature: dict, index: int) -> str:
    """把单项功能的用途、操作和实际边界放在自己的页面。"""
    bullets = "".join(f"<span>{esc(item)}</span>" for item in feature["bullets"])
    steps = "".join(
        f'<article class="how-step"><span>{i + 1:02d}</span><div><h2>{title}</h2><p>{body}</p></div></article>'
        for i, (title, body) in enumerate(feature["steps"])
    )
    next_feature = FEATURES[(index + 1) % len(FEATURES)]
    title = feature["title"].replace("\n", "<br>")
    return (
        f"""<div class="wrap breadcrumb"><a href="../features.html">功能画廊</a><span>／</span><span>{feature["name"]}</span></div>"""
        + title_block(feature["kicker"], title, feature["description"])
        + f'''<section class="wrap"><div class="feature-badges">{bullets}</div><figure class="feature-figure"><img src="../media/{feature["id"]}.svg?v={ASSET_HASH}" width="1280" height="800" alt="{feature["name"]}功能示意"><figcaption>原创功能示意 · 使用虚构示例，实际界面以Android应用为准</figcaption></figure></section>
<section class="wrap narrow section">{steps}<aside class="callout"><h3>把使用边界说清楚</h3><p>{feature["boundary"]}</p></aside><div class="actions"><a class="button primary" href="../downloads.html">下载后试一试 ↗</a><a class="text-link" href="{next_feature["id"]}.html">下一个：{next_feature["name"]} →</a></div></section>'''
    )


def provider_cards() -> str:
    """生成无需JS也可访问的厂商导航列表。"""
    return "".join(
        f'''<a class="provider-card" data-provider data-category="{p["category"]}" data-search="{esc(p["id"] + " " + p["name"] + " " + p["category"])}" href="models/{p["id"]}.html"><span class="provider-mark">{p["mark"]}</span><span class="chip">{p["category"]}</span><h3>{p["name"]}</h3><p>{p["intro"]}</p><span class="text-link">查看详细教程 ↗</span></a>'''
        for p in PROVIDERS
    )


def models_index() -> str:
    """分层说明接入概念，提供厂商搜索和独立教程。"""
    groups = "".join(
        f'<button type="button" data-provider-filter="{name}" aria-pressed="{str(i == 0).lower()}">{name}</button>'
        for i, name in enumerate(["全部", "国内平台", "国际平台", "聚合服务", "本地与自建"])
    )
    return (
        title_block(
            "BRING YOUR OWN INTELLIGENCE",
            "选一个模型，<br>开始你的<span class='accent'>第一次对话。</span>",
            "从账号、API Key、地址和模型ID开始。按你选择的厂商阅读，不用在一张长页面里翻找。",
        )
        + f"""<section class="wrap"><div class="start-guide"><div><span class="eyebrow">第一次接入？</span><h2>先走通文字对话，<br>其他能力慢慢加。</h2><p>App里通常从“设置 → 模型”或“添加AI服务商”进入。优先选对应厂商预置；名称会随版本略有差异。</p></div><ol><li><b>01</b><span>去厂商控制台准备账号、额度与Key。</span></li><li><b>02</b><span>在App选择协议，填写基础URL和Key。</span></li><li><b>03</b><span>刷新模型或手动添加精确模型ID。</span></li><li><b>04</b><span>在设置中选择“对话”模型，发一条短问候。</span></li></ol></div>
<div class="concept-grid"><article><h3>API Key是凭证</h3><p>只填App的服务商设置。这里不会要求你输入Key，也不会替你测试真实请求。</p></article><article><h3>Base URL是服务入口</h3><p>不是控制台网址，也通常不是完整的/chat/completions操作地址。</p></article><article><h3>模型ID是准确名字</h3><p>优先从平台列表复制，厂商前缀、大小写和日期后缀都可能有意义。</p></article></div>
<div class="catalogue-toolbar" id="providers"><div><p class="eyebrow">CHOOSE YOUR PROVIDER</p><h2>从你使用的平台开始。</h2></div><label class="search-box"><span>查找服务商</span><input type="search" id="provider-search" placeholder="搜索百炼、DeepSeek、Claude…" autocomplete="off"></label></div><div class="filter-pills" aria-label="按服务类别筛选">{groups}</div><p class="muted" id="provider-count" role="status" aria-live="polite">{len(PROVIDERS)}种接入入口</p><div class="provider-grid">{provider_cards()}</div><p id="provider-empty" class="empty-state" hidden>没有匹配的服务商。试试英文品牌名，或查看“其他OpenAI兼容服务”。</p></section>
<section class="wrap section reading-grid"><div><p class="eyebrow">BEFORE YOU CONNECT</p><h2>四个设置，<br>先弄清它们的关系。</h2></div><div><details open><summary>对话、操作屏幕、生成图片、生成视频要全部配置吗？</summary><p>不需要。先选“对话”模型。操作屏幕需要视觉能力，生成图片和视频需要专用模型及App已适配的接口，不能用普通文本模型代替。</p></details><details><summary>为什么自动追加/v1会影响连接？</summary><p>App会根据开关拼接地址。基础URL已经含/v1时不要再追加；智谱的/v4、方舟的/v3和Gemini原生/v1beta也不能再追加。每篇教程都给出字段和开关的对应值。</p></details><details><summary>聊天会员、API余额、Coding套餐是一回事吗？</summary><p>通常分别管理。订阅能否用于第三方App、可用端点及客户端范围，须以具体产品条款为准。不要把编程套餐当作通用无限聊天额度。</p></details><details><summary>没有模型列表怎么办？</summary><p>有些服务不支持列举模型。在App服务商详情里使用“添加自定义模型”，填写控制台给出的精确ID；普通聊天成功后再验证流式和工具。</p></details><details><summary>朗读和语音输入也要买模型服务吗？</summary><p>回复可使用手机系统TTS。语音输入可以沿用手机输入法；专门的实时语音服务是另一项可选配置，不是文字聊天的前提。</p></details><details><summary>这些教程是否代表全部厂商都经过实机验证？</summary><p>教程根据当前App源码和官方资料整理，核对日期为2026-11-13；没有使用你的Key逐一请求所有厂商。模型、计费和账号可用性以实际控制台为准。</p></details></div></section>"""
    )


def provider_detail(provider: dict) -> str:
    """逐厂商解释表单差异，并提供验证、排障和官方资料。"""
    p = provider
    url = p["url"]
    append = url.endswith("/v1")
    form = url[:-3] if append else url
    protocol = p.get("protocol", "OpenAI兼容")
    if protocol == "Anthropic":
        form, append = "https://api.anthropic.com", True
    sidebar = "".join(
        f'<a href="{x["id"]}.html"{(" aria-current=" + chr(34) + "page" + chr(34)) if x["id"] == p["id"] else ""}>{x["name"]}</a>'
        for x in PROVIDERS
    )
    regions = "".join(
        f"<li><strong>{label}</strong><code>{esc(endpoint)}</code></li>"
        for label, endpoint in p.get("region", [])
    )
    specials = "".join(f"<li>{esc(text)}</li>" for text in p["special"])
    errors = "".join(
        f'<tr><th scope="row">{esc(code)}</th><td>{esc(reason)}</td></tr>'
        for code, reason in p["failures"]
    )
    local = p["category"] == "本地与自建" and p["id"] != "custom"
    return f'''<div class="wrap breadcrumb"><a href="../models.html">模型接入</a><span>／</span><span>{p["name"]}</span></div><div class="wrap guide-layout"><aside class="guide-nav"><details open><summary>接入目录</summary>{sidebar}</details></aside><article class="guide-article"><p class="eyebrow">{p["category"]} / SETUP GUIDE</p><h1>{p["name"]}<br><span class="accent">接入指南。</span></h1><p class="lead">{p["intro"]}</p><p class="guide-meta">按当前App配置逻辑编写 · 官方资料核对：2026-11-13</p><nav class="article-toc" aria-label="本篇目录"><a href="#prepare">账号与凭证</a><a href="#configure">App怎么填</a><a href="#verify">逐步验证</a><a href="#troubleshoot">排查问题</a><a href="#sources">官方资料</a></nav>
<section id="prepare"><h2>01 / {"准备本地服务" if local else "准备账号与API服务"}</h2><p>{p["account"]}</p>{link(p["console"], "打开官方控制台／下载入口 ↗", "text-link")}<h3>取得正确的凭证</h3><p>{p["key"]}</p></section>
<section id="configure"><h2>02 / 在App里填写</h2><p>进入添加AI服务商，选择对应预置或下面指定的协议。API Key只写入App的凭证字段；不要发到主要聊天，也不要贴在本网页。</p><div class="config-card"><div class="config-card-title"><span>{p["mark"]}</span><div><strong>{p["name"]}</strong><small>字段对应表 · 非真实密钥</small></div></div><dl><dt>服务商类型／协议</dt><dd>{protocol}</dd><dt>基础URL字段</dt><dd><code>{esc(form)}</code><button type="button" class="copy-button" data-copy="{esc(form)}" aria-label="复制{p["name"]}基础URL">复制</button></dd><dt>自动追加/v1</dt><dd><span class="toggle-label">{"开启" if append else "关闭"}</span></dd><dt>最终API入口</dt><dd><code>{esc(url)}</code></dd><dt>API Key</dt><dd>{"按自建服务的认证设置填写；无认证时无需厂商Key" if local else "填写上一步取得的完整Key，不附加Bearer或请求头名称"}</dd><dt>模型ID参考</dt><dd><code>{esc(p["model"])}</code><small>示例不保证你的账号已开通；优先使用当前列表中的准确ID。</small></dd></dl></div><ul class="guide-points">{specials}</ul>{('<h3>其他地域</h3><ul class="endpoint-list">' + regions + "</ul><p>地域地址和API Key一起切换，再按结尾路径检查/v1开关。</p>") if regions else ""}</section>
<section id="verify"><h2>03 / 从一条回复开始验证</h2><ol class="numbered-list"><li><strong>保存连接设置。</strong>修改URL和/v1开关后，点击保存URL设置；不要只编辑后直接返回。</li><li><strong>刷新模型。</strong>在服务商详情点击刷新模型；不提供列表时，使用添加自定义模型并填精确ID。</li><li><strong>选为对话模型。</strong>在设置的模型选择中选中该服务商下的模型，主要聊天和新对话使用所选模型；已有旁聊可能保留原选择。</li><li><strong>先发短文本。</strong>例如“请用一句话说你好”。看到完整回复后，再检查流式输出是否正常。</li><li><strong>再试应用工具。</strong>请求查询现有待办或建立一个明确任务，回到待办页确认工具是否实际保存；普通文字回复不算工具成功。</li><li><strong>最后加可选能力。</strong>图片理解、操作屏幕、图像或视频分别验证。系统TTS可沿用手机语音引擎。</li></ol><aside class="callout"><h3>如何判断接入成功？</h3><p>保存配置、读取模型列表、普通回复、流式回复、工具执行是不同检查。只看到模型名或一句“可以帮你”不足以证明全部功能已适配。</p></aside></section>
<section id="troubleshoot"><h2>04 / 出问题时先看哪里</h2><div class="table-wrap"><table><thead><tr><th>现象</th><th>优先排查</th></tr></thead><tbody>{errors}<tr><th scope="row">地址或协议报错</th><td>检查是否填了网页登录地址、完整操作路径，或重复追加/v1。协议必须与服务端一致。</td></tr><tr><th scope="row">能聊天，不能创建任务</th><td>检查模型工具调用支持及应用授权；改用服务商中明确支持工具的模型，再查看工具返回结果。</td></tr><tr><th scope="row">长对话才失败</th><td>新开一个短对话，降低上下文和输出长度，检查服务端限额及错误详情。</td></tr></tbody></table></div></section>
<section><h2>05 / 费用与数据去向</h2><p>{p["cost"]}</p><p>请求会发送到你填入的服务端。使用聚合网关时还可能到达其上游模型；本地服务也可能因所选模型或工具联网。请按实际端点和启用的功能判断数据流。</p><a href="../privacy.html" class="text-link">了解Nivo的数据边界 →</a></section>
<section id="sources"><h2>官方资料与维护依据</h2><p>本篇将官方端点资料与Nivo的实际表单逻辑对照整理，未使用个人Key逐一请求厂商。后续遇到控制台迁移，以官方最新文档为准。</p><ul><li>{link(p["docs"], esc(p["name"]) + "官方文档 ↗")}</li><li>{link(p["console"], "控制台／产品入口 ↗")}</li><li>{link(REPO + "/blob/master/android/src/android/app/src/main/java/io/github/nanomuse/cloud/OwnKeyPresets.kt", "App预置与/v1拼接逻辑 ↗")}</li></ul></section><div class="article-end"><a href="../models.html" class="text-link">← 返回全部服务商</a><a class="button primary" href="../downloads.html">获取App ↗</a></div></article></div>'''


def release_card(release: dict, prefix: str = "") -> str:
    """静态首屏也提供真实可下载的发行文件。"""
    return f'''<div class="release-card"><div class="release-heading"><span class="platform-symbol">↗</span><div><p class="eyebrow">ANDROID / STABLE</p><h2>Nivo Bot <span>v{release["version"]}</span></h2></div><span class="chip">正式签名</span></div><p class="release-summary">{release["summary"]}</p><div class="release-facts"><span>Android {release["minimumOs"]}+</span><span>{release["architecture"]}</span><span>{release["sizeBytes"] / 1024 / 1024:.1f}MB</span><span>{release["releasedAt"]}</span></div><div class="actions"><a class="button primary" href="{release["downloadUrl"]}">下载APK <span>↓</span></a><a class="text-link" href="{prefix}{release["notesUrl"]}">查看更新说明 ↗</a></div><div class="checksum"><span>APK SHA256</span><code>{release["sha256"]}</code><button class="copy-button" data-copy="{release["sha256"]}" type="button" aria-label="复制APK SHA256">复制校验和</button></div><div class="release-links">{link(release["sourceUrl"], "下载本版对应源码ZIP ↗")}{link("https://nivo.8666886.xyz/downloads/SHA256SUMS.txt", "校验清单 ↗")}</div></div>'''


def downloads(releases: dict) -> str:
    """提供平台选择、可维护的历史版本与安装说明。"""
    android = [
        r for r in releases["releases"] if r["platform"] == "android" and r["channel"] == "stable"
    ]
    first = sorted(
        android,
        key=lambda r: (
            tuple(int(x) for x in r["version"].split("-")[0].split(".")),
            r.get("versionCode", 0),
        ),
        reverse=True,
    )[0]
    tabs = "".join(
        f'<button role="tab" data-platform="{p["id"]}" aria-selected="{str(p["id"] == "android").lower()}" aria-controls="release-content" id="platform-{p["id"]}" tabindex="{0 if p["id"] == "android" else -1}">{p["name"]} <span>{"已发布" if p["status"] == "available" else "尚未公开发布"}</span></button>'
        for p in releases["platforms"]
    )
    return (
        title_block(
            "A PLACE TO START, AND RETURN",
            "选择适合你的版本。<br>让日常<span class='accent'>接着发生。</span>",
            "正式安装包、版本记录和对应源码，都放在这里。后续平台与版本会继续加入同一份目录。",
        )
        + f'''<section class="wrap download-layout" data-downloads><div><div class="platform-tabs" role="tablist" aria-label="选择平台">{tabs}</div><div class="download-filters"><label>发行渠道<select id="release-channel"><option value="stable">稳定版</option><option value="beta">测试版</option><option value="all">全部已发布版本</option></select></label><label>选择版本<select id="release-version"><option value="{first["id"]}">v{first["version"]}（{first["versionCode"]}）· {first["releasedAt"]}</option></select></label></div><p id="release-message" role="status" aria-live="polite" class="muted">正在同步版本目录；下方提供当前正式版。</p><div id="release-content" role="tabpanel" aria-labelledby="platform-android" tabindex="0">{release_card(first)}</div><button type="button" id="release-retry" class="text-button" hidden>重新加载版本目录</button><noscript><p>未启用JavaScript时仍可下载上方Android正式版。iOS目前没有公开安装包。</p></noscript></div><aside class="download-aside"><span class="eyebrow">A FEW THINGS TO KNOW</span><h2>开始之前，<br>把这些准备好。</h2><ol><li><strong>选择对的设备</strong><p>目前发布arm64-v8a架构的Android安装包。iOS单独展示发布状态。</p></li><li><strong>保留原有数据</strong><p>同包名应用通常需要相同签名才能覆盖升级。旧Debug签名或上游签名包请先核对备份，不要直接卸载。</p></li><li><strong>连接一个模型</strong><p>客户端开源；模型服务由你选择，调用费用遵循服务商规则。</p><a href="models.html" class="text-link">接入教程 →</a></li></ol></aside></section>
<section class="wrap section" id="history"><div class="section-heading"><div><p class="eyebrow">RELEASE ARCHIVE</p><h2>每个版本，<br>都留一个清楚的来处。</h2></div><p>按平台、版本和发行日期选择，<br>并核对该版本的源码与校验信息。</p></div><div id="release-history" class="table-wrap"><table><thead><tr><th>平台</th><th>版本</th><th>渠道</th><th>发布日期</th><th>详情</th></tr></thead><tbody><tr><td>Android</td><td>v{first["version"]}（{first["versionCode"]}）</td><td>稳定版</td><td>{first["releasedAt"]}</td><td><a href="{first["notesUrl"]}">更新说明 ↗</a></td></tr></tbody></table></div></section>
<section class="wrap narrow section"><h2>下载后，怎么开始？</h2><details open><summary>Android安装步骤</summary><p>下载安装包，在Android文件管理器中打开；仅为此次安装允许来源应用安装软件，然后按系统提示操作。首次打开后，按模型教程配置你自己的服务商。</p></details><details><summary>怎样检查安装包有没有损坏？</summary><p>比较APK文件的SHA256与本页值。Windows可运行<code>Get-FileHash -Algorithm SHA256 -LiteralPath '你的APK路径'</code>；macOS可运行<code>shasum -a 256 '你的APK路径'</code>。校验和用于检查文件一致性，签名则用于确认应用更新身份。</p></details><details><summary>iOS会直接提供IPA文件吗？</summary><p>暂未确定公开分发方式，当前没有可用安装入口。后续若发布，会在iOS页说明系统要求、TestFlight或App Store等实际渠道；不提供未经验证的下载按钮。</p></details></section>'''
    )


def release_detail(release: dict) -> str:
    """逐版生成不可漂移的发行说明与源码入口。"""
    platform = "Android" if release["platform"] == "android" else "iOS"
    title = f"{platform} v{release['version']}"
    certificate = release.get("certificateSha256")
    certificate_html = (
        f"<h2>发行签名</h2><p>证书SHA256：</p><pre><code>{esc(certificate)}</code></pre>"
        if certificate
        else ""
    )
    notes = "".join(f"<li>{esc(item)}</li>" for item in release.get("notes", []))
    source_hash = (
        f"<h3>源码ZIP SHA256</h3><pre><code>{esc(release['sourceSha256'])}</code></pre>"
        if release.get("sourceSha256")
        else ""
    )
    return (
        f'<div class="wrap breadcrumb"><a href="../downloads.html">下载与版本记录</a><span>／</span><span>{title}</span></div>'
        + title_block(
            "RELEASE NOTES",
            title,
            f"{release['releasedAt']} · {platform} {release['minimumOs']}及以上",
        )
        + f"""<section class="wrap narrow"><h2>这一版的变化</h2><p>{esc(release["summary"])}</p><ul class="guide-points">{notes}</ul><h2>安装与升级</h2><p>请按本版平台和分发方式安装。Android同包名覆盖升级通常需要同一签名；旧Debug证书或其他证书的包请先核对签名和备份范围。</p>{certificate_html}<h2>验证范围</h2><p>发行包提供对应源码和文件身份信息，不代表每个手机、模型服务或全部业务流程均已实机验收。历史安装包与源码保持原发行文件不变。</p><h2>本版对应源码</h2><p>安装文件与本版源码对应；GitHub默认分支可能包含之后的维护提交。</p><div class="actions">{link(release["downloadUrl"], "打开本版安装入口 ↓", "button primary")}{link(release["sourceUrl"], "本版对应源码 ↗", "text-link")}</div>{source_hash}<a class="text-link" href="../downloads.html">← 返回下载中心</a></section>"""
    )


def developers() -> str:
    """提供真实仓库入口和后续维护版本清单的方式。"""
    return (
        title_block(
            "BUILD IN THE OPEN",
            "看得见的代码，<br>接得上的<span class='accent'>改变。</span>",
            "Nivo Bot是一个持续维护的开源衍生项目。了解构建方式、模块边界与每次发行对应的源码。",
        )
        + f"""<div class="wrap narrow"><section id="start"><h2>从源码开始</h2><p>{link(REPO, "打开sherlockerX/Nivo-Bot仓库 ↗", "text-link")}</p><pre><code>git clone --recurse-submodules {REPO}.git
cd Nivo-Bot
bash scripts/android/build-natives.sh
cd android/src/android
bash gradlew :app:assembleDebug --console=plain --no-daemon</code></pre><p>使用JDK21、Android SDK36、NDK27.2.12479018和CMake3.22.1。完整工具链与Windows入口以仓库文档为准。</p><p>{link(REPO + "/blob/master/docs/android-development.md", "Android构建与签名文档 ↗")} · {link(REPO + "/actions/workflows/android.yml", "GitHub自动打包 ↗")}</p></section>
<section><h2>模块有各自的职责</h2><div class="table-wrap"><table><thead><tr><th>入口</th><th>职责</th></tr></thead><tbody><tr><td>chat / ui/chat</td><td>主要聊天、工具协作、回复朗读</td></tr><tr><td>todo</td><td>任务、分组、标签、版本冲突与完成证据</td></tr><tr><td>focus</td><td>计时事实、全屏恢复、背景和统计</td></tr><tr><td>mosaic</td><td>生活碎片、草稿和任务／专注关联</td></tr><tr><td>coach</td><td>课程、每日练习、证据与回访</td></tr></tbody></table></div><p>Android扩展主要位于io.github.nanomuse命名空间。上游包名、沙盒协议与许可继续保留。</p>{link(REPO + "/blob/master/docs/android-code-map.md", "阅读源码地图 ↗")}</section>
<section><h2>给之后的版本留好位置</h2><p>下载中心由版本清单驱动。每个发行记录保存平台、渠道、版本、架构、日期、安装地址、SHA256、对应源码和说明页。加入新版本即可继续显示历史版本；只有实际可用的文件会显示下载入口。</p><p>iOS目前单独显示尚未公开发布。未来应按实际分发渠道增加记录，而不是让Android和iOS共用一个安装按钮。</p></section>
<section><h2>参与贡献</h2><p>带着具体场景、预期、实际结果和复现步骤提交Issue；日志先脱敏。修改任务或计时逻辑时关注账号隔离、重复请求和中断恢复。代码提交遵循DCO签署及原项目规范。</p>{link(REPO + "/blob/master/CONTRIBUTING.md", "贡献指南 ↗")}</section>
<section id="origins"><h2>开放，也保留来处</h2><p>本项目在nanoMuse基础上演进，Android底座来自OpenMinis，继续使用GPL-3.0-or-later并保留相关版权和第三方许可。本项目不代表上游官方服务，也不隶属于Meta或其Muse产品。</p><p>{link("https://github.com/nano-muse/nanoMuse", "致谢nanoMuse ↗")} · {link("https://github.com/OpenMinis/OpenMinis", "致谢OpenMinis ↗")} · {link(REPO + "/blob/master/LICENSE", "查看许可 ↗")}</p></section></div>"""
    )


def privacy() -> str:
    """说明产品与网站各自的数据边界，不承诺所有功能离线。"""
    return (
        title_block(
            "YOUR DATA, IN CONTEXT",
            "说清楚，<br>数据<span class='accent'>去了哪里。</span>",
            "是否联网，取决于你选择的服务、模型和功能。",
        )
        + """<div class="wrap narrow"><section><h2>这个网站</h2><p>产品图使用虚构示例，不展示真实聊天、任务或学习档案。轮播、厂商筛选和版本选择在浏览器中运行。网站不要求填写API Key，不发起模型调用，不接入分析追踪器、远程字体或广告SDK。</p><p>访问网站和下载文件仍会产生正常的服务器与网络请求；托管和网络服务可能保留常规访问日志。复制按钮使用浏览器剪贴板权限，拒绝时会提示手动复制。</p></section><section><h2>App里的记录</h2><p>待办、专注和生活碎片具有本地存储。账号、同步、远程操作及其他云端功能的数据流由实际启用的服务决定。本地记录不等于整个App永不联网。</p></section><section><h2>与模型对话</h2><p>AI请求会发送到你配置的服务端。上下文、附件或工具返回内容是否被送出，取决于当前对话和授权。使用聚合服务时，还需核对其上游路由及数据保留政策。</p><p>本地模型地址指向自己的设备或服务器；仍要留意模型是否实际使用云推理、工具是否联网、是否启用了其他同步服务。</p></section><section><h2>密钥与备份</h2><p>API Key只应填写在App服务商设置中，不要发给聊天模型、贴到公开Issue或上传截图。导出备份前检查包含的数据范围；不同模块和附件的覆盖范围需分别核验。</p><a class="text-link" href="models.html">返回模型接入指南 →</a></section></div>"""
    )


def svg_text(
    x: int, y: int, text: str, size: int = 20, fill: str = "#21453b", weight: str = "400"
) -> str:
    """生成不依赖远程字体的SVG文字。"""
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}">{esc(text)}</text>'


def rect(x: int, y: int, width: int, height: int, fill: str, radius: int = 18) -> str:
    """生成圆角UI图形。"""
    return f'<rect x="{x}" y="{y}" width="{width}" height="{height}" rx="{radius}" fill="{fill}"/>'


def screen_chat() -> str:
    """绘制聊天与任务工具反馈。"""
    return (
        rect(699, 220, 300, 72, "#e4ebda")
        + svg_text(720, 251, "想每天读一点书，")
        + svg_text(720, 278, "先从今天的一章开始。")
        + rect(670, 325, 327, 86, "#f0f0e7")
        + svg_text(690, 358, "先把‘读一章’放进待办，")
        + svg_text(690, 387, "再留25分钟给自己。")
        + rect(670, 444, 327, 110, "#e1e8dc")
        + svg_text(692, 478, "✓  读一章，留下一句笔记", 21, weight="600")
        + svg_text(692, 512, "个人成长 · 阅读 · 已保存", 15, "#637c6c")
        + rect(670, 599, 327, 52, "#f0f0e7")
        + svg_text(687, 631, "和你的AI说点什么…", 17, "#7a8275")
    )


def screen_tasks() -> str:
    """绘制真实功能分类和任务状态示意。"""
    out = svg_text(675, 226, "今天，先做好三件事。", 21, weight="600")
    for i, (title, tag, done) in enumerate(
        [
            ("读一章，留一句笔记", "个人成长", False),
            ("完成项目的第一版草稿", "分内工作", False),
            ("出门走一段路", "生活", True),
        ]
    ):
        y = 260 + i * 94
        out += (
            rect(667, y, 334, 78, "#f0f2e9")
            + f'<circle cx="692" cy="{y + 31}" r="9" fill="none" stroke="#64816a" stroke-width="2"/>'
            + svg_text(714, y + 36, title, 18)
            + svg_text(714, y + 61, ("已完成 · " if done else "待办 · ") + tag, 14, "#74816f")
        )
    return (
        out
        + rect(670, 584, 325, 58, "#21453b")
        + svg_text(692, 621, "＋  记下一件要做的事", 18, "#fffdf4")
    )


def screen_focus() -> str:
    """绘制全屏风景与倒计时，不使用外部图片。"""
    return (
        '<g clip-path="url(#screen)">'
        + rect(642, 171, 386, 516, "#b9cabe")
        + '<circle cx="935" cy="292" r="51" fill="#e9dcc0"/><path d="M642 432Q720 238 825 418T1040 365V690H642Z" fill="#6c9483"/><path d="M635 535Q760 369 900 506T1040 460V690H635Z" fill="#3b6b5b"/><path d="M640 617Q787 489 1035 585V700H640Z" fill="#234b40"/>'
        + svg_text(705, 270, "此刻，只做这一件事", 20)
        + svg_text(700, 398, "24:59", 77, "#fffdf3", "500")
        + svg_text(736, 441, "读一章，留一句笔记", 17, "#fffdf3")
        + rect(739, 542, 184, 51, "#edf0df")
        + svg_text(787, 575, "Ⅱ  暂停", 21)
        + "</g>"
    )


def screen_fragments() -> str:
    """绘制日常记录及任务与计时关联。"""
    return (
        svg_text(674, 227, "今天，留下一点痕迹。", 21, weight="600")
        + rect(668, 263, 331, 220, "#f4e9db")
        + svg_text(689, 301, "11月13日  ·  平静", 16, "#826f5c")
        + svg_text(689, 350, "今天给阅读留了25分钟。", 19)
        + svg_text(689, 386, "读得不多，但开始了。", 19)
        + svg_text(689, 451, "生活中的一小片", 15, "#8a7763")
        + rect(670, 510, 328, 57, "#e6ecdf")
        + svg_text(690, 545, "✓  关联待办：读一章", 18)
        + rect(670, 586, 328, 57, "#e6ecdf")
        + svg_text(690, 621, "◴  已专注：25分钟", 18)
    )


def screen_coach() -> str:
    """绘制竹海与讨论主题，避免用同一种房屋图形代表所有能力。"""
    bamboo = "".join(
        f'<path d="M{x} 393V254m0 38-14-22m14 53 17-20m-17 43-12-17" fill="none" stroke="#5d7b5f" stroke-width="3"/>'
        for x in (707, 737, 775)
    )
    return (
        svg_text(674, 226, "今天，想探索哪个方向？", 21, weight="600")
        + rect(670, 254, 327, 161, "#e1e8d5")
        + bamboo
        + svg_text(812, 308, "决策书房", 22, weight="600")
        + svg_text(812, 340, "打磨原则与判断", 16)
        + rect(670, 437, 327, 109, "#eee0d0")
        + '<ellipse cx="726" cy="494" rx="34" ry="16" fill="#b6997b"/><circle cx="704" cy="468" r="11" fill="#d1aa8e"/><circle cx="751" cy="470" r="11" fill="#8a9e85"/>'
        + svg_text(790, 482, "圆桌讨论", 22, weight="600")
        + svg_text(790, 514, "从不同角度理解", 16)
        + rect(670, 580, 327, 65, "#21453b")
        + svg_text(693, 620, "继续每日练习  ↗", 20, "#fffdf3")
    )


def screen_ideas() -> str:
    """绘制每日点子分类和可继续对话的灵感卡。"""
    out = svg_text(674, 225, "给今天，一个新的开始。", 21, weight="600")
    for i, label in enumerate(["工作", "生活", "学习", "关系"]):
        out += rect(670 + i * 82, 254, 72, 35, "#e5e9dc") + svg_text(687 + i * 82, 278, label, 16)
    for i, (title, sub) in enumerate(
        [
            ("把复杂任务缩成20分钟", "工作 · 从最小的一步开始"),
            ("试着表达一个真实偏好", "关系 · 不必等到重要场合"),
            ("拍一段自己的普通日常", "自媒体 · 从身边的素材出发"),
        ]
    ):
        y = 320 + i * 101
        out += (
            rect(670, y, 327, 83, ["#ede0cc", "#dce6d6", "#e8d8cc"][i])
            + svg_text(688, y + 34, title, 19, weight="600")
            + svg_text(688, y + 64, sub, 14, "#73816e")
        )
    return out


def feature_svg(feature: dict, index: int) -> str:
    """生成统一品牌下各有场景的原创产品插画。"""
    screens = dict(
        chat=screen_chat,
        tasks=screen_tasks,
        focus=screen_focus,
        fragments=screen_fragments,
        coach=screen_coach,
        ideas=screen_ideas,
    )
    out = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 800" role="img" aria-labelledby="title desc"><title id="title">{feature["name"]}功能示意</title><desc id="desc">{esc(feature["summary"])}。使用虚构内容，不是手机截图。</desc><defs><clipPath id="screen"><rect x="649" y="172" width="373" height="512" rx="14"/></clipPath></defs><g font-family="'Times New Roman','SimSun','Songti SC',serif">{rect(0, 0, 1280, 800, "#f1f2e9", 0)}<circle cx="1040" cy="250" r="385" fill="{feature["color"]}"/>
{svg_text(72, 80, "n.  Nivo Bot", 27, weight="600")}{svg_text(72, 191, f"{index + 1:02d} / {feature['kicker']}", 14, "#ae6247")}
{"".join(svg_text(72, 278 + i * 69, line, 49, weight="600") for i, line in enumerate(feature["title"].split(chr(10))))}
{svg_text(72, 425, feature["summary"][:22], 20, "#668071")}
{"".join(rect(72, 475 + i * 47, 365, 34, "#e5e9db") + svg_text(88, 498 + i * 47, line, 16) for i, line in enumerate(feature["bullets"]))}
{rect(632, 69, 406, 645, "#21453b", 43)}{rect(644, 82, 382, 618, "#fffef8", 32)}{rect(773, 91, 123, 19, "#21453b", 10)}
{svg_text(672, 149, feature["name"], 24, weight="600")}{svg_text(977, 147, "···", 22)}{screens[feature["id"]]()}
{svg_text(72, 736, "原创功能示意 · 示例内容，并非手机截图", 14, "#80907d")}{svg_text(1097, 736, f"{index + 1:02d} / 06", 23, "#6e8270")}</g></svg>'''
    return out


def generated(root: Path) -> dict[str, str]:
    """收集白名单页面和资源，供生成与漂移检查使用。"""
    global ASSET_HASH
    ASSET_HASH = hashlib.sha256(
        (root / "product.css").read_bytes()
        + (root / "product.js").read_bytes()
        + Path(__file__).read_bytes()
        + Path(__file__).with_name("content.py").read_bytes()
    ).hexdigest()[:12]
    releases = json.loads((root / "releases.json").read_text(encoding="utf-8"))
    outputs = {
        "index.html": page(
            "index.html",
            "让对话走向行动",
            "连接AI对话、待办、专注、生活碎片与成长教练的开源Android工作台。",
            home(),
            "home",
        ),
        "features.html": page(
            "features.html",
            "功能画廊",
            "用图片轮播认识Nivo Bot的六个功能入口。",
            feature_index(),
            "features",
        ),
        "models.html": page(
            "models.html",
            "模型接入指南",
            "逐厂商解释API Key、基础URL、模型ID、协议、费用与排障。",
            models_index(),
            "models",
        ),
        "downloads.html": page(
            "downloads.html",
            "下载与版本记录",
            "选择Android或iOS，查找正式版本、校验和、源码与更新说明。",
            downloads(releases),
            "downloads",
        ),
        "developers.html": page(
            "developers.html",
            "开放项目",
            "构建Nivo Bot，了解源码、许可、版本维护与贡献方式。",
            developers(),
            "developers",
        ),
        "privacy.html": page(
            "privacy.html",
            "数据与隐私",
            "了解网站、App、本地模型与第三方服务的数据边界。",
            privacy(),
            "developers",
        ),
    }
    for i, feature in enumerate(FEATURES):
        path = f"features/{feature['id']}.html"
        outputs[path] = page(
            path, feature["name"], feature["summary"], feature_detail(feature, i), "features"
        )
        outputs[f"media/{feature['id']}.svg"] = feature_svg(feature, i)
    for provider in PROVIDERS:
        path = f"models/{provider['id']}.html"
        outputs[path] = page(
            path,
            provider["name"] + "接入教程",
            provider["intro"],
            provider_detail(provider),
            "models",
        )
    for release in releases["releases"]:
        path = release["notesUrl"]
        if not (root / path).resolve().is_relative_to(root.resolve()):
            raise ValueError("Release notes path escapes site root")
        outputs[path] = page(
            path,
            f"{release['platform']} v{release['version']}更新说明",
            release["summary"],
            release_detail(release),
            "downloads",
        )
    paths = sorted(name for name in outputs if name.endswith(".html"))
    outputs["sitemap.xml"] = (
        '<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
        + "".join(f"<url><loc>{ORIGIN}{p if p != 'index.html' else ''}</loc></url>" for p in paths)
        + "</urlset>"
    )
    outputs["robots.txt"] = f"User-agent: *\nAllow: /\nSitemap: {ORIGIN}sitemap.xml\n"
    files = sorted(
        [
            *outputs,
            "product.css",
            "product.js",
            "releases.json",
            "release.json",
            "brand-mark.svg",
            "site-manifest.json",
        ]
    )
    outputs["site-manifest.json"] = (
        json.dumps({"schemaVersion": 1, "files": files}, ensure_ascii=False, indent=2) + "\n"
    )
    return outputs


def main() -> None:
    """生成或检查生成文件，不改变下载包和任何本机配置。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    outputs = generated(args.root)
    differences = []
    for name, text in outputs.items():
        path = args.root / name
        data = text.encode("utf-8")
        if args.check:
            if not path.is_file() or path.read_bytes() != data:
                differences.append(name)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    print(
        json.dumps(
            {
                "generated": len(outputs),
                "pages": sum(p.endswith(".html") for p in outputs),
                "providerGuides": len(PROVIDERS),
                "differences": differences,
            }
        )
    )
    raise SystemExit(bool(differences))


if __name__ == "__main__":
    main()
