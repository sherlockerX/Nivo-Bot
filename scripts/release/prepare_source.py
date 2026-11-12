"""从当前代码和已审查覆盖层生成本地源码候选包，不修改或发布原仓库。"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import zipfile

from source_audit import git, is_forbidden, secret_findings, tracked_paths

EXTRA_ROOTS = ('android/src/android/app/src', 'android/src/android/app/schemas',
               'docs', 'scripts', 'site')


def checked_path(relative: str) -> str:
    """归档路径不能绝对寻址或向上穿越。"""
    path = PurePosixPath(relative)
    if path.is_absolute() or '..' in path.parts or '\\' in relative or ':' in relative:
        raise ValueError('Unsafe archive path')
    return relative


def prepare(root: Path, overlay: Path, output: Path, restore_missing: bool) -> dict:
    """保留工作树现有改动，缺失跟踪文件仅在候选包中从HEAD恢复。"""
    paths = set(tracked_paths(root))
    for folder in EXTRA_ROOTS:
        for path in (root / folder).rglob('*'):
            if path.is_file() and path.suffix in {'.kt', '.xml', '.json', '.md', '.py', '.ps1', '.html', '.css', '.js', '.svg'}:
                relative = path.relative_to(root).as_posix()
                if not is_forbidden(relative):
                    paths.add(relative)
    paths.update(path.relative_to(overlay).as_posix() for path in overlay.rglob('*') if path.is_file())
    report = {'restored_from_head': [], 'excluded': [], 'submodules': [], 'files': [], 'suspected_secrets': []}
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix('.partial.zip')
    try:
        with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for relative in sorted(paths):
                checked_path(relative)
                if is_forbidden(relative):
                    report['excluded'].append(relative)
                    continue
                source = overlay / relative if (overlay / relative).is_file() else root / relative
                source_root = overlay if source.is_relative_to(overlay) else root
                if not source.resolve().is_relative_to(source_root.resolve()):
                    raise ValueError(f'Path escapes source root: {relative}')
                if source.is_dir():
                    report['submodules'].append(relative)
                    continue
                if source.is_symlink():
                    raise ValueError(f'Symlink needs review: {relative}')
                if source.exists():
                    data = source.read_bytes()
                elif restore_missing:
                    entry = git(root, 'ls-tree', 'HEAD', '--', relative).decode('utf-8')
                    if entry.startswith('160000'):
                        report['submodules'].append(relative)
                        continue
                    data = git(root, 'show', f'HEAD:{relative}')
                    report['restored_from_head'].append(relative)
                else:
                    raise FileNotFoundError(relative)
                findings = secret_findings(relative, data)
                report['suspected_secrets'].extend(findings)
                if findings:
                    continue
                archive.writestr(relative, data)
                report['files'].append({'path': relative, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
            if report['suspected_secrets']:
                raise ValueError('Suspected secrets detected; see report, values are not printed')
            archive.writestr('SOURCE_CANDIDATE.json', json.dumps({
                'status': 'local-review-candidate', 'base_commit': git(root, 'rev-parse', 'HEAD').decode().strip(),
                'restored_files': report['restored_from_head'], 'submodules': report['submodules'],
                'notice': 'Local changes included. No Git history or private config. Submodules must be fetched separately. Not a verified fresh-clone build.'
            }, ensure_ascii=False, indent=2))
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise ValueError('Archive CRC failed')
        os.replace(temporary, output)
        report['archive_sha256'] = hashlib.sha256(output.read_bytes()).hexdigest()
        report['archive'] = str(output)
        return report
    finally:
        if temporary.exists():
            temporary.unlink()
        output.with_suffix('.manifest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')


def main() -> None:
    """显式要求恢复缺失文件，避免把既有删除悄悄带回工作树。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--overlay', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--restore-missing-from-head', action='store_true')
    args = parser.parse_args()
    report = prepare(args.root.resolve(), args.overlay.resolve(), args.output.resolve(), args.restore_missing_from_head)
    print(json.dumps({'files': len(report['files']), 'restored': len(report['restored_from_head']),
                      'excluded': len(report['excluded']), 'sha256': report['archive_sha256']}))


if __name__ == '__main__':
    main()
