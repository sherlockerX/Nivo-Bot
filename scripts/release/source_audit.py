"""只读检查源码候选，不输出秘密值，不扫描用户运行目录。"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import Iterable

FORBIDDEN_PARTS = {'.git', '.gradle', '.kotlin', 'node_modules', '__pycache__',
                   '.venv', 'venv', 'build', 'dist', '.idea', '.vscode', 'logs'}
FORBIDDEN_SUFFIXES = {'.apk', '.aab', '.jks', '.keystore', '.db', '.enc', '.key',
                      '.log', '.pyc', '.hprof'}
SECRET_PATTERNS = (
    ('private-key', re.compile(rb'^\s*-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----\s*$', re.MULTILINE)),
    ('github-token', re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b')),
    ('aws-access-id', re.compile(rb'\bAKIA[A-Z0-9]{16}\b')),
    ('provider-token', re.compile(rb'\bsk-(?:proj-|ant-api\d+-)?[A-Za-z0-9_-]{35,}\b')),
)


def git(root: Path, *arguments: str) -> bytes:
    """只为本次调用信任指定仓库，不修改全局Git配置。"""
    return subprocess.run(
        ['git', '-c', f'safe.directory={root}', '-C', str(root), *arguments],
        check=True, capture_output=True,
    ).stdout


def is_forbidden(relative: str) -> bool:
    """禁止运行数据、签名密钥与本机配置进入源码候选。"""
    path = Path(relative)
    name = path.name.lower()
    if any(part.lower() in FORBIDDEN_PARTS for part in path.parts):
        return True
    if path.suffix.lower() in FORBIDDEN_SUFFIXES:
        return True
    if name.startswith('.env') and not name.endswith('.example'):
        return True
    if name in {'local.properties', 'keystore.properties', 'provider-customization.properties',
                'providercustomization.xcconfig', 'config.toml', 'debug.keystore'}:
        return True
    return name.endswith('.local.toml') or name.endswith('.env')


def secret_findings(relative: str, data: bytes) -> list[dict]:
    """返回命中类别与行号，报告不含匹配内容。"""
    if b'\0' in data[:8192]:
        return []
    findings = []
    for category, pattern in SECRET_PATTERNS:
        for match in pattern.finditer(data):
            findings.append({'path': relative, 'line': data.count(b'\n', 0, match.start()) + 1,
                             'category': category})
    return findings


def tracked_paths(root: Path) -> list[str]:
    """列出主仓库路径，不隐式展开或下载子模块。"""
    return [item.decode('utf-8') for item in git(root, 'ls-files', '-z').split(b'\0') if item]


def audit_files(root: Path, paths: Iterable[str]) -> dict:
    """审查当前工作树；缺失文件和疑似凭据均阻止发布。"""
    missing, forbidden, secrets, files = [], [], [], []
    for relative in sorted(set(paths)):
        path = root / relative
        if is_forbidden(relative):
            forbidden.append(relative)
            continue
        if not path.exists():
            missing.append(relative)
            continue
        if path.is_dir():
            continue
        if path.is_symlink():
            files.append({'path': relative, 'kind': 'symlink'})
            continue
        data = path.read_bytes()
        secrets.extend(secret_findings(relative, data))
        files.append({'path': relative, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
    return {'missing': missing, 'forbidden': forbidden, 'suspected_secrets': secrets,
            'files_checked': len(files), 'ready': not (missing or forbidden or secrets),
            'limits': 'Pattern scan only. Git history, runtime services and third-party licences require separate review.'}


def main() -> None:
    """输出可审查JSON，发现问题时返回非零退出码。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = audit_files(args.root.resolve(), tracked_paths(args.root.resolve()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({key: len(report[key]) for key in ('missing', 'forbidden', 'suspected_secrets')}))
    raise SystemExit(0 if report['ready'] else 2)


if __name__ == '__main__':
    main()
