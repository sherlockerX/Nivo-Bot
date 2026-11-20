"""在本地或已部署的产品站执行浏览器验收，模型服务始终不被调用。"""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from time import monotonic
from urllib.parse import urljoin

from playwright.sync_api import Browser, Locator, Page, Route, expect, sync_playwright

SCREENSHOT_IDS = ("chat", "tasks", "focus", "fragments", "coach", "ideas")
SCREENSHOT_LINK = "a.screenshot-link, a.app-screenshot"


def check_gallery_tab_scroll(page: Page) -> dict:
    """注入浏览器原生触摸，验证标签真正横向滚动且不切换功能面板。"""
    tabs = page.locator(".gallery-tabs")
    tabs.scroll_into_view_if_needed()
    expect(page.locator("#slide-chat")).to_be_visible()
    assert tabs.evaluate("element => element.scrollWidth > element.clientWidth")
    rectangle = tabs.bounding_box()
    assert rectangle is not None
    before = tabs.evaluate("element => element.scrollLeft")
    start = rectangle["x"] + rectangle["width"] * 0.8
    end = rectangle["x"] + rectangle["width"] * 0.2
    vertical = rectangle["y"] + rectangle["height"] / 2
    session = page.context.new_cdp_session(page)
    try:
        session.send(
            "Input.dispatchTouchEvent",
            {
                "type": "touchStart",
                "touchPoints": [{"x": start, "y": vertical}],
            },
        )
        for step in range(1, 9):
            session.send(
                "Input.dispatchTouchEvent",
                {
                    "type": "touchMove",
                    "touchPoints": [{"x": start + (end - start) * step / 8, "y": vertical}],
                },
            )
        session.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
        page.wait_for_function(
            "before => document.querySelector('.gallery-tabs').scrollLeft > before + 20",
            arg=before,
        )
        expect(page.locator("#slide-chat")).to_be_visible()
        expect(page.locator("#slide-tasks")).to_be_hidden()
        expect(tabs.locator('[data-slide="0"]')).to_have_attribute("aria-selected", "true")
        expect(page.locator("[data-carousel-count]")).to_have_text("01 / 06")
        return {
            "scrollBefore": before,
            "scrollAfter": tabs.evaluate("element => element.scrollLeft"),
        }
    finally:
        session.detach()


def check_screenshot(link: Locator, identifier: str, base: str) -> dict:
    """解码实际截图并检查完整比例、祖先裁剪和同源原图入口，不以HTTP成功替代图像有效。"""
    expect(link).to_have_count(1)
    expect(link).to_be_visible()
    expect(link.locator("img")).to_have_count(1)
    link.scroll_into_view_if_needed()
    facts = link.evaluate(
        """async anchor => {
          const image = anchor.querySelector('img');
          await image.decode();
          const rectangle = image.getBoundingClientRect();
          const style = getComputedStyle(image);
          const clippedBy = [];
          let ancestor = image.parentElement;
          while (ancestor && ancestor !== document.body && ancestor !== document.documentElement) {
            const parent = ancestor.getBoundingClientRect();
            const computed = getComputedStyle(ancestor);
            const x = parent.left + ancestor.clientLeft;
            const y = parent.top + ancestor.clientTop;
            const clips = value => ['hidden','clip','auto','scroll'].includes(value);
            if ((clips(computed.overflowX)
                  && (rectangle.left < x - 2 || rectangle.right > x + ancestor.clientWidth + 2))
                || (clips(computed.overflowY)
                  && (rectangle.top < y - 2 || rectangle.bottom > y + ancestor.clientHeight + 2))
                || computed.clipPath !== 'none') {
              clippedBy.push(ancestor.className || ancestor.tagName);
            }
            ancestor = ancestor.parentElement;
          }
          return {
            source: image.currentSrc, original: anchor.href,
            naturalWidth: image.naturalWidth, naturalHeight: image.naturalHeight,
            displayedWidth: rectangle.width, displayedHeight: rectangle.height,
            objectFit: style.objectFit, clippedBy, alt: image.alt,
            label: anchor.getAttribute('aria-label') || anchor.textContent.trim(),
            target: anchor.target, rel: anchor.rel, download: anchor.hasAttribute('download')
          };
        }"""
    )
    expected = urljoin(base, f"media/screenshots/{identifier}.png")
    assert facts["source"].split("?", 1)[0] == expected, facts
    assert facts["original"] == facts["source"], f"Original differs from displayed image: {facts}"
    assert (facts["naturalWidth"], facts["naturalHeight"]) == (1080, 2400), facts
    assert facts["displayedWidth"] > 0 and facts["displayedHeight"] > 0, facts
    ratio = facts["displayedWidth"] / facts["displayedHeight"]
    assert abs(ratio - 1080 / 2400) < 0.005, f"Screenshot aspect ratio changed: {facts}"
    assert facts["objectFit"] in {"contain", "scale-down"}, f"Screenshot may be cropped: {facts}"
    assert not facts["clippedBy"], f"Screenshot is clipped by its container: {facts}"
    assert facts["alt"].strip() and facts["label"].strip(), facts
    assert not facts["download"], f"Original screenshot should open for viewing: {facts}"
    if facts["target"] == "_blank":
        assert "noopener" in facts["rel"].split(), facts
    return facts


