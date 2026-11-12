"""验证源码打包的秘密拦截、路径边界和候选恢复。"""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest
import zipfile

from source_audit import is_forbidden, secret_findings
from prepare_source import checked_path, prepare


class ReleaseToolsTest(unittest.TestCase):
    """临时仓库检验真实归档行为，不接触用户项目。"""
    def test_block_private_files(self):
        for path in ['.env', 'config/config.toml', 'android/keystore.properties',
                     'x/node_modules/a.js', 'private.jks', 'local.properties', 'x.db']:
            self.assertTrue(is_forbidden(path), path)
        self.assertFalse(is_forbidden('.env.example'))
        self.assertFalse(is_forbidden('app/schemas/database/1.json'))

    def test_secret_report_never_contains_value(self):
        token = b'ghp_' + b'a' * 36
        findings = secret_findings('test.txt', b'line\n' + token)
        self.assertEqual(2, findings[0]['line'])
        self.assertNotIn(token.decode(), json.dumps(findings))

    def test_reject_traversal(self):
        for path in ['../key', '/secret', 'C:/secret', 'x\\..\\key']:
            with self.assertRaises(ValueError):
                checked_path(path)

    def test_restore_only_in_archive_and_keep_worktree_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'repo'
            overlay = Path(directory) / 'overlay'
            root.mkdir(); overlay.mkdir()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'LICENSE').write_text('license', encoding='utf-8')
            (root / 'app.txt').write_text('base', encoding='utf-8')
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test',
                            '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture'], check=True)
            (root / 'LICENSE').unlink()
            (root / 'app.txt').write_text('local edit', encoding='utf-8')
            (overlay / 'site').mkdir()
            (overlay / 'site/index.html').write_text('new page', encoding='utf-8')
            archive = Path(directory) / 'source.zip'
            report = prepare(root, overlay, archive, True)
            self.assertEqual(['LICENSE'], report['restored_from_head'])
            self.assertFalse((root / 'LICENSE').exists())
            with zipfile.ZipFile(archive) as source:
                self.assertEqual(b'local edit', source.read('app.txt'))
                self.assertEqual(b'license', source.read('LICENSE'))
                self.assertEqual(b'new page', source.read('site/index.html'))


if __name__ == '__main__':
    unittest.main()
