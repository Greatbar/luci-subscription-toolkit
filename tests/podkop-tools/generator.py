#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Generator contract tests; no router, Podkop execution or external services."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class GeneratorContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='toolkit-generator-')
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.native = self.root / 'podkop'
        self.job = self.root / 'job'
        self.script = self.root / 'generate'
        self.script.write_text((ROOT / 'root/usr/libexec/podkop-tools/generate').read_text()
                               .replace('/usr/bin/podkop', str(self.native))
                               .replace('/tmp/podkop-tools/job', str(self.job)))

    def fixture(self, boundary='case "$1" in', initializer='sing_box_init_config() {'):
        self.native.write_text('''#!/bin/sh
printf loaded > "''' + str(self.root / 'sourced') + '''"
config_load() { CONFIG_SECTIONS='settings main'; }
config_get() { eval "$1=\\\"$job/generated.json\\\""; }
''' + initializer + '''
    [ "$UCI_CONFIG_DIR" = "$job/uci" ] || return 1
    [ "$TMP_RULESET_FOLDER" = "$job/rulesets" ] || return 1
    printf '{}\\n' > "$config_path"
}
''' + boundary + '''
*) printf dispatched > "''' + str(self.root / 'dispatched') + '''";;
esac
''')

    def run_generator(self, *args):
        return subprocess.run(['sh', str(self.script), *args], capture_output=True, text=True)

    def test_check_accepts_contract_without_executing_or_creating_job(self):
        self.fixture()
        result = self.run_generator('--check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'sourced').exists())
        self.assertFalse((self.root / 'dispatched').exists())
        self.assertFalse(self.job.exists())

    def test_check_accepts_whitespace_variations(self):
        self.fixture(boundary='  case  "$1"  in # CLI', initializer='sing_box_init_config ( )\n{')
        result = self.run_generator('--check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.job.exists())

    def test_braced_dispatch_argument_is_supported(self):
        self.fixture(boundary='case "${1}" in')
        result = self.run_generator('--check')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_initializer_must_be_before_dispatch(self):
        self.fixture(initializer='different_generator() {')
        self.native.write_text(self.native.read_text() + '\nsing_box_init_config() { :; }\n')
        result = self.run_generator('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('generator_unavailable', result.stderr)

    def test_missing_boundary_does_not_execute_source_or_cli(self):
        self.fixture(boundary='case "$2" in')
        result = self.run_generator('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('generator_unavailable', result.stderr)
        self.assertFalse((self.root / 'sourced').exists())
        self.assertFalse((self.root / 'dispatched').exists())

    def test_missing_initializer_does_not_execute_source(self):
        self.fixture(initializer='different_generator() {')
        result = self.run_generator('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('generator_unavailable', result.stderr)
        self.assertFalse((self.root / 'sourced').exists())

    def test_syntax_error_has_generic_diagnostic(self):
        self.fixture()
        self.native.write_text(self.native.read_text().replace('CONFIG_SECTIONS=', 'PRIVATE_ROUTER_SECRET $( '))
        result = self.run_generator('--check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('generator_unavailable', result.stderr)
        self.assertNotIn('PRIVATE_ROUTER_SECRET', result.stderr)

    def test_generation_uses_staging_and_never_dispatches_cli(self):
        self.fixture()
        (self.job / 'uci').mkdir(parents=True)
        (self.job / 'rulesets').mkdir()
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.job / 'generated.json').read_text(), '{}\n')
        self.assertTrue((self.root / 'sourced').exists())
        self.assertFalse((self.root / 'dispatched').exists())


if __name__ == '__main__':
    unittest.main()
