"""验证静态产品页的本地依赖、锚点和发布元信息。"""
import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlparse

SITE_FILES = ('index.html', 'developers.html', 'product.css', 'product.js',
              'release.json', 'brand-mark.svg')


class Page(HTMLParser):
    """收集ID、资源和链接用于静态校验。"""
    def __init__(self):
        super().__init__()
        self.ids, self.links, self.errors = set(), [], []

    def handle_starttag(self, tag, attributes):
        """检查重复ID、无障碍文本和新窗口安全属性。"""
        attrs = dict(attributes)
        if attrs.get('id'):
            if attrs['id'] in self.ids:
                self.errors.append(f'Duplicate ID: {attrs["id"]}')
            self.ids.add(attrs['id'])
        self.links.extend(attrs[key] for key in ('src', 'href') if attrs.get(key))
        if tag == 'img' and 'alt' not in attrs:
            self.errors.append('Image missing alt')
        if attrs.get('target') == '_blank' and 'noopener' not in attrs.get('rel', ''):
            self.errors.append('External window missing noopener')


def check(root: Path, allow_local: bool = False) -> dict:
    """拒绝断链和误把本地安装包作为公开版本发布。"""
    errors = [f'Missing file: {name}' for name in SITE_FILES if not (root / name).is_file()]
    pages = {}
    for name in ('index.html', 'developers.html'):
        if (root / name).is_file():
            page = Page()
            page.feed((root / name).read_text(encoding='utf-8'))
            pages[name] = page
            errors.extend(f'{name}: {error}' for error in page.errors)
    for name, page in pages.items():
        for link in page.links:
            parsed = urlparse(link)
            if parsed.scheme:
                if parsed.scheme not in {'https', 'http', 'mailto'}:
                    errors.append(f'{name}: Invalid scheme: {parsed.scheme}')
                continue
            relative = unquote(parsed.path) or name
            target = (root / relative).resolve()
            if not target.is_relative_to(root.resolve()) or not target.is_file():
                errors.append(f'{name}: Missing local target: {relative}')
            if parsed.fragment and relative in pages and parsed.fragment not in pages[relative].ids:
                errors.append(f'{name}: Missing anchor: {link}')
    release = json.loads((root / 'release.json').read_text(encoding='utf-8')) if (root / 'release.json').exists() else {}
    channel = release.get('channel')
    if channel not in {'source', 'public', 'local-preview'}:
        errors.append('Invalid release channel')
    if channel == 'local-preview' and not allow_local:
        errors.append('Local preview cannot be published')
    if channel == 'public':
        if not str(release.get('downloadUrl', '')).startswith('https://'):
            errors.append('Public APK requires HTTPS URL')
        if not re.fullmatch('[a-fA-F0-9]{64}', str(release.get('sha256', ''))):
            errors.append('Public APK requires SHA256')
    if channel == 'source' and release.get('downloadUrl'):
        errors.append('Source-only channel must not advertise an APK')
    return {'passed': not errors, 'errors': errors, 'pages': len(pages), 'release_channel': channel}


def main() -> None:
    """本地与CI共用退出码。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('site'))
    parser.add_argument('--allow-local-preview', action='store_true')
    args = parser.parse_args()
    report = check(args.root, args.allow_local_preview)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    raise SystemExit(0 if report['passed'] else 1)


if __name__ == '__main__':
    main()
