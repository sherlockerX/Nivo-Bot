"""只复制产品网站白名单，不夹带旧站素材、源码或本机APK。"""

import argparse
import hashlib
import json
import shutil
from pathlib import Path

from check_site import check, site_files


def build(root: Path, output: Path) -> dict:
    """空目录打包，已有文件时拒绝覆盖以免发布残留文件。"""
    report = check(root)
    if not report["passed"]:
        raise ValueError(report["errors"])
    if output.exists() and any(output.iterdir()):
        raise ValueError("Output directory must be empty")
    output.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for name in site_files(root):
        (output / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, output / name)
        manifest[name] = hashlib.sha256((output / name).read_bytes()).hexdigest()
    (output / ".nojekyll").write_text("", encoding="utf-8")
    return manifest


def main() -> None:
    """不进行Git操作，也不触发部署。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("site"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(build(args.root, args.output), indent=2))


if __name__ == "__main__":
    main()
