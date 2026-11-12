"""用原创HTML与矢量场景渲染README功能图，并编码横向轮播。"""

from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

REPO = Path(__file__).resolve().parents[1]
OUT = REPO / "docs/media/readme"
OUT.mkdir(parents=True, exist_ok=True)
CSS = """
*{box-sizing:border-box}body{margin:0;font-family:'Segoe UI',Arial,sans-serif;color:#203e35;background:#f4f2eb;-webkit-font-smoothing:antialiased}
.slide{width:1200px;height:640px;position:relative;padding:60px 68px;overflow:hidden;display:grid;grid-template-columns:1fr 1fr;gap:55px}
.slide:before{content:'';position:absolute;width:520px;height:520px;border-radius:50%;border:1px solid #d2d8ca;right:-75px;top:45px;z-index:0}
.copy,.preview{position:relative;z-index:1}.brand{font-size:20px;font-weight:700;display:flex;gap:10px;align-items:center}.mark{width:32px;height:32px;display:grid;place-items:center;border-radius:10px;background:#203e35;color:#f4f2eb;font-size:26px;font-weight:700}
.eyebrow{margin-top:58px;font-size:13px;letter-spacing:2.5px;color:#8a583e;text-transform:uppercase}.copy h1{font-size:49px;line-height:1.12;letter-spacing:-1.7px;margin:18px 0 22px;font-weight:650}.copy p{font-size:18px;line-height:1.7;color:#67736a;max-width:440px}.chips{display:flex;gap:8px;margin-top:27px}.chip{border:1px solid #d4dacf;border-radius:22px;padding:8px 13px;font-size:11px;color:#526b58}
.bottom{position:absolute;bottom:32px;left:68px;right:68px;display:flex;justify-content:space-between;align-items:center;font-size:11px;color:#70806e}.number{font-family:Georgia,serif;font-size:25px;color:#809273}.dots{display:flex;gap:7px}.dots i{width:6px;height:6px;border-radius:50%;background:#ccd4c5}.dots i.on{background:#bb5138;width:23px;border-radius:5px}
.preview{margin-top:20px;background:#fffef9;border:1px solid #dce0d4;border-radius:24px;box-shadow:0 24px 60px #203e3510;height:456px;padding:26px}.preview h3{margin:0 0 24px;font-size:19px;letter-spacing:-.3px}.mini{font-size:10px;color:#82917c;letter-spacing:1px}.muted{color:#7a8677;font-size:12px}.row{display:flex;justify-content:space-between;align-items:center}.bubble{padding:15px 17px;border-radius:15px;line-height:1.6;font-size:14px;max-width:90%;margin:18px 0}.user{background:#e5ecd9;margin-left:auto}.ai{background:#f3f3ea}.task{padding:17px;border:1px solid #dce2d4;border-radius:13px;margin:14px 0;font-size:14px;background:#fffef9}.task strong{display:block;font-size:14px}.task small{display:block;font-size:11px;color:#7b8675;margin-top:9px}.ring{display:inline-grid;place-items:center;border:1px solid #83967e;border-radius:50%;width:19px;height:19px;margin-right:10px;color:#688360;font-size:11px}.input{background:#f2f3eb;border-radius:24px;padding:13px 16px;font-size:12px;color:#8b9486;position:absolute;bottom:24px;left:26px;right:26px}.nav{display:flex;gap:6px}.nav span{background:#eff2e7;border-radius:18px;font-size:11px;padding:8px 11px}.pill{background:#203e35;color:white;font-size:11px;padding:7px 14px;border-radius:16px}.note{padding:20px;background:#edf0e4;border-radius:15px;margin:14px 0;line-height:1.6;font-size:14px}.note p{margin:8px 0}.tiny{font-size:10px;color:#7c8974}
.landscape{position:absolute;inset:0;z-index:0;border-radius:24px;overflow:hidden;background:#aebfa8}.landscape svg{width:100%;height:100%}.focus-ui{position:relative;text-align:center;color:#fffef9;padding-top:40px}.clock{font-size:84px;font-weight:300;letter-spacing:3px;margin:45px 0 6px}.focus-button{margin:28px auto 0;background:#fffef9df;color:#203e35;border-radius:24px;padding:13px 25px;width:145px;font-size:13px}.two{display:grid;grid-template-columns:1fr 1fr;gap:10px}.capability{height:118px;background:#f0f3e6;border-radius:14px;padding:14px;position:relative}.capability b{font-size:12px;display:block;margin-top:7px}.capability svg{height:55px;width:100%;}.evidence{display:flex;justify-content:space-between;font-size:12px;margin-top:18px;padding:12px;background:#edf0e4;border-radius:10px}.idea{padding:16px;border:1px solid #e0e4d8;border-radius:13px;margin:11px 0}.idea small{color:#a3684c;font-size:10px;letter-spacing:1px}.idea p{font-size:14px;line-height:1.4;margin:7px 0 0}.bar{height:7px;border-radius:9px;background:#e5eadb;overflow:hidden;margin-top:12px}.bar i{display:block;height:100%;width:42%;background:#6e8763}
.hero{width:1440px;height:660px;position:relative;padding:58px 70px;overflow:hidden}.hero h1{font-size:88px;letter-spacing:-4px;margin:38px 0 8px;line-height:1.02}.hero h1 em{font:italic 92px Georgia,serif;color:#bb5138}.hero>p{font-size:20px;line-height:1.8;color:#6c7868;width:600px}.hero .meta{position:absolute;bottom:50px;left:70px;font-size:12px;letter-spacing:1px;color:#75816f}.hero-art{position:absolute;top:70px;right:60px;width:580px;height:500px}.orb{position:absolute;border:1px solid #ccd4c4;width:500px;height:500px;border-radius:50%;transform:scaleX(1.14)}.hero-card{position:absolute;background:#fffef9;border:1px solid #d7ddd0;border-radius:18px;padding:21px;width:260px;box-shadow:0 16px 40px #203e3510}.hero-card h3{font-size:17px;margin:8px 0}.hero-card p{font-size:13px;line-height:1.6;color:#6d7a66}.hc1{top:12px;left:18px;transform:rotate(-7deg)}.hc2{top:125px;right:0;transform:rotate(6deg);background:#2d5144;color:white}.hc3{bottom:5px;left:45px;transform:rotate(-3deg)}.hc2 p{color:#d5e1cf}.hero-clock{font-size:64px;font-weight:300;padding:20px 0}.connector{position:absolute;right:128px;bottom:78px;color:#bb5138;font-size:50px}.hero .label{font-size:11px;letter-spacing:1.7px}
"""
LANDSCAPE = """<div class="landscape"><svg viewBox="0 0 500 460" preserveAspectRatio="none"><rect width="500" height="460" fill="#acc0aa"/><circle cx="393" cy="74" r="36" fill="#ebdab1"/><path d="M0 225Q110 50 260 247T500 180V460H0" fill="#7d9e87"/><path d="M0 320Q170 130 310 317T500 270V460H0" fill="#507968"/><path d="M0 411Q110 290 300 398T500 350V460H0" fill="#2d5547"/></svg></div>"""
BAMBOO = """<svg viewBox="0 0 180 70"><g fill="none" stroke="#668463" stroke-width="3"><path d="M66 68V5m24 63V0m27 68V13M66 26l-13-13m13 33 16-18m8-12 15-12m-15 44-17-19m44 21 13-18"/><path d="M62 21h8m16 15h8m19 21h8"/></g></svg>"""
DEBATE = """<svg viewBox="0 0 180 70"><ellipse cx="90" cy="47" rx="43" ry="14" fill="#d7be9e"/><g fill="#78917b"><circle cx="55" cy="20" r="8"/><circle cx="123" cy="20" r="8"/></g><path d="M36 43q20-22 38 0m34 0q20-22 38 0" fill="#a8b89a"/><path d="M77 12h24v15H88l-5 5v-5h-6z" fill="none" stroke="#ad7351" stroke-width="2"/></svg>"""
SCREENS = [
    (
        "chat",
        "01 / CONVERSATION TO ACTION",
        "Say it.<br>Start something.",
        "Capture an intention in chat.<br>Let app tools turn it into a saved task.",
        ["Your model", "App tools", "System TTS"],
        """<div class="row"><h3>Nivo Bot</h3><span class="mini">MAIN CHAT</span></div><div class="bubble user">I want to read a little every day.</div><div class="bubble ai">Start with one chapter. Shall I add it to your tasks?</div><div class="task"><strong><span class="ring">✓</span>Read a chapter. Keep one note.</strong><small>Personal growth · Reading · Task saved</small></div><div class="bubble ai">You can begin a focus session from this task.</div><div class="input">What would you like to do today? &nbsp; ↑</div>""",
    ),
    (
        "tasks",
        "02 / ONE PLACE FOR WHAT MATTERS",
        "Make room<br>for the next step.",
        "Reusable groups, tags and useful views.<br>Find the task. Choose what comes next.",
        ["Calendar", "Four quadrants", "Groups & tags"],
        """<div class="row"><h3>My tasks</h3><span class="pill">+ New</span></div><div class="nav"><span>Today</span><span>Calendar</span><span>Quadrants</span></div><div class="task"><strong><span class="ring"></span>Read a chapter</strong><small>Personal growth · Reading · In progress</small><div class="bar"><i></i></div></div><div class="task"><strong><span class="ring"></span>Prepare the project outline</strong><small>Work · Writing · Next</small></div><div class="task"><strong><span class="ring">✓</span>Take a walk</strong><small>Life · Health · Done</small></div><div class="muted">Saved groups and tags are ready to reuse.</div>""",
    ),
    (
        "focus",
        "03 / A LITTLE UNDIVIDED ATTENTION",
        "One task.<br>A quieter screen.",
        "Choose a background. Start a timer.<br>Pause, return and keep the actual time.",
        ["Countdown", "Stopwatch", "Screen recovery"],
        LANDSCAPE
        + """<div class="focus-ui"><div class="mini" style="color:#eef2e4">FOCUS / READING</div><p style="font-size:17px">Read a chapter</p><div class="clock">24:59</div><span style="font-size:12px;opacity:.8">A moment for just this.</span><div class="focus-button">Ⅱ &nbsp; Pause</div><p style="font-size:10px;opacity:.75;margin-top:22px">Your imported backgrounds stay on your device.</p></div>""",
    ),
    (
        "fragments",
        "04 / LEAVE A TRACE OF YOUR DAY",
        "Keep the story,<br>not just a number.",
        "Connect daily notes with task progress<br>and the focus sessions you finished.",
        ["Daily notes", "Task progress", "Focus links"],
        """<div class="row"><h3>Daily fragments</h3><span class="mini">TODAY</span></div><div class="note"><span class="tiny">A SMALL DISCOVERY</span><p>I read slowly today.<br>One idea was enough to make a note.</p></div><div class="task"><strong><span class="ring">✓</span>Read a chapter</strong><small>Linked task · Done</small></div><div class="note"><div class="row"><strong style="font-size:14px">Time for reading</strong><b style="font-size:26px">25 min</b></div><span class="tiny">Linked finished focus session</span></div><div class="muted">Experiences and actions, in the same record.</div>""",
    ),
    (
        "coach",
        "05 / LEARN IT. TRY IT. REVISIT IT.",
        "A practice<br>worth returning to.",
        "Explore a capability. Practise in chat.<br>Keep evidence in your learning archive.",
        ["Course proposals", "Daily practice", "Learning archive"],
        """<div class="row"><h3>Growth coach</h3><span class="mini">EXPLORE</span></div><div class="two"><div class="capability">"""
        + BAMBOO
        + """<b>Principles & judgement</b></div><div class="capability">"""
        + DEBATE
        + """<b>Expression & perspective</b></div></div><div class="note"><span class="tiny">CONTINUE A TOPIC</span><p>Say no, without losing sight<br>of the relationship.</p><span class="pill">Open daily practice →</span></div><div class="evidence"><span>Concept → Practice → Revisit</span><span>↗</span></div>""",
    ),
    (
        "ideas",
        "06 / SOMETHING NEW TO TRY",
        "A small spark<br>for an ordinary day.",
        "Date-refreshed ideas across your life.<br>Take an interesting one into a conversation.",
        ["Work & life", "Learning", "Content ideas"],
        """<div class="row"><h3>Daily ideas</h3><span class="mini">A FRESH START</span></div><div class="nav"><span>Ideas</span><span>Work</span><span>Life</span><span>More</span></div><div class="idea"><small>LEARNING</small><p>Explain one thing you learned<br>as if teaching a friend.</p></div><div class="idea"><small>FAMILY & RELATIONSHIPS</small><p>Ask a question you usually<br>leave for another day.</p></div><div class="idea"><small>CONTENT CREATION</small><p>Make a short story from<br>one observation in your day.</p></div><div class="muted">Choose an idea → Continue in chat</div>""",
    ),
]