def check_app_screenshots(browser: Browser, base: str) -> list[dict]:
    """逐一检查六张真实截图在画廊和详情页的四种宽度，以及首页与原图真实导航。"""
    context = browser.new_context(reduced_motion="reduce")
    results = []
    errors = []
    try:
        page = context.new_page()
        page.on("pageerror", lambda error: errors.append(str(error)))
        for width in (320, 390, 768, 1440):
            page.set_viewport_size({"width": width, "height": 900})
            page.goto(base + "features.html", wait_until="load")
            tabs = page.locator("[data-carousel] [role=tab]")
            expect(tabs).to_have_count(len(SCREENSHOT_IDS))
            for index, identifier in enumerate(SCREENSHOT_IDS):
                tabs.nth(index).click()
                link = page.locator(f"#slide-{identifier}").locator(SCREENSHOT_LINK)
                facts = check_screenshot(link, identifier, base)
                results.append({"page": "gallery", "width": width, "feature": identifier, **facts})
            for identifier in SCREENSHOT_IDS:
                detail = base + f"features/{identifier}.html"
                page.goto(detail, wait_until="load")
                link = page.locator(".feature-figure").locator(SCREENSHOT_LINK)
                facts = check_screenshot(link, identifier, base)
                results.append({"page": "detail", "width": width, "feature": identifier, **facts})
                if width == 1440:
                    # 实际点击完整原图，并在浏览器解码它，防止链接只是占位或返回HTML错误页。
                    if facts["target"] == "_blank":
                        with page.expect_popup() as opened:
                            link.click()
                        original = opened.value
                    else:
                        link.click()
                        original = page
                    expect(original).to_have_url(facts["original"])
                    original.wait_for_load_state("load")
                    assert original.evaluate("document.contentType") == "image/png"
                    image = original.locator("img")
                    expect(image).to_have_count(1)
                    dimensions = image.evaluate(
                        "async image => {await image.decode(); return [image.naturalWidth, image.naturalHeight];}"
                    )
                    assert dimensions == [1080, 2400], dimensions
                    results[-1]["originalOpened"] = True
                    if original is not page:
                        original.close()
            page.goto(base, wait_until="load")
            for index, identifier in enumerate(SCREENSHOT_IDS[:4]):
                page.locator("[data-story-tab]").nth(index).click()
                link = page.locator(f"#day-{identifier}").locator(SCREENSHOT_LINK)
                facts = check_screenshot(link, identifier, base)
                results.append({"page": "home", "width": width, "feature": identifier, **facts})
        assert not errors, errors
        return results
    finally:
        context.close()


def check_story_panel(page: Page, selected: int) -> None:
    """核对故事当前面板、标签状态和键盘可达性，不依赖展示文案。"""
    story = page.locator("[data-story]")
    tabs = story.locator("[data-story-tab]")
    expect(tabs).to_have_count(4)
    for index, identifier in enumerate(("chat", "tasks", "focus", "fragments")):
        panel = story.locator(f"#day-{identifier}")
        expect(panel).to_have_attribute("tabindex", "0")
        expect(tabs.nth(index)).to_have_attribute("aria-selected", str(index == selected).lower())
        expect(tabs.nth(index)).to_have_attribute("tabindex", "0" if index == selected else "-1")
        if index == selected:
            expect(panel).to_be_visible()
        else:
            expect(panel).to_be_hidden()


