"""在本地或已部署的产品站执行浏览器验收，模型服务始终不被调用。"""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from playwright.sync_api import expect, sync_playwright


def run(base: str, output: Path, full: bool = False) -> dict:
    """检查手机布局、轮播、搜索、版本切换及未来iOS分发兼容性。"""
    output.mkdir(parents=True, exist_ok=True)
    report = {"url": base, "checks": [], "pageErrors": []}

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
        page.goto(base, wait_until="networkidle")
        expect(page.get_by_role("heading", level=1)).to_contain_text("想法说出来")
        page.screenshot(path=str(output / "home-desktop.png"), full_page=True)
        region = page.locator("[data-carousel]")
        region.get_by_role("tab", name="个人待办").click()
        expect(page.locator("#slide-tasks")).to_be_visible()
        region.get_by_role("tab", name="个人待办").press("ArrowRight")
        expect(page.locator("#slide-focus")).to_be_visible()
        region.locator("[data-carousel-prev]").click()
        expect(page.locator("#slide-tasks")).to_be_visible()
        region.locator("[data-carousel-play]").click()
        expect(region.locator("[data-carousel-play]")).to_have_text("播放")
        record("图片轮播点击、键盘与暂停")
        page.goto(base + "models.html", wait_until="networkidle")
        page.locator("#provider-search").fill("Kimi")
        expect(page.locator("[data-provider]:visible")).to_have_count(1)
        page.locator("#provider-search").fill("")
        page.locator('[data-provider-filter="国内平台"]').click()
        expect(page.locator("[data-provider]:visible")).to_have_count(7)
        page.locator("#provider-search").fill("no-match-fixture")
        expect(page.locator("#provider-empty")).to_be_visible()
        record("服务商搜索、类别筛选和无结果状态")
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
        page.goto(base + "downloads.html", wait_until="networkidle")
        expect(page.locator("#release-message")).to_contain_text("1个可用版本")
        expect(page.locator("#release-content a.button")).to_have_attribute(
            "href", "https://nivo.8666886.xyz/downloads/Nivo-Bot-v2.0.0-arm64.apk"
        )
        page.get_by_role("tab", name="iOS").click()
        expect(page.locator("#release-content")).to_contain_text("尚未公开发布")
        expect(page.locator("#release-content a.button")).to_have_count(0)
        assert "platform=ios" in page.url
        page.go_back(wait_until="networkidle")
        expect(page.locator("#release-content a.button")).to_have_count(1)
        page.locator("#release-channel").select_option("beta")
        expect(page.locator("#release-content")).to_contain_text("当前渠道暂无版本")
        expect(page.locator("#release-channel")).to_be_enabled()
        page.screenshot(path=str(output / "downloads-desktop.png"), full_page=True)
        record("下载平台、未发布iOS、空渠道与浏览器返回")

        # 未来版本仅通过网络拦截构造，不修改或发布真实发行清单。
        response = context.request.get(base + "releases.json")
        catalogue = response.json()
        future = copy.deepcopy(catalogue)
        older = copy.deepcopy(future["releases"][0])
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
        context.route("**/releases.json", lambda route: route.abort())
        page.goto(base + "downloads.html", wait_until="networkidle")
        expect(page.locator("#release-retry")).to_be_visible()
        expect(page.locator("#release-content a.button")).to_have_count(1)
        expect(page.locator("#platform-ios")).to_be_disabled()
        record("版本目录离线时保留静态正式下载入口")
        context.unroute("**/releases.json")
        page.locator("#release-retry").click()
        expect(page.locator("#release-retry")).to_be_hidden()
        expect(page.locator("#platform-ios")).to_be_enabled()
        expect(page.locator("#release-version")).to_be_enabled()
        record("网络恢复后重试恢复平台与版本选择")

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
        phone.locator("[data-carousel]").evaluate("""region => {
          const point = x => new Touch({identifier: 1, target: region, clientX: x, clientY: 400});
          region.dispatchEvent(new TouchEvent('touchstart', {changedTouches: [point(270)]}));
          region.dispatchEvent(new TouchEvent('touchend', {changedTouches: [point(80)]}));
        }""")
        expect(phone.locator("#slide-tasks")).to_be_visible()
        record("手机轮播触摸事件切换")
        phone.get_by_role("button", name="导航").click()
        expect(phone.locator("#navigation")).to_be_visible()
        phone.get_by_role("navigation", name="主导航").get_by_role("link", name="模型接入").click()
        expect(phone.get_by_role("heading", level=1)).to_contain_text("选一个模型")
        record("手机导航及系统减少动态效果")
        manifest = context.request.get(base + "site-manifest.json").json()
        paths = [name for name in manifest["files"] if name.endswith(".html")]
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
        record(f"{len(targets)}页×4种宽度无整页横向溢出")
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