def document(body: str) -> str:
    """返回可独立渲染的静态页面。"""
    return (
        '<!doctype html><html lang="en"><meta charset="utf-8"><style>'
        + CSS
        + "</style><body>"
        + body
        + "</body></html>"
    )


def main() -> None:
    """渲染封面与六个功能页，生成横向切换的GIF。"""
    hero = """<div class="hero"><div class="brand"><span class="mark">n</span>Nivo Bot</div><h1>Less switching.<br><em>More living.</em></h1><p>Turn conversations into action.<br>Tasks, focus, daily notes and growth coaching,<br>connected in one AI workspace.</p><div class="meta">ANDROID 8.0+ &nbsp; / &nbsp; YOUR MODEL &nbsp; / &nbsp; OPEN SOURCE</div><div class="hero-art"><div class="orb"></div><div class="hero-card hc1"><span class="label">A CONVERSATION</span><h3>What do you want to start?</h3><p>One chapter. One useful note.<br>A little time for yourself.</p></div><div class="hero-card hc2"><span class="label">A MOMENT OF FOCUS</span><div class="hero-clock">25:00</div><p>Read a chapter</p></div><div class="hero-card hc3"><span class="label">A TRACE OF YOUR DAY</span><h3>Something to return to.</h3><p>Task → Focus → Daily fragment<br>Learning → Practice → Archive</p></div><span class="connector">↗</span></div></div>"""
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1440, "height": 660}, device_scale_factor=1)
        page.set_content(document(hero))
        page.screenshot(path=str(OUT / "hero.png"))
        page.set_viewport_size({"width": 1200, "height": 640})
        for index, (name, label, title, description, chips, screen) in enumerate(SCREENS):
            dots = "".join('<i class="on"></i>' if i == index else "<i></i>" for i in range(6))
            body = (
                f'<div class="slide"><div class="copy"><div class="brand"><span class="mark">n</span>Nivo Bot</div><div class="eyebrow">{label}</div><h1>{title}</h1><p>{description}</p><div class="chips">'
                + "".join(f'<span class="chip">{chip}</span>' for chip in chips)
                + f'</div></div><div class="preview">{screen}</div><div class="bottom"><span>ILLUSTRATED FEATURE OVERVIEW / SAMPLE CONTENT</span><div class="dots">{dots}</div><span class="number">0{index + 1} / 06</span></div></div>'
            )
            page.set_content(document(body))
            page.screenshot(path=str(OUT / f"{name}.png"))
        browser.close()
    images = [
        Image.open(OUT / f"{screen[0]}.png")
        .convert("RGB")
        .resize((960, 512), Image.Resampling.LANCZOS)
        for screen in SCREENS
    ]
    frames = []
    durations = []
    for index, image in enumerate(images):
        frames.append(image.copy())
        durations.append(1900)
        following = images[(index + 1) % len(images)]
        for step in range(1, 5):
            shift = round(960 * step / 5)
            frame = Image.new("RGB", (960, 512))
            frame.paste(image, (-shift, 0))
            frame.paste(following, (960 - shift, 0))
            frames.append(frame)
            durations.append(110)
    palette = images[0].quantize(colors=128)
    encoded = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
    encoded[0].save(
        OUT / "feature-tour.gif",
        save_all=True,
        append_images=encoded[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=2,
    )
    for path in sorted(OUT.iterdir()):
        print(path.name, path.stat().st_size)


if __name__ == "__main__":
    main()