def check_local_text_contrast(page: Page, selector: str) -> dict:
    """检查局部文字与叠加后的纯色背景，图片、渐变和透明分组另记为人工验收项。"""
    samples = page.locator(selector).evaluate_all(
        """elements => {
          const rgba = value => {
            const values = value.match(/[\\d.]+/g).map(Number);
            return [values[0], values[1], values[2], values[3] ?? 1];
          };
          const blend = (front, back) => [
            ...front.slice(0, 3).map((value, index) =>
              value * front[3] + back[index] * (1 - front[3])), 1
          ];
          const luminance = color => color.slice(0, 3).map(value => {
            value /= 255;
            return value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4;
          }).reduce((sum, value, index) => sum + value * [.2126, .7152, .0722][index], 0);
          return elements.filter(element => element.getClientRects().length
            && getComputedStyle(element).visibility === 'visible'
            && element.textContent.trim()).map(element => {
              const label = element.textContent.trim().replace(/\\s+/g, ' ').slice(0, 70);
              const layers = [];
              let ancestor = element;
              let backgroundCovered = false;
              while (ancestor) {
                const style = getComputedStyle(ancestor);
                if (Number(style.opacity) < 1
                  || (!backgroundCovered && style.backgroundImage !== 'none')) {
                  return {label, manual: '图片、渐变或透明分组需人工核对'};
                }
                if (!backgroundCovered) {
                  const background = rgba(style.backgroundColor);
                  layers.unshift(background);
                  backgroundCovered = background[3] >= 1;
                }
                ancestor = ancestor.parentElement;
              }
              const style = getComputedStyle(element);
              const background = layers.reduce((back, front) => blend(front, back), [255,255,255,1]);
              const foreground = blend(rgba(style.color), background);
              const frontLight = luminance(foreground), backLight = luminance(background);
              const ratio = (Math.max(frontLight, backLight) + .05) / (Math.min(frontLight, backLight) + .05);
              const isLarge = parseFloat(style.fontSize) >= 24
                || (parseFloat(style.fontSize) >= 18.667 && parseInt(style.fontWeight, 10) >= 700);
              return {label, ratio, minimum: isLarge ? 3 : 4.5};
            });
        }"""
    )
    measured = [sample for sample in samples if "ratio" in sample]
    assert measured, f"No measurable visible text: {page.url} {selector}"
    failures = [sample for sample in measured if sample["ratio"] < sample["minimum"]]
    assert not failures, f"Local text contrast below WCAG AA: {page.url} {failures}"
    return {
        "url": page.url,
        "selector": selector,
        "measured": len(measured),
        "minimumRatio": round(min(sample["ratio"] for sample in measured), 2),
        "manualReview": [sample for sample in samples if "manual" in sample],
    }


def check_binary_card(card: Locator, release: dict) -> None:
    """对照发行清单核对所选安装包、十进制大小和该版本的校验文件。"""
    expect(card.locator("a.button")).to_have_attribute("href", release["downloadUrl"])
    if release.get("sizeBytes"):
        megabytes = f"{release['sizeBytes'] / 1_000_000:.1f}MB"
        expect(card.locator(".release-facts").get_by_text(megabytes, exact=True)).to_be_visible()
    if release.get("checksumsUrl"):
        expect(card.get_by_role("link", name="本版校验清单")).to_have_attribute(
            "href", release["checksumsUrl"]
        )


def check_static_downloads(container: Locator, catalogue: dict) -> None:
    """静态恢复入口指向真实清单的各平台最新稳定版，保留未签名IPA的安装前提。"""
    for platform in catalogue["platforms"]:
        releases = [
            release
            for release in catalogue["releases"]
            if release["platform"] == platform["id"] and release["channel"] == "stable"
        ]
        if not releases:
            continue
        latest = max(
            releases,
            key=lambda release: (
                tuple(int(part) for part in release["version"].split(".")[:3]),
                release.get("versionCode", 0),
            ),
        )
        card = container.locator(".release-card:visible").filter(
            has=container.page.locator(f'a.button[href="{latest["downloadUrl"]}"]')
        ).first
        check_binary_card(card, latest)
        if latest.get("signing") == "unsigned":
            expect(container).to_contain_text("不能下载后直接安装到iPhone")
            expect(container).to_contain_text("签名")


def check_without_javascript(browser: Browser, base: str, catalogue: dict) -> None:
    """关闭脚本后沿真实页面链接进入功能、教程与两平台下载，不请求安装文件。"""
    context = browser.new_context(java_script_enabled=False, viewport={"width": 390, "height": 844})
    try:
        page = context.new_page()
        for destination in ("features.html", "models.html", "downloads.html"):
            page.goto(base, wait_until="load")
            expect(page.get_by_role("heading", level=1)).to_contain_text("把一个想法")
            expect(page.locator(".entry-grid > a")).to_have_count(3)
            expect(page.locator("#day-chat")).to_be_visible()
            page.locator(f'.entry-grid > a[href="{destination}"]').click()
            expect(page).to_have_url(base + destination)
        check_static_downloads(page.locator("main"), catalogue)
        page.goto(base + "features.html", wait_until="load")
        page.get_by_role("navigation", name="当前栏目").get_by_role("link", name="个人待办").click()
        expect(page).to_have_url(base + "features/tasks.html")
        expect(page.locator("main h1")).to_be_visible()
        page.goto(base + "models.html", wait_until="load")
        providers = page.locator("[data-provider]")
        assert providers.count() > 0
        expect(page.locator("[data-provider]:visible")).to_have_count(providers.count())
        page.locator('[data-provider][href="models/gemini.html"]').click()
        expect(page).to_have_url(base + "models/gemini.html")
        expect(page.locator(".config-card")).to_contain_text(
            "https://generativelanguage.googleapis.com/v1beta"
        )
        directory = page.locator(".guide-nav details")
        # 无脚本时可以保留展开目录作为静态入口；默认手机折叠在正常脚本场景单独验证。
        if directory.get_attribute("open") is not None:
            directory.locator("summary").click()
        expect(directory.locator('a[href="custom.html"]')).to_be_hidden()
        directory.locator("summary").click()
        expect(directory.locator('a[href="custom.html"]')).to_be_visible()
    finally:
        context.close()


