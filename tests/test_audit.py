#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Publication audit regression: findings must not disclose their values."""
import importlib.util, pathlib, unittest, uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('audit',ROOT/'tools/audit.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
class AuditTests(unittest.TestCase):
 def test_injected_identifiers_are_detected_and_redacted(self):
  values=[str(uuid.UUID(int=1)), 'https://'+'fixture.example.invalid/sub?token=synthetic', '/home/'+'fixture/backup', '-----BEGIN '+'PRIVATE KEY-----']
  findings=audit.scan('\n'.join(values).encode(),'fixture')
  self.assertGreaterEqual({f['kind'] for f in findings},{'uuid','url','private_path','private_key'})
  for value in values:self.assertNotIn(value,str(findings))
 def test_exception_cannot_accept_another_file_or_value(self):
  original=audit.scan(('https://'+'fixture.example.invalid/one').encode(),'allowed')[0]
  moved=audit.scan(('https://'+'fixture.example.invalid/one').encode(),'other')[0]
  changed=audit.scan(('https://'+'fixture.example.invalid/two').encode(),'allowed')[0]
  self.assertNotEqual(audit.key(original),audit.key(moved))
  self.assertNotEqual(audit.key(original),audit.key(changed))
if __name__=='__main__':unittest.main()
