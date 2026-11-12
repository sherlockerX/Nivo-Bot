#!/usr/bin/env python3
"""仅为明确请求正式签名的GitHub任务准备临时密钥，不修改本地签名配置。"""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SECRET_NAMES = (
    "NIVO_ANDROID_KEYSTORE_BASE64",
    "NIVO_ANDROID_STORE_PASSWORD",
    "NIVO_ANDROID_KEY_ALIAS",
    "NIVO_ANDROID_KEY_PASSWORD",
)


def properties_value(value: str) -> str:
    """将属性值转成Java Properties可无损读取的ASCII。"""
    result = value.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r")
    result = result.replace(" ", "\\ ").replace("=", "\\=").replace(":", "\\:")
    return result.encode("ascii", "backslashreplace").decode("ascii")


def signing_paths(root: Path, temp: Path) -> tuple[Path, Path, Path]:
    """返回固定的临时密钥、所有权标记和Gradle配置路径。"""
    folder = temp / "nivo-android-signing"
    return folder / "release.keystore", folder / "state.json", root / "android/keystore.properties"


def prepare(root: Path, temp: Path, env: dict[str, str]) -> None:
    """验证输入后生成临时文件，拒绝覆盖任何已有签名配置。"""
    missing = [name for name in SECRET_NAMES if not env.get(name)]
    if missing:
        raise ValueError("Missing GitHub Secrets: " + ", ".join(missing))
    encoded = "".join(env[SECRET_NAMES[0]].split())
    content = base64.b64decode(encoded, validate=True)
    if not content:
        raise ValueError("Keystore is empty")
    key, marker, config = signing_paths(root, temp)
    if config.exists() or key.exists() or marker.exists():
        raise ValueError("Refusing to overwrite existing signing files")
    key.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    key.write_bytes(content)
    key.chmod(0o600)
    # 只保存路径和别名；密码由当前构建步骤的环境变量注入。
    text = f"storeFile={properties_value(key.as_posix())}\n"
    text += f"keyAlias={properties_value(env[SECRET_NAMES[2]])}\n"
    marker.write_text(json.dumps({"config": str(config.resolve())}), encoding="utf-8")
    with config.open("x", encoding="ascii", newline="\n") as stream:
        stream.write(text)
    config.chmod(0o600)


def cleanup(root: Path, temp: Path) -> None:
    """只删除本任务拥有的临时文件，未创建配置时保持原文件不动。"""
    key, marker, config = signing_paths(root, temp)
    if not marker.is_file():
        return
    state = json.loads(marker.read_text(encoding="utf-8"))
    if state.get("config") != str(config.resolve()):
        raise ValueError("Signing cleanup ownership mismatch")
    config.unlink(missing_ok=True)
    key.unlink(missing_ok=True)
    marker.unlink()
    key.parent.rmdir()


def main() -> None:
    """只允许在GitHub隔离runner中执行准备或清理。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cleanup", action="store_true")
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true" or not os.environ.get("RUNNER_TEMP"):
        raise SystemExit("This helper requires a GitHub Actions runner")
    temp = Path(os.environ["RUNNER_TEMP"]).resolve()
    if args.cleanup:
        cleanup(ROOT, temp)
    else:
        prepare(ROOT, temp, dict(os.environ))


if __name__ == "__main__":
    main()