def check_hanging_downloads(browser: Browser, base: str, catalogue: dict) -> dict:
    """保持目录请求挂起，等待产品自己的八秒超时显示静态入口，不提前中止请求。"""
    context = browser.new_context(viewport={"width": 1440, "height": 1000})
    pending_routes: list[tuple[Route, float]] = []
    errors = []
    try:
        page = context.new_page()
        page.on("pageerror", lambda error: errors.append(str(error)))
        # 断言结束前不调用fulfill、continue或abort，只让产品自己的超时终止等待。
        context.route("**/releases.json", lambda route: pending_routes.append((route, monotonic())))
        page.goto(base + "downloads.html?platform=ios", wait_until="domcontentloaded")
        expect(page.locator("[data-downloads]")).to_be_visible()
        assert len(pending_routes) == 1, "Expected one pending catalogue request"
        expect(page.locator("#release-fallback")).to_be_hidden()
        expect(page.locator("#release-retry")).to_be_hidden()
        expect(page.locator("#release-fallback")).to_be_visible(timeout=12_000)
        elapsed = monotonic() - pending_routes[0][1]
        assert elapsed >= 7.5, f"Fallback appeared before the eight-second deadline: {elapsed:.2f}s"
        expect(page.locator("#release-retry")).to_be_visible()
        check_static_downloads(page.locator("#release-fallback"), catalogue)
        for selector in (
            "#platform-android",
            "#platform-ios",
            "#release-channel",
            "#release-version",
        ):
            expect(page.locator(selector)).to_be_disabled()
        assert not errors, errors
        return {"elapsedSeconds": round(elapsed, 2), "requests": len(pending_routes)}
    finally:
        # 产品超时断言已经结束，再释放测试拦截器，防止Playwright残留未完成路由任务。
        try:
            for route, _ in pending_routes:
                route.abort()
        finally:
            context.close()


