#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Fail-closed publication regressions; all attack data is generated locally."""
import importlib.util
import pathlib
import sys
import tempfile
import unittest
import json
import os
import shutil
import subprocess

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))


class TreeSecurityTests(unittest.TestCase):
    def setUp(self):
        import security
        self.security = security
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        (self.root / 'root/etc').mkdir(parents=True)
        (self.root / 'root/etc/expected').write_text('synthetic\n')
        self.allowed = {'root/etc/expected'}

    def test_exact_tree(self):
        self.security.inspect_tree(self.root, self.allowed)

    def test_hidden_file(self):
        (self.root / 'root/etc/.hidden').write_text('SYNTHETIC_CANARY')
        with self.assertRaises(self.security.SecurityError):
            self.security.inspect_tree(self.root, self.allowed)

    def test_nested_build(self):
        (self.root / 'root/etc/.build').mkdir()
        with self.assertRaises(self.security.SecurityError):
            self.security.inspect_tree(self.root, self.allowed)

    def test_external_file_and_directory_links(self):
        for target in (self.root / 'root/etc/expected', self.root / 'root/etc'):
            link = self.root / 'link'
            link.symlink_to(target)
            with self.assertRaises(self.security.SecurityError):
                self.security.inspect_tree(self.root, self.allowed)
            link.unlink()

    def test_only_exact_local_directory_is_excluded(self):
        (self.root / '.build').mkdir()
        (self.root / '.build/synthetic.key').write_text('SYNTHETIC_CANARY')
        self.security.inspect_tree(self.root, self.allowed)
        (self.root / '.build').rename(self.root / 'root/.build')
        with self.assertRaises(self.security.SecurityError):
            self.security.inspect_tree(self.root, self.allowed)

    def test_excluded_directory_cannot_be_link(self):
        (self.root / '.build').symlink_to(self.root / 'root', target_is_directory=True)
        with self.assertRaises(self.security.SecurityError):
            self.security.inspect_tree(self.root, self.allowed)

    def test_missing_file(self):
        with self.assertRaises(self.security.SecurityError):
            self.security.inspect_tree(self.root, self.allowed | {'missing'})

    def test_managed_placeholders_must_be_empty(self):
        (self.root / '.agents').mkdir()
        self.security.inspect_tree(self.root, self.allowed)
        (self.root / '.agents/private-probe').write_text('SYNTHETIC_CANARY')
        with self.assertRaises(self.security.SecurityError):
            self.security.inspect_tree(self.root, self.allowed)

    def test_release_extra_and_symlink_rejected(self):
        release = self.root / 'release'
        release.mkdir()
        (release / 'private-report').write_text('SYNTHETIC_CANARY')
        with self.assertRaises(self.security.SecurityError):
            self.security.check_release_directory(release)


class PublicationAttackTests(unittest.TestCase):
    """Exercise both real entry points in isolated clones; no commits are made."""
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='toolkit-attack-tests-')
        cls.base = pathlib.Path(cls.tmp.name)
        cls.names = json.loads((ROOT/'tools/publication-files.json').read_text())

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def clone(self, name):
        target = self.base/name
        env = {k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
        env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
        subprocess.run(['git','clone','--no-hardlinks','--quiet',str(ROOT),str(target)],
                       env=env,check=True,capture_output=True)
        for name in self.names:
            destination=target/name
            destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(ROOT/name,destination)
            destination.chmod((ROOT/name).stat().st_mode & 0o777)
        return target

    def test_both_commands_reject_all_source_attacks(self):
        scenarios = ('hidden', 'external-file-link', 'external-directory-link',
                     'nested-build', 'dirty-payload', 'secret-wrong-path', 'ignored-secret')
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                clone=self.clone(scenario)
                external=self.base/(scenario+'-external')
                if scenario=='hidden':
                    (clone/'root/etc/.hidden').write_text('SYNTHETIC_CANARY')
                elif scenario=='external-file-link':
                    external.write_text('SYNTHETIC_CANARY')
                    (clone/'root/etc/external-link').symlink_to(external)
                elif scenario=='external-directory-link':
                    external.mkdir()
                    (external/'canary').write_text('SYNTHETIC_CANARY')
                    (clone/'root/etc/external-link').symlink_to(external,target_is_directory=True)
                elif scenario=='nested-build':
                    (clone/'root/etc/.build').mkdir()
                    (clone/'root/etc/.build/private-probe').write_text('SYNTHETIC_CANARY')
                elif scenario=='dirty-payload':
                    with (clone/'root/etc/config/podkop_tools').open('a') as stream:
                        stream.write('\n# UNREVIEWED_SYNTHETIC_CHANGE\n')
                elif scenario=='secret-wrong-path':
                    with (clone/'README.md').open('a') as stream:
                        stream.write('\napi_key = "SYNTHETIC_AUDIT_ONLY_CANARY"\n')
                else:
                    (clone/'.env').write_text('SYNTHETIC_CANARY')
                for script in ('build-podkop-tools.py','prepublish.py'):
                    command=[sys.executable,'-B',str(clone/'tools'/script),'--output',str(self.base/(scenario+'-'+script))]
                    if script=='build-podkop-tools.py':command+=['--stage-only']
                    result=subprocess.run(command,capture_output=True,text=True)
                    self.assertEqual(result.returncode,1,script+' accepted '+scenario)
                    self.assertIn('BLOCKED:',result.stderr)
                    expected = ('unreviewed payload source bytes' if scenario=='dirty-payload'
                                else 'unreviewed sensitive patterns' if scenario=='secret-wrong-path'
                                else 'symlink rejected' if 'link' in scenario
                                else 'unexpected')
                    self.assertIn(expected,result.stderr)
                    self.assertNotIn('SYNTHETIC_AUDIT_ONLY_CANARY',result.stderr)

    def test_fixture_bytes_must_match_generator(self):
        clone=self.clone('fixture-mismatch')
        with (clone/'tests/fixtures/provider.json').open('a') as stream:
            stream.write(' ')
        result=subprocess.run([sys.executable,'-B',str(clone/'tools/generate-fixtures.py'),'--check'],capture_output=True)
        self.assertNotEqual(result.returncode,0)


if __name__ == '__main__':
    unittest.main()
