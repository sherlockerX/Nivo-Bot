#!/usr/bin/env python3
"""刷新十份README文末致谢中的nanoMuse上游贡献者头像。

名单继续来自``nano-muse/nanoMuse``，用于保留上游贡献归属，不代表Nivo分支的
独立贡献名单。``README.md``与``docs/readme/README_*.md``中的贡献者标记之间
保存头像与GitHub主页链接，按上游贡献数排序；另行署名的上游维护者与机器人不列入。

    scripts/readme-contributors.py            # 更新头像区块并报告变更文件
    scripts/readme-contributors.py --check    # 区块落后时返回1，适用于CI
    scripts/readme-contributors.py --from-json contributors.json   # 使用离线API记录

可设置``GITHUB_TOKEN``提高请求限额，也可以匿名调用。发布前与其他README检查一起运行。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
REPO = "nano-muse/nanoMuse"
API = f"https://api.github.com/repos/{REPO}/contributors"
START = "<!-- contributors:start -->"
END = "<!-- contributors:end -->"
MAINTAINERS = frozenset({"lgy0404"})
AVATAR = 48


def readmes(root: Path = ROOT) -> list[Path]:
    """The English README and the translations under docs/readme/, in a fixed order."""
    return [root / "README.md", *sorted(root.glob("docs/readme/README_*.md"))]


def fetch(token: str | None = None) -> list[dict[str, Any]]:
    """Every page of GitHub's contributors list for the repository."""
    people: list[dict[str, Any]] = []
    page = 1
    while True:
        req = urllib.request.Request(
            f"{API}?per_page=100&page={page}",
            headers={
                "Accept": "application/vnd.github+json",
                "User-Agent": "nanomuse-readme-contributors",
                **({"Authorization": f"Bearer {token}"} if token else {}),
            },
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            batch = json.load(resp)
        if not isinstance(batch, list):
            raise SystemExit(f"unexpected answer from {API}: {str(batch)[:200]}")
        people.extend(batch)
        if len(batch) < 100:
            return people
        page += 1


def community(people: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The contributors who get an avatar: no maintainers, no bots, GitHub's order kept."""
    out = []
    for person in people:
        login = str(person.get("login", ""))
        if not login or login in MAINTAINERS:
            continue
        if person.get("type") == "Bot" or login.endswith("[bot]"):
            continue
        out.append(person)
    return out


def render(people: list[dict[str, Any]]) -> str:
    """The HTML between the markers: one linked avatar per person."""
    lines = ["<p>"]
    for person in community(people):
        login, uid = person["login"], person["id"]
        lines.append(
            f'<a href="https://github.com/{login}">'
            f'<img src="https://avatars.githubusercontent.com/u/{uid}?v=4&s={AVATAR}" '
            f'width="{AVATAR}" height="{AVATAR}" alt="{login}"></a>'
        )
    lines.append("</p>")
    return "\n".join(lines)


def rewrite(text: str, block: str) -> str:
    """``text`` with the part between the markers replaced by ``block``."""
    start = text.find(START)
    end = text.find(END)
    if start < 0 or end < 0 or end < start:
        raise ValueError("no contributors block")
    return text[: start + len(START)] + "\n" + block + "\n" + text[end:]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="exit 1 when a README is behind")
    parser.add_argument("--from-json", type=Path, help="the API's JSON from a file, no network")
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    if args.from_json:
        people = json.loads(args.from_json.read_text(encoding="utf-8"))
    else:
        people = fetch(os.environ.get("GITHUB_TOKEN"))
    block = render(people)

    behind: list[Path] = []
    for path in readmes(args.root):
        text = path.read_text(encoding="utf-8")
        try:
            new = rewrite(text, block)
        except ValueError:
            print(f"{path.relative_to(args.root)}: no contributors block", file=sys.stderr)
            return 2
        if new == text:
            continue
        behind.append(path)
        if not args.check:
            path.write_text(new, encoding="utf-8")

    names = ", ".join(p["login"] for p in community(people)) or "nobody yet"
    if args.check:
        if behind:
            files = ", ".join(str(p.relative_to(args.root)) for p in behind)
            print(f"{len(behind)} README(s) behind: {files}")
            return 1
        print(f"contributors current ({names})")
        return 0
    if behind:
        print(f"updated {len(behind)} README(s): {names}")
    else:
        print(f"nothing to do ({names})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
