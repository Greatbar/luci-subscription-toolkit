// SPDX-License-Identifier: GPL-2.0-only
import { compatibility_report } from '/usr/libexec/podkop-tools/compatibility.uc';
let passed = 0;
function assert(ok, message) { if (!ok) die(message); passed++; }
let versions = { openwrt: '99.0', podkop: '9.9.9', sing_box: '9.9.9' };
let ready = { fetch: null, selector: null, monitoring: null, measurement: null, generation: null, reload: null, backup: null };
let report = compatibility_report(ready, versions);
assert(index(report.warnings, 'untested_versions') >= 0, 'unknown versions are diagnostic');
for (let name in keys(report.capabilities)) assert(report.capabilities[name].available, 'unknown version blocked ' + name);
let facts = { ...ready, generation: 'generator_unavailable' };
report = compatibility_report(facts, versions);
for (let name in ['fetch', 'selector', 'monitoring', 'switch', 'measurement', 'recovery']) assert(report.capabilities[name].available, 'generator blocks unrelated ' + name);
for (let name in ['apply', 'rollback']) assert(!report.capabilities[name].available && report.capabilities[name].reason == 'generator_unavailable', 'generator must block ' + name);
report = compatibility_report({ ...ready, selector: 'api_unavailable' }, versions);
assert(report.capabilities.fetch.available, 'API blocks download');
assert(!report.capabilities.monitoring.available && !report.capabilities.switch.available && !report.capabilities.recovery.available, 'missing API not detected');
assert(report.capabilities.rollback.available, 'runtime API blocks emergency rollback preflight');
report = compatibility_report({ ...ready, backup: 'rollback_unavailable' }, versions);
assert(!report.capabilities.rollback.available && report.capabilities.apply.available, 'backup absence blocks apply');
report = compatibility_report({ ...ready, measurement: 'sing_box_unavailable' }, versions);
assert(report.capabilities.fetch.available && report.capabilities.monitoring.available && report.capabilities.switch.available, 'measurement blocks unrelated functions');
assert(!report.capabilities.apply.available && !report.capabilities.measurement.available, 'measurement requirement missing');
print(sprintf('%J\n', { passed }));
