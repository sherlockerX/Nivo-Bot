#!/usr/bin/env python3
"""生成念步／Nelan手机品牌资源，重复执行不产生额外变化。

日常更名使用brand-only入口，只更新可见资源，保留版本和安装身份。
完整上游移植入口还处理包标识、版本、链接、配色、通知图标和历史文案；
不要将其作为仅改显示名的命令。Kotlin及Swift中的身份、持久化路径和历史
迁移条件由各平台维护，不机械替换；iOS字符串目录保留原查找键。

图标由gen-android-icons.py与gen-ios-icons.py生成。其他上游改动带nanoMuse注释。

    python scripts/rebrand.py            # 完整上游移植，再报告历史检查项
    python scripts/rebrand.py --check    # 只检查，不写入
    python scripts/rebrand.py --android-brand-only  # 仅更新Android可见品牌，不更改版本或数据标识
    python scripts/rebrand.py --android-identity-only  # 显式更新Android安装身份与快捷入口
    python scripts/rebrand.py --ios-brand-only      # 仅更新iOS可见品牌，不更改版本或数据标识
    python scripts/rebrand.py --ios-version-only    # 仅更新iOS版本，不更改品牌、图像或数据标识
    python scripts/rebrand.py --versions-only       # 仅更新Android和iOS版本
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android" / "src" / "android"
APP = ANDROID / "app"
MAIN = APP / "src" / "main"
JAVA = MAIN / "java" / "com" / "openminis" / "app"
RES = MAIN / "res"
IOS = ROOT / "android" / "src" / "ios"

ANDROID_APP_ID = "io.github.sherlockerx.nelan"
IOS_APP_ID = "io.github.nanomuse.app"  # iOS保留已发行身份，不能随Android包名变动。
NAME = "Nelan"  # 手机产品的英文显示名；持久化标识保留原值。
CHINESE_NAME = "念步"
VERSION_NAME = "2.0.9"
VERSION_CODE = 60
# 手机版本使用同一发布来源，完整品牌生成也不能恢复旧的Android版本。
ANDROID_VERSION_NAME = VERSION_NAME
ANDROID_VERSION_CODE = VERSION_CODE
ANDROID_NAME = NAME
REPO = "sherlockerX/Nicholasx"  # Nicholasx：本分支的源码与反馈入口
REPO_URL = f"https://github.com/{REPO}"
PRIVACY_URL = f"{REPO_URL}/blob/main/docs/privacy.md"

# X-Minis-Token is a protocol header; MinisSkills is a path. The tail is an ASCII
# lookahead rather than \b so that "Minis가" (Korean particle) is still caught.
WORD = re.compile(r"(?<!X-)\bMinis(?!Skills)(?![A-Za-z0-9_])")
changed: list[str] = []


def edit(path: Path, subs: list[tuple[str, str]], count: int = 0) -> None:
    text = path.read_text(encoding="utf-8")
    new = text
    for pattern, repl in subs:
        new = re.sub(pattern, repl, new, count=count, flags=re.M)
    if new != text:
        path.write_text(new, encoding="utf-8", newline="\n")
        changed.append(str(path.relative_to(ROOT)))


def android_versions_only() -> None:
    """仅生成Android版本字段，保留包名、品牌、图像与签名配置。"""
    edit(
        APP / "build.gradle.kts",
        [
            (r"versionCode = \d+", f"versionCode = {ANDROID_VERSION_CODE}"),
            (r'versionName = "[^"]+"', f'versionName = "{ANDROID_VERSION_NAME}"'),
        ],
    )


def gradle() -> None:
    """完整品牌生成复用版本入口，再更新应用标识。"""
    android_versions_only()
    edit(
        APP / "build.gradle.kts",
        [(r'applicationId = "[^"]+"', f'applicationId = "{ANDROID_APP_ID}"')],
    )


def android_identity_only() -> None:
    """仅显式切换Android安装身份及入口，不调整版本或另一平台。"""
    edit(
        APP / "build.gradle.kts",
        [(r'applicationId = "[^"]+"', f'applicationId = "{ANDROID_APP_ID}"')],
    )
    package_ids()


def package_ids() -> None:
    """将快捷入口指向当前Android应用，无障碍组件使用运行时安装ID。"""
    edit(
        RES / "xml" / "shortcuts.xml",
        [
            (r'android:targetPackage="[^"]+"', f'android:targetPackage="{ANDROID_APP_ID}"'),
        ],
    )
    a11y = JAVA / "accessibility" / "MinisAccessibilityService.kt"
    edit(
        a11y,
        [
            (
                r'const val SERVICE_ID = "com\.openminis\.app/\.accessibility\.MinisAccessibilityService"',
                'val SERVICE_ID = "${BuildConfig.APPLICATION_ID}/com.openminis.app.accessibility.'
                'MinisAccessibilityService" // nanoMuse: the applicationId is not the package',
            ),
        ],
    )
    text = a11y.read_text(encoding="utf-8")
    if "import com.openminis.app.BuildConfig" not in text:
        text = text.replace("\nimport ", "\nimport com.openminis.app.BuildConfig\nimport ", 1)
        a11y.write_text(text, encoding="utf-8")


def product_name() -> None:
    """完整生成也只更新资源，避免重写默认身份和历史名称迁移条件。"""
    android_brand_only()


def soul_defaults() -> None:
    edit(
        JAVA / "agent" / "SoulStore.kt",
        [
            (r'const val DISPLAY_EMOJI = "✨"', 'const val DISPLAY_EMOJI = "🐾"'),
        ],
    )
    # The default-name round-trip follows DEFAULT; explicit stored-name fixtures stay intact.
    test = APP / "src" / "test" / "java" / "com" / "openminis" / "app" / "agent"
    test /= "SoulIconConfigEdgeTest.kt"
    if test.is_file():
        edit(
            test,
            [
                (
                    r'^([ \t]*)assertEquals\("Minis", back\.metadata\.name\)$',
                    r"\1// nanoMuse: round-trip the rebranded default name.\n"
                    r"\1assertEquals(SoulMetadata.DEFAULT.name, back.metadata.name)",
                ),
            ],
        )


def links() -> None:
    """更新当前分支的发行入口，防止再次品牌化时恢复上游地址。"""
    owner, repository = REPO.split("/", 1)
    edit(
        JAVA / "data" / "UpdateChecker.kt",
        [
            (r'private const val OWNER = "[^"]+"', f'private const val OWNER = "{owner}"'),
            (r'private const val REPO = "[^"]+"', f'private const val REPO = "{repository}"'),
            (
                r'const val RELEASES_URL: String = "[^"]+"',
                f'const val RELEASES_URL: String = "{REPO_URL}/releases"',
            ),
        ],
    )
    community = MAIN / "java" / "io" / "github" / "nanomuse" / "community" / "UpdateCheck.kt"
    if community.is_file():
        edit(
            community,
            [
                (
                    r'const val DOWNLOAD_URL = "[^"]+"',
                    f'const val DOWNLOAD_URL = "{REPO_URL}/releases"',
                ),
                (
                    r'const val GITHUB_LATEST_URL = "[^"]+"',
                    f'const val GITHUB_LATEST_URL = "https://api.github.com/repos/{REPO}/releases/latest"',
                ),
            ],
        )
    edit(
        JAVA / "ui" / "settings" / "AboutScreen.kt",
        [
            (r'"https://github\.com/OpenMinis/OpenMinis"\)', f'"{REPO_URL}")'),
        ],
    )
    edit(
        JAVA / "ui" / "settings" / "SettingsScreen.kt",
        [
            (r'"https://openminis\.github\.io/privacy-policy\.html"', f'"{PRIVACY_URL}"'),
            (r'"https://github\.com/OpenMinis/OpenMinis/issues/new"', f'"{REPO_URL}/issues/new"'),
        ],
    )


SYSTEM_SCHEME = "nanomuse"  # what the system knows the app by; inside, links stay minis://


def schemes() -> None:
    """The scheme registered with the system is ours, so a phone with OpenMinis installed too
    never has two apps claiming `minis://`; the in-app vocabulary (`minis://…`) does not change."""
    edit(
        MAIN / "AndroidManifest.xml",
        [(r'<data android:scheme="minis" />', f'<data android:scheme="{SYSTEM_SCHEME}" />')],
    )


# (pattern, replacement); applied to Theme.kt only.
THEME_MAP = [
    ("0xFF528AD2", "0xFF015CFB"),  # primary
    ("0xFFB2DFDB", "0xFFE5F0FF"),  # primaryContainer
    ("0xFF00332F", "0xFF012F80"),  # onPrimaryContainer
    ("0xFF4A6360", "0xFF4F5B6E"),  # secondary
    ("0xFFCCE8E4", "0xFFDCE6F5"),  # secondaryContainer
    ("0xFF05201D", "0xFF101C2E"),  # onSecondaryContainer
    ("0xFFF5FAFA", "0xFFF2F2F7"),  # background / surface (overridden by the neutrals)
    ("0xFF171D1C", "0xFF1C1C1E"),  # onBackground / onSurface
    ("0xFFDAE5E2", "0xFFE5E5EA"),  # surfaceVariant
    ("0xFF3F4947", "0xFF3C3C43"),  # onSurfaceVariant (light) / surfaceVariant (dark)
    ("0xFF6F7977", "0xFF6E6E73"),  # outline
    ("0xFF6A94CE", "0xFF58A6FF"),  # dark primary
    ("0xFF003737", "0xFF00224D"),  # dark onPrimary
    ("0xFF1A6B6B", "0xFF1A2B4A"),  # dark primaryContainer
    ("0xFFB1CCC8", "0xFFB8C6DA"),  # dark secondary
    ("0xFF1C3532", "0xFF22304A"),  # dark onSecondary
    ("0xFF334B48", "0xFF334159"),  # dark secondaryContainer
    ("0xFF0E1514", "0xFF000000"),  # dark background / surface
    ("0xFFDEE4E2", "0xFFE5E5EA"),  # dark onBackground / onSurface
    ("0xFFBEC9C6", "0xFFC7C7CC"),  # dark onSurfaceVariant
    ("0xFF899390", "0xFF8E8E93"),  # dark outline
]

# Applied to ChatColors.kt only; light palette first, then dark. The user's own
# message is a black pill in the light theme and a white one in the dark theme
# (docs/design.md); the send button keeps upstream's black / white, so no entry.
CHAT_MAP = [
    ("userBubble = Color(0x1E787880)", "userBubble = Color(0xFF000000)"),
    ("codeBlockText = Color(0xFF34C759)", "codeBlockText = Color(0xFFE5E5EA)"),
    ("inlineCodeText = Color(0xFFFF9500)", "inlineCodeText = Color(0xFF015CFB)"),
    ("blockquoteBar = Color(0x80FF9500)", "blockquoteBar = Color(0x80015CFB)"),
    ("fabAccent = Color(0xFFB7AF96)", "fabAccent = Color(0xFF015CFB)"),
    ("userBubble = Color(0xFF2F3A5C)", "userBubble = Color(0xFFFFFFFF)"),
    ("codeBlockText = Color(0xFF8CF38C)", "codeBlockText = Color(0xFFE5E5EA)"),
    ("inlineCodeText = Color(0xFFFF9F0A)", "inlineCodeText = Color(0xFF58A6FF)"),
    ("blockquoteBar = Color(0x80FF9F0A)", "blockquoteBar = Color(0x8058A6FF)"),
    ("fabAccent = Color(0xFF504C42)", "fabAccent = Color(0xFF58A6FF)"),
]

# The iOS system blues, wherever they are hard-coded (any alpha).
GLOBAL_MAP = [
    (r"0x([0-9A-Fa-f]{2})007AFF", r"0x\g<1>015CFB"),
    (r"0x([0-9A-Fa-f]{2})0A84FF", r"0x\g<1>58A6FF"),
    (r"#007AFF\b", "#015CFB"),
    (r"#0A84FF\b", "#58A6FF"),
]


def colours() -> None:
    edit(JAVA / "ui" / "theme" / "Theme.kt", [(re.escape(a), b) for a, b in THEME_MAP])
    edit(JAVA / "ui" / "theme" / "ChatColors.kt", [(re.escape(a), b) for a, b in CHAT_MAP], count=1)
    for path in sorted(JAVA.rglob("*.kt")) + sorted(RES.rglob("*.xml")):
        edit(path, GLOBAL_MAP)
    edit(RES / "values" / "colors.xml", [(r'(<color name="seed">)#[0-9A-Fa-f]+', r"\g<1>#015CFB")])


def notification_icons() -> None:
    for path in sorted(JAVA.rglob("*.kt")):
        edit(
            path,
            [
                (
                    r"setSmallIcon\(R\.mipmap\.ic_launcher\)",
                    "setSmallIcon(R.drawable.ic_stat_nanomuse) // nanoMuse: flat status-bar mark",
                ),
            ],
        )


FACE = re.compile(
    r"(Notification(?:Compat)?\.Builder\((\w+), [^\n]*\)\n(\s*)\.setSmallIcon\([^\n]*\n)"
    r"(?!\s*\.setLargeIcon)"
)


def notification_faces() -> None:
    """Every notification the agent sends shows its face as the large icon."""

    def add(m: re.Match[str]) -> str:
        ctx, indent = m.group(2), m.group(3)
        return (
            f"{m.group(1)}{indent}.setLargeIcon(io.github.nanomuse.identity.NanoMuseIdentity"
            f".face({ctx})) // nanoMuse: the agent is the sender\n"
        )

    for path in sorted(JAVA.rglob("*.kt")):
        text = path.read_text(encoding="utf-8")
        new = FACE.sub(add, text)
        if new != text:
            path.write_text(new, encoding="utf-8")
            changed.append(str(path.relative_to(ROOT)))


# Reworded in nanoMuse's voice. Locale dir -> string name -> text.
COPY: dict[str, dict[str, str]] = {
    "values": {
        "sessionlist_welcome_subtitle": "Three steps, and you have an assistant that lives on your phone.",
        "about_minis_tagline": "An open-source personal agent for every device you own. On this phone today; everything runs here, with your own model.",
        "onboarding_welcome_subtitle": "An AI assistant with its own terminal and browser, running on this phone.",
        "bg_service_notification_title": "Nicholasx is working",
    },
    "values-zh": {
        "sessionlist_welcome_subtitle": "三步之后，你就有一个住在手机里的助理。",
        "about_minis_tagline": "一个开源的个人智能体，面向你的所有设备。目前在这台手机上：一切都在本机运行，模型由你自己带。",
        "onboarding_welcome_subtitle": "有自己的终端和浏览器、能用这台手机的 AI 助理。",
        "bg_service_notification_title": "Nicholasx 正在工作",
    },
    "values-zh-rTW": {
        "sessionlist_welcome_subtitle": "三步之後，你就有一個住在手機裡的助理。",
        "about_minis_tagline": "一個開源的個人智慧體，面向你的所有裝置。目前在這支手機上：一切都在本機執行，模型由你自己帶。",
        "onboarding_welcome_subtitle": "有自己的終端機和瀏覽器、能用這支手機的 AI 助理。",
        "bg_service_notification_title": "Nicholasx 正在工作",
    },
}


def reword() -> None:
    for folder, strings in COPY.items():
        subs = [
            (rf'(<string name="{name}">)[^<]*(</string>)', rf"\g<1>{text}\g<2>")
            for name, text in strings.items()
        ]
        edit(RES / folder / "strings.xml", subs)
    # "<name> is browsing": the product name becomes a placeholder in every locale.
    for path in sorted(RES.glob("values*/strings.xml")):
        edit(
            path,
            [
                (
                    rf'(<string name="browser_minis_browsing">[^<]*?){NAME}([^<]*</string>)',
                    r"\g<1>%1$s\g<2>",
                )
            ],
        )


# --- iOS -------------------------------------------------------------------------------------

IOS_ID_RULES = [
    (r"com\.openminis\.app", IOS_APP_ID),
    (r"com\.openminis\.MinisTests", "io.github.nanomuse.MinisTests"),
    (r"com\.openminis\.MinisUITests", "io.github.nanomuse.MinisUITests"),
]


def ios_files(*suffixes: str) -> list[Path]:
    out: list[Path] = []
    for path in sorted(IOS.rglob("*")):
        if path.is_file() and path.suffix in suffixes and "Vendor" not in path.parts:
            out.append(path)
    return out


def ios_ids() -> None:
    """Bundle ids, app group, iCloud container, BGTask / URL-scheme / keychain ids: the iOS side
    has no fixed package name, so the whole family moves to ours."""
    for path in ios_files(
        ".swift", ".plist", ".entitlements", ".pbxproj", ".xcscheme", ".xcprivacy"
    ):
        edit(path, IOS_ID_RULES)
    # Stale File Provider domains are matched by prefix; ours now start with our id.
    edit(
        IOS / "MinisApp.swift",
        [(r'contains\("com\.openminis"\)', 'contains("io.github.nanomuse")')],
    )


def ios_schemes() -> None:
    """Same as `schemes()` for the phone's other half: Info.plist registers `nanomuse` and
    `nanomuse-mcp`, the share extension opens `nanomuse://share`; `minis://` stays in-app."""
    edit(
        IOS / "Info.plist",
        [
            (r"<string>minis</string>", f"<string>{SYSTEM_SCHEME}</string>"),
            (r"<string>minis-mcp</string>", f"<string>{SYSTEM_SCHEME}-mcp</string>"),
        ],
    )
    edit(
        IOS / "ShareExtension" / "ShareViewController.swift",
        [(r"minis://share", f"{SYSTEM_SCHEME}://share")],
    )


def ios_versions_only() -> None:
    """仅生成iOS版本字段，不改可见品牌、图像、数据标识或其他平台。"""
    if not IOS.is_dir():
        return
    pbx = IOS / "Minis.xcodeproj" / "project.pbxproj"
    edit(
        pbx,
        [
            (r"MARKETING_VERSION = \d+(?:\.\d+)+;", f"MARKETING_VERSION = {VERSION_NAME};"),
            (r"CURRENT_PROJECT_VERSION = \d+;", f"CURRENT_PROJECT_VERSION = {VERSION_CODE};"),
        ],
    )


def ios_project() -> None:
    """完整iOS品牌流程复用同一版本生成入口，避免后续同步回退版本。"""
    ios_versions_only()
    pbx = IOS / "Minis.xcodeproj" / "project.pbxproj"
    edit(
        pbx,
        [
            (
                r'INFOPLIST_KEY_CFBundleDisplayName = "Share to Minis";',
                f'INFOPLIST_KEY_CFBundleDisplayName = "Share to {NAME}";',
            ),
            (
                r'INFOPLIST_KEY_CFBundleDisplayName = "Minis Files";',
                f'INFOPLIST_KEY_CFBundleDisplayName = "{NAME} Files";',
            ),
            # The app target has no display name of its own (PRODUCT_NAME is the target, "Minis").
            (
                r'(INFOPLIST_FILE = "\$\(SRCROOT\)/Info\.plist";\n)(?!\t*INFOPLIST_KEY_CFBundleDisplayName)',
                f"\\g<1>\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = {NAME};\n",
            ),
            # The launch screen: upstream's "Open Minis — … is starting" storyboard is left in
            # place; the app shows NanoMuse/NanoMuseLaunch.storyboard (the mark, no words).
            (
                r'INFOPLIST_KEY_UILaunchStoryboardName = "Launch Screen";',
                "INFOPLIST_KEY_UILaunchStoryboardName = NanoMuseLaunch;",
            ),
        ],
    )


def ios_product_name() -> None:
    """完整生成保留代码及翻译键，只刷新本地化显示值。"""
    ios_info_brand()
    ios_catalogue_brand()


def xcstrings_dumps(data: object, like: str) -> str:
    """Xcode's own layout (2-space indent, ` : `, empty objects spread over three lines, trailing
    newline only if the file had one), keys in the order they were read, so the diff stays at the
    renamed entries."""
    out = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "))
    out = re.sub(
        r"^([ ]*)(.*)\{\}",
        lambda m: f"{m.group(1)}{m.group(2)}{{\n\n{m.group(1)}}}",
        out,
        flags=re.M,
    )
    return out + ("\n" if like.endswith("\n") else "")


def ios_links() -> None:
    """iOS只维护产品隐私链接；不生成仓库推广、旧反馈或检查更新入口。"""
    privacy_pattern = (
        r'URL\(string: "https://(?:openminis\.github\.io/privacy-policy\.html'
        r"|github\.com/(?:nano-muse/nanoMuse|OpenMinis/OpenMinis|sherlockerX/Nicholasx)"
        r'/blob/main/docs/privacy\.md)"\)!'
    )
    for relative in ("Views/ContentView.swift", "Views/Providers/AddProviderView.swift"):
        edit(IOS / relative, [(privacy_pattern, "NivoProduct.privacy")])


def ios_soul_defaults() -> None:
    edit(
        IOS / "Agent" / "Session" / "SoulStore.swift",
        [(r'var displayEmoji: String \{ "✨" \}', 'var displayEmoji: String { "🐾" }')],
    )


def ios_colours() -> None:
    """AccentColor: the iOS system blues -> the brand blue (light) and its dark-mode tint."""
    path = IOS / "Assets.xcassets" / "AccentColor.colorset" / "Contents.json"
    if not path.exists():
        return
    raw = path.read_text(encoding="utf-8")
    data = json.loads(raw)
    want = {
        None: ("0.004", "0.361", "0.984"),  # #015CFB
        "dark": ("0.345", "0.651", "1.000"),  # #58A6FF
    }
    touched = False
    for entry in data.get("colors", []):
        appearance = None
        for a in entry.get("appearances", []):
            if a.get("appearance") == "luminosity":
                appearance = a.get("value")
        r, g, b = want.get(appearance, want[None])
        comps = entry.setdefault("color", {}).setdefault("components", {})
        new = {"red": r, "green": g, "blue": b, "alpha": comps.get("alpha", "1.000")}
        if comps != new:
            comps.clear()
            comps.update(new)
            touched = True
    if touched:
        path.write_text(xcstrings_dumps(data, raw), encoding="utf-8")
        changed.append(str(path.relative_to(ROOT)))


def ios() -> None:
    if not IOS.is_dir():
        return
    ios_ids()
    ios_schemes()
    ios_project()
    ios_product_name()
    ios_links()
    ios_soul_defaults()
    ios_colours()
    ios_brand_only()


def ios_check() -> int:
    if not IOS.is_dir():
        return 0
    problems = 0
    leftovers = re.compile(
        r"com\.openminis\.(app|Minis)|openminis\.github\.io|MARKETING_VERSION = (?!"
        + re.escape(VERSION_NAME)
        + r";)"
    )
    for path in ios_files(".swift", ".plist", ".entitlements", ".pbxproj"):
        for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if leftovers.search(line):
                print(f"  ! {path.relative_to(ROOT)}:{i}: {line.strip()[:80]}")
                problems += 1
    for path in ios_files(".plist", ".strings"):
        if path.name != "PrivacyInfo.xcprivacy" and WORD.search(path.read_text(encoding="utf-8")):
            print(f"  ! Minis left in {path.relative_to(ROOT)}")
            problems += 1
    plist = (IOS / "Info.plist").read_text(encoding="utf-8")
    if re.search(r"<string>minis(-mcp)?</string>", plist):
        print("  ! Info.plist still registers upstream's URL scheme")
        problems += 1
    share = (IOS / "ShareExtension" / "ShareViewController.swift").read_text(encoding="utf-8")
    if "minis://share" in share:
        print("  ! the share extension still opens minis://share")
        problems += 1
    return problems


def check() -> int:
    problems = 0
    gradle_text = (APP / "build.gradle.kts").read_text(encoding="utf-8")
    for want in (
        f'applicationId = "{ANDROID_APP_ID}"',
        f"versionCode = {ANDROID_VERSION_CODE}",
        f'versionName = "{ANDROID_VERSION_NAME}"',
    ):
        if want not in gradle_text:
            print(f"  ! app/build.gradle.kts lacks {want}")
            problems += 1
    for path in sorted(RES.glob("values*/strings.xml")):
        if WORD.search(path.read_text(encoding="utf-8")):
            print(f"  ! Minis left in {path.relative_to(ROOT)}")
            problems += 1
    leftovers = re.compile(
        r"0x[0-9A-Fa-f]{2}(007AFF|0A84FF|528AD2|6A94CE)|#007AFF|#0A84FF|nanoMuseSkills"
    )
    for path in sorted(JAVA.rglob("*.kt")) + sorted(RES.rglob("*.xml")):
        for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if leftovers.search(line):
                print(f"  ! {path.relative_to(ROOT)}:{i}: {line.strip()[:80]}")
                problems += 1
    if 'android:scheme="minis"' in (MAIN / "AndroidManifest.xml").read_text(encoding="utf-8"):
        print("  ! AndroidManifest.xml still registers upstream's URL scheme")
        problems += 1
    return problems


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args in (["-h"], ["--help"]):
        print(__doc__.strip())
        return 0
    if args == ["--android-brand-only"]:
        android_brand_only()
        print(f"{len(set(changed))} Android brand files changed")
        return 0
    if args == ["--android-identity-only"]:
        android_identity_only()
        print(f"{len(set(changed))} Android identity files changed")
        return 0
    if args == ["--ios-brand-only"]:
        ios_brand_only()
        print(f"{len(set(changed))} iOS brand files changed")
        return 0
    if args == ["--ios-version-only"]:
        ios_versions_only()
        print(f"{len(set(changed))} iOS version files changed")
        return 0
    if args == ["--versions-only"]:
        android_versions_only()
        ios_versions_only()
        print(f"{len(set(changed))} version files changed")
        return 0
    if args not in ([], ["--check"]):
        print(f"usage: {sys.argv[0]} [--check]  (unknown: {' '.join(args)})", file=sys.stderr)
        return 2
    if not APP.is_dir():
        sys.exit(f"{APP} not found")
    if args == ["--check"]:
        problems = check() + ios_check()
        print("clean" if problems == 0 else f"{problems} leftovers")
        return 1 if problems else 0
    gradle()
    package_ids()
    product_name()
    soul_defaults()
    links()
    schemes()
    colours()
    notification_icons()
    notification_faces()
    reword()
    android_brand_only()
    ios()
    for path in sorted(set(changed)):
        print(f"  edited {path}")
    print(f"{len(set(changed))} files changed")
    problems = check() + ios_check()
    print("clean" if problems == 0 else f"{problems} leftovers")
    return 1 if problems else 0


def android_brand_only() -> None:
    """仅生成Android显示文案，不修改版本、签名、程序标识或历史迁移条件。"""
    for path in sorted(RES.glob("values*/*.xml")):
        text = path.read_text(encoding="utf-8")
        locale = path.parent.name.removeprefix("values-")
        # 只处理文字节点，保留资源键、注释和链接里的旧品牌标识。
        new = re.sub(
            r"<!--.*?-->|(?<=>)[^<>]+(?=<)",
            lambda m, locale=locale: (
                m[0] if m[0].startswith("<!--") else mobile_brand_text(m[0], locale)
            ),
            text,
            flags=re.S,
        )
        new = android_local_copy(new, locale)
        if path.name == "nm_strings.xml":
            new = android_required_copy(new, locale)
        # 分享卡介绍当前产品，历史上游推广链接不再作为产品署名。
        new = re.sub(
            r'(<string name="nm_avatar_share_tagline">)(.*?)(</string>)',
            lambda m: m[1] + m[2].replace(" · github.com/nano-muse/nanoMuse", "") + m[3],
            new,
        )
        if new != text:
            ET.fromstring(new.encode("utf-8"))
            write_brand_file(path, new)


MOBILE_BRAND = re.compile(
    r"(?<![A-Za-z0-9_./@-])(?:Nivo Bot|Nivo|Nicholasx|nanoMuse|Minis|Nelan|念步)(?![A-Za-z0-9_]|\.[A-Za-z0-9_])"
)
MOBILE_BRAND_OR_URL = re.compile(
    r"`[^`]*`|(?:[a-zA-Z][a-zA-Z0-9+.-]*://|www\.)[^\s<>\"']+|"
    r"(?<![A-Za-z0-9_./@-])(?:Nivo Bot|Nivo|Nicholasx|nanoMuse|Minis|Nelan|念步)[ -](?:Cloud|Desktop)(?![A-Za-z])|"
    r"(?<![A-Za-z0-9_./@-])(?:nanoMuses|AI-nanoMuse Agent|Nelan-nanoMuse Agent)(?![A-Za-z0-9_])|"
    + MOBILE_BRAND.pattern
)
IOS_BRAND_LOCALES = ("en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "ru")
MOBILE_RESOURCE_COPY = {
    "en": {
        "no_files": "No Nelan files",
        "system_files": "Manage the assistant’s identity, preferences and memory here. Files stay on this phone and can be edited on this page.",
        "avatar": "Avatar images stay on this phone. Creating an avatar uses your configured image provider.",
        "settings": "Providers, model groups, skills, appearance and advanced settings.",
        "saved": "Saved on this device.",
        "sync": "Account sync is unavailable in this version.",
    },
    "zh": {
        "no_files": "暂无念步文件",
        "system_files": "在这里管理助手的身份、偏好和记忆。文件保存在这台手机上，可以在此页面编辑。",
        "avatar": "形象图片保存在这台手机上。创建形象会使用你配置的图像服务商。",
        "settings": "服务商、模型组、技能、外观和高级设置。",
        "saved": "已保存在这台设备上。",
        "sync": "当前版本不支持账号同步。",
    },
    "zh-Hant": {
        "no_files": "暫無念步檔案",
        "system_files": "在這裡管理助手的身分、偏好和記憶。檔案儲存在這台手機上，可以在此頁面編輯。",
        "avatar": "形象圖片儲存在這台手機上。建立形象會使用你設定的圖像服務商。",
        "settings": "服務商、模型群組、技能、外觀和進階設定。",
        "saved": "已儲存在這台裝置上。",
        "sync": "目前版本不支援帳號同步。",
    },
    "de": {
        "no_files": "Keine Nelan-Dateien",
        "system_files": "Verwalte hier Identität, Vorlieben und Erinnerungen des Assistenten. Die Dateien bleiben auf diesem Telefon und können hier bearbeitet werden.",
        "avatar": "Avatarbilder bleiben auf diesem Telefon. Für neue Avatare wird dein eingerichteter Bildanbieter verwendet.",
        "settings": "Anbieter, Modellgruppen, Fähigkeiten, Darstellung und erweiterte Einstellungen.",
        "saved": "Auf diesem Gerät gespeichert.",
        "sync": "Die Kontosynchronisierung ist in dieser Version nicht verfügbar.",
    },
    "es": {
        "no_files": "No hay archivos de Nelan",
        "system_files": "Gestiona aquí la identidad, las preferencias y la memoria del asistente. Los archivos permanecen en este teléfono y se pueden editar en esta página.",
        "avatar": "Las imágenes del avatar permanecen en este teléfono. Crear un avatar utiliza el proveedor de imágenes configurado.",
        "settings": "Proveedores, grupos de modelos, habilidades, apariencia y ajustes avanzados.",
        "saved": "Guardado en este dispositivo.",
        "sync": "La sincronización de la cuenta no está disponible en esta versión.",
    },
    "fil": {
        "no_files": "Walang mga file ng Nelan",
        "system_files": "Pamahalaan dito ang pagkakakilanlan, mga kagustuhan at alaala ng assistant. Nananatili ang mga file sa teleponong ito at puwedeng i-edit sa pahinang ito.",
        "avatar": "Nananatili sa teleponong ito ang mga larawan ng avatar. Ginagamit sa paggawa ng avatar ang itinakda mong provider ng larawan.",
        "settings": "Mga provider, grupo ng modelo, kasanayan, hitsura at advanced na setting.",
        "saved": "Na-save sa device na ito.",
        "sync": "Hindi available ang pag-sync ng account sa bersyong ito.",
    },
    "fr": {
        "no_files": "Aucun fichier Nelan",
        "system_files": "Gérez ici l'identité, les préférences et la mémoire de l'assistant. Les fichiers restent sur ce téléphone et peuvent être modifiés sur cette page.",
        "avatar": "Les images de l'avatar restent sur ce téléphone. La création utilise votre fournisseur d'images configuré.",
        "settings": "Fournisseurs, groupes de modèles, compétences, apparence et paramètres avancés.",
        "saved": "Enregistré sur cet appareil.",
        "sync": "La synchronisation du compte est indisponible dans cette version.",
    },
    "in": {
        "no_files": "Tidak ada file Nelan",
        "system_files": "Kelola identitas, preferensi, dan ingatan asisten di sini. File tetap berada di ponsel ini dan dapat diedit di halaman ini.",
        "avatar": "Gambar avatar tetap berada di ponsel ini. Pembuatan avatar menggunakan penyedia gambar yang Anda konfigurasi.",
        "settings": "Penyedia, grup model, keterampilan, tampilan, dan pengaturan lanjutan.",
        "saved": "Disimpan di perangkat ini.",
        "sync": "Sinkronisasi akun tidak tersedia dalam versi ini.",
    },
    "ja": {
        "no_files": "Nelanのファイルはありません",
        "system_files": "助手の情報、好み、記憶をここで管理できます。ファイルはこの端末に保存され、このページで編集できます。",
        "avatar": "アバター画像はこの端末に保存されます。作成には設定した画像プロバイダーを使用します。",
        "settings": "プロバイダー、モデルグループ、スキル、外観、詳細設定。",
        "saved": "この端末に保存しました。",
        "sync": "このバージョンではアカウントの同期を利用できません。",
    },
    "ko": {
        "no_files": "Nelan 파일이 없습니다",
        "system_files": "여기에서 도우미의 정체성, 선호도, 기억을 관리합니다. 파일은 이 휴대전화에 저장되며 이 페이지에서 편집할 수 있습니다.",
        "avatar": "아바타 이미지는 이 휴대전화에 저장됩니다. 아바타를 만들 때 설정한 이미지 제공업체를 사용합니다.",
        "settings": "제공업체, 모델 그룹, 스킬, 외관 및 고급 설정.",
        "saved": "이 기기에 저장했습니다.",
        "sync": "이 버전에서는 계정 동기화를 사용할 수 없습니다.",
    },
    "ms": {
        "no_files": "Tiada fail Nelan",
        "system_files": "Urus identiti, pilihan dan ingatan pembantu di sini. Fail kekal pada telefon ini dan boleh disunting pada halaman ini.",
        "avatar": "Imej avatar kekal pada telefon ini. Penciptaan avatar menggunakan penyedia imej yang anda tetapkan.",
        "settings": "Penyedia, kumpulan model, kemahiran, penampilan dan tetapan lanjutan.",
        "saved": "Disimpan pada peranti ini.",
        "sync": "Penyegerakan akaun tidak tersedia dalam versi ini.",
    },
    "pl": {
        "no_files": "Brak plików Nelan",
        "system_files": "Zarządzaj tutaj tożsamością, preferencjami i pamięcią asystenta. Pliki pozostają na tym telefonie i można je edytować na tej stronie.",
        "avatar": "Obrazy awatara pozostają na tym telefonie. Tworzenie awatara korzysta ze skonfigurowanego dostawcy obrazów.",
        "settings": "Dostawcy, grupy modeli, umiejętności, wygląd i ustawienia zaawansowane.",
        "saved": "Zapisano na tym urządzeniu.",
        "sync": "Synchronizacja konta jest niedostępna w tej wersji.",
    },
    "pt-rBR": {
        "no_files": "Nenhum arquivo do Nelan",
        "system_files": "Gerencie aqui a identidade, as preferências e a memória do assistente. Os arquivos ficam neste celular e podem ser editados nesta página.",
        "avatar": "As imagens do avatar ficam neste celular. A criação usa o provedor de imagens configurado.",
        "settings": "Provedores, grupos de modelos, habilidades, aparência e configurações avançadas.",
        "saved": "Salvo neste dispositivo.",
        "sync": "A sincronização de conta não está disponível nesta versão.",
    },
    "ro": {
        "no_files": "Nu există fișiere Nelan",
        "system_files": "Gestionează aici identitatea, preferințele și memoria asistentului. Fișierele rămân pe acest telefon și pot fi editate pe această pagină.",
        "avatar": "Imaginile avatarului rămân pe acest telefon. Crearea unui avatar folosește furnizorul de imagini configurat.",
        "settings": "Furnizori, grupuri de modele, abilități, aspect și setări avansate.",
        "saved": "Salvat pe acest dispozitiv.",
        "sync": "Sincronizarea contului nu este disponibilă în această versiune.",
    },
    "ru": {
        "no_files": "Нет файлов Nelan",
        "system_files": "Здесь можно управлять личностью, предпочтениями и памятью помощника. Файлы остаются на этом телефоне и редактируются на этой странице.",
        "avatar": "Изображения аватара остаются на этом телефоне. Для создания используется настроенный провайдер изображений.",
        "settings": "Провайдеры, группы моделей, навыки, оформление и расширенные настройки.",
        "saved": "Сохранено на этом устройстве.",
        "sync": "Синхронизация аккаунта недоступна в этой версии.",
    },
    "th": {
        "no_files": "ไม่มีไฟล์ Nelan",
        "system_files": "จัดการตัวตน ความชอบ และความทรงจำของผู้ช่วยได้ที่นี่ ไฟล์จะอยู่ในโทรศัพท์เครื่องนี้และแก้ไขได้ในหน้านี้",
        "avatar": "ภาพอวาตาร์จะอยู่ในโทรศัพท์เครื่องนี้ การสร้างอวาตาร์ใช้ผู้ให้บริการภาพที่คุณตั้งค่าไว้",
        "settings": "ผู้ให้บริการ กลุ่มโมเดล ทักษะ รูปลักษณ์ และการตั้งค่าขั้นสูง",
        "saved": "บันทึกไว้ในอุปกรณ์นี้แล้ว",
        "sync": "เวอร์ชันนี้ไม่รองรับการซิงค์บัญชี",
    },
    "tr": {
        "no_files": "Nelan dosyası yok",
        "system_files": "Asistanın kimliğini, tercihlerini ve belleğini buradan yönetin. Dosyalar bu telefonda kalır ve bu sayfada düzenlenebilir.",
        "avatar": "Avatar görselleri bu telefonda kalır. Avatar oluşturmak için yapılandırdığınız görsel sağlayıcısı kullanılır.",
        "settings": "Sağlayıcılar, model grupları, beceriler, görünüm ve gelişmiş ayarlar.",
        "saved": "Bu cihaza kaydedildi.",
        "sync": "Bu sürümde hesap eşitlemesi kullanılamıyor.",
    },
}
ANDROID_RESOURCE_COPY = {
    "storage_no_minis_files": "no_files",
    "nm_sysfiles_footer": "system_files",
    "nm_avatar_footer": "avatar",
    "perm_allow_minis_config": "config",
    "nm_storage_location": "storage_location",
    "nm_about_upstream_credit_title": "credit_title",
    "nm_about_upstream_credit_body": "credit_body",
    "nm_config_permission_title": "permission_title",
    "nm_config_permission_detail": "permission_detail",
}
IOS_RESOURCE_COPY = {
    "No minis files": "session_files",
    "Providers, model groups, skills, appearance and the rest of the OpenMinis settings.": "settings",
    "Pictures are drawn through nanoMuse Cloud and kept on this phone; the face is shared with your other devices through your account. Each new face is eight pictures: four to choose from and four moods.": "avatar",
    "Pictures are drawn with your Bailian key and kept on this phone; the face is shared with your other devices through your account. Each new face is eight pictures: four to choose from and four moods.": "avatar",
    "Saved on this device.": "saved",
    "Account sync is unavailable in this version.": "sync",
    "Allow minis-config": "config",
    "3D toy (Muse)": "toy",
    "Muse home": "home",
    "Muse home is the chat with Feed, Ideas, Goals and Library beside it, on iPhone and iPad. Off, the app opens on the OpenMinis layout; the drawer still has it.": "task_home",
    "Muse home is the chat with the feed, ideas, goals and library as tabs. Off, the app opens on the classic OpenMinis chat list. The second switch puts the face and the name in the title of side chats; off, they show the model.": "task_home_titles",
    "Muse shows only the name. Turn this on to see the model group and provider · model under it; tap them to switch. Off, the model is under ••• → Model and in Settings.": "header",
    "Portraits of your Muse and the pictures you ask for.": "portraits",
    "Short clips of your Muse.": "clips",
    "Sign in to nanoMuse Cloud or add a provider": "provider",
    "The clip stays on this phone. It is not uploaded to nanoMuse Cloud or synced to your other devices.": "clip_local",
    "None of your providers can draw. Sign in to nanoMuse Cloud, or add an Alibaba Cloud Bailian provider with an API key; the avatar is drawn with one of the two.": "image_provider",
    "Sign in to nanoMuse Cloud, or add an Alibaba Cloud Bailian key under Providers; the pictures are drawn with one of the two.": "image_provider",
    "No provider that can make video yet. nanoMuse speaks Alibaba Cloud Model Studio's video API, which nanoMuse Cloud relays too. Sign in to nanoMuse Cloud, or add a Model Studio key (it can be the same one as the image model uses), and the avatar starts moving; until then it stays as still pictures.": "video_provider",
    "Avatar changes: the four candidates and the poses. Alibaba Cloud Model Studio: qwen-image-3.0 (draws and poses; ¥0.18 a picture) or the Pro tier, drawn with your own key. nanoMuse Cloud draws from the account's allowance.": "image_usage",
    "Only the requests to the providers you added with your own key, and to the ChatGPT plan, go through it. nanoMuse Cloud, your computers and the local network never do. Kept on this phone only.": "proxy",
    "nanoMuse Computer": "workspace",
    "nanoMuse is using Shell": "command",
    "nanoMuse is reading File": "read_file",
    "nanoMuse is using Editor": "write_file",
    "nanoMuse is editing File": "edit_file",
    "nanoMuse is using Browser": "browser",
    "nanoMuse is reading Image": "read_image",
    "nanoMuse is using Memory": "memory",
    "Models nanoMuse Can Call at Runtime": "task_models",
    "During a nanoMuse task, the agent calls these models for sub-tasks such as generating an image or summarizing text — work its own model can't do. Also callable from the terminal via minis-model-use. Only these are visible to the agent.": "task_models_help",
}
IOS_TASK_COPY = {
    "en": {
        "proxy": "Requests to your configured providers and ChatGPT plan use this proxy. Local network requests bypass it. These settings stay on this phone.",
        "task_home": "The home layout puts chat and personal tools in tabs. Turn it off to open the classic chat list.",
        "task_home_titles": "The home layout puts chat and personal tools in tabs. Turn it off to open the classic chat list. The second switch shows the assistant's face and name in side chats; otherwise the model is shown.",
        "workspace": "Tool workspace",
        "command": "Running a command",
        "read_file": "Reading a file",
        "write_file": "Writing a file",
        "edit_file": "Editing a file",
        "browser": "Using the browser",
        "read_image": "Reading an image",
        "memory": "Using memory",
        "task_models": "Models available for tasks",
        "task_models_help": "The assistant can call these models for tasks such as generating an image or summarizing text. They can also be called from the terminal with minis-model-use. Only the listed models are available to the assistant.",
        "session_files": "No session files",
    },
    "zh": {
        "proxy": "发往你配置的服务商和ChatGPT套餐的请求使用此代理，局域网请求不经过代理。设置仅保存在这台手机上。",
        "task_home": "主页布局用标签页呈现对话和个人工具。关闭后打开经典对话列表。",
        "task_home_titles": "主页布局用标签页呈现对话和个人工具。关闭后打开经典对话列表。第二个开关在旁聊标题中显示助手形象和名字；关闭时显示模型。",
        "workspace": "工具工作区",
        "command": "运行命令",
        "read_file": "读取文件",
        "write_file": "写入文件",
        "edit_file": "编辑文件",
        "browser": "使用浏览器",
        "read_image": "读取图片",
        "memory": "使用记忆",
        "task_models": "任务可调用的模型",
        "task_models_help": "助手可调用这些模型完成生图、总结等任务，也可通过终端命令minis-model-use调用。助手只能使用此处列出的模型。",
        "session_files": "暂无会话文件",
    },
    "zh-Hant": {
        "proxy": "發往你設定的服務商和ChatGPT方案的請求使用此代理，區域網路請求不經過代理。設定僅儲存在這台手機上。",
        "task_home": "主頁配置以分頁呈現對話和個人工具。關閉後開啟經典對話列表。",
        "task_home_titles": "主頁配置以分頁呈現對話和個人工具。關閉後開啟經典對話列表。第二個開關在旁聊標題中顯示助手形象和名字；關閉時顯示模型。",
        "workspace": "工具工作區",
        "command": "執行命令",
        "read_file": "讀取檔案",
        "write_file": "寫入檔案",
        "edit_file": "編輯檔案",
        "browser": "使用瀏覽器",
        "read_image": "讀取圖片",
        "memory": "使用記憶",
        "task_models": "任務可呼叫的模型",
        "task_models_help": "助手可呼叫這些模型完成圖片產生、摘要等任務，也可透過終端命令minis-model-use呼叫。助手只能使用此處列出的模型。",
        "session_files": "暫無對話檔案",
    },
    "de": {
        "proxy": "Anfragen an deine eingerichteten Anbieter und dein ChatGPT-Abo nutzen diesen Proxy. Anfragen im lokalen Netzwerk umgehen ihn. Diese Einstellungen bleiben auf diesem Telefon.",
        "task_home": "Die Startansicht zeigt Chat und persönliche Werkzeuge in Tabs. Schalte sie aus, um die klassische Chatliste zu öffnen.",
        "task_home_titles": "Die Startansicht zeigt Chat und persönliche Werkzeuge in Tabs. Schalte sie aus, um die klassische Chatliste zu öffnen. Der zweite Schalter zeigt Bild und Namen des Assistenten in Nebenchats; sonst wird das Modell angezeigt.",
        "workspace": "Arbeitsbereich für Werkzeuge",
        "command": "Befehl wird ausgeführt",
        "read_file": "Datei wird gelesen",
        "write_file": "Datei wird geschrieben",
        "edit_file": "Datei wird bearbeitet",
        "browser": "Browser wird verwendet",
        "read_image": "Bild wird gelesen",
        "memory": "Erinnerungen werden verwendet",
        "task_models": "Modelle für Aufgaben",
        "task_models_help": "Der Assistent kann diese Modelle für Aufgaben wie Bilderzeugung oder Textzusammenfassungen aufrufen. Sie lassen sich auch im Terminal mit minis-model-use aufrufen. Nur die aufgeführten Modelle stehen dem Assistenten zur Verfügung.",
        "session_files": "Keine Sitzungsdateien",
    },
    "es": {
        "proxy": "Las solicitudes a tus proveedores configurados y a tu plan de ChatGPT usan este proxy. Las solicitudes de la red local lo omiten. Estos ajustes permanecen en este teléfono.",
        "task_home": "El inicio muestra el chat y las herramientas personales en pestañas. Desactívalo para abrir la lista clásica de chats.",
        "task_home_titles": "El inicio muestra el chat y las herramientas personales en pestañas. Desactívalo para abrir la lista clásica de chats. El segundo interruptor muestra la imagen y el nombre del asistente en los chats secundarios; de lo contrario, se muestra el modelo.",
        "workspace": "Espacio de trabajo de herramientas",
        "command": "Ejecutando un comando",
        "read_file": "Leyendo un archivo",
        "write_file": "Escribiendo un archivo",
        "edit_file": "Editando un archivo",
        "browser": "Usando el navegador",
        "read_image": "Leyendo una imagen",
        "memory": "Usando la memoria",
        "task_models": "Modelos disponibles para tareas",
        "task_models_help": "El asistente puede llamar a estos modelos para tareas como generar imágenes o resumir textos. También se pueden usar desde el terminal con minis-model-use. Solo los modelos de esta lista están disponibles para el asistente.",
        "session_files": "No hay archivos de sesión",
    },
    "fr": {
        "proxy": "Les requêtes vers vos fournisseurs configurés et votre abonnement ChatGPT utilisent ce proxy. Celles du réseau local le contournent. Ces paramètres restent sur ce téléphone.",
        "task_home": "L'accueil affiche la discussion et les outils personnels dans des onglets. Désactivez-le pour ouvrir la liste classique des discussions.",
        "task_home_titles": "L'accueil affiche la discussion et les outils personnels dans des onglets. Désactivez-le pour ouvrir la liste classique des discussions. Le second interrupteur affiche l'image et le nom de l'assistant dans les discussions secondaires ; sinon, le modèle est affiché.",
        "workspace": "Espace de travail des outils",
        "command": "Exécution d'une commande",
        "read_file": "Lecture d'un fichier",
        "write_file": "Écriture d'un fichier",
        "edit_file": "Modification d'un fichier",
        "browser": "Utilisation du navigateur",
        "read_image": "Lecture d'une image",
        "memory": "Utilisation de la mémoire",
        "task_models": "Modèles disponibles pour les tâches",
        "task_models_help": "L'assistant peut appeler ces modèles pour générer des images ou résumer du texte. Ils sont aussi accessibles depuis le terminal avec minis-model-use. Seuls les modèles de cette liste sont disponibles pour l'assistant.",
        "session_files": "Aucun fichier de session",
    },
    "ja": {
        "proxy": "設定したプロバイダーとChatGPTプランへのリクエストはこのプロキシを使用します。ローカルネットワークへのリクエストは経由しません。設定はこの端末だけに保存されます。",
        "task_home": "ホームはチャットと個人用ツールをタブで表示します。オフにすると従来のチャット一覧が開きます。",
        "task_home_titles": "ホームはチャットと個人用ツールをタブで表示します。オフにすると従来のチャット一覧が開きます。2番目のスイッチでサブチャットに助手の画像と名前を表示し、オフの場合はモデルを表示します。",
        "workspace": "ツールの作業領域",
        "command": "コマンドを実行中",
        "read_file": "ファイルを読み取り中",
        "write_file": "ファイルを書き込み中",
        "edit_file": "ファイルを編集中",
        "browser": "ブラウザーを使用中",
        "read_image": "画像を読み取り中",
        "memory": "記憶を使用中",
        "task_models": "タスクに使用できるモデル",
        "task_models_help": "助手は画像生成や文章の要約などにこれらのモデルを使用できます。ターミナルからminis-model-useで呼び出すこともできます。助手が使えるのはここに表示されたモデルだけです。",
        "session_files": "セッションのファイルはありません",
    },
    "ko": {
        "proxy": "설정한 제공업체와 ChatGPT 요금제로 보내는 요청은 이 프록시를 사용합니다. 로컬 네트워크 요청은 프록시를 거치지 않습니다. 설정은 이 휴대전화에만 저장됩니다.",
        "task_home": "홈은 채팅과 개인 도구를 탭으로 표시합니다. 끄면 기존 채팅 목록이 열립니다.",
        "task_home_titles": "홈은 채팅과 개인 도구를 탭으로 표시합니다. 끄면 기존 채팅 목록이 열립니다. 두 번째 스위치를 켜면 보조 채팅에 도우미의 이미지와 이름이 표시되고, 끄면 모델이 표시됩니다.",
        "workspace": "도구 작업 공간",
        "command": "명령 실행 중",
        "read_file": "파일 읽는 중",
        "write_file": "파일 쓰는 중",
        "edit_file": "파일 편집 중",
        "browser": "브라우저 사용 중",
        "read_image": "이미지 읽는 중",
        "memory": "기억 사용 중",
        "task_models": "작업에 사용할 수 있는 모델",
        "task_models_help": "도우미는 이미지 생성이나 텍스트 요약 등의 작업에 이 모델들을 호출할 수 있습니다. 터미널에서 minis-model-use로 호출할 수도 있습니다. 도우미는 여기에 나열된 모델만 사용할 수 있습니다.",
        "session_files": "세션 파일이 없습니다",
    },
    "ru": {
        "proxy": "Запросы к настроенным провайдерам и подписке ChatGPT используют этот прокси. Запросы к локальной сети идут напрямую. Настройки хранятся только на этом телефоне.",
        "task_home": "Главная показывает чат и личные инструменты во вкладках. Отключите её, чтобы открыть классический список чатов.",
        "task_home_titles": "Главная показывает чат и личные инструменты во вкладках. Отключите её, чтобы открыть классический список чатов. Второй переключатель показывает изображение и имя помощника в дополнительных чатах; иначе отображается модель.",
        "workspace": "Рабочая область инструментов",
        "command": "Выполнение команды",
        "read_file": "Чтение файла",
        "write_file": "Запись файла",
        "edit_file": "Редактирование файла",
        "browser": "Использование браузера",
        "read_image": "Чтение изображения",
        "memory": "Использование памяти",
        "task_models": "Модели для выполнения задач",
        "task_models_help": "Помощник может вызывать эти модели для создания изображений, обобщения текста и других задач. Их также можно вызвать из терминала командой minis-model-use. Помощнику доступны только модели из этого списка.",
        "session_files": "Нет файлов сеанса",
    },
}
IOS_MEDIA_COPY = {
    "en": {
        "provider": "Add a model provider",
        "clip_local": "The clip stays on this phone and is not synced to other devices.",
        "image_provider": "Add a provider with an image model and your own API key in Settings to generate pictures.",
        "video_provider": "Add a provider with a supported video model and your own API key. Until then, the avatar uses still pictures.",
        "image_usage": "Avatar pictures are generated with the image model and API key configured on this device. Your provider bills the requests.",
    },
    "zh": {
        "provider": "添加模型服务商",
        "clip_local": "视频保存在这台手机上，不会同步到其他设备。",
        "image_provider": "请在设置中添加支持图像模型的服务商，并填写自己的API密钥后生成图片。",
        "video_provider": "请添加支持视频模型的服务商，并填写自己的API密钥。配置前形象保持静态图片。",
        "image_usage": "形象图片使用这台设备上配置的图像模型和API密钥生成，由你选择的服务商计费。",
    },
    "zh-Hant": {
        "provider": "加入模型服務商",
        "clip_local": "影片儲存在這台手機上，不會同步到其他裝置。",
        "image_provider": "請在設定中加入支援圖像模型的服務商，並填入自己的API金鑰後產生圖片。",
        "video_provider": "請加入支援影片模型的服務商，並填入自己的API金鑰。設定前形象維持靜態圖片。",
        "image_usage": "形象圖片使用這台裝置上設定的圖像模型和API金鑰產生，由你選擇的服務商計費。",
    },
    "de": {
        "provider": "Modellanbieter hinzufügen",
        "clip_local": "Das Video bleibt auf diesem Telefon und wird nicht mit anderen Geräten synchronisiert.",
        "image_provider": "Füge in den Einstellungen einen Anbieter mit Bildmodell und deinem eigenen API-Schlüssel hinzu, um Bilder zu erzeugen.",
        "video_provider": "Füge einen Anbieter mit unterstütztem Videomodell und deinem eigenen API-Schlüssel hinzu. Bis dahin bleibt der Avatar ein Standbild.",
        "image_usage": "Avatarbilder werden mit dem Bildmodell und API-Schlüssel auf diesem Gerät erzeugt. Dein Anbieter rechnet die Anfragen ab.",
    },
    "es": {
        "provider": "Añadir un proveedor de modelos",
        "clip_local": "El vídeo permanece en este teléfono y no se sincroniza con otros dispositivos.",
        "image_provider": "Añade en Ajustes un proveedor con un modelo de imágenes y tu propia clave de API para generar imágenes.",
        "video_provider": "Añade un proveedor con un modelo de vídeo compatible y tu propia clave de API. Hasta entonces, el avatar usa imágenes estáticas.",
        "image_usage": "Las imágenes del avatar se generan con el modelo y la clave de API configurados en este dispositivo. Tu proveedor factura las solicitudes.",
    },
    "fr": {
        "provider": "Ajouter un fournisseur de modèles",
        "clip_local": "La vidéo reste sur ce téléphone et ne se synchronise pas avec les autres appareils.",
        "image_provider": "Ajoutez dans les paramètres un fournisseur avec un modèle d'image et votre clé API pour générer des images.",
        "video_provider": "Ajoutez un fournisseur avec un modèle vidéo compatible et votre clé API. En attendant, l'avatar utilise des images fixes.",
        "image_usage": "Les images de l'avatar utilisent le modèle et la clé API configurés sur cet appareil. Votre fournisseur facture les requêtes.",
    },
    "ja": {
        "provider": "モデルプロバイダーを追加",
        "clip_local": "動画はこの端末に保存され、ほかの端末には同期されません。",
        "image_provider": "画像を生成するには、設定で画像モデルに対応したプロバイダーと自分のAPIキーを追加してください。",
        "video_provider": "対応する動画モデルのプロバイダーと自分のAPIキーを追加してください。設定するまでは静止画を使用します。",
        "image_usage": "アバター画像はこの端末で設定した画像モデルとAPIキーで生成されます。料金は選択したプロバイダーが請求します。",
    },
    "ko": {
        "provider": "모델 제공업체 추가",
        "clip_local": "동영상은 이 휴대전화에 저장되며 다른 기기와 동기화되지 않습니다.",
        "image_provider": "이미지를 생성하려면 설정에서 이미지 모델을 지원하는 제공업체와 자신의 API 키를 추가하세요.",
        "video_provider": "지원되는 동영상 모델의 제공업체와 자신의 API 키를 추가하세요. 설정하기 전에는 정지 이미지를 사용합니다.",
        "image_usage": "아바타 이미지는 이 기기에 설정한 이미지 모델과 API 키로 생성됩니다. 선택한 제공업체가 요청에 대해 요금을 청구합니다.",
    },
    "ru": {
        "provider": "Добавить провайдера моделей",
        "clip_local": "Видео остаётся на этом телефоне и не синхронизируется с другими устройствами.",
        "image_provider": "Добавьте в настройках провайдера с моделью изображений и своим API-ключом для создания картинок.",
        "video_provider": "Добавьте провайдера с поддерживаемой видеомоделью и своим API-ключом. До этого аватар будет использовать статичные изображения.",
        "image_usage": "Изображения аватара создаются с моделью и API-ключом, настроенными на этом устройстве. Запросы оплачиваются вашему провайдеру.",
    },
}
IOS_SURFACE_COPY = {
    "en": {
        "toy": "3D toy",
        "home": "Nelan home",
        "home_layout": "The home view combines chat, feed, ideas, goals and library. Turn it off to open the classic chat list. The title setting switches side chats between the assistant's name and the model.",
        "header": "The header shows the name by default. Turn this on to show the model group and provider below it; tap to switch. Otherwise, open More → Model or Settings.",
        "portraits": "Portraits of Shiqi and the pictures you request.",
        "clips": "Short clips of Shiqi.",
    },
    "zh": {
        "toy": "3D玩偶",
        "home": "念步主页",
        "home_layout": "主页将对话、动态、灵感、目标和资料库放在一起。关闭后显示经典对话列表。标题设置可让旁聊显示助手名字或模型。",
        "header": "标题默认只显示名字。开启后会在下方显示模型组和服务商，轻点即可切换；关闭时可通过“更多→模型”或设置切换。",
        "portraits": "十七的形象和你请求生成的图片。",
        "clips": "十七的短片。",
    },
    "zh-Hant": {
        "toy": "3D玩偶",
        "home": "念步主頁",
        "home_layout": "主頁結合對話、動態、靈感、目標和資料庫。關閉後顯示經典對話列表。標題設定可讓旁聊顯示助手名字或模型。",
        "header": "標題預設只顯示名字。開啟後會在下方顯示模型群組和服務商，輕點即可切換；關閉時可透過「更多→模型」或設定切換。",
        "portraits": "十七的形象和你要求產生的圖片。",
        "clips": "十七的短片。",
    },
    "de": {
        "toy": "3D-Spielzeug",
        "home": "Nelan-Startseite",
        "home_layout": "Die Startseite vereint Chat, Feed, Ideen, Ziele und Bibliothek. Ausgeschaltet öffnet sich die klassische Chatliste. Die Titeleinstellung zeigt in Nebenchats den Namen des Assistenten oder das Modell.",
        "header": "Standardmäßig steht im Titel nur der Name. Aktiviere diese Option für Modellgruppe und Anbieter darunter; tippe zum Wechseln. Andernfalls findest du das Modell unter Mehr → Modell oder in den Einstellungen.",
        "portraits": "Porträts von Shiqi und deine angeforderten Bilder.",
        "clips": "Kurze Videos von Shiqi.",
    },
    "es": {
        "toy": "Juguete 3D",
        "home": "Inicio de Nelan",
        "home_layout": "El inicio reúne chat, actividad, ideas, objetivos y biblioteca. Al desactivarlo se abre la lista clásica de chats. El ajuste del título muestra el nombre del asistente o el modelo en los chats secundarios.",
        "header": "El encabezado muestra solo el nombre de forma predeterminada. Activa esta opción para ver el grupo de modelos y el proveedor; toca para cambiarlos. Si está desactivada, usa Más → Modelo o Ajustes.",
        "portraits": "Retratos de Shiqi y las imágenes que solicites.",
        "clips": "Vídeos cortos de Shiqi.",
    },
    "fr": {
        "toy": "Jouet 3D",
        "home": "Accueil Nelan",
        "home_layout": "L'accueil réunit discussion, fil, idées, objectifs et bibliothèque. Désactivé, il ouvre la liste classique des discussions. Le réglage du titre affiche le nom de l'assistant ou le modèle dans les discussions secondaires.",
        "header": "Par défaut, le titre affiche seulement le nom. Activez cette option pour afficher le groupe de modèles et le fournisseur ; touchez-les pour changer. Sinon, utilisez Plus → Modèle ou les paramètres.",
        "portraits": "Portraits de Shiqi et images que vous demandez.",
        "clips": "Courtes vidéos de Shiqi.",
    },
    "ja": {
        "toy": "3Dトイ",
        "home": "Nelanホーム",
        "home_layout": "ホームにはチャット、フィード、アイデア、目標、ライブラリがまとまっています。オフにすると従来のチャット一覧が開きます。タイトル設定でサブチャットに助手名またはモデルを表示できます。",
        "header": "通常は名前だけを表示します。オンにすると下にモデルグループとプロバイダーが表示され、タップで切り替えられます。オフの場合は「その他→モデル」または設定から変更できます。",
        "portraits": "Shiqiのポートレートとリクエストした画像。",
        "clips": "Shiqiの短い動画。",
    },
    "ko": {
        "toy": "3D 장난감",
        "home": "Nelan 홈",
        "home_layout": "홈에는 채팅, 피드, 아이디어, 목표, 라이브러리가 모여 있습니다. 끄면 기존 채팅 목록이 열립니다. 제목 설정으로 보조 채팅에 도우미 이름이나 모델을 표시할 수 있습니다.",
        "header": "기본적으로 이름만 표시합니다. 켜면 아래에 모델 그룹과 제공업체가 표시되며 눌러서 바꿀 수 있습니다. 끈 상태에서는 더보기→모델 또는 설정에서 바꿀 수 있습니다.",
        "portraits": "Shiqi의 초상화와 요청한 이미지입니다.",
        "clips": "Shiqi의 짧은 동영상입니다.",
    },
    "ru": {
        "toy": "3D-игрушка",
        "home": "Главная Nelan",
        "home_layout": "Главная объединяет чат, ленту, идеи, цели и библиотеку. При отключении открывается классический список чатов. Настройка заголовка показывает имя помощника или модель в дополнительных чатах.",
        "header": "По умолчанию отображается только имя. Включите эту настройку, чтобы видеть группу моделей и провайдера; нажмите для переключения. Иначе выберите Ещё → Модель или откройте настройки.",
        "portraits": "Портреты Shiqi и изображения по вашему запросу.",
        "clips": "Короткие видео с Shiqi.",
    },
}
MOBILE_CONFIG_PERMISSION = {
    "en": "Allow configuration changes",
    "zh": "允许修改配置",
    "zh-Hant": "允許修改設定",
    "de": "Konfigurationsänderungen erlauben",
    "es": "Permitir cambios de configuración",
    "fil": "Payagan ang pagbabago ng configuration",
    "fr": "Autoriser les modifications de configuration",
    "in": "Izinkan perubahan konfigurasi",
    "ja": "設定の変更を許可",
    "ko": "설정 변경 허용",
    "ms": "Benarkan perubahan konfigurasi",
    "pl": "Zezwól na zmiany konfiguracji",
    "pt-rBR": "Permitir alterações de configuração",
    "ro": "Permite modificarea configurației",
    "ru": "Разрешить изменение настроек",
    "th": "อนุญาตให้เปลี่ยนการตั้งค่า",
    "tr": "Yapılandırma değişikliklerine izin ver",
}
MOBILE_STORAGE_LABEL = {
    "en": "Storage location",
    "zh": "存储位置",
    "zh-Hant": "儲存位置",
    "de": "Speicherort",
    "es": "Ubicación de almacenamiento",
    "fil": "Lokasyon ng imbakan",
    "fr": "Emplacement de stockage",
    "in": "Lokasi penyimpanan",
    "ja": "保存場所",
    "ko": "저장 위치",
    "ms": "Lokasi storan",
    "pl": "Miejsce przechowywania",
    "pt-rBR": "Local de armazenamento",
    "ro": "Locație de stocare",
    "ru": "Место хранения",
    "th": "ตำแหน่งจัดเก็บ",
    "tr": "Depolama konumu",
}
ANDROID_REQUIRED_COPY = {
    "en": {
        "credit_title": "Upstream acknowledgements",
        "credit_body": "Built on nanoMuse and OpenMinis. Thanks to their contributors.",
        "permission_title": "Allow the assistant to manage settings",
        "permission_detail": "The assistant uses minis-config to read settings and propose changes. Changes require your confirmation. When off, it cannot use this command; existing changes remain available under Logs → Config Changes.",
    },
    "zh": {
        "credit_title": "上游致谢",
        "credit_body": "基于nanoMuse与OpenMinis开发，感谢上游贡献者。",
        "permission_title": "允许助手管理设置",
        "permission_detail": "助手通过minis-config读取设置并提出修改，修改需要你确认。关闭后，助手不能使用该命令；已有变更仍可在「日志→配置变更」查看。",
    },
    "zh-Hant": {
        "credit_title": "上游致謝",
        "credit_body": "基於nanoMuse與OpenMinis開發，感謝上游貢獻者。",
        "permission_title": "允許助手管理設定",
        "permission_detail": "助手透過minis-config讀取設定並提出修改，修改需要你確認。關閉後，助手不能使用該命令；已有變更仍可在「日誌→設定變更」查看。",
    },
    "de": {
        "credit_title": "Dank an die Ursprungsprojekte",
        "credit_body": "Basiert auf nanoMuse und OpenMinis. Vielen Dank an ihre Mitwirkenden.",
        "permission_title": "Dem Assistenten erlauben, Einstellungen zu verwalten",
        "permission_detail": "Der Assistent verwendet minis-config, um Einstellungen zu lesen und Änderungen vorzuschlagen. Änderungen erfordern deine Bestätigung. Ist diese Option aus, kann er diesen Befehl nicht verwenden; bisherige Änderungen bleiben unter Protokolle → Konfigurationsänderungen verfügbar.",
    },
    "es": {
        "credit_title": "Agradecimientos a los proyectos originales",
        "credit_body": "Basado en nanoMuse y OpenMinis. Gracias a sus colaboradores.",
        "permission_title": "Permitir que el asistente gestione los ajustes",
        "permission_detail": "El asistente usa minis-config para leer ajustes y proponer cambios. Los cambios requieren tu confirmación. Al desactivarlo, no podrá usar este comando; los cambios anteriores siguen disponibles en Registros → Cambios de configuración.",
    },
    "fil": {
        "credit_title": "Pasasalamat sa mga orihinal na proyekto",
        "credit_body": "Binuo gamit ang nanoMuse at OpenMinis. Salamat sa kanilang mga kontribyutor.",
        "permission_title": "Payagan ang assistant na pamahalaan ang mga setting",
        "permission_detail": "Ginagamit ng assistant ang minis-config para basahin ang mga setting at magmungkahi ng mga pagbabago. Kailangan ang kumpirmasyon mo sa mga pagbabago. Kapag naka-off, hindi nito magagamit ang command na ito; makikita pa rin ang mga naunang pagbabago sa Mga Log → Mga Pagbabago sa Configuration.",
    },
    "fr": {
        "credit_title": "Remerciements aux projets d'origine",
        "credit_body": "Basé sur nanoMuse et OpenMinis. Merci à leurs contributeurs.",
        "permission_title": "Autoriser l'assistant à gérer les paramètres",
        "permission_detail": "L'assistant utilise minis-config pour lire les paramètres et proposer des modifications. Les modifications nécessitent votre confirmation. Désactivé, il ne peut pas utiliser cette commande ; les modifications précédentes restent disponibles dans Journaux → Modifications de configuration.",
    },
    "in": {
        "credit_title": "Terima kasih kepada proyek asal",
        "credit_body": "Dibangun di atas nanoMuse dan OpenMinis. Terima kasih kepada para kontributornya.",
        "permission_title": "Izinkan asisten mengelola pengaturan",
        "permission_detail": "Asisten menggunakan minis-config untuk membaca pengaturan dan mengusulkan perubahan. Perubahan memerlukan konfirmasi Anda. Saat dinonaktifkan, asisten tidak dapat menggunakan perintah ini; perubahan sebelumnya tetap tersedia di Log → Perubahan Konfigurasi.",
    },
    "ja": {
        "credit_title": "元プロジェクトへの謝辞",
        "credit_body": "nanoMuseとOpenMinisを基に開発しました。貢献者の皆さまに感謝します。",
        "permission_title": "助手による設定の管理を許可",
        "permission_detail": "助手はminis-configを使って設定を読み取り、変更を提案します。変更にはあなたの確認が必要です。オフにするとこのコマンドを使えなくなりますが、過去の変更は「ログ→設定変更」で引き続き確認できます。",
    },
    "ko": {
        "credit_title": "원본 프로젝트에 대한 감사",
        "credit_body": "nanoMuse와 OpenMinis를 기반으로 개발했습니다. 기여자 여러분께 감사드립니다.",
        "permission_title": "도우미의 설정 관리 허용",
        "permission_detail": "도우미는 minis-config로 설정을 읽고 변경을 제안합니다. 변경하려면 사용자의 확인이 필요합니다. 끄면 이 명령을 사용할 수 없지만 기존 변경 사항은 로그→설정 변경에서 계속 확인할 수 있습니다.",
    },
    "ms": {
        "credit_title": "Penghargaan kepada projek asal",
        "credit_body": "Dibina berasaskan nanoMuse dan OpenMinis. Terima kasih kepada penyumbangnya.",
        "permission_title": "Benarkan pembantu mengurus tetapan",
        "permission_detail": "Pembantu menggunakan minis-config untuk membaca tetapan dan mencadangkan perubahan. Perubahan memerlukan pengesahan anda. Apabila dimatikan, pembantu tidak boleh menggunakan arahan ini; perubahan terdahulu masih tersedia dalam Log → Perubahan Konfigurasi.",
    },
    "pl": {
        "credit_title": "Podziękowania dla projektów źródłowych",
        "credit_body": "Oparte na nanoMuse i OpenMinis. Dziękujemy ich współtwórcom.",
        "permission_title": "Zezwól asystentowi na zarządzanie ustawieniami",
        "permission_detail": "Asystent używa minis-config do odczytywania ustawień i proponowania zmian. Zmiany wymagają Twojego potwierdzenia. Po wyłączeniu nie może używać tego polecenia; wcześniejsze zmiany pozostają dostępne w Dzienniki → Zmiany konfiguracji.",
    },
    "pt-rBR": {
        "credit_title": "Agradecimentos aos projetos originais",
        "credit_body": "Desenvolvido com base em nanoMuse e OpenMinis. Obrigado aos seus colaboradores.",
        "permission_title": "Permitir que o assistente gerencie as configurações",
        "permission_detail": "O assistente usa minis-config para ler configurações e propor alterações. As alterações exigem sua confirmação. Quando desativado, ele não pode usar esse comando; as alterações anteriores continuam disponíveis em Registros → Alterações de configuração.",
    },
    "ro": {
        "credit_title": "Mulțumiri proiectelor originale",
        "credit_body": "Bazat pe nanoMuse și OpenMinis. Mulțumim contributorilor lor.",
        "permission_title": "Permite asistentului să gestioneze setările",
        "permission_detail": "Asistentul folosește minis-config pentru a citi setările și a propune modificări. Modificările necesită confirmarea ta. Când este dezactivat, nu poate folosi această comandă; modificările anterioare rămân disponibile în Jurnale → Modificări de configurație.",
    },
    "ru": {
        "credit_title": "Благодарности исходным проектам",
        "credit_body": "Основано на nanoMuse и OpenMinis. Спасибо их участникам.",
        "permission_title": "Разрешить помощнику управлять настройками",
        "permission_detail": "Помощник использует minis-config для чтения настроек и предложения изменений. Изменения требуют вашего подтверждения. При отключении он не может использовать эту команду; прежние изменения доступны в разделе Журналы → Изменения конфигурации.",
    },
    "th": {
        "credit_title": "ขอบคุณโครงการต้นทาง",
        "credit_body": "พัฒนาต่อยอดจาก nanoMuse และ OpenMinis ขอบคุณผู้มีส่วนร่วมในทั้งสองโครงการ",
        "permission_title": "อนุญาตให้ผู้ช่วยจัดการการตั้งค่า",
        "permission_detail": "ผู้ช่วยใช้ minis-config เพื่ออ่านการตั้งค่าและเสนอการเปลี่ยนแปลง การเปลี่ยนแปลงต้องได้รับการยืนยันจากคุณ เมื่อปิด ผู้ช่วยจะใช้คำสั่งนี้ไม่ได้ แต่ยังดูการเปลี่ยนแปลงก่อนหน้าได้ที่ บันทึก → การเปลี่ยนแปลงการกำหนดค่า",
    },
    "tr": {
        "credit_title": "Kaynak projelere teşekkürler",
        "credit_body": "nanoMuse ve OpenMinis üzerine geliştirilmiştir. Katkıda bulunanlara teşekkür ederiz.",
        "permission_title": "Asistanın ayarları yönetmesine izin ver",
        "permission_detail": "Asistan, ayarları okumak ve değişiklik önermek için minis-config kullanır. Değişiklikler onayınızı gerektirir. Kapalıyken bu komutu kullanamaz; önceki değişikliklere Günlükler → Yapılandırma Değişiklikleri bölümünden erişilebilir.",
    },
}


def mobile_resource_copy(key: str, locale: str) -> str:
    """返回明确核验过入口的产品文案，不将历史云服务误称为新服务。"""
    language = mobile_locale(locale)
    if key == "config":
        return MOBILE_CONFIG_PERMISSION[language]
    if key == "storage_location":
        return MOBILE_STORAGE_LABEL[language]
    if key in ANDROID_REQUIRED_COPY[language]:
        return ANDROID_REQUIRED_COPY[language][key]
    if key in IOS_TASK_COPY.get(language, {}):
        return IOS_TASK_COPY[language][key]
    if key in IOS_SURFACE_COPY.get(language, {}):
        return IOS_SURFACE_COPY[language][key]
    if key in IOS_MEDIA_COPY.get(language, {}):
        return IOS_MEDIA_COPY[language][key]
    return MOBILE_RESOURCE_COPY[language][key]


def android_required_copy(text: str, locale: str) -> str:
    """补齐界面引用的新增资源，所有语言独立提供译文且重复运行不重复插入。"""
    resource_keys = (
        "nm_storage_location",
        "nm_about_upstream_credit_title",
        "nm_about_upstream_credit_body",
        "nm_config_permission_title",
        "nm_config_permission_detail",
    )
    for resource_key in resource_keys:
        if f'name="{resource_key}"' in text:
            continue
        value = mobile_resource_copy(ANDROID_RESOURCE_COPY[resource_key], locale)
        escaped = escape(value).replace("'", "\\'")
        text = text.replace(
            "</resources>", f'    <string name="{resource_key}">{escaped}</string>\n</resources>'
        )
    return text


def android_local_copy(text: str, locale: str) -> str:
    """仅更新指定显示资源，保留XML属性、注释、帮助命令及资源查找键。"""

    def substitute(match: re.Match[str]) -> str:
        key = ANDROID_RESOURCE_COPY.get(match[2])
        if key is None:
            return match[0]
        value = escape(mobile_resource_copy(key, locale)).replace("'", "\\'")
        return match[1] + value + match[4]

    return re.sub(
        r'(<string\b[^>]*\bname="([^"]+)"[^>]*>)(.*?)(</string>)',
        substitute,
        text,
        flags=re.S,
    )


def mobile_locale(locale: str) -> str:
    """统一Android资源目录和iOS语言代码，保持繁体中文单独翻译。"""
    if locale in ("zh-rTW", "zh-Hant"):
        return "zh-Hant"
    if locale.startswith("zh"):
        return "zh"
    return "en" if locale == "values" else locale


def mobile_name(locale: str) -> str:
    """中文系统使用念步，其他语言使用Nelan。"""
    return CHINESE_NAME if locale.startswith("zh") else NAME


def mobile_brand_text(text: str, locale: str) -> str:
    """更新显示品牌，保留上游署名、原服务名、网址、技术标识和占位符。"""
    preserve_upstream = "OpenMinis" in text

    def substitute(match: re.Match[str]) -> str:
        if re.match(r"`|[a-zA-Z][a-zA-Z0-9+.-]*://|www\.", match[0]):
            return match[0]
        if match[0].endswith((" Cloud", "-Cloud", " Desktop", "-Desktop")):
            return "nanoMuse Desktop" if match[0].endswith("Desktop") else "nanoMuse Cloud"
        if match[0] == "nanoMuses":
            return "Nelans"
        if match[0] == "AI-nanoMuse Agent":
            return "ИИ-агент Nelan" if locale == "ru" else "Nelan AI agent"
        if match[0] == "Nelan-nanoMuse Agent":
            return "Nelan-Agent"
        if preserve_upstream and match[0] == "nanoMuse":
            return match[0]
        return mobile_name(locale)

    result = MOBILE_BRAND_OR_URL.sub(substitute, text)
    if locale.startswith("zh"):
        result = re.sub(
            r"(?<=[\u3400-\u9fff]) +(?=念步)|(?<=念步) +(?=[\u3400-\u9fff])", "", result
        )
    return result


def write_brand_file(path: Path, text: str) -> None:
    """只保存实际变化的资源，保持LF换行和重复运行稳定。"""
    if path.is_file() and path.read_text(encoding="utf-8") == text:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    changed.append(str(path.relative_to(ROOT)))


def localized_system_label(target: str, locale: str) -> str:
    """提供主应用、分享、文件入口和小组件的系统显示名称。"""
    name = mobile_name(locale)
    labels = {
        "ShareExtension": {
            "en": "Share to Nelan",
            "zh-Hans": "分享到念步",
            "zh-Hant": "分享到念步",
            "ja": "Nelanに共有",
            "ko": "Nelan으로 공유",
            "fr": "Partager avec Nelan",
            "de": "Mit Nelan teilen",
            "es": "Compartir con Nelan",
            "ru": "Поделиться с Nelan",
        },
        "FileProvider": {
            "en": "Nelan Files",
            "zh-Hans": "念步文件",
            "zh-Hant": "念步檔案",
            "ja": "Nelanのファイル",
            "ko": "Nelan 파일",
            "fr": "Fichiers Nelan",
            "de": "Nelan-Dateien",
            "es": "Archivos de Nelan",
            "ru": "Файлы Nelan",
        },
        "AgentWidget": {
            "en": "Nelan Activity",
            "zh-Hans": "念步动态",
            "zh-Hant": "念步動態",
            "ja": "Nelanのアクティビティ",
            "ko": "Nelan 활동",
            "fr": "Activité Nelan",
            "de": "Nelan-Aktivität",
            "es": "Actividad de Nelan",
            "ru": "Активность Nelan",
        },
    }
    return labels.get(target, {}).get(locale, name)


def ios_info_brand() -> None:
    """生成权限提示和系统显示名；URL scheme、文档类型标识与App Group保持不变。"""
    for path in IOS.glob("*/Info.plist"):
        text = path.read_text(encoding="utf-8")
        write_brand_file(
            path, re.sub(r"(?<=>)[^<>]+(?=<)", lambda m: mobile_brand_text(m[0], "en"), text)
        )
    info = IOS / "Info.plist"
    if info.is_file():
        text = info.read_text(encoding="utf-8")
        # CFBundleURLName只标识协议，不能跟着显示品牌更名。
        pattern = r"(<key>(?:\w+UsageDescription|CFBundleTypeName|UTTypeDescription)</key>\s*<string>)(.*?)(</string>)"
        text = re.sub(pattern, lambda m: m[1] + mobile_brand_text(m[2], "en") + m[3], text)
        write_brand_file(info, text)
    for path in IOS.glob("*.lproj/InfoPlist.strings"):
        locale = path.parent.stem
        text = path.read_text(encoding="utf-8")
        text = re.sub(
            r'("[^"\n]+"\s*=\s*")((?:[^"\\]|\\.)*)(";)',
            lambda m, locale=locale: m[1] + mobile_brand_text(m[2], locale) + m[3],
            text,
        )
        display = f'"CFBundleDisplayName" = "{mobile_name(locale)}";'
        if '"CFBundleDisplayName"' in text:
            text = re.sub(r'"CFBundleDisplayName"\s*=\s*"[^"]*";', display, text)
        else:
            text += "\n/* nanoMuse: 系统桌面和设置采用当前产品名称。 */\n" + display + "\n"
        write_brand_file(path, text)


def ios_brand_resource_id(key: str) -> str:
    """按资源角色生成稳定的Xcode引用，避免多次生成出现重复成员。"""
    return hashlib.sha256(f"nelan.display.{key}".encode()).hexdigest()[:24].upper()


def pbx_add_object(text: str, section: str, object_id: str, declaration: str) -> str:
    """仅在缺失时将资源对象加入已有工程段。"""
    if re.search(rf"\b{object_id} /\*[^\r\n]*?\*/ =", text):
        return text
    marker = f"/* End {section} section */"
    if marker not in text:
        raise ValueError(f"Missing Xcode section: {section}")
    return text.replace(marker, declaration + "\n" + marker, 1)


def pbx_add_member(text: str, object_id: str, member: str, field: str) -> str:
    """将本地化组绑定到指定target的资源阶段和目录组。"""
    pattern = rf"(\t\t{object_id} /\*[^\r\n]*?\*/ = \{{.*?\b{field} = \()(.*?)(\n\t\t\t\);)"

    def substitute(match: re.Match[str]) -> str:
        if member in match[2]:
            return match[0]
        return match[1] + match[2] + "\n\t\t\t\t" + member + "," + match[3]

    result, count = re.subn(pattern, substitute, text, count=1, flags=re.S)
    if count != 1:
        raise ValueError(f"Missing Xcode object: {object_id}")
    return result


def ios_extension_labels(text: str) -> str:
    """为三个扩展分别打包本地化InfoPlist.strings，不能复用主App的名称文件。"""
    targets = {
        "ShareExtension": ("E5E000030", "E5E000042"),
        "FileProvider": ("E5FP00030", "E5FP00042"),
        "AgentWidget": ("E5H000030", "E5H000042"),
    }
    for target, (group, phase) in targets.items():
        variant_id = ios_brand_resource_id(f"{target}.variant")
        build_id = ios_brand_resource_id(f"{target}.build")
        members = []
        for locale in IOS_BRAND_LOCALES:
            path = IOS / target / f"{locale}.lproj/InfoPlist.strings"
            write_brand_file(
                path,
                "/* nanoMuse: 扩展的系统显示名称与文件入口名称。 */\n"
                f'"CFBundleDisplayName" = "{localized_system_label(target, locale)}";\n'
                f'"Nelan" = "{mobile_name(locale)}";\n',
            )
            file_id = ios_brand_resource_id(f"{target}.{locale}")
            members.append(f"\t\t\t\t{file_id} /* {locale} */,")
            text = pbx_add_object(
                text,
                "PBXFileReference",
                file_id,
                f"\t\t{file_id} /* {locale} */ = {{isa = PBXFileReference; "
                f'lastKnownFileType = text.plist.strings; name = "{locale}"; '
                f'path = "{locale}.lproj/InfoPlist.strings"; sourceTree = "<group>"; }};',
            )
        text = pbx_add_object(
            text,
            "PBXVariantGroup",
            variant_id,
            f"\t\t{variant_id} /* InfoPlist.strings */ = {{\n\t\t\tisa = PBXVariantGroup;\n"
            "\t\t\tchildren = (\n" + "\n".join(members) + "\n\t\t\t);\n"
            '\t\t\tname = InfoPlist.strings;\n\t\t\tsourceTree = "<group>";\n\t\t};',
        )
        text = pbx_add_object(
            text,
            "PBXBuildFile",
            build_id,
            f"\t\t{build_id} /* InfoPlist.strings in Resources */ = {{isa = PBXBuildFile; "
            f"fileRef = {variant_id} /* InfoPlist.strings */; }};",
        )
        text = pbx_add_member(text, group, f"{variant_id} /* InfoPlist.strings */", "children")
        text = pbx_add_member(
            text, phase, f"{build_id} /* InfoPlist.strings in Resources */", "files"
        )
    return text


def ios_catalogue_brand() -> None:
    """只更新译文，保留Swift、AppIntents和系统查询使用的原翻译键。"""
    catalogue = IOS / "Localizable.xcstrings"
    if not catalogue.is_file():
        return
    raw = catalogue.read_text(encoding="utf-8")
    data = json.loads(raw)
    strings = data.setdefault("strings", {})
    for key, entry in strings.items():
        ios_catalogue_entry_brand(key, entry)
    # 修正原翻译中将英文Agent和产品名重复拼接的句子，保留AppIntents使用的键。
    russian_intents = {
        "Re-runs the AI agent from a specific user message in a session. Presents a list of user messages to choose from, then retries from that point.": "Перезапускает ИИ-агента Nelan с выбранного сообщения пользователя. Показывает список сообщений для выбора и повторяет выполнение с этого места.",
        "Sends a follow-up prompt to an existing nanoMuse session, continuing the conversation with the AI agent.": "Отправляет дополнительный запрос в существующую сессию Nelan, продолжая разговор с ИИ-агентом.",
        "Sends a prompt to the nanoMuse AI agent. Returns session info immediately while the task runs in the background.": "Отправляет запрос ИИ-агенту Nelan. Сразу возвращает сведения о сессии, пока задача выполняется в фоне.",
    }
    for key, value in russian_intents.items():
        if key in strings:
            strings[key].setdefault("localizations", {})["ru"] = {
                "stringUnit": {"state": "translated", "value": value}
            }
    strings["Nelan"] = {
        "localizations": {
            locale: {"stringUnit": {"state": "translated", "value": mobile_name(locale)}}
            for locale in IOS_BRAND_LOCALES
        }
    }
    for key, copy_key in IOS_RESOURCE_COPY.items():
        if key not in strings and copy_key not in ("saved", "sync"):
            continue
        entry = strings.setdefault(key, {})
        localizations = entry.setdefault("localizations", {})
        for locale in IOS_BRAND_LOCALES:
            localizations[locale] = {
                "stringUnit": {
                    "state": "translated",
                    "value": mobile_resource_copy(copy_key, locale),
                }
            }
    if json.loads(raw) != data:
        write_brand_file(catalogue, xcstrings_dumps(data, raw))


def ios_catalogue_entry_brand(key: str, entry: dict) -> None:
    """为品牌键提供英文回退，逐语言处理译文，分享署名不再指向上游推广页。"""
    has_brand = MOBILE_BRAND.search(key) is not None
    localizations = (
        entry.setdefault("localizations", {}) if has_brand else entry.get("localizations", {})
    )
    if has_brand and "en" not in localizations:
        localizations["en"] = {"stringUnit": {"state": "translated", "value": key}}
    for locale, localization in localizations.items():
        ios_localization_brand(localization, locale)
        unit = localization.get("stringUnit", {})
        if (
            key == "Your personal AI agent, open source · github.com/nano-muse/nanoMuse"
            and "value" in unit
        ):
            unit["value"] = unit["value"].replace(" · github.com/nano-muse/nanoMuse", "")


def ios_localization_brand(node: object, locale: str) -> None:
    """兼容复数和设备变体的字符串目录结构。"""
    if not isinstance(node, dict):
        return
    for key, value in node.items():
        if key == "value" and isinstance(value, str):
            node[key] = mobile_brand_text(value, locale)
        else:
            ios_localization_brand(value, locale)


def ios_brand_only() -> None:
    """更新手机品牌资源和配置，保留历史代码、版本、协议及持久化身份。"""
    if not IOS.is_dir():
        return
    edit(
        IOS / "Minis.xcodeproj/project.pbxproj",
        [
            (
                r'INFOPLIST_KEY_CFBundleDisplayName = "?(?:Minis|nanoMuse|Nicholasx|Nivo Bot)"?;',
                'INFOPLIST_KEY_CFBundleDisplayName = "Nelan";',
            ),
            (
                r'INFOPLIST_KEY_CFBundleDisplayName = "Share to (?:Minis|nanoMuse|Nicholasx|Nivo Bot)";',
                'INFOPLIST_KEY_CFBundleDisplayName = "Share to Nelan";',
            ),
            (
                r'INFOPLIST_KEY_CFBundleDisplayName = "(?:Minis|nanoMuse|Nicholasx|Nivo Bot) Files";',
                'INFOPLIST_KEY_CFBundleDisplayName = "Nelan Files";',
            ),
            (
                r'INFOPLIST_KEY_CFBundleDisplayName = "Agent Activity";',
                'INFOPLIST_KEY_CFBundleDisplayName = "Nelan Activity";',
            ),
        ],
    )
    settings = IOS / "NanoMuse/NanoMuseSettings.swift"
    if settings.is_file():
        edit(
            settings,
            [
                (r'URL\(string: "https://nanomuse\.cn/privacy/"\)!', "NivoProduct.privacy"),
                (r'"https://nanomuse\.cn/own-key"', "NivoProduct.modelGuide.absoluteString"),
            ],
        )
    connector = IOS / "NanoMuse/NanoMuseConnectors.swift"
    if connector.is_file():
        edit(
            connector,
            [
                (
                    r"The authorization server refused to register nanoMuse",
                    r"The authorization server refused to register \\(NivoProduct.name)",
                ),
            ],
        )
    ios_info_brand()
    ios_catalogue_brand()
    project = IOS / "Minis.xcodeproj/project.pbxproj"
    text = project.read_text(encoding="utf-8")
    if "/* Begin PBXVariantGroup section */" in text:
        write_brand_file(project, ios_extension_labels(text))


if __name__ == "__main__":
    raise SystemExit(main())
