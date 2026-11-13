"""通过Netcatty在既有服务器执行可回滚的静态网站发布，不修改公网代理或应用包。"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import tarfile
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath

CADDY = """# Nivo Bot静态站点，公网HTTPS继续由原Caddy代理提供。
:80 {
    root * /site/current
    encode zstd gzip
    header X-Content-Type-Options nosniff
    header Referrer-Policy strict-origin-when-cross-origin
    @pages not path /downloads/*
    header @pages Cache-Control "no-cache"
    @downloads path /downloads/*
    header @downloads Cache-Control "public, max-age=3600"
    file_server
}
""".encode()


def command(*arguments: str, content: bytes | None = None) -> str:
    """按固定参数执行服务器命令，失败即停止。"""
    result = subprocess.run(arguments, input=content, capture_output=True, check=True)
    return result.stdout.decode("utf-8", errors="replace")


def unpack(archive: Path, destination: Path) -> None:
    """拒绝路径穿越、符号链接和二进制下载文件，不使用不受限extractall。"""
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or "downloads" in path.parts:
                raise ValueError("Unsafe deployment archive path")
            if not member.isfile() or member.size > 4 * 1024 * 1024:
                raise ValueError("Unexpected deployment archive entry")
            if not (destination / member.name).resolve().is_relative_to(destination.resolve()):
                raise ValueError("Deployment archive escapes target")
        for member in members:
            stream = bundle.extractfile(member)
            if stream is None:
                raise ValueError("Missing archive content")
            target = destination / member.name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(stream.read())


def deploy(root: Path, archive: Path, release_id: str) -> dict:
    """验证新文件后原子切换站点，保留旧版本、下载文件及回滚配置。"""
    if not re.fullmatch(r"site-[A-Za-z0-9._-]{1,80}", release_id):
        raise ValueError("Invalid site release ID")
    current = root / "www/current"
    previous = current.resolve(strict=True)
    releases = root / "www/releases"
    if not current.is_symlink() or not previous.is_relative_to(releases.resolve()):
        raise ValueError("Unexpected current site target")
    downloads = (previous / "downloads").resolve(strict=True)
    if not downloads.is_relative_to((root / "www").resolve()):
        raise ValueError("Unexpected download location")
    download_hashes = {
        p.name: hashlib.sha256(p.read_bytes()).hexdigest()
        for p in downloads.iterdir()
        if p.is_file()
    }
    release = releases / release_id
    release.mkdir(exist_ok=False)
    unpack(archive, release)
    manifest = json.loads((release / "files.json").read_text(encoding="utf-8"))
    for name, digest in manifest["files"].items():
        if not (release / name).resolve().is_relative_to(release.resolve()):
            raise ValueError("Manifest path escapes release")
        if hashlib.sha256((release / name).read_bytes()).hexdigest() != digest:
            raise ValueError("Uploaded site checksum mismatch")
    (release / "downloads").symlink_to(os.path.relpath(downloads, release))
    config = root / "Caddyfile"
    before = config.read_bytes()
    backup = root / "backups" / release_id
    backup.mkdir(parents=True, exist_ok=False)
    (backup / "Caddyfile").write_bytes(before)
    deployment_file = root / "deployment-manifest.json"
    if deployment_file.exists():
        (backup / "deployment-manifest.json").write_bytes(deployment_file.read_bytes())
    command(
        "docker",
        "exec",
        "-i",
        "nivo-site",
        "sh",
        "-c",
        "cat > /tmp/nivo-site-candidate && caddy validate --config /tmp/nivo-site-candidate --adapter caddyfile",
        content=CADDY,
    )
    next_link = root / "www" / (".current-" + release_id)
    if next_link.exists() or next_link.is_symlink() or current.resolve() != previous:
        raise ValueError("Site changed during preparation")
    next_link.symlink_to("releases/" + release_id)
    try:
        # 配置文件使用文件绑定挂载，原位写入以保留被容器挂载的inode。
        config.write_bytes(CADDY)
        os.replace(next_link, current)
        command(
            "docker",
            "exec",
            "nivo-site",
            "caddy",
            "reload",
            "--config",
            "/etc/caddy/Caddyfile",
            "--adapter",
            "caddyfile",
        )
        for path in (
            "index.html",
            "features.html",
            "models.html",
            "models/gemini.html",
            "downloads.html",
            "releases.json",
        ):
            body = command(
                "docker", "exec", "nivo-site", "wget", "-qO-", "http://127.0.0.1/" + path
            )
            if "Nivo" not in body and "schemaVersion" not in body:
                raise ValueError("Published page is not the expected document")
        after_downloads = {
            p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in downloads.iterdir()
            if p.is_file()
        }
        if after_downloads != download_hashes:
            raise ValueError("Existing download files changed")
    except Exception:
        rollback = root / "www" / (".rollback-" + release_id)
        rollback.symlink_to(os.path.relpath(previous, root / "www"))
        os.replace(rollback, current)
        config.write_bytes(before)
        command(
            "docker",
            "exec",
            "nivo-site",
            "caddy",
            "reload",
            "--config",
            "/etc/caddy/Caddyfile",
            "--adapter",
            "caddyfile",
        )
        raise
    app_release = json.loads((release / "release.json").read_text(encoding="utf-8"))
    result = {
        "url": "https://nivo.8666886.xyz/",
        "site_release": release_id,
        "release": str(release),
        "previous_release": str(previous),
        "source_commit": manifest.get("source_commit"),
        "version": app_release["version"],
        "versionCode": app_release["versionCode"],
        "verified_files": len(manifest["files"]),
        "preserved_download_hashes": download_hashes,
        "backup": str(backup),
        "public_verified": False,
        "deployed_at": datetime.now(UTC).isoformat(),
    }
    deployment_file.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    (backup / "completed.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main() -> None:
    """要求明确指定服务器上的归档与发布ID，不能在本机代替Netcatty执行。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("/opt/nivo-site"))
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--release-id", required=True)
    args = parser.parse_args()
    print(json.dumps(deploy(args.root, args.archive, args.release_id), indent=2))


if __name__ == "__main__":
    main()
