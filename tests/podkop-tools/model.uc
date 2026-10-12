// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 LuCI Subscription Toolkit contributors
import { canonical, parse_provider, reconcile, plan, proxy_uri, sample, decode, encode } from '/usr/libexec/podkop-tools/model.uc';
import * as model from '/usr/libexec/podkop-tools/model.uc';
let count = 0;
function assert(ok, message) { if (!ok) die(message); count++; }
function rejected(fn, code) { let failed = false; try { fn(); } catch (e) { failed = e.message == code; } assert(failed, code); }
let incoming = [
    { name: 'Sweden', outbound: { type: 'vless', server: 'a.example', server_port: 443, uuid: 'a' } },
    { name: 'Latvia', outbound: { type: 'vless', server: 'b.example', server_port: 443, uuid: 'b' } },
    { name: 'Germany', outbound: { type: 'vless', server: 'c.example', server_port: 443, uuid: 'c' } }
];
// Inject a deterministic opaque-ID hash solely in the pure model tests.
function hash(v) { return v; }
let previous = reconcile([], incoming, hash), selected = previous[1].id;
let result = plan(previous, [incoming[2], incoming[0], incoming[1]], selected, hash);
assert(!result.runtime_changed && canonical(previous) == canonical(result.nodes), 'reorder_noop');
let changed = json(sprintf('%J', incoming)); changed[1].name = 'Латвия';
result = plan(previous, changed, selected, hash);
assert(result.labels_changed && !result.runtime_changed && result.selected_id == selected, 'rename_without_reload');
changed = json(sprintf('%J', incoming)); changed[1].outbound.server = 'new.example';
result = plan(previous, changed, selected, hash);
assert(result.runtime_changed && result.selected_id == selected, 'parameters_stable_id');
rejected(() => plan(previous, [incoming[0]], selected, hash), 'fallback_not_verified');
result = plan(previous, [incoming[0]], previous[2].id, hash, previous[0].id);
assert(result.fallback_used && result.selected_tag == 'main-1-out', 'removed_out_of_range');
result = plan(previous, [incoming[1], incoming[2]], selected, hash);
assert(result.nodes[1].id == selected && result.selected_tag == 'main-2-out', 'cached_position');
rejected(() => parse_provider('<html>PRIVATE_TOKEN</html>'), 'invalid_json');
rejected(() => parse_provider('[]'), 'invalid_root');
let profile = { remarks: '🇸🇪 Швеция', outbounds: [{ protocol: 'vless', tag: 'proxy', settings: { vnext: [{ address: 'localhost', port: 443, users: [{ id: '00000000-0000-4000-8000-000000000001' }] }] }, streamSettings: { network: 'tcp', security: 'none' } }] };
let parsed = parse_provider(sprintf('%J', [profile]));
assert(length(parsed.nodes) == 1 && parsed.nodes[0].name == profile.remarks, 'provider_names');
let uri = proxy_uri(parsed.nodes[0]);
assert(decode(split(uri, '#')[1]) == profile.remarks, 'utf8_fragment_roundtrip');
let metrics = { http_code: 200, size_download: 1048576, time_starttransfer: 1, time_total: 3 };
assert(sample(metrics, 28, 4194304, 262144, 0.5).mbps > 4, 'time_bound_partial_valid');
metrics.size_download = 100;
assert(sample(metrics, 28, 4194304, 262144, 0.5).error == 'insufficient_sample', 'minimum_bytes');
metrics.size_download = 1048576; metrics.time_total = 1.1;
assert(sample(metrics, 0, 4194304, 262144, 0.5).error == 'insufficient_sample', 'minimum_duration');
metrics.time_total = 3; metrics.http_code = 403;
assert(sample(metrics, 28, 4194304, 262144, 0.5).error == 'unexpected_http_status', 'reject_error_page');
metrics.http_code = 200;
assert(sample(metrics, 56, 4194304, 262144, 0.5).error == 'transfer_failed', 'reject_network_failure');
assert(type(model.deferred_gate) == 'function', 'bounded_series_gate_missing');
let now=200000;
assert(!model.deferred_gate({version_at:now-60}, {started_at:now-12*3600},now,6*3600,24*3600).ready, 'young_version_before_deadline');
assert(model.deferred_gate({version_at:now-7*3600}, {started_at:now-7*3600},now,6*3600,24*3600).trigger == 'stable_version', 'stable_version_normal_delay');
for (let step=0;step<=48;step++) {
    let instant=now+step*3600;
    assert(model.deferred_gate({version_at:instant}, {started_at:now},instant,6*3600,24*3600).ready == (step>=24), 'hourly_rotation_finite_bound');
}
assert(model.deferred_gate(null,{started_at:now-25*3600},now,6*3600,24*3600).trigger=='series_deadline','expired_candidate_still_demands_refetch');
assert(!model.deferred_gate(null,null,now,6*3600,24*3600).ready,'no_changes_no_apply');
print(sprintf('%J\n', { passed: count }));