def run(base: str, output: Path, full: bool = False) -> dict:
    """检查手机布局、轮播、搜索、版本切换及未来iOS分发兼容性。"""
    output.mkdir(parents=True, exist_ok=True)
    report = {"url": base, "checks": [], "pageErrors": [], "localTextContrast": []}

    def record(name: str) -> None:
        """仅在断言通过后登记验收结果。"""
        report["checks"].append(name)

    with sync_playwright() as engine:
        browser = engine.chromium.launch(headless=True)
        context = browser.new_context(
            viewport={"width": 1440, "height": 1000},
            permissions=["clipboard-read", "clipboard-write"],
        )
        page = context.new_page()
        page.on("pageerror", lambda error: report["pageErrors"].append(str(error)))
        page.clock.install()
        page.goto(base, wait_until="networkidle")
        expect(page.get_by_role("heading", level=1)).to_contain_text("把一个想法")
        expect(page.locator('meta[name="google-site-verification"]')).to_have_attribute(
            "content", "QVsEHxt7qwqGw9QpgACh-3VsNUXY6RNqMSVKd5DIol0"
        )
        structured_data = page.locator('script[type="application/ld+json"]').all_text_contents()
        assert any('"@type":"SoftwareApplication"' in value for value in structured_data)
        assert page.locator("body").evaluate(
            "el => getComputedStyle(el).fontFamily.includes('Times New Roman')"
        )
        text_contrast = page.locator("body").evaluate(
            """el => {
              const rgb = value => value.match(/[\\d.]+/g).slice(0,3).map(Number);
              const luminance = color => rgb(color).map(v => {
                v /= 255;
                return v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4;
              }).reduce((sum, v, i) => sum + v * [.2126,.7152,.0722][i], 0);
              const fg = luminance(getComputedStyle(el).color);
              const bg = luminance(getComputedStyle(el).backgroundColor);
              return (Math.max(fg,bg) + .05) / (Math.min(fg,bg) + .05);
            }"""
        )
        assert text_contrast >= 7, f"Body contrast below AAA: {text_contrast:.2f}:1"
        report["bodyContrast"] = round(text_contrast, 2)
        record("Google验证标签、Android结构化数据与正文AAA对比度")
        expect(page.locator("[data-carousel], [data-provider], [data-downloads]")).to_have_count(0)
        expect(page.locator(".entry-grid > a")).to_have_count(3)
        story = page.locator("[data-story]")
        expect(story).to_have_count(1)
        story.scroll_into_view_if_needed()
        check_story_panel(page, 0)
        # 推进虚拟时间，首屏即使在视口内且没有焦点或悬停也不自动切换。
        page.mouse.move(0, 0)
        page.clock.fast_forward(20_000)
        check_story_panel(page, 0)
        story_tabs = story.locator("[data-story-tab]")
        for index in range(4):
            story_tabs.nth(index).click()
            check_story_panel(page, index)
        for key, selected in (("Home", 0), ("ArrowRight", 1), ("ArrowLeft", 0), ("End", 3)):
            story.locator('[data-story-tab][aria-selected="true"]').press(key)
            check_story_panel(page, selected)
            expect(story_tabs.nth(selected)).to_be_focused()
            story_tabs.nth(selected).press("Tab")
            expect(
                story.locator("#day-" + ("chat", "tasks", "focus", "fragments")[selected])
            ).to_be_focused()
            page.keyboard.press("Shift+Tab")
            expect(story_tabs.nth(selected)).to_be_focused()
        story_tabs.nth(0).click()
        record("首页四步故事点击、方向键与Home/End切换，默认不自动播放")
        record("故事标签切换后Tab进入当前面板，Shift+Tab返回选中标签")
        report["localTextContrast"].append(
            check_local_text_contrast(page, ".entry-grid p, [data-story-tab], .button.primary")
        )
        page.screenshot(path=str(output / "home-desktop.png"), full_page=True)
        page.get_by_role("navigation", name="主导航", exact=True).get_by_role(
            "link", name="功能画廊"
        ).click()
        expect(page).to_have_url(base + "features.html")
        page.screenshot(path=str(output / "gallery-desktop.png"), full_page=True)
        region = page.locator("[data-carousel]")
        expect(region.locator("[data-carousel-play]")).to_have_text("播放")
        region.scroll_into_view_if_needed()
        page.mouse.move(0, 0)
        page.clock.fast_forward(20_000)
        expect(page.locator("#slide-chat")).to_be_visible()
        region.get_by_role("tab", name="个人待办").click()
        expect(page.locator("#slide-tasks")).to_be_visible()
        region.get_by_role("tab", name="个人待办").press("ArrowRight")
        expect(page.locator("#slide-focus")).to_be_visible()
        region.locator("[data-carousel-prev]").click()
        expect(page.locator("#slide-tasks")).to_be_visible()
        detail_link = page.locator('#slide-tasks a[href="features/tasks.html"]')
        detail_link.focus()
        detail_link.press("ArrowRight")
        expect(detail_link).to_be_focused()
        expect(detail_link).to_be_visible()
        expect(page.locator("#slide-tasks")).to_be_visible()
        expect(page.locator("#slide-focus")).to_be_hidden()
        expect(region.get_by_role("tab", name="个人待办")).to_have_attribute(
            "aria-selected", "true"
        )
        record("轮播详情链接按方向键不会切换面板或隐藏当前焦点")
        region.locator("[data-carousel-play]").click()
        expect(region.locator("[data-carousel-play]")).to_have_text("暂停")
        region.locator("[data-carousel-play]").click()
        expect(region.locator("[data-carousel-play]")).to_have_text("播放")
        record("图片轮播默认手动，点击、键盘及播放暂停状态切换")
        page.goto(base + "models.html", wait_until="networkidle")
        page.locator("#provider-search").fill("Kimi")
        expect(page.locator("[data-provider]:visible")).to_have_count(1)
        page.locator("#provider-search").fill("")
        page.locator('[data-provider-filter="国内平台"]').click()
        expect(page.locator("[data-provider]:visible")).to_have_count(6)
        expect(page.locator('[href="models/siliconflow.html"]')).to_have_count(0)
        expect(page.locator('[href="models/openrouter.html"]')).to_have_count(0)
        page.locator("#provider-search").fill("no-match-fixture")
        expect(page.locator("#provider-empty")).to_be_visible()
        empty = page.locator("#provider-empty")
        expect(empty.locator('a[href="models/custom.html"]')).to_be_visible()
        empty.locator("[data-provider-reset]").click()
        expect(page.locator("#provider-search")).to_have_value("")
        expect(page.locator('[data-provider-filter="全部"]')).to_have_attribute(
            "aria-pressed", "true"
        )
        expect(page.locator('[data-provider-filter][aria-pressed="true"]')).to_have_count(1)
        expect(page.locator("[data-provider]:visible")).to_have_count(
            page.locator("[data-provider]").count()
        )
        expect(empty).to_be_hidden()
        page.locator("#provider-search").fill("no-match-fixture")
        empty.locator('a[href="models/custom.html"]').click()
        expect(page).to_have_url(base + "models/custom.html")
        page.goto(base + "models.html", wait_until="networkidle")
        record("服务商搜索与类别筛选，空态清除全部筛选或直达自定义接口教程")
        report["localTextContrast"].append(
            check_local_text_contrast(
                page, ".provider-card p, .filter-pills button, #provider-count"
            )
        )
        expect(page.locator(".start-guide")).to_have_count(0)
        page.locator(".entry-banner").click()
        expect(page).to_have_url(base + "getting-started.html")
        expect(page.locator(".start-guide")).to_be_visible()
        expect(page.locator(".callout")).to_contain_text("暂时跳过")
        record("首页、功能画廊、服务商目录和入门说明独立切换")
        page.goto(base + "models/gemini.html", wait_until="networkidle")
        expect(page.locator(".config-card")).to_contain_text(
            "https://generativelanguage.googleapis.com/v1beta"
        )
        page.locator(".config-card [data-copy]").click()
        expect(page.locator("#page-status")).to_contain_text("已复制")
        assert (
            page.evaluate("navigator.clipboard.readText()")
            == "https://generativelanguage.googleapis.com/v1beta"
        )
        record("模型配置说明与复制基础URL")
        report["localTextContrast"].append(
            check_local_text_contrast(page, ".guide-meta, .config-card dt, .config-card dd small")
        )
        page.get_by_role("navigation", name="本篇目录").get_by_role(
            "link", name="App怎么填"
        ).click()
        page.wait_for_function(
            "Math.abs(document.querySelector('#configure').getBoundingClientRect().top - (parseFloat(getComputedStyle(document.documentElement).scrollPaddingTop) + 20)) < 4"
        )
        assert (
            page.locator("#configure").bounding_box()["y"]
            >= page.locator(".site-header").bounding_box()["height"]
        )
        page.screenshot(path=str(output / "guide-scrolled-desktop.png"))
        record("教程锚点跳转位于常驻导航下方")
        catalogue = context.request.get(base + "releases.json").json()
        android = sorted(
            (
                release
                for release in catalogue["releases"]
                if release["platform"] == "android" and release["channel"] == "stable"
            ),
            key=lambda release: (
                tuple(int(part) for part in release["version"].split(".")[:3]),
                release.get("versionCode", 0),
            ),
            reverse=True,
        )
        page.goto(base + "downloads.html", wait_until="networkidle")
        expect(page.locator("#release-message")).to_contain_text(f"{len(android)}个可用版本")
        check_binary_card(page.locator("#release-content .release-card"), android[0])
        expect(page.locator("#release-history")).to_have_count(0)
        expect(page.locator("#release-content a.button")).to_have_text("下载APK")
        expect(page.locator("#release-fallback")).to_be_hidden()
        report["localTextContrast"].append(
            check_local_text_contrast(
                page, "#release-content .release-summary, .release-facts span, .checksum > code"
            )
        )
        page.screenshot(path=str(output / "downloads-desktop.png"), full_page=True)
        page.get_by_role("navigation", name="当前栏目").get_by_role("link", name="版本历史").click()
        expect(page).to_have_url(base + "versions.html")
        expect(page.locator("#release-history")).to_contain_text(android[0]["version"])
        page.get_by_role("navigation", name="当前栏目").get_by_role(
            "link", name="安装与升级"
        ).click()
        expect(page).to_have_url(base + "install.html")
        expect(page.locator("main")).to_contain_text("Android安装步骤")
        page.go_back(wait_until="networkidle")
        expect(page).to_have_url(base + "versions.html")
        page.go_back(wait_until="networkidle")
        expect(page).to_have_url(base + "downloads.html")
        record("下载、版本历史与安装说明独立页面及后退恢复")
        page.get_by_role("tab", name="iOS").click()
        ios_releases = [
            release
            for release in catalogue["releases"]
            if release["platform"] == "ios" and release["channel"] == "stable"
        ]
        if ios_releases:
            selected = page.locator("#release-version").input_value()
            release = next(item for item in ios_releases if item["id"] == selected)
            check_binary_card(page.locator("#release-content .release-card"), release)
            record("两平台下载卡片大小和校验入口与所选安装包一致")
        else:
            expect(page.locator("#release-content")).to_contain_text("尚未公开发布")
            expect(page.locator("#release-content a.button")).to_have_count(0)
        assert "platform=ios" in page.url
        page.go_back(wait_until="networkidle")
        expect(page.locator("#release-content a.button")).to_have_count(1)
        page.locator("#release-channel").select_option("beta")
        expect(page.locator("#release-content")).to_contain_text("当前渠道暂无版本")
        expect(page.locator("#release-channel")).to_be_enabled()
        record("真实平台发行状态、空渠道与浏览器返回")

        # 未来版本仅通过网络拦截构造，不修改或发布真实发行清单。
        future = copy.deepcopy(catalogue)
        older = copy.deepcopy(android[0])
        older.pop("checksumsUrl", None)
        newer = copy.deepcopy(older)
        older.update(id="android-2.9.0-fixture", version="2.9.0", versionCode=59)
        newer.update(id="android-2.10.0-fixture", version="2.10.0", versionCode=60)
        future["releases"].extend([older, newer])
        future["platforms"][1]["status"] = "available"
        ios = copy.deepcopy(newer)
        ios.update(
            id="ios-store-fixture",
            platform="ios",
            distribution="app-store",
            downloadUrl="https://apps.apple.com/",
            minimumOs="16.0",
        )
        del ios["sha256"]
        del ios["sizeBytes"]
        future["releases"].append(ios)
        context.route("**/releases.json", lambda route: route.fulfill(json=future))
        page.goto(base + "downloads.html", wait_until="networkidle")
        expect(page.locator("#release-version")).to_have_value("android-2.10.0-fixture")
        page.locator("#release-version").select_option("android-2.9.0-fixture")
        expect(page.locator("#release-content")).to_contain_text("v2.9.0")
        page.get_by_role("tab", name="iOS").click()
        expect(page.locator("#release-content .chip")).to_have_text("App Store")
        expect(page.locator("#platform-ios")).to_contain_text("已发布")
        expect(page.locator("#release-content .checksum")).to_have_count(0)
        record("未来多版本数字排序、旧版选择与iOS商店分发")
        context.unroute("**/releases.json")
        unsigned = copy.deepcopy(future)
        unsigned["releases"][-1].update(
            distribution="ipa",
            signing="unsigned",
            sizeBytes=123456,
            sha256="a" * 64,
            downloadUrl="https://example.com/nivo-unsigned.ipa",
        )
        context.route("**/releases.json", lambda route: route.fulfill(json=unsigned))
        page.goto(base + "downloads.html?platform=ios", wait_until="networkidle")
        expect(page.locator("#release-content .chip")).to_have_text("未签名IPA")
        expect(page.locator("#release-content a.button")).to_have_text("下载未签名IPA")
        expect(page.locator("#release-content")).to_contain_text("不能下载后直接安装到iPhone")
        expect(page.locator("#release-content")).to_contain_text(
            "本文件没有TestFlight或App Store安装入口"
        )
        expect(page.locator("#release-content .checksum")).to_have_count(1)
        record("未签名IPA按钮、文件校验与自行签名安装提示")
        context.unroute("**/releases.json")
        unavailable = copy.deepcopy(catalogue)
        unavailable["platforms"][1]["status"] = "unreleased"
        unavailable["platforms"][1]["message"] = "此测试平台尚未公开发布。"
        unavailable["releases"] = [
            release for release in unavailable["releases"] if release["platform"] != "ios"
        ]
        context.route("**/releases.json", lambda route: route.fulfill(json=unavailable))
        page.goto(base + "downloads.html?platform=ios", wait_until="networkidle")
        expect(page.locator("#release-content")).to_contain_text("尚未公开发布")
        expect(page.locator("#release-content a.button")).to_have_count(0)
        record("未发布平台无虚构下载入口")
        context.unroute("**/releases.json")
        context.route("**/releases.json", lambda route: route.abort())
        page.goto(base + "downloads.html?platform=ios", wait_until="networkidle")
        expect(page.locator("#release-retry")).to_be_visible()
        fallback = page.locator("#release-fallback")
        expect(fallback).to_be_visible()
        check_static_downloads(fallback, catalogue)
        expect(page.locator("#platform-android")).to_be_disabled()
        expect(page.locator("#platform-ios")).to_be_disabled()
        expect(page.locator("#release-channel")).to_be_disabled()
        expect(page.locator("#release-version")).to_be_disabled()
        record("iOS直达链接遇到目录请求失败时，两平台静态下载与签名前提仍可见")
        context.unroute("**/releases.json")
        page.locator("#release-retry").click()
        expect(page.locator("#release-retry")).to_be_hidden()
        expect(fallback).to_be_hidden()
        expect(page.locator("#platform-ios")).to_be_enabled()
        expect(page.locator("#release-version")).to_be_enabled()
        record("网络恢复后重试恢复平台与版本选择")
        report["hangingCatalogue"] = check_hanging_downloads(browser, base, catalogue)
        record("目录请求持续挂起后由八秒超时展示两平台静态下载，控件保持禁用")

        mobile = browser.new_context(
            viewport={"width": 390, "height": 844},
            is_mobile=True,
            has_touch=True,
            reduced_motion="reduce",
        )
        phone = mobile.new_page()
        phone.on("pageerror", lambda error: report["pageErrors"].append(str(error)))
        phone.goto(base + "features.html", wait_until="networkidle")
        expect(phone.locator("[data-carousel-play]")).to_have_text("播放")
        report["galleryTabScroll"] = check_gallery_tab_scroll(phone)
        record("手机原生横向手势滚动功能标签，当前截图与选中功能保持不变")
        phone.locator(".gallery-stage").evaluate("""stage => {
          const point = x => new Touch({identifier: 1, target: stage, clientX: x, clientY: 400});
          stage.dispatchEvent(new TouchEvent('touchstart', {bubbles: true, changedTouches: [point(270)]}));
          stage.dispatchEvent(new TouchEvent('touchcancel', {bubbles: true, changedTouches: [point(270)]}));
          stage.dispatchEvent(new TouchEvent('touchend', {bubbles: true, changedTouches: [point(80)]}));
        }""")
        expect(phone.locator("#slide-chat")).to_be_visible()
        expect(phone.locator("#slide-tasks")).to_be_hidden()
        record("画面手势取消后清空起点，残留结束事件不切换截图")
        phone.locator(".gallery-stage").evaluate("""stage => {
          const point = x => new Touch({identifier: 1, target: stage, clientX: x, clientY: 400});
          stage.dispatchEvent(new TouchEvent('touchstart', {bubbles: true, changedTouches: [point(270)]}));
          stage.dispatchEvent(new TouchEvent('touchend', {bubbles: true, changedTouches: [point(80)]}));
        }""")
        expect(phone.locator("#slide-tasks")).to_be_visible()
        record("手机轮播画面区域触摸事件切换，取消后新手势仍然有效")
        phone.evaluate(
            "window.scrollTo({top:document.documentElement.scrollHeight,behavior:'instant'})"
        )
        assert abs(phone.locator(".site-header").bounding_box()["y"]) <= 1
        expect(phone.get_by_role("navigation", name="页面切换")).to_be_visible()
        phone.screenshot(path=str(output / "mobile-scrolled-navigation.png"))
        phone.get_by_role("navigation", name="页面切换").get_by_role(
            "link", name="下载应用"
        ).click()
        expect(phone).to_have_url(base + "downloads.html")
        record("手机下滑后直接使用常驻页面标签跳转")
        phone.get_by_role("button", name="导航").click()
        expect(phone.locator("#navigation")).to_be_visible()
        menu_link = phone.get_by_role("navigation", name="主导航").get_by_role(
            "link", name="模型接入"
        )
        menu_link.focus()
        menu_link.press("Escape")
        expect(phone.locator("#navigation")).to_be_hidden()
        expect(phone.locator(".menu-button")).to_be_focused()
        expect(phone.locator(".menu-button")).to_have_attribute("aria-expanded", "false")
        phone.locator(".menu-button").click()
        menu_link.click()
        expect(phone.get_by_role("heading", level=1)).to_contain_text("选一个模型")
        record("手机菜单Escape关闭后恢复按钮焦点，再次打开可切页")
        phone.goto(base + "models/gemini.html", wait_until="networkidle")
        directory = phone.locator(".guide-nav details")
        expect(directory).not_to_have_attribute("open", "")
        expect(directory.locator('a[href="deepseek.html"]')).to_be_hidden()
        directory.locator("summary").click()
        expect(directory.locator('a[href="deepseek.html"]')).to_be_visible()
        directory.locator("summary").click()
        expect(directory.locator('a[href="deepseek.html"]')).to_be_hidden()
        report["localTextContrast"].append(
            check_local_text_contrast(phone, ".mobile-page-tabs a, .guide-meta, .config-card dt")
        )
        record("手机教程服务商目录默认折叠且可展开，正文与导航局部文字达到AA对比度")
        check_without_javascript(browser, base, catalogue)
        record("禁用JavaScript时首页入口、功能详情、模型教程及两平台真实下载仍可用")
        report["appScreenshots"] = check_app_screenshots(browser, base)
        record("六张1080×2400截图在四种宽度完整显示并解码成功，六个原图链接真实打开")
        manifest = context.request.get(base + "site-manifest.json").json()
        sitemap = context.request.get(base + "sitemap.xml").text()
        assert "<lastmod>" in sitemap
        expect(context.request.get(base + "robots.txt")).to_be_ok()
        record("公开robots与含更新时间的站点地图")
        paths = [
            name
            for name in manifest["files"]
            if name.endswith(".html") and not name.startswith("google")
        ]
        targets = (
            paths
            if full
            else [
                "index.html",
                "features.html",
                "models.html",
                "models/gemini.html",
                "downloads.html",
                "features/focus.html",
            ]
        )
        for width in [320, 390, 768, 1440]:
            page.set_viewport_size({"width": width, "height": 900})
            for target in targets:
                page.goto(base + target, wait_until="load")
                assert not page.evaluate("document.documentElement.scrollWidth > innerWidth + 1"), (
                    f"Overflow {width} {target}"
                )
                page.evaluate(
                    "window.scrollTo({top:document.documentElement.scrollHeight,behavior:'instant'})"
                )
                header = page.locator(".site-header").bounding_box()
                assert abs(header["y"]) <= 1, f"Header disappeared {width} {target}"
                assert page.locator(".site-header").evaluate(
                    "el => {const r=el.getBoundingClientRect(); return el.contains(document.elementFromPoint(r.width/2, r.height/2));}"
                ), f"Header covered {target}"
        record(f"{len(targets)}页×4种宽度无整页横向溢出")
        record(f"{len(targets)}页×4种宽度滚动到底后顶部导航保持可见")
        for target, name in [
            ("index.html", "home-mobile.png"),
            ("features.html", "gallery-mobile.png"),
            ("models/gemini.html", "guide-mobile.png"),
            ("downloads.html?platform=ios", "ios-mobile.png"),
        ]:
            phone.goto(base + target, wait_until="networkidle")
            phone.screenshot(path=str(output / name), full_page=True)
        assert not report["pageErrors"], report["pageErrors"]
        report["passed"] = True
        browser.close()
    (output / "browser-qa.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return report


def main() -> None:
    """支持本地与公网同一套验收，公开页不需要密钥。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8783/")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args()
    print(
        json.dumps(
            run(args.url.rstrip("/") + "/", args.output, args.full), ensure_ascii=False, indent=2
        )
    )


if __name__ == "__main__":
    main()
