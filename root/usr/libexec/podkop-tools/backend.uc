// SPDX-License-Identifier: GPL-2.0-only
import * as fs from 'fs';
import * as sections from '/usr/libexec/podkop-tools/sections.uc';
import { compatibility_report } from '/usr/libexec/podkop-tools/compatibility.uc';
import { priority_order, observe, reserve_slot, nonemergency_allowed, latency_better, remaining, selection_event } from '/usr/libexec/podkop-tools/policy.uc';
import { history_record, history_query, history_snapshot, history_restore } from '/usr/libexec/podkop-tools/statistics.uc';
import { cursor } from 'uci';
import { canonical, parse_provider, reconcile, plan, proxy_uri, encode, decode, sample, service_sample, deferred_gate } from '/usr/libexec/podkop-tools/model.uc';

const BASE = '/etc/podkop-tools', TMP = '/tmp/podkop-tools', JOB = TMP + '/job';
let ctx = cursor(), probe_pid = null, batch_request = null;
let execution_deadline = null, runtime_cache = null;
function monotime() { return +split(trim(fs.readfile('/proc/uptime')), ' ')[0]; }
function budget(cap, reserve) {
    let value = execution_deadline == null ? cap : remaining(execution_deadline, monotime(), cap, reserve ?? 0);
    if (value < 0.05) die('budget_exhausted');
    return value;
}
function q(v) { return "'" + replace('' + v, /'/g, "'\\''") + "'"; }
function run(args) {
    if (execution_deadline != null && args[0] != '/bin/kill') args = ['/usr/bin/timeout', '-s', 'TERM', '' + budget(300), ...args];
    let proc = fs.popen(join(' ', map(args, q)) + ' 9>&- 2>/dev/null', 'r');
    if (!proc) die('process_failed');
    let out = proc.read('all') ?? '', code = proc.close();
    return { out, code };
}
function must(args, code) { let r = run(args); if (r.code) die(code); return r.out; }
function load(path, fallback) {
    let text = fs.readfile(path, 2097153);
    if (text == null) return fallback;
    if (length(text) > 2097152) die('body_too_large');
    try { return json(text); } catch (e) { die('invalid_state'); }
}
function save(path, value) {
    let tmp = path + '.new';
    if (fs.writefile(tmp, sprintf('%J', value)) == null || !fs.chmod(tmp, 0600) || !fs.rename(tmp, path)) die('state_write_failed');
}
function hash(text) {
    if (fs.writefile(JOB + '/hash', text) == null) die('state_write_failed');
    return substr(must(['/usr/bin/sha256sum', JOB + '/hash'], 'hash_failed'), 0, 64);
}
function filehash(path) { return substr(must(['/usr/bin/sha256sum', path], 'hash_failed'), 0, 64); }
function atomic_copy(source, target) {
    let data = fs.readfile(source);
    if (data == null || fs.writefile(target + '.podkop-tools-new', data) == null ||
        !fs.chmod(target + '.podkop-tools-new', 0600) || !fs.rename(target + '.podkop-tools-new', target)) die('apply_failed');
}
function cfg(key, fallback) { return ctx.get('podkop_tools', 'main', key) ?? fallback; }
function priorities() { let p=ctx.get('podkop_tools','main','priority_ids') ?? []; return type(p)=='array'?p:[p]; }
function owns_ag(config) { let marker = config.get('podkop', 'antigravity', 'subscription_node_id'); return type(marker) == 'string' && length(marker) > 0; }
function number(key, fallback, min, max) {
    let n = int(cfg(key, '' + fallback));
    if (n == null || n < min || n > max) die('invalid_settings');
    return n;
}
function runtime() { if (runtime_cache) return runtime_cache; let r = load('/etc/sing-box/config.json'); if (!r) die('runtime_unavailable'); runtime_cache = r; return r; }
function status_update(values) {
    let status = load(TMP + '/status.json', {});
    for (let k, v in values) status[k] = v;
    save(TMP + '/status.json', status);
}
function curl_escape(v) { return '"' + replace(replace('' + v, /\\/g, '\\\\'), /"/g, '\\"') + '"'; }
function check_url(url) {
    if (type(url) != 'string' || !match(url, /^https:\/\/[^@\/]+\//) || match(url, /[[:space:][:cntrl:]]/)) die('invalid_url');
}
function curl_request(url, proxy, output, seconds, cap, method, payload, secret) {
    check_url(url);
    let content = 'url = ' + curl_escape(url) + '\n';
    if (proxy) content += 'proxy = ' + curl_escape(proxy) + '\nnoproxy = ""\n';
    else content += 'noproxy = "*"\n';
    if (method) content += 'request = ' + curl_escape(method) + '\n';
    if (payload) content += 'data = ' + curl_escape(payload) + '\nheader = "Content-Type: application/json"\n';
    if (secret) content += 'header = ' + curl_escape('Authorization: Bearer ' + secret) + '\n';
    fs.writefile(JOB + '/curl.cfg', content); fs.chmod(JOB + '/curl.cfg', 0600);
    let r = run(['/usr/bin/curl', '--disable', '--proto', '=https', '--proto-redir', '=https', '--max-redirs', '0', '--config', JOB + '/curl.cfg', '--silent', '--connect-timeout', '3', '--max-time', '' + budget(seconds, 0.2),
        '--max-filesize', '' + cap, '--output', output, '--write-out', '%{json}', '--header', 'Accept-Encoding: identity']);
    let metrics = {};
    try { metrics = json(r.out); } catch (e) { }
    fs.unlink(JOB + '/curl.cfg');
    return { code: r.code, metrics };
}
function api(path, method, payload, probe) {
    let api = runtime().experimental?.clash_api;
    let address = api?.external_controller;
    if (!match(address ?? '', /^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$/)) die('api_unavailable');
    if (index(address, '0.0.0.0:') == 0) address = replace(address, '0.0.0.0:', '127.0.0.1:');
    let secret = api.secret ?? '';
    if (match(secret, /[\r\n]/)) die('api_unavailable');
    let content = 'url = ' + curl_escape('http://' + address + path) + '\nnoproxy = "*"\nheader = ' + curl_escape('Authorization: Bearer ' + secret) + '\n';
    if (method) content += 'request = ' + curl_escape(method) + '\n';
    if (payload) content += 'data = ' + curl_escape(sprintf('%J', payload)) + '\nheader = "Content-Type: application/json"\n';
    let config_file = ARGV[0] == 'status' ? TMP + '/api-status-' + split(fs.readfile('/proc/self/stat'), ' ')[0] : JOB + '/api.cfg';
    fs.writefile(config_file, content); fs.chmod(config_file, 0600);
    let args = ['/usr/bin/curl', '--disable', probe ? '-sS' : '-fsS', '--config', config_file, '--connect-timeout', '2', '--max-time', '' + budget(probe ? 6 : 8, 0.2), '--max-filesize', '262144'];
    if (probe) args = [...args, '--write-out', '\n%{http_code}'];
    let result = run(args);
    fs.unlink(config_file);
    if (result.code) die('api_unavailable');
    if (probe) {
        let parts = split(result.out, '\n'), code = int(pop(parts));
        if (code == 503 || code == 504) return { failed: true };
        if (code != 200) die('api_unavailable');
        result.out = join('\n', parts);
    }
    if (!length(result.out)) return {};
    try { return json(result.out); } catch (e) { die('api_unavailable'); }
}
function dependency(paths) {
    for (let path in paths) {
        let st = fs.stat(path);
        if (!st || st.type != 'file' || !(st.mode & 0111)) die('dependency_missing');
    }
}
function compatible() {
    // Selector consumers do not depend on the native generator or other sections.
    if (ctx.get('podkop', 'main', 'proxy_config_type') != 'selector' ||
        ctx.get('podkop', 'settings', 'config_path') != '/etc/sing-box/config.json' ||
        ctx.get('podkop', 'main', 'connection_type') != 'proxy') die('unsupported_main');
    let r = runtime(), selector = filter(r.outbounds ?? [], o => o.tag == 'main-out' && o.type == 'selector');
    if (length(selector) != 1 || r.route?.final != 'direct-out') die('unsupported_runtime');
    let group = api('/proxies/main-out');
    if (group.type != 'Selector' || type(group.all) != 'array' || !length(group.all) ||
        index(group.all, group.now) < 0 || canonical(group.all) != canonical(selector[0].outbounds)) die('unsupported_runtime');
}
function measurement_requirements() {
    let st = fs.stat('/usr/bin/sing-box');
    if (!st || !(st.mode & 0111)) die('sing_box_unavailable');
    dependency(['/usr/bin/curl', '/usr/bin/timeout']);
}
function generation_requirements() {
    if (owns_ag(ctx) && (ctx.get('podkop', 'antigravity', 'connection_type') != 'proxy' ||
        index(['outbound', 'selector'], ctx.get('podkop', 'antigravity', 'proxy_config_type')) < 0 ||
        !match(ctx.get('podkop', 'antigravity', 'subscription_node_id') ?? '', /^[a-f0-9]{64}$/))) die('unsupported_main');
    if (ctx.get('podkop', 'main', 'proxy_config_type') != 'selector' ||
        ctx.get('podkop', 'main', 'connection_type') != 'proxy' ||
        ctx.get('podkop', 'settings', 'config_path') != '/etc/sing-box/config.json') die('unsupported_main');
    if (run(['/usr/libexec/podkop-tools/generate', '--check']).code) die('generator_unavailable');
    measurement_requirements();
}
function require_operation(name) {
    if (name == 'source') return;
    if (name == 'fetch' || name == 'check') { dependency(['/usr/bin/curl', '/usr/bin/sha256sum']); return; }
    if (name == 'rollback') {
        generation_requirements(); dependency(['/etc/init.d/podkop', '/usr/bin/timeout', '/usr/bin/dig']);
        if (!fs.stat(BASE + '/rollback/podkop')) die('rollback_unavailable');
        return;
    }
    compatible();
    if (name == 'health') dependency(['/usr/bin/timeout']);
    if (index(['apply', 'due'], name) >= 0) {
        generation_requirements(); dependency(['/etc/init.d/podkop', '/usr/bin/timeout', '/usr/bin/dig']);
    } else if (index(['speed', 'latency', 'service', 'batch', 'recovery'], name) >= 0) measurement_requirements();
}
function failure_reason(fn) {
    try { fn(); return null; } catch (e) {
        return index(['unsupported_main', 'unsupported_runtime', 'api_unavailable', 'runtime_unavailable',
            'dependency_missing', 'sing_box_unavailable', 'generator_unavailable', 'rollback_unavailable'], e.message) >= 0 ? e.message : 'operation_failed';
    }
}
function detected_versions() {
    // Read metadata; do not execute Podkop just to discover its version.
    let release = fs.readfile('/etc/openwrt_release') ?? '';
    let constants = fs.readfile('/usr/lib/podkop/constants.sh') ?? '';
    let binary = run(['/usr/bin/sing-box', 'version']);
    return {
        openwrt: match(release, /DISTRIB_RELEASE=['"]?([0-9A-Za-z._+-]+)/)?.[1] ?? null,
        podkop: match(constants, /PODKOP_VERSION=['"]?([0-9]+\.[0-9]+\.[0-9A-Za-z._+-]+)/)?.[1] ?? null,
        sing_box: match(binary.out, /^sing-box version ([0-9A-Za-z._+-]+)/)?.[1] ?? null
    };
}
function compatibility_status() {
    let selector = failure_reason(compatible);
    let facts = {
        fetch: failure_reason(() => require_operation('fetch')), selector,
        monitoring: failure_reason(() => dependency(['/usr/bin/timeout'])),
        measurement: failure_reason(measurement_requirements),
        generation: failure_reason(generation_requirements),
        reload: failure_reason(() => dependency(['/etc/init.d/podkop', '/usr/bin/timeout', '/usr/bin/dig'])),
        backup: fs.stat(BASE + '/rollback/podkop') ? null : 'rollback_unavailable'
    };
    let report = compatibility_report(facts, detected_versions());
    if (fs.stat(BASE + '/transaction.json')) {
        for (let name in ['selector', 'monitoring', 'switch', 'apply', 'recovery', 'measurement'])
            report.capabilities[name] = { available: false, reason: 'recovery_required' };
    }
    return report;
}
// Ownership is the ordered MAIN server list, never unrelated routing/DNS options.
function server_uri(value) {
    // Stock Podkop decodes the whole URI first. Query order and fragment encoding
    // do not alter server ownership; unknown parameters remain in the signature.
    if (type(value) != 'string') die('state_conflict');
    let decoded = decode(value), fragment = split(decoded, '#'), parts = split(fragment[0], '?');
    if (length(parts) > 2 || !match(parts[0], /^vless:\/\//)) die('state_conflict');
    let query = { encryption: 'none', type: 'tcp', security: 'none' };
    for (let pair in split(parts[1] ?? '', '&')) {
        if (!length(pair)) continue;
        let kv = split(pair, '='); if (length(kv) != 2 || !length(kv[0])) die('state_conflict');
        query[kv[0]] = kv[1];
    }
    return { peer: parts[0], query, name: length(fragment) > 1 ? substr(decoded, index(decoded, '#') + 1) : 'Server' };
}
function antigravity_node(config, nodes) {
    if (!owns_ag(config)) return null;
    let id = config.get('podkop', 'antigravity', 'subscription_node_id');
    let found = filter(nodes, n => n.id == id);
    if (length(found) != 1) die('antigravity_node_missing');
    return found[0];
}
function sync_antigravity(config, nodes, selected) {
    if (!owns_ag(config)) return;
    let id = selected ?? config.get('podkop', 'antigravity', 'subscription_node_id');
    if (!length(filter(nodes, n => n.id == id))) id = nodes[0]?.id;
    if (!id || !config.set('podkop', 'antigravity', 'proxy_config_type', 'selector') ||
        !config.set('podkop', 'antigravity', 'subscription_node_id', id) ||
        !config.set('podkop', 'antigravity', 'selector_proxy_links', map(nodes, proxy_uri))) die('staging_failed');
    config.delete('podkop', 'antigravity', 'outbound_json');
}
function antigravity_signature(config) {
    if (!owns_ag(config)) return null;
    let kind = config.get('podkop', 'antigravity', 'proxy_config_type'), profile;
    if (index(['outbound', 'selector'], kind) < 0) die('state_conflict');
    if (kind == 'selector') profile = map(config.get('podkop', 'antigravity', 'selector_proxy_links') ?? [], server_uri);
    else try { profile = json(config.get('podkop', 'antigravity', 'outbound_json') ?? ''); } catch (e) { die('state_conflict'); }
    // Preserve legacy outbound transaction signatures across package upgrades;
    // selector arrays and outbound objects already distinguish the two modes.
    return hash(canonical({ id: config.get('podkop', 'antigravity', 'subscription_node_id'), profile }));
}
function verify_antigravity(config, nodes, generated, error) {
    if (!owns_ag(config)) return;
    let owned_tags = ['antigravity-out'];
    if (config.get('podkop', 'antigravity', 'proxy_config_type') == 'selector')
        owned_tags = [...owned_tags, ...map(nodes, (n, i) => sprintf('antigravity-%d-out', i + 1))];
    let actual = filter(generated.outbounds, o => index(owned_tags, o.tag) >= 0);
    if (config.get('podkop', 'antigravity', 'proxy_config_type') == 'selector') {
        let tags = map(nodes, (n, i) => sprintf('antigravity-%d-out', i + 1));
        let links = config.get('podkop', 'antigravity', 'selector_proxy_links') ?? [];
        if (canonical(map(links, server_uri)) != canonical(map(map(nodes, proxy_uri), server_uri)) ||
            length(actual) != length(nodes) + 1) die(error);
        let group = filter(actual, o => o.tag == 'antigravity-out')[0];
        if (group?.type != 'selector' || canonical(group.outbounds) != canonical(tags)) die(error);
        for (let i = 0; i < length(nodes); i++) {
            let expected = json(sprintf('%J', nodes[i].outbound)); expected.tag = tags[i];
            if (canonical(filter(actual, o => o.tag == tags[i])[0]) != canonical(expected)) die(error);
        }
        return;
    }
    let node = antigravity_node(config, nodes);
    let configured;
    try { configured = json(config.get('podkop', 'antigravity', 'outbound_json') ?? ''); } catch (e) { die(error); }
    let expected = json(sprintf('%J', node.outbound)); expected.tag = 'antigravity-out';
    if (canonical(configured) != canonical(node.outbound) || length(actual) != 1 || canonical(actual[0]) != canonical(expected)) die(error);
}
function antigravity_selection(nodes) {
    let config = cursor();
    if (!owns_ag(config)) return null;
    if (config.get('podkop', 'antigravity', 'proxy_config_type') == 'outbound') return antigravity_node(config, nodes).id;
    let group = api('/proxies/antigravity-out');
    if (canonical(group.all) != canonical(map(nodes, (n, i) => sprintf('antigravity-%d-out', i + 1)))) die('state_conflict');
    let selected = nodes[index(group.all, group.now)]?.id;
    if (!selected) die('state_conflict');
    return selected;
}
function remember_antigravity(id, reason) {
    if (!id) return;
    let old = load(BASE + '/antigravity-selection.json', {}), boot = trim(fs.readfile('/proc/sys/kernel/random/boot_id'));
    let current = { selected_id: id, boot, reason: reason ?? (old.selected_id == id ? old.reason : 'external') ?? 'migrated' };
    if (canonical(current) != canonical(old)) save(BASE + '/antigravity-selection.json', current);
}
function select_antigravity(nodes, id, reason) {
    if (!id || !owns_ag(cursor())) return;
    let position = index(map(nodes, n => n.id), id);
    if (position < 0) die('antigravity_node_missing');
    let tag = sprintf('antigravity-%d-out', position + 1);
    api('/proxies/antigravity-out', 'PUT', { name: tag });
    if (api('/proxies/antigravity-out').now != tag) die('selection_failed');
    remember_antigravity(id, reason);
}
function restore_antigravity(state) {
    if (!owns_ag(cursor()) || cursor().get('podkop', 'antigravity', 'proxy_config_type') != 'selector') return;
    let saved = load(BASE + '/antigravity-selection.json'), boot = trim(fs.readfile('/proc/sys/kernel/random/boot_id'));
    if (saved && saved.boot != boot && length(filter(state.nodes, n => n.id == saved.selected_id)))
        select_antigravity(state.nodes, saved.selected_id, saved.reason);
    else remember_antigravity(antigravity_selection(state.nodes));
}
function main_profiles(config) { return sections.main_profiles(config); }
function managed_configuration(nodes) {
    let fresh = cursor('/etc/config', JOB + '/read-delta', '');
    return { connection_type: fresh.get('podkop', 'main', 'connection_type'),
        proxy_config_type: fresh.get('podkop', 'main', 'proxy_config_type'),
        selector_proxy_links: map(nodes ? map(nodes, proxy_uri) : (fresh.get('podkop', 'main', 'selector_proxy_links') ?? []), server_uri) };
}
function state_digest(state) {
    let value = json(sprintf('%J', state)); delete value.state_hash;
    return hash(canonical(value));
}
function seal_state(state) {
    state.schema_version = 2;
    state.managed_hash = hash(canonical(managed_configuration(state.nodes)));
    state.state_hash = state_digest(state);
}
function save_state(path, state) {
    seal_state(state);
    save(path, state);
}
function validate_state(state) {
    if (type(state?.nodes) != 'array' || !length(state.nodes) || length(state.nodes) > 128) die('state_conflict');
    let ids = {};
    for (let n in state.nodes) {
        if (!match(n.id ?? '', /^[a-f0-9]{64}$/) || ids[n.id] || type(n.name) != 'string' || n.outbound?.type != 'vless') die('state_conflict');
        ids[n.id] = true;
    }
    if (!ids[state.selected_id]) die('state_conflict');
    if (state.schema_version == 2 && (state.state_hash != state_digest(state) ||
        state.managed_hash != hash(canonical(managed_configuration(state.nodes))))) die('state_conflict');
    else if (state.schema_version != 2 && (state.schema_version != null || state.managed_hash != null || state.state_hash != null)) die('state_conflict');
}
function server_selection(state) {
    validate_state(state);
    let live = managed_configuration(), expected = managed_configuration(state.nodes);
    if (live.connection_type != 'proxy' || live.proxy_config_type != 'selector' || canonical(live) != canonical(expected)) die('state_conflict');
    let group = api('/proxies/main-out'), r = runtime();
    if (canonical(group.all) != canonical(map(state.nodes, (n, i) => sprintf('main-%d-out', i + 1)))) die('state_conflict');
    verify_antigravity(cursor(), state.nodes, r, 'state_conflict');
    let actual = main_profiles(r);
    if (length(actual) != length(state.nodes)) die('state_conflict');
    for (let i = 0; i < length(state.nodes); i++) {
        let o = filter(actual, x => x.tag == group.all[i])[0];
        if (!o) die('state_conflict');
        o = json(sprintf('%J', o)); delete o.tag;
        if (canonical(o) != canonical(state.nodes[i].outbound)) die('state_conflict');
    }
    let node = state.nodes[index(group.all, group.now)];
    if (!node) die('state_conflict');
    return node.id;
}
function state_seed() {
    compatible();
    let state = load(BASE + '/state.json');
    if (state) return state;
    let r = runtime(), group = api('/proxies/main-out'), nodes = [], links = ctx.get('podkop', 'main', 'selector_proxy_links');
    if (type(links) != 'array' || length(links) != length(group.all)) die('state_conflict');
    for (let i = 0; i < length(group.all); i++) {
        let out = filter(r.outbounds, o => o.tag == group.all[i])[0];
        if (out?.type != 'vless') die('unsupported_main');
        out = json(sprintf('%J', out)); delete out.tag;
        let name = decode(split(links[i], '#')[1] ?? 'Server');
        push(nodes, { id: hash(canonical(out)), name, outbound: out });
    }
    let chosen = nodes[index(group.all, group.now)]?.id;
    if (!chosen) die('state_conflict');
    state = { nodes, selected_id: chosen, podkop_hash: filehash('/etc/config/podkop'), last_apply: 0 };
    save_state(BASE + '/state.json', state);
    return state;
}
function actual_selection(state) {
    if (state.schema_version != 2 && filehash('/etc/config/podkop') != state.podkop_hash) die('state_conflict');
    return server_selection(state);
}
function migrate_state() {
    if (fs.stat(BASE + '/transaction.json')) die('recovery_required');
    let state = load(BASE + '/state.json');
    if (state?.schema_version == 2) { actual_selection(state); return; }
    server_selection(state);
    let before = filehash('/etc/config/podkop');
    if (before != state.podkop_hash) {
        // Prove the last accepted bytes from its checked predecessor. Never bless current MAIN.
        if (run(['/usr/bin/sha256sum', '-c', BASE + '/rollback/SHA256SUMS']).code) die('state_conflict');
        must(['/bin/mkdir', '-p', JOB + '/migration', JOB + '/migration-delta'], 'staging_failed');
        must(['/bin/cp', BASE + '/rollback/podkop', JOB + '/migration/podkop'], 'staging_failed');
        let staged = cursor(JOB + '/migration', JOB + '/migration-delta', '');
        staged.set('podkop', 'main', 'selector_proxy_links', map(state.nodes, proxy_uri));
        staged.set('podkop', 'settings', 'config_path', JOB + '/generated.json'); staged.commit('podkop');
        staged.set('podkop', 'settings', 'config_path', '/etc/sing-box/config.json'); staged.commit('podkop');
        if (filehash(JOB + '/migration/podkop') != state.podkop_hash) die('state_conflict');
    }
    let selected = server_selection(state);
    if (before != filehash('/etc/config/podkop') || server_selection(state) != selected) die('uci_changed');
    must(['/bin/cp', BASE + '/state.json', BASE + '/state.v1.backup.json'], 'backup_failed');
    save_state(BASE + '/state.json', state);
    status_update({ state: 'state_migrated', error: null, fetch_error: null, last_apply_error: null });
}
// libuci uses flock on the config inode. Keep that inode for queued commit readers,
// and CAS the complete staged snapshot while holding the same native lock.
function write_main(source, expected) {
    if (length(fs.readfile('/tmp/.uci/podkop') ?? '')) die('uci_changed');
    let file = fs.open('/etc/config/podkop', 'r+');
    if (!file || !file.lock('xn')) { if (file) file.close(); die('uci_busy'); }
    try {
        let fdstat = fs.stat('/proc/self/fd/' + file.fileno()), pathstat = fs.stat('/etc/config/podkop');
        if (fdstat.inode != pathstat.inode || canonical(fdstat.dev) != canonical(pathstat.dev) || filehash('/etc/config/podkop') != expected ||
            length(fs.readfile('/tmp/.uci/podkop') ?? '')) die('uci_changed');
        let data = fs.readfile(source);
        if (data == null || file.seek(0) == null || file.write(data) != length(data) || !file.flush() || !file.truncate(length(data))) die('apply_failed');
        must(['/bin/sync'], 'apply_failed');
        if (filehash('/etc/config/podkop') != filehash(source)) die('uci_changed_after_write');
    } catch (e) { file.close(); die(e.message); }
    file.close();
}
function probe_port_open(port) {
    let address = sprintf(':%04X', port);
    for (let line in split(fs.readfile('/proc/net/tcp') ?? '', '\n')) {
        let fields = split(trim(line), /[[:space:]]+/);
        if (fields[3] == '0A' && substr(fields[1] ?? '', -5) == address) return true;
    }
    return false;
}
function stop_probe() {
    if (probe_pid) {
        // Only our deadline process; timeout forwards TERM to its own child.
        run(['/bin/kill', '-TERM', '' + probe_pid]); probe_pid = null;
        for (let i = 0; i < 80; i++) {
            if (!probe_port_open(16902)) break;
            sleep(25);
        }
    }
}
function start_probe_set(outbounds) {
    stop_probe();
    for (let i = 0; i < length(outbounds); i++) if (probe_port_open(16902 + i)) die('probe_start_failed');
    let bootstrap = cfg('bootstrap_dns', '77.88.8.8');
    if (!match(bootstrap, /^([0-9]{1,3}\.){3}[0-9]{1,3}$/)) die('invalid_settings');
    let outputs = [], inbounds = [], rules = [];
    for (let i = 0; i < length(outbounds); i++) {
        let out = json(sprintf('%J', outbounds[i]));
        if (out.detour || (out.type != 'vless' && !(length(outbounds) == 1 && out.type == 'direct'))) die('invalid_settings');
        out.tag = 'probe-out-' + i; out.routing_mark = 2097152;
        push(outputs, out);
        push(inbounds, { type: 'mixed', tag: 'probe-in-' + i, listen: '127.0.0.1', listen_port: 16902 + i });
        push(rules, { inbound: ['probe-in-' + i], action: 'route', outbound: out.tag });
    }
    let config = { log: { disabled: true }, dns: { servers: [{ type: 'udp', tag: 'bootstrap', server: bootstrap, server_port: number('bootstrap_port', 53, 1, 65535) }], final: 'bootstrap' },
        inbounds, outbounds: outputs, route: { rules, final: outputs[0].tag, default_domain_resolver: 'bootstrap' } };
    save(JOB + '/probe.json', config);
    must(['/usr/bin/sing-box', 'check', '-c', JOB + '/probe.json'], 'validation_failed');
    let result = run(['/bin/sh', '-c', 'timeout -s TERM 240 /usr/bin/sing-box run -c /tmp/podkop-tools/job/probe.json >/dev/null 2>&1 & echo $!']);
    probe_pid = int(trim(result.out));
    if (!probe_pid || probe_pid < 2) die('probe_start_failed');
    fs.writefile(JOB + '/probe.pid', '' + probe_pid);
    for (let i = 0; i < 160; i++) {
        budget(5, 0.5);
        if (probe_port_open(16902 + length(outbounds) - 1)) return 'http://127.0.0.1:16902';
        if (!fs.stat('/proc/' + probe_pid)) die('probe_start_failed');
        sleep(25);
    }
    die('probe_start_failed');
}
function start_probe(outbound) { return start_probe_set([outbound]); }
function get_through(outbound, url, file, seconds, cap) {
    let proxy = start_probe(outbound);
    let result = curl_request(url, proxy, file, seconds, cap);
    stop_probe();
    return result;
}
function health(node) {
    // This is control-endpoint reachability, never an application-health verdict.
    try {
        let endpoint = cfg('health_url', 'https://www.gstatic.com/generate_204');
        let result = get_through(node.outbound, endpoint, '/dev/null', 5, 65536);
        return result.code == 0 && +result.metrics.http_code == 204;
    } catch (e) { stop_probe(); return false; }
}
function healthy_fallback(nodes, chosen) {
    let meta=load(BASE+'/selection.json',{});
    let order=filter(priority_order(nodes,meta.preferred_id,priorities()),n=>n.id!=chosen);
    let deadline = time() + 90;
    for (let node in order) {
        if (time() >= deadline) break;
        if (health(node)) return node.id;
    }
    return null;
}
function pending_fresh(pending) {
    let age = number('pending_max_age_hours', 12, 1, 72) * 3600;
    return pending?.verified_at > 0 && pending.verified_at <= time() && time() - pending.verified_at < age;
}
function expire_pending() {
    let pending = load(BASE + '/pending.json');
    if (pending?.verified_at) {
        validate_state({ nodes: pending.nodes, selected_id: pending.selected_id });
        let signature = {}; for (let n in pending.nodes) signature[n.id] = { name: n.name, outbound: n.outbound };
        if (pending.source_hash != hash(canonical(signature))) die('state_conflict');
    }
    // Retain only history across expiration, never unverified endpoint eligibility.
    if (pending && !fs.stat(BASE + '/change-series.json')) {
        let started = pending.series_started_at ?? pending.first_seen;
        save(BASE + '/change-series.json', { started_at: started > 0 && started <= time() ? started : time() });
    }
    if (pending && !pending_fresh(pending)) {
        if (!pending.verified_at && !fs.stat(BASE + '/legacy-pending.json')) save(BASE + '/legacy-pending.json', pending);
        fs.unlink(BASE + '/pending.json');
        status_update({ state: 'pending_expired', pending: false });
        return null;
    }
    return pending;
}
function candidate_snapshot(state, nodes, selected, verified_at, skipped) {
    let fallback = filter(nodes, n => n.id == cfg('fallback_id', ''))[0]?.id ?? nodes[0]?.id;
    // Candidate planning never switches MAIN or verifies a recovery choice.
    let candidate = plan(state.nodes, nodes, selected, hash, fallback), signature = {};
    candidate.antigravity_migration = owns_ag(ctx) && ctx.get('podkop', 'antigravity', 'proxy_config_type') == 'outbound';
    if (candidate.antigravity_migration) candidate.runtime_changed = true;
    for (let n in nodes) signature[n.id] = { name: n.name, outbound: n.outbound };
    candidate.source_hash = hash(canonical(signature));
    let previous = expire_pending();
    candidate.first_seen = previous?.source_hash == candidate.source_hash ? previous.first_seen : time();
    candidate.version_at = candidate.first_seen;
    let series = load(BASE + '/change-series.json');
    candidate.series_started_at = series?.started_at > 0 && series.started_at <= time() ? series.started_at : time();
    candidate.verified_at = verified_at;
    candidate.before_selected = selected; candidate.skipped = skipped ?? [];
    return candidate;
}
function independent_uci(config) {
    let value = config.get_all('podkop');
    if (value.main) delete value.main.selector_proxy_links;
    if (value.settings) delete value.settings.config_path;
    if (owns_ag(config) && value.antigravity) {
        for (let key in ['proxy_config_type', 'selector_proxy_links', 'outbound_json', 'subscription_node_id']) delete value.antigravity[key];
    }
    return canonical(value);
}
function native_generation() {
    must(['/usr/libexec/podkop-tools/generate'], 'generation_failed');
    must(['/usr/bin/sing-box', 'check', '-c', JOB + '/generated.json'], 'validation_failed');
    let generated = load(JOB + '/generated.json');
    sections.validate_tags(generated);
    return generated;
}
function independent_snapshot(generated, config) { return sections.independent_snapshot(generated, owns_ag(config), filehash); }
function validate_generated_routes(generated, nodes) {
    sections.validate_tags(generated);
    let selectors = filter(generated.outbounds ?? [], o => o.tag == 'main-out');
    if (generated.route?.final != 'direct-out' || length(selectors) != 1 || selectors[0].type != 'selector' ||
        canonical(selectors[0].outbounds) != canonical(map(nodes, (n, i) => sprintf('main-%d-out', i + 1))) ||
        !length(filter(generated.outbounds ?? [], o => o.tag == 'direct-out' && o.type == 'direct'))) die('routing_changed');
}
function stage(candidate) {
    generation_requirements();
    candidate.staged_from = filehash('/etc/config/podkop');
    let previous = state_seed();
    candidate.antigravity_before_id = antigravity_selection(previous.nodes);
    candidate.antigravity_selected_id = candidate.antigravity_before_id;
    let saved = load(BASE + '/antigravity-selection.json', {});
    candidate.antigravity_reason = saved.selected_id == candidate.antigravity_before_id ? saved.reason : 'external';
    if (candidate.antigravity_selected_id && !length(filter(candidate.nodes, n => n.id == candidate.antigravity_selected_id))) {
        let main = candidate.before_selected ?? previous.selected_id;
        candidate.antigravity_selected_id = filter(candidate.nodes, n => n.id == main)[0]?.id ?? candidate.nodes[0]?.id;
        candidate.antigravity_reason = 'node_removed';
    }
    if (owns_ag(cursor()) && cursor().get('podkop', 'antigravity', 'proxy_config_type') == 'outbound') {
        candidate.runtime_changed = true;
        if (candidate.antigravity_reason != 'node_removed') candidate.antigravity_reason = 'migrated';
    }

    must(['/bin/cp', '/etc/config/podkop', JOB + '/uci/podkop'], 'staging_failed');
    let staged = cursor(JOB + '/uci', JOB + '/delta', '');
    let independent = independent_uci(staged);
    // Generate the current native UCI first, so valid new independent settings
    // are accepted even before their next native reload.
    staged.set('podkop', 'settings', 'config_path', JOB + '/generated.json'); staged.commit('podkop');
    let baseline = independent_snapshot(native_generation(), staged);
    sync_antigravity(staged, candidate.nodes, candidate.antigravity_selected_id);
    if (!staged.set('podkop', 'main', 'selector_proxy_links', map(candidate.nodes, proxy_uri)) ||
        !staged.set('podkop', 'settings', 'config_path', JOB + '/generated.json') || !staged.commit('podkop')) die('staging_failed');
    must(['/usr/libexec/podkop-tools/generate'], 'generation_failed');
    must(['/usr/bin/sing-box', 'check', '-c', JOB + '/generated.json'], 'validation_failed');
    let generated = load(JOB + '/generated.json');
    if (independent_uci(staged) != independent) die('routing_changed');
    sections.assert_preserved(baseline, independent_snapshot(generated, staged));
    candidate.independent_snapshot = independent_snapshot(generated, staged);
    validate_generated_routes(generated, candidate.nodes);
    verify_antigravity(staged, candidate.nodes, generated, 'generated_nodes_mismatch');
    let actual = main_profiles(generated);
    if (length(actual) != length(candidate.nodes)) die('generated_nodes_mismatch');
    for (let i = 0; i < length(actual); i++) {
        let expected = json(sprintf('%J', candidate.nodes[i].outbound)); expected.tag = sprintf('main-%d-out', i + 1);
        if (canonical(actual[i]) != canonical(expected)) die('generated_nodes_mismatch');
    }
    staged.set('podkop', 'settings', 'config_path', '/etc/sing-box/config.json'); staged.commit('podkop');
    if (filehash('/etc/config/podkop') != candidate.staged_from) die('uci_changed');
}
function accept_snapshot(state, nodes, selected, verified_at, skipped) {
    let candidate = candidate_snapshot(state, nodes, selected, verified_at, skipped);
    if (!candidate.runtime_changed && !candidate.labels_changed) {
        fs.unlink(BASE + '/pending.json');
        fs.unlink(BASE + '/change-series.json');
        status_update({ state: 'unchanged', pending: false });
        return;
    }
    stage(candidate);
    // Version age changes; the series clock survives revision churn and TTL expiry.
    if (!fs.stat(BASE + '/change-series.json')) save(BASE + '/change-series.json', { started_at: candidate.series_started_at });
    save(BASE + '/pending.json', candidate);
    status_update({ state: 'pending', pending: true, pending_since: candidate.first_seen });
}
function selection_state(state, boot) {
    let actual = actual_selection(state), old = load(BASE + '/selection.json', {});
    // Health may run before the finite boot job; never replace an old-boot
    // saved ID with the selector's cold-cache default before restoring it.
    restore_antigravity(state);
    if (old.intent?.profile && old.intent.profile != hash(canonical(filter(state.nodes,n=>n.id==old.intent.to)[0]?.outbound))) delete old.intent;
    let current = selection_event(old, actual, time(), boot);
    if (!old.preferred_id) {
        current.origin = boot ? 'boot_adopted_unknown' : 'migrated';
        current.version = 1;
        let fallback = cfg('fallback_id', '');
        if (fallback && !ctx.get('podkop_tools','main','priority_ids')) {
            ctx.set('podkop_tools','main','priority_ids',[fallback]); ctx.commit('podkop_tools');
        }
    }
    if (canonical(current) != canonical(old)) save(BASE + '/selection.json', current);
    // Adopt only a validated runtime choice. Keep the signed snapshot in sync
    // before health revalidates it; legacy migration remains a separate task.
    if (state.schema_version == 2 && state.selected_id != actual) {
        state.selected_id = actual;
        save_state(BASE + '/state.json', state);
    }
    return current;
}
function record_history(id, ok, delay, reason) {
    if (fs.stat(BASE + '/history.json.gz') && !fs.stat(TMP + '/history-ready')) return;
    try { history_record(id, time(), ok, delay, reason); } catch (e) { }
}
function select_node(state, id, reason) {
    require_operation('switch');
    let position = index(map(state.nodes, n => n.id), id);
    if (position < 0) die('unknown_node');
    let meta = load(BASE + '/selection.json', { preferred_id: state.selected_id, selected_id: state.selected_id, version: 1 });
    let from = meta.selected_id;
    if (reason == 'selected') { meta.preferred_id = id; meta.origin = 'manual'; }
    meta.intent = { from, to: id, reason, profile: hash(canonical(state.nodes[position].outbound)), at: time() }; save(BASE + '/selection.json', meta);
    api('/proxies/main-out', 'PUT', { name: sprintf('main-%d-out', position + 1) });
    if (api('/proxies/main-out').now != sprintf('main-%d-out', position + 1)) die('selection_failed');
    state.selected_id = id; save_state(BASE + '/state.json', state);
    meta = selection_event(meta, id, time()); meta.last_switch = time();
    meta.transitions = filter(meta.transitions ?? [], t => time() >= t && time()-t < 1800);
    if (from != id) { if (reason != 'outage' && reason != 'recovered_from_saved_snapshot' && reason != 'selected') push(meta.transitions, time()); record_history(id, null, null, 'switch_' + reason); }
    save(BASE + '/selection.json', meta);
    fs.unlink(TMP + '/health.json');
    fs.unlink(TMP + '/health-v2.json');
    fs.unlink(TMP + '/recovery-v2.json');
    status_update({ state: reason, selected_id: id, control: null });
}
function rollback() {
    require_operation('rollback');
    let backup = BASE + '/rollback', tx = load(BASE + '/transaction.json');
    if (!fs.stat(backup + '/podkop')) die('rollback_unavailable');
    if (run(['/usr/bin/sha256sum', '-c', backup + '/SHA256SUMS']).code) die('rollback_failed');
    let old = load(backup + '/state.json'), current = load(BASE + '/state.json');
    validate_state(old); validate_state(current);
    // A legacy interrupted transaction lacks a trustworthy post-write ownership record.
    if (tx && (tx.schema_version != 2 || !tx.after_managed || !tx.before_state)) die('recovery_conflict');
    let live = hash(canonical(managed_configuration()));
    if (tx) {
        if (filehash(backup + '/state.json') != tx.backup_state ||
            (live != tx.after_managed && live != tx.before_managed) ||
            (filehash(BASE + '/state.json') != tx.before_state && filehash(BASE + '/state.json') != tx.after_state &&
             filehash(BASE + '/state.json') != tx.rollback_state && filehash(BASE + '/state.json') != tx.rollback_previous_state)) die('recovery_conflict');
        let ag = antigravity_signature(cursor());
        if (ag != (tx.antigravity_before ?? null) && ag != (tx.antigravity_after ?? null) && ag != tx.antigravity_rollback) die('recovery_conflict');
    } else {
        if (live != current.managed_hash) die('state_conflict');
        actual_selection(current);
    }
    // Only undo managed servers; retain the latest independent UCI settings.
    let expected = filehash('/etc/config/podkop');
    must(['/bin/cp', '/etc/config/podkop', JOB + '/uci/podkop'], 'staging_failed');
    let staged = cursor(JOB + '/uci', JOB + '/delta', '');
    let independent = independent_uci(staged);
    let ag = load(backup + '/antigravity-selection.json');
    let ag_id = owns_ag(staged) ? (ag?.selected_id ?? staged.get('podkop', 'antigravity', 'subscription_node_id')) : null;
    if (owns_ag(staged) && !length(filter(old.nodes, n => n.id == ag_id))) die('recovery_conflict');
    sync_antigravity(staged, old.nodes, ag_id);
    staged.set('podkop', 'main', 'selector_proxy_links', map(old.nodes, proxy_uri));
    staged.set('podkop', 'settings', 'config_path', JOB + '/generated.json'); staged.commit('podkop');
    must(['/usr/libexec/podkop-tools/generate'], 'generation_failed');
    must(['/usr/bin/sing-box', 'check', '-c', JOB + '/generated.json'], 'validation_failed');
    let rollback_generated = load(JOB + '/generated.json');
    if (independent_uci(staged) != independent) die('routing_changed');
    let rollback_independent = independent_snapshot(rollback_generated, staged);
    validate_generated_routes(rollback_generated, old.nodes);
    verify_antigravity(staged, old.nodes, rollback_generated, 'generated_nodes_mismatch');
    let rollback_profiles = main_profiles(rollback_generated);
    if (length(rollback_profiles) != length(old.nodes)) die('generated_nodes_mismatch');
    for (let i = 0; i < length(old.nodes); i++) {
        let expected_node = { ...old.nodes[i].outbound, tag: sprintf('main-%d-out', i + 1) };
        if (canonical(rollback_profiles[i]) != canonical(expected_node)) die('generated_nodes_mismatch');
    }
    staged.set('podkop', 'settings', 'config_path', '/etc/sing-box/config.json'); staged.commit('podkop');
    if (tx) { tx.antigravity_rollback = antigravity_signature(staged); save(BASE + '/transaction.json', tx); }
    write_main(JOB + '/uci/podkop', expected);
    runtime_cache = null;
    must(['/usr/bin/timeout', '-s', 'TERM', '120', '/etc/init.d/podkop', 'reload'], 'rollback_failed');
    for (let i = 0; i < 30; i++) {
        try {
            old.podkop_hash = filehash('/etc/config/podkop');
            if (tx) {
                tx.rollback_previous_state = filehash(BASE + '/state.json');
                seal_state(old); tx.rollback_state = hash(sprintf('%J', old));
                save(BASE + '/transaction.json', tx);
            }
            if (owns_ag(staged)) select_antigravity(old.nodes, ag_id, ag?.reason ?? 'rolled_back');
            select_node(old, old.selected_id, 'rolled_back');
            if (actual_selection(old) != old.selected_id ||
                run(['/usr/bin/dig', '+short', '+time=3', '+tries=1', '@127.0.0.42', 'openwrt.org', 'A']).out == '') die('rollback_failed');
            sections.assert_preserved(rollback_independent, independent_snapshot(runtime(), cursor()));
            return;
        } catch (e) { run(['/bin/sleep', '2']); }
    }
    die('rollback_failed');
}
function apply_candidate(candidate, urgent, selection_reason) {
    require_operation('apply');
    let accepted_from = filehash(BASE + '/state.json');
    let state = state_seed(), selected = actual_selection(state);
    if (selected != candidate.before_selected) die('selection_changed');
    restore_antigravity(state);
    stage(candidate);
    if (filehash('/etc/config/podkop') != candidate.staged_from) die('uci_changed');
    if (actual_selection(state) != selected) die('state_conflict');
    if (antigravity_selection(state.nodes) != candidate.antigravity_before_id) die('selection_changed');
    let chosen = filter(candidate.nodes, n => n.id == candidate.selected_id)[0];
    if (!chosen || !health(chosen)) die('selected_endpoint_unreachable');
    if (actual_selection(state) != selected) die('selection_changed');
    if (antigravity_selection(state.nodes) != candidate.antigravity_before_id) die('selection_changed');
    if (filehash(BASE + '/state.json') != accepted_from) die('state_conflict');
    must(['/bin/mkdir', '-p', BASE + '/rollback'], 'backup_failed');
    for (let file in ['podkop', 'dhcp', 'sing-box']) must(['/bin/cp', '/etc/config/' + file, BASE + '/rollback/' + file], 'backup_failed');
    state.selected_id = selected; save_state(BASE + '/rollback/state.json', state);
    remember_antigravity(candidate.antigravity_before_id);
    save(BASE + '/rollback/antigravity-selection.json', candidate.antigravity_before_id ? load(BASE + '/antigravity-selection.json') : null);
    let checksums = '';
    for (let file in ['podkop', 'dhcp', 'sing-box', 'state.json', 'antigravity-selection.json']) checksums += filehash(BASE + '/rollback/' + file) + '  ' + BASE + '/rollback/' + file + '\n';
    fs.writefile(BASE + '/rollback/SHA256SUMS', checksums); fs.chmod(BASE + '/rollback/SHA256SUMS', 0600);
    // A durable marker makes the next boot/task restore an interrupted apply.
    let transaction = { schema_version: 2, started: time(), before_state: filehash(BASE + '/state.json'), before_managed: state.managed_hash, after_managed: hash(canonical(managed_configuration(candidate.nodes))), before_main: candidate.staged_from, after_main: filehash(JOB + '/uci/podkop') };
    transaction.antigravity_before = antigravity_signature(cursor());
    transaction.antigravity_after = antigravity_signature(cursor(JOB + '/uci', JOB + '/delta', ''));
    // Backup state must be the exact pre-write accepted snapshot.
    transaction.backup_state = filehash(BASE + '/rollback/state.json');
    save(BASE + '/transaction.json', transaction);
    try {
        write_main(JOB + '/uci/podkop', candidate.staged_from);
        // Label-only changes are still explicit/deferred apply, but need no reload.
        if (candidate.runtime_changed) {
            runtime_cache = null;
            must(['/usr/bin/timeout', '-s', 'TERM', '120', '/etc/init.d/podkop', 'reload'], 'apply_failed');
        }
        let success = false;
        for (let i = 0; i < 30; i++) {
            try {
                let group = api('/proxies/main-out');
                if (length(group.all) == length(candidate.nodes) && canonical(filter(runtime().outbounds, o => o.type == 'vless')) == canonical(filter(load(JOB + '/generated.json').outbounds, o => o.type == 'vless'))) { success = true; break; }
            } catch (e) { }
            run(['/bin/sleep', '2']);
        }
        if (!success) die('apply_failed');
        state = { nodes: candidate.nodes, selected_id: candidate.selected_id, podkop_hash: filehash('/etc/config/podkop'), last_apply: time(), last_urgent: urgent ? time() : state.last_urgent, last_recovery: urgent ? time() : state.last_recovery };
        seal_state(state);
        transaction.after_state = hash(sprintf('%J', state)); save(BASE + '/transaction.json', transaction);
        save(BASE + '/state.json', state);
        select_antigravity(state.nodes, candidate.antigravity_selected_id, candidate.antigravity_reason);
        select_node(state, candidate.selected_id, selection_reason ?? (urgent ? 'recovered' : 'applied'));
        let live = runtime(), generated = load(JOB + '/generated.json');
        if (canonical(filter(live.outbounds, o => o.type == 'vless')) != canonical(filter(generated.outbounds, o => o.type == 'vless'))) die('apply_failed');
        actual_selection(state);
        sections.assert_preserved(candidate.independent_snapshot, independent_snapshot(live, cursor()));
        // Actual DNS service check; does not treat site HTTP200 as application success.
        if (run(['/usr/bin/dig', '+short', '+time=3', '+tries=1', '@127.0.0.42', 'openwrt.org', 'A']).out == '') die('dns_failed');
        if (!health(chosen)) die('selected_endpoint_unreachable');
        if (filehash(BASE + '/state.json') != transaction.after_state || actual_selection(state) != candidate.selected_id) die('state_conflict');
        fs.unlink(BASE + '/pending.json'); fs.unlink(BASE + '/transaction.json');
        if (!urgent) fs.unlink(BASE + '/change-series.json');
        status_update({ state: urgent ? 'recovered' : 'applied', last_apply: time(), pending: false });
    } catch (e) {
        if (index(['uci_changed', 'uci_busy'], e.message) >= 0 && filehash('/etc/config/podkop') != transaction.after_main) { fs.unlink(BASE + '/transaction.json'); die(e.message); }
        rollback(); fs.unlink(BASE + '/transaction.json'); die('apply_rolled_back');
    }
}
function fetch() {
    require_operation('fetch');
    expire_pending();
    let url = ctx.get('podkop_tools_subscription', 'main', 'url') ?? '';
    check_url(url);
    let saved = load(BASE + '/state.json', {});
    // Bootstrap optional fallback profiles from a working MAIN on first use.
    // Failure to inspect MAIN must never prohibit a direct/system download.
    if (!length(saved.nodes ?? [])) { try { saved = state_seed(); } catch (e) {} }
    let selected = saved.selected_id;
    let paths = [{ id: 'direct', outbound: { type: 'direct' } }];
    // Saved profiles are optional transport fallbacks, not fetch prerequisites.
    let alternatives = saved.nodes ?? [], last_path = load(TMP + '/fetch-path.json', ''), preferred = cfg('fallback_id', '');
    for (let wanted in [last_path, preferred]) {
        let node = filter(alternatives, n => n.id == wanted)[0];
        if (node && !length(filter(paths, n => n.id == wanted))) push(paths, node);
    }
    for (let n in alternatives) if (n.id != selected && !length(filter(paths, p => p.id == n.id))) push(paths, n);
    let active = filter(alternatives, n => n.id == selected)[0];
    if (active && !length(filter(paths, p => p.id == active.id))) push(paths, active);
    // Retain marked, bootstrap-resolved DIRECT first; ordinary curl is a last
    // fallback when no isolated sing-box transport is usable. It may follow
    // system DNS/routing, so report it separately rather than claiming DIRECT.
    push(paths, { id: 'system' });
    let parsed = null, used = null, started = time();
    for (let path in paths) {
        if (time() - started >= 40 || (execution_deadline != null && execution_deadline - monotime() < 2)) break;
        let response;
        try {
            response = path.id == 'system' ? curl_request(url, null, JOB + '/response', 8, 2097152) :
                get_through(path.outbound, url, JOB + '/response', 8, 2097152);
        } catch (e) { stop_probe(); continue; }
        if (response.code || +response.metrics.http_code != 200) continue;
        try { parsed = parse_provider(fs.readfile(JOB + '/response', 2097153) ?? ''); used = path.id; break; }
        catch (e) { }
    }
    fs.unlink(JOB + '/response');
    if (!parsed) die('subscription_unavailable_or_invalid');
    let verified_at = time(), incoming = parsed.nodes, stage_error = null;
    // A successful download survives an unavailable Selector/native generator.
    // This private snapshot is never an approved pending transaction.
    save(BASE + '/download.json', { nodes: incoming, verified_at, skipped: parsed.skipped });
    try {
        if (fs.stat(BASE + '/transaction.json')) die('recovery_required');
        let state = state_seed(); selected = actual_selection(state);
        incoming = reconcile(state.nodes, parsed.nodes, hash);
        accept_snapshot(state, incoming, selected, verified_at, parsed.skipped);
    } catch (e) {
        let safe = ['recovery_required', 'unsupported_main', 'unsupported_runtime', 'api_unavailable', 'runtime_unavailable', 'state_conflict',
            'generator_unavailable', 'dependency_missing', 'sing_box_unavailable', 'validation_failed', 'generation_failed',
            'generated_nodes_mismatch', 'routing_changed', 'uci_changed', 'antigravity_node_missing', 'unrepresentable_stock_uri'];
        stage_error = index(safe, e.message) >= 0 ? e.message : 'operation_failed';
        // Never allow an older staged candidate to masquerade as this download.
        fs.unlink(BASE + '/pending.json');
        status_update({ state: 'downloaded', pending: false });
    }
    save(TMP + '/fetch-path.json', used);
    status_update({ last_success: verified_at, downloaded_count: length(parsed.nodes), skipped: length(parsed.skipped),
        fetch_path: used == 'system' ? 'system' : used == 'direct' ? 'direct' : 'saved_server', error: null, fetch_error: null, fetch_stage_error: stage_error });
    return { nodes: incoming, verified_at, skipped: parsed.skipped };
}
function apply_pending(manual, approved_version) {
    let pending = expire_pending();
    let series = load(BASE + '/change-series.json');
    if (!pending && (!series || manual)) { status_update({ state: 'no_pending', apply_blocked_reason: null }); return; }
    if (manual && approved_version != pending.source_hash) die('pending_changed');
    let state = state_seed();
    let delay = number('defer_hours', 6, 1, 168) * 3600, limit = number('max_defer_hours', 24, 1, 168) * 3600;
    if (limit < delay) die('invalid_settings');
    if (!manual) {
        let reason = cfg('apply_policy', 'manual') != 'window' ? 'manual_policy' :
            localtime(time()).hour != number('apply_hour', 3, 0, 23) ? 'outside_window' :
            time() - state.last_apply < 86400 ? 'daily_cooldown' : null;
        let gate = deferred_gate(pending, series, time(), delay, limit);
        if (reason || !gate.ready) { status_update({ apply_blocked_reason: reason ?? gate.trigger }); return; }
    }
    // No apply from an old download, even if its TTL has not yet elapsed.
    let version = pending?.source_hash;
    status_update({ last_apply_attempt: time(), last_apply_error: null, apply_blocked_reason: null });
    fetch();
    let stage_error = load(TMP + '/status.json', {}).fetch_stage_error;
    if (stage_error) die(stage_error);
    pending = expire_pending();
    if (!pending) { status_update({ apply_blocked_reason: null }); return; }
    if (manual && pending.source_hash != version) die('pending_changed');
    let gate = deferred_gate(pending, load(BASE + '/change-series.json'), time(), delay, limit);
    if (!manual && !gate.ready) {
        status_update({ state: 'pending_revision_changed', apply_blocked_reason: gate.trigger }); return;
    }
    if (!pending_fresh(pending)) die('pending_expired');
    status_update({ apply_blocked_reason: null, apply_trigger: manual ? 'manual' : gate.trigger });
    let selected = actual_selection(state), present = filter(pending.nodes, n => n.id == selected)[0], fallback = null;
    if (!present) fallback = healthy_fallback(pending.nodes, selected);
    let candidate = plan(state.nodes, pending.nodes, selected, hash, fallback); candidate.before_selected = selected;
    apply_candidate(candidate, false);
}
function policy_config() {
    return { failure_seconds: number('failure_seconds',120,1,86400), failure_count: number('failure_count',3,1,100),
        latency_threshold_ms: number('latency_threshold_ms',1000,1,60000), latency_duration_seconds: number('latency_duration_seconds',300,1,86400),
        improvement_percent: number('improvement_percent',20,0,100), improvement_ms: number('improvement_ms',50,0,60000),
        cooldown_seconds: number('cooldown_seconds',600,0,86400) };
}
function delay_probe(state,node) {
    let position=index(map(state.nodes,n=>n.id),node.id);
    if(position<0) return null;
    let milliseconds=int(budget(number('probe_timeout_seconds',5,1,5),1)*1000);
    if(milliseconds<100) return null;
    try {
        let result=api('/proxies/main-'+(position+1)+'-out/delay?timeout='+milliseconds+'&url='+encode(cfg('health_url','https://www.gstatic.com/generate_204')),null,null,true);
        if(result.failed) return {ok:false,delay:null};
        if(type(result.delay)!='int' && type(result.delay)!='double')return null;
        return {ok:true,delay:result.delay};
    } catch(e) { return null; }
}
function observed(state,node,now,records,config,preferred) {
    let key=hash(canonical(node.outbound)), sample=delay_probe(state,node);
    if(!sample){delete records[node.id];return null;}
    let old=records[node.id], gap=node.id==preferred && state.selected_id!=preferred?330:90;
    if(old && (now<old.at || now-old.at>gap))old=null;
    // Preferred is sampled every five minutes; use an explicit sparse success window.
    let observation=observe(old,key,now,sample.ok,sample.delay,config);
    if(node.id==preferred && state.selected_id!=preferred && sample.ok) {
        observation.successes=old?.ok && old.key==key?(old.successes ?? 0)+1:1;
        observation.success_since=old?.ok && old.key==key?old.success_since:now;
    }
    records[node.id]=observation;
    if(!old || observation.at!=old.at)record_history(node.id,sample.ok,sample.delay,null);
    return observation;
}
function activate_verified(state,selected,chosen,reason) {
    if(actual_selection(state)!=selected)die('selection_changed');
    let meta=selection_state(state);
    if(meta.selected_id!=selected)die('selection_changed');
    // The short search deadline must never kill a started durable transaction.
    execution_deadline=null;
    let applied=filter(state.nodes,n=>n.id==chosen.id && canonical(n.outbound)==canonical(chosen.outbound))[0];
    if(applied)select_node(state,chosen.id,reason);
    else {
        let nodes=map(state.nodes,n=>n.id==chosen.id?chosen:n);
        if(!length(filter(nodes,n=>n.id==chosen.id)))push(nodes,chosen);
        let candidate=plan(state.nodes,nodes,selected,hash,chosen.id);
        candidate.before_selected=selected;candidate.selected_id=chosen.id;
        let position=index(map(state.nodes,n=>n.id),selected), target=index(map(candidate.nodes,n=>n.id),chosen.id);
        let temp=candidate.nodes[position];candidate.nodes[position]=candidate.nodes[target];candidate.nodes[target]=temp;
        candidate.selected_tag=sprintf('main-%d-out',position+1);
        status_update({state:'recovery_apply',recovery_stage:'apply'});
        apply_candidate(candidate,true,chosen.id==selected?'profile_update':reason);
    }
    fs.unlink(TMP+'/recovery-v2.json');
}
function strict_measure(node, seconds) {
    let outer=execution_deadline, result=null;
    execution_deadline=outer==null?monotime()+seconds:min(outer,monotime()+seconds);
    try {
        let response=get_through(node.outbound,cfg('health_url','https://www.gstatic.com/generate_204'),'/dev/null',seconds,65536);
        result={ok:response.code==0 && +response.metrics.http_code==204,delay:int(+response.metrics.time_total*1000)};
    } catch(e) { stop_probe();result={ok:null,delay:null}; }
    execution_deadline=outer;return result;
}
function strict_probe(node, seconds) { return strict_measure(node,seconds).ok; }
function recover_active(state,selected) {
    let node=filter(state.nodes,n=>n.id==selected)[0], signature=hash(canonical(node.outbound));
    let progress=load(TMP+'/recovery-v2.json',{}), now=time();
    if(progress.selected_id!=selected || progress.signature!=signature)progress={selected_id:selected,signature,stage:'confirm',cursor:0,seen:{},fetch_at:0};
    let instant=monotime(), boot=trim(fs.readfile('/proc/sys/kernel/random/boot_id'));
    if(progress.boot==boot && progress.attempt_mono!=null && instant>=progress.attempt_mono && instant-progress.attempt_mono<60){status_update({state:'recovery_wait'});return;}
    progress.boot=boot;progress.attempt_mono=instant;save(TMP+'/recovery-v2.json',progress);
    execution_deadline=instant+45;
    if(progress.stage=='confirm') {
        let confirmation=strict_probe(node,5);
        if(confirmation==null){status_update({state:'control_unknown'});return;}
        if(confirmation){fs.unlink(TMP+'/recovery-v2.json');status_update({state:'control_recovered'});return;}
        progress.stage='fetch';record_history(selected,null,null,'outage');
        save(TMP+'/recovery-v2.json',progress);
    }
    let meta=selection_state(state);
    if(progress.stage=='fetch') {
        let outer=execution_deadline;
        execution_deadline=min(outer-2,monotime()+15);
        try { fetch();progress.fetch_error=null; } catch(e){stop_probe();progress.fetch_error='subscription_unavailable_or_invalid';}
        execution_deadline=outer;
        progress.fetch_at=now;progress.stage='same';save(TMP+'/recovery-v2.json',progress);
    }
    let pending=expire_pending(), incoming=pending_fresh(pending)?pending.nodes:[];
    let candidates=[], seen={};
    function add(n){if(!n)return;let key=hash(canonical(n.outbound));if(!seen[key]){push(candidates,n);seen[key]=true;}}
    // Current stable ID with provider-rotated parameters precedes all reserves.
    let changed=filter(incoming,n=>n.id==selected && canonical(n.outbound)!=canonical(node.outbound))[0];
    add(changed);
    let order=priority_order([...incoming,...state.nodes],meta.preferred_id,priorities());
    for(let n in order)if(n.id!=selected)add(n);
    // Include saved profiles even when provider offers an unreachable new revision.
    for(let n in priority_order(state.nodes,meta.preferred_id,priorities()))if(n.id!=selected)add(n);
    let search_end=min(execution_deadline-2,monotime()+20), exhausted=true;
    for(let candidate in candidates) {
        let key=hash(canonical(candidate.outbound));
        if(progress.seen[key])continue;
        if(search_end-monotime()<7){exhausted=false;break;}
        progress.stage=candidate.id==selected?'same':'reserves';progress.cursor++;
        let ok=strict_probe(candidate,5);
        if(ok==null){exhausted=false;break;}
        progress.seen[key]=true;save(TMP+'/recovery-v2.json',progress);
        if(ok){
            if(actual_selection(state)!=selected)die('selection_changed');
            // A late external choice cancels the recovery rather than being overwritten.
            let current=selection_state(state);
            if(current.preferred_id!=meta.preferred_id)die('selection_changed');
            activate_verified(state,selected,candidate,'outage');return;
        }
    }
    if(exhausted){progress.seen={};progress.cursor=0;progress.stage='reserves';}
    // A long reserve scan must not postpone provider updates for tens of minutes.
    // Continuing passes check reserves FIRST; the due fetch uses only its own
    // leftover slice and never resets the cursor or already examined profiles.
    if(now-progress.fetch_at>=300 && execution_deadline-monotime()>=17){
        let outer=execution_deadline;execution_deadline=min(outer-2,monotime()+15);
        try{fetch();progress.fetch_error=null;}catch(e){stop_probe();progress.fetch_error='subscription_unavailable_or_invalid';}
        execution_deadline=outer;progress.fetch_at=now;
    }
    save(TMP+'/recovery-v2.json',progress);
    status_update({state:'recovery_no_verified_candidate',recovery_fetch_error:progress.fetch_error});
}
function check_active() {
    expire_pending();
    let state=state_seed(), meta=selection_state(state), selected=meta.selected_id;
    let config=policy_config(), now=time(), tick_mono=monotime(), boot=trim(fs.readfile('/proc/sys/kernel/random/boot_id'));
    state.selected_id=selected;
    let health_state=load(TMP+'/health-v2.json',{boot,records:{},cursor:0});
    let clock_delta=health_state.mono!=null ? (now-health_state.at)-(monotime()-health_state.mono) : 0;
    let clock_changed=clock_delta>5 || clock_delta < -5;
    if(health_state.boot!=boot || clock_changed){health_state={boot,records:{},cursor:0};fs.unlink(TMP+'/recovery-v2.json');}
    let progress=load(TMP+'/recovery-v2.json');
    if(progress && progress.selected_id==selected && cfg('priority_recovery','1')=='1'){recover_active(state,selected);return;}
    if(health_state.at!=null && now>=health_state.at && now-health_state.at<45)return;
    let active=filter(state.nodes,n=>n.id==selected)[0];
    let current=observed(state,active,now,health_state.records,config,meta.preferred_id);
    let slot=reserve_slot(state.nodes,selected,meta.preferred_id,health_state,now), reserve=null;
    let pending=expire_pending(), pending_preferred=filter(pending?.nodes ?? [],n=>n.id==meta.preferred_id)[0];
    if(slot && execution_deadline-monotime()>2) {
        let node=filter(state.nodes,n=>n.id==slot.id)[0];
        if (slot.id==meta.preferred_id && selected!=meta.preferred_id && pending_fresh(pending) && pending_preferred && canonical(pending_preferred.outbound)!=canonical(node.outbound)) {
            // Recovery of a provider-rotated preferred profile is exceptional work,
            // not a third normal probe or a permanent probe process.
            execution_deadline=monotime()+15;
            let key=hash(canonical(pending_preferred.outbound)), old=health_state.records[node.id];
            if(old && (old.key!=key || now<old.at || now-old.at>330))old=null;
            let ok=strict_probe(pending_preferred,5);
            if(ok==null){delete health_state.records[node.id];} else {
            reserve=observe(old,key,now,ok,null,config);
            if(ok){reserve.successes=old?.ok?(old.successes ?? 0)+1:1;reserve.success_since=old?.ok?old.success_since:now;}
            health_state.records[node.id]=reserve;record_history(node.id,ok,null,null);
            }
        } else reserve=observed(state,node,now,health_state.records,config,meta.preferred_id);
        if(reserve){health_state.cursor=slot.cursor;health_state.preferred_at=slot.preferred_at;}
    }
    if(actual_selection(state)!=selected)die('selection_changed');
    health_state.at=now;health_state.mono=tick_mono;save(TMP+'/health-v2.json',health_state);
    status_update({state:'control_checked',error:null,control:{selected_id:selected,ok:current?.ok,at:now,failures:current?.failures ?? 0,basis:'HTTPS_CONTROL_ENDPOINT',delay:current?.delay}});
    if(cfg('priority_recovery','1')!='1')return;
    if(current?.confirmed){recover_active(state,selected);return;}
    if(!current?.ok || !nonemergency_allowed(meta,now,config))return;
    let target=null, reason=null;
    let preferred=health_state.records[meta.preferred_id];
    if(selected!=meta.preferred_id && cfg('failback_enabled','1')=='1' && preferred?.ok &&
        preferred.successes>=number('failback_successes',3,1,100) && now-preferred.success_since>=number('failback_seconds',600,1,86400) && now-preferred.at<=360) {
        target=pending_fresh(pending) && pending_preferred && hash(canonical(pending_preferred.outbound))==preferred.key?pending_preferred:filter(state.nodes,n=>n.id==meta.preferred_id)[0];reason='failback';
    } else if(cfg('latency_enabled','0')=='1' && current.high) {
        target=filter(priority_order(state.nodes,meta.preferred_id,priorities()),n=>n.id!=selected && health_state.records[n.id]?.ok)[0];reason='latency';
    }
    // Comparison and strict verification are a separate bounded exceptional phase.
    if(target){
        execution_deadline=monotime()+30;
        let a=delay_probe(state,active), live=filter(state.nodes,n=>n.id==target.id)[0];
        let changed=canonical(live?.outbound)!=canonical(target.outbound);
        let b=changed?strict_measure(target,5):delay_probe(state,target);
        let acceptable=reason=='failback'?(cfg('latency_enabled','0')!='1' || (b.delay!=null && b.delay<=config.latency_threshold_ms*0.8)):latency_better(a?.delay,b?.delay,config);
        if(a?.ok && b?.ok && acceptable && strict_probe(target,5)) {
            if(actual_selection(state)!=selected)die('selection_changed');
            activate_verified(state,selected,target,reason);
        }
        return;
    }
    // Subscription refresh while on reserve is recovery work, never ordinary monitoring.
    if(selected!=meta.preferred_id){
        let refresh=load(TMP+'/reserve-fetch.json',{at:now});
        if(!fs.stat(TMP+'/reserve-fetch.json'))save(TMP+'/reserve-fetch.json',refresh);
        if(now-refresh.at>=900){
            execution_deadline=monotime()+15;
            try{fetch();}catch(e){stop_probe();}
            save(TMP+'/reserve-fetch.json',{at:now});
        }
    }
}

function speed(id) {
    let state = state_seed(); actual_selection(state);
    let node = filter(state.nodes, n => n.id == id)[0]; if (!node) die('unknown_node');
    let results = load(TMP + '/tests.json', {}), previous = results[id]?.speed_started_at ?? results[id]?.at ?? 0;
    if (time() - previous < 60) die('speed_cooldown');
    let memory = fs.readfile('/proc/meminfo'), available = match(memory, /MemAvailable:[[:space:]]+([0-9]+)/);
    let loadavg = +split(fs.readfile('/proc/loadavg'), ' ')[0];
    if (!available || +available[1] < 32768 || loadavg > 4) die('router_busy');
    let cap = number('speed_bytes', 4194304, 262144, 16777216), seconds = number('speed_seconds', 6, 2, 15);
    let endpoint = cfg('speed_url', 'https://speed.cloudflare.com/__down?bytes={bytes}');
    endpoint = replace(endpoint, '{bytes}', '' + cap); check_url(endpoint);
    // Rate-limit repeat attempts of this stable ID, including failed probes.
    // The task mutex serializes different IDs through probe cleanup.
    let old = results[id] ?? {};
    old.speed_started_at = time(); results[id] = old; save(TMP + '/tests.json', results);
    let result;
    try {
        let response = get_through(node.outbound, endpoint, '/dev/null', seconds, cap);
        result = sample(response.metrics, response.code, cap, 262144, 0.5);
    } catch (e) { stop_probe(); result = { error: 'speed_failed' }; }
    result.at = time(); result.profile_signature = canonical(node.outbound);
    for (let field in ['mbps', 'bytes', 'seconds', 'limit', 'short_sample', 'error']) delete old[field];
    for (let k, v in result) old[k] = v;
    if (!result.error) delete old.error;
    else delete old.mbps;
    results[id] = old; save(TMP + '/tests.json', results);
    status_update({ state: 'speed_finished' });
}
function service(id) {
    let state = state_seed(); actual_selection(state);
    let node = filter(state.nodes, n => n.id == id)[0]; if (!node) die('unknown_node');
    // A probe has exactly one outbound. Never allow detours or MAIN as a substitute.
    if (node.outbound.type != 'vless' || node.outbound.detour) die('invalid_settings');
    let endpoint = cfg('service_url', 'https://web.telegram.org/k/'); check_url(endpoint);
    let expected = number('service_status', 200, 200, 299);
    let mime = cfg('service_content_type', 'text/html');
    let markers = cfg('service_markers', ['<title>Telegram Web</title>', 'content="https://web.telegram.org/k/"', '<script type="module"']);
    if (type(markers) != 'array' || !length(markers) || length(markers) > 8 ||
        !length(mime) || length(mime) > 128 || match(mime, /[[:space:][:cntrl:]]/)) die('invalid_settings');
    for (let marker in markers) if (type(marker) != 'string' || !length(marker) || length(marker) > 512) die('invalid_settings');
    let result;
    try {
        let response = get_through(node.outbound, endpoint, JOB + '/service-body', 8, 524288);
        let body = fs.readfile(JOB + '/service-body', 524289) ?? '';
        result = service_sample(response.metrics, response.code, body, expected, mime, markers);
    } catch (e) { stop_probe(); result = { ok: false, error: 'service_probe_failed' }; }
    fs.unlink(JOB + '/service-body');
    result.at = time();
    result.configuration_hash = filehash('/etc/config/podkop');
    result.profile_signature = canonical(node.outbound);
    let tests = load(TMP + '/tests.json', {}), item = tests[id] ?? {};
    item.service = result; tests[id] = item; save(TMP + '/tests.json', tests);
    status_update({ state: 'service_finished' });
}
function latency(id) {
    let state = state_seed(), position = index(map(state.nodes, n => n.id), id); if (position < 0) die('unknown_node');
    let tests = load(TMP + '/tests.json', {}), item = tests[id] ?? {};
    try {
        let result = api('/proxies/' + sprintf('main-%d-out', position + 1) + '/delay?timeout=5000&url=' + encode(cfg('health_url', 'https://www.gstatic.com/generate_204')));
        item.latency = result.delay; delete item.latency_error;
    } catch (e) { delete item.latency; item.latency_error = 'latency_failed'; }
    item.latency_profile_signature = canonical(state.nodes[position].outbound);
    item.latency_at = time(); tests[id] = item; save(TMP + '/tests.json', tests);
}
function service_contract() {
    let endpoint = cfg('service_url', 'https://web.telegram.org/k/'); check_url(endpoint);
    let expected = number('service_status', 200, 200, 299), mime = cfg('service_content_type', 'text/html');
    let markers = cfg('service_markers', ['<title>Telegram Web</title>', 'content="https://web.telegram.org/k/"', '<script type="module"']);
    if (type(markers) != 'array' || !length(markers) || length(markers) > 8 ||
        !length(mime) || length(mime) > 128 || match(mime, /[[:space:][:cntrl:]]/)) die('invalid_settings');
    for (let marker in markers) if (type(marker) != 'string' || !length(marker) || length(marker) > 512) die('invalid_settings');
    return { endpoint, expected, mime, markers };
}
function batch_receipt(receipt) {
    save(TMP + '/batch-' + receipt.token + '.json', receipt);
    status_update({ batch: receipt, state: 'batch_' + receipt.state, error: receipt.error ?? null });
}
function batch_curl(key, proxy, url, seconds, cap, body) {
    check_url(url);
    let content = 'url = ' + curl_escape(url) + '\nproxy = ' + curl_escape(proxy) + '\nnoproxy = ""\n' +
        'silent\nproto = "=https"\nproto-redir = "=https"\nmax-redirs = 0\nconnect-timeout = 3\n' +
        'max-time = ' + seconds + '\nmax-filesize = ' + cap + '\nheader = "Accept-Encoding: identity"\n' +
        'output = ' + curl_escape(body) + '\nwrite-out = "%{json}"\n';
    if (fs.writefile(JOB + '/' + key + '.cfg', content) == null || !fs.chmod(JOB + '/' + key + '.cfg', 0600)) die('state_write_failed');
}
function batch_pool(jobs, slots, consume) {
    if (!length(jobs) || fs.stat(TMP + '/cancel-' + batch_request.token)) return;
    for (let i = 0; i < length(jobs); i++) fs.writefile(JOB + '/queue-' + i, jobs[i].key + '\n');
    fs.writefile(JOB + '/queue.next', '0\n'); fs.writefile(JOB + '/queue.total', length(jobs) + '\n');
    let command = 'set --; trap \'kill "$@" 2>/dev/null; wait; exit 1\' TERM INT; ';
    for (let i = 0; i < slots; i++) command += '/usr/libexec/podkop-tools/probe-worker & set -- "$@" "$!"; ';
    command += 'wait';
    let proc = fs.popen('/bin/sh -c ' + q(command) + ' 9>&- 2>/dev/null', 'r');
    if (!proc) die('process_failed');
    let by_key = {}; for (let job in jobs) by_key[job.key] = job;
    let line;
    try {
        while ((line = proc.read('line')) != null) {
            let job = by_key[trim(line)]; if (!job) continue;
            let metrics;
            try { metrics = load(JOB + '/' + job.key + '.metrics', {}); } catch (e) { metrics = {}; }
            consume(job, metrics, int(trim(fs.readfile(JOB + '/' + job.key + '.code') ?? '1')));
            delete by_key[job.key];
        }
    } catch (e) {
        // Stop dispatch and reap active slots before task cleanup removes files.
        fs.writefile(TMP + '/cancel-' + batch_request.token, '');
        proc.read('all'); proc.close();
        die(e.message);
    }
    let code = proc.close();
    let cancelled = fs.stat(TMP + '/cancel-' + batch_request.token);
    let deadline = int(trim(fs.readfile(JOB + '/deadline')));
    if (!cancelled && (code || (length(keys(by_key)) && int(split(fs.readfile('/proc/uptime'), ' ')[0]) < deadline))) die('batch_failed');
    return length(keys(by_key));
}
function batch(request) {
    if (type(request.ids) != 'array' || !length(request.ids) || length(request.ids) > 128 ||
        type(request.kinds) != 'array' || !length(request.kinds) || length(request.kinds) > 3) die('invalid_settings');
    let seen = {};
    for (let id in request.ids) {
        if (type(id) != 'string' || !match(id, /^[a-f0-9]{64}$/) || seen[id]) die('invalid_settings');
        seen[id] = true;
    }
    seen = {};
    for (let kind in request.kinds) {
        if (index(['latency', 'service', 'speed'], kind) < 0 || seen[kind]) die('invalid_settings');
        seen[kind] = true;
    }
    let cap = number('speed_bytes', 4194304, 262144, 16777216);
    if (seen.speed && request.speed_bytes != cap) die('speed_cap_changed');
    let state = state_seed(); actual_selection(state);
    let nodes = map(request.ids, id => filter(state.nodes, n => n.id == id)[0]);
    for (let node in nodes) if (!node) die('unknown_node');
    let memory = match(fs.readfile('/proc/meminfo'), /MemAvailable:[[:space:]]+([0-9]+)/);
    if (!memory || +memory[1] < 32768 || +split(fs.readfile('/proc/loadavg'), ' ')[0] > 4) die('router_busy');
    let contract = seen.service ? service_contract() : null;
    let health_url = cfg('health_url', 'https://www.gstatic.com/generate_204'); check_url(health_url);
    let speed_url = replace(cfg('speed_url', 'https://speed.cloudflare.com/__down?bytes={bytes}'), '{bytes}', '' + cap);
    if (seen.speed) check_url(speed_url);
    let configuration_hash = seen.service ? filehash('/etc/config/podkop') : null;
    let tests = load(TMP + '/tests.json', {}), jobs = [], speed_jobs = [], completed = {}, errors = {};
    let receipt = { token: request.token, state: 'running', done: 0, total: length(nodes), started_at: time(), errors };
    fs.writefile(JOB + '/batch-token', request.token + '\n');
    let deadline = int(split(fs.readfile('/proc/uptime'), ' ')[0]) + 210;
    fs.writefile(JOB + '/deadline', deadline + '\n');
    batch_receipt(receipt);
    for (let i = 0; i < length(nodes); i++) {
        let node = nodes[i], proxy = 'http://127.0.0.1:' + (16902 + i);
        completed[node.id] = 0;
        for (let kind in request.kinds) {
            let job = { key: i + '-' + kind, kind, node };
            if (kind == 'speed') {
                let prior = tests[node.id]?.speed_started_at ?? tests[node.id]?.at ?? 0;
                if (time() - prior < 60) {
                    errors[node.id] ??= {}; errors[node.id].speed = 'speed_cooldown'; completed[node.id]++;
                    continue;
                }
                batch_curl(job.key, proxy, speed_url, number('speed_seconds', 6, 2, 15), cap, '/dev/null');
                push(speed_jobs, job);
            } else if (kind == 'service') {
                batch_curl(job.key, proxy, contract.endpoint, 8, 524288, JOB + '/' + job.key + '.body'); push(jobs, job);
            } else {
                batch_curl(job.key, proxy, health_url, 5, 65536, '/dev/null'); push(jobs, job);
            }
        }
    }
    let consume = (job, metrics, code) => {
        let node = job.node, item = tests[node.id] ?? {}, result;
        if (job.kind == 'latency') {
            if (code == 0 && +metrics.http_code == 204 && +metrics.time_total > 0) {
                item.latency = int(+metrics.time_total * 1000); delete item.latency_error;
            } else { delete item.latency; item.latency_error = 'latency_failed'; }
            item.latency_profile_signature = canonical(node.outbound); item.latency_at = time();
        } else if (job.kind == 'service') {
            result = service_sample(metrics, code, fs.readfile(JOB + '/' + job.key + '.body', 524289) ?? '', contract.expected, contract.mime, contract.markers);
            result.at = time(); result.configuration_hash = configuration_hash; result.profile_signature = canonical(node.outbound);
            item.service = result; fs.unlink(JOB + '/' + job.key + '.body');
        } else {
            result = sample(metrics, code, cap, 262144, 0.5);
            for (let field in ['mbps', 'bytes', 'seconds', 'limit', 'short_sample', 'error']) delete item[field];
            for (let field, value in result) item[field] = value;
            item.at = time(); item.profile_signature = canonical(node.outbound);
        }
        tests[node.id] = item; save(TMP + '/tests.json', tests);
        completed[node.id]++;
        receipt.done = length(filter(nodes, n => completed[n.id] == length(request.kinds)));
        batch_receipt(receipt);
    };
    let missing = 0;
    if (length(jobs) || length(speed_jobs)) {
        start_probe_set(map(nodes, n => n.outbound));
        missing += batch_pool(jobs, 8, consume) ?? length(jobs);
        // Stamp only speed attempts that are actually dispatched, in the worker.
        missing += batch_pool(speed_jobs, 1, (job, metrics, code) => {
            let item = tests[job.node.id] ?? {};
            item.speed_started_at = int(trim(fs.readfile(JOB + '/' + job.key + '.started') ?? '' + time()));
            tests[job.node.id] = item; consume(job, metrics, code);
        }) ?? length(speed_jobs);
    }
    stop_probe();
    receipt.done = length(filter(nodes, n => completed[n.id] == length(request.kinds)));
    receipt.state = fs.stat(TMP + '/cancel-' + batch_request.token) ? 'cancelled' : missing ? 'failed' : 'finished';
    receipt.error = missing && receipt.state != 'cancelled' ? 'batch_timeout' : null;
    receipt.finished_at = time(); batch_receipt(receipt);
}
function public_status() {
    let state = load(BASE + '/state.json', {}), pending = load(BASE + '/pending.json'), status = load(TMP + '/status.json', {}), tests = load(TMP + '/tests.json', {});
    status.compatibility = compatibility_status();
    // Legacy field describes Selector access only; never a global operation gate.
    status.compatible = status.compatibility.capabilities.selector.available;
    if (status.error == 'incompatible') delete status.error;
    status.subscription_configured = !!ctx.get('podkop_tools_subscription', 'main', 'url');
    status.speed_bytes = number('speed_bytes', 4194304, 262144, 16777216);
    let service_url = cfg('service_url', 'https://web.telegram.org/k/');
    status.service_name = match(service_url, /^https:\/\/web\.telegram\.org\//) ? 'Telegram Web' : match(service_url, /^https:\/\/([^\/]+)/)?.[1] ?? 'Проверка HTTPS';
    if (match(ARGV[1] ?? '', /^[a-f0-9]{64}$/)) status.batch = load(TMP + '/batch-' + ARGV[1] + '.json');
    status.speed_next_at = 0; // Retained RPC field: there is no global speed cooldown.
    let selection = load(BASE + '/selection.json', {});
    status.preferred_id = selection.preferred_id ?? state.selected_id;
    status.selection_origin = selection.origin ?? 'unmigrated';
    status.last_switch_reason = selection.reason;
    status.recovery = load(TMP + '/recovery-v2.json', {});
    status.policy = { latency_enabled: cfg('latency_enabled','0') == '1', cooldown_until: (selection.last_switch ?? 0) + number('cooldown_seconds',600,60,86400) };
    status.enabled = cfg('enabled', '0') == '1'; status.selected_id = state.selected_id; status.last_apply = state.last_apply;
    status.pending = pending != null; status.count = length(state.nodes ?? []); status.pending_count = length(pending?.nodes ?? []);
    status.pending_version = pending?.source_hash;
    status.pending_stale = pending != null && !pending_fresh(pending);
    status.pending_version_at = pending?.first_seen;
    status.pending_verified_at = pending?.verified_at;
    let series = load(BASE + '/change-series.json');
    status.pending_series_started_at = series?.started_at;
    status.pending_deadline_at = series?.started_at ? series.started_at + number('max_defer_hours', 24, 1, 168) * 3600 : null;
    try {
        let group = api('/proxies/main-out');
        let chosen = (state.nodes ?? [])[index(group.all, group.now)]?.id;
        if (chosen) status.selected_id = chosen;
    } catch (e) { status.runtime_available = false; }
    delete status.antigravity;
    if (owns_ag(ctx)) {
        let saved = load(BASE + '/antigravity-selection.json', {});
        try {
            let selected = antigravity_selection(state.nodes ?? []);
            status.antigravity = { selected_id: selected, mode: ctx.get('podkop', 'antigravity', 'proxy_config_type'),
                reason: saved.selected_id == selected ? saved.reason : 'external' };
        } catch (e) { status.antigravity = { mode: ctx.get('podkop', 'antigravity', 'proxy_config_type'), unavailable: true }; }
    }
    if (status.control && status.control.selected_id != status.selected_id) status.control = null;
    let service_configuration_hash = length(filter(state.nodes ?? [], n => tests[n.id]?.service != null)) ? filehash('/etc/config/podkop') : null;
    status.nodes = map(state.nodes ?? [], n => {
        let test = json(sprintf('%J', tests[n.id] ?? {}));
        let speed_started = test.speed_started_at ?? test.at ?? 0;
        test.speed_next_at = speed_started ? speed_started + 60 : 0;
        let profile = canonical(n.outbound);
        test.latency_stale = test.latency_profile_signature != profile;
        test.speed_stale = test.profile_signature != profile;
        if (test.service) {
            test.service.stale = test.service.profile_signature != profile || test.service.configuration_hash != service_configuration_hash;
            delete test.service.profile_signature;
        }
        // Profile signatures contain private outbound data. Never return them through RPC.
        delete test.latency_profile_signature; delete test.profile_signature;
        return { id: n.id, name: n.name, selected: n.id == status.selected_id, test };
    });
    status.busy = fs.stat(TMP + '/lock') != null;
    return status;
}
function task_log(result) {
    if (index(['check', 'health', 'due'], ARGV[0]) < 0) return;
    try {
        let s = load(TMP + '/status.json', {}), state = load(BASE + '/state.json', {});
        if (ARGV[0] == 'health' && result == 'ok' && s.state == 'control_checked') return;
        run(['logger', '-t', 'podkop-tools', sprintf('task=%s result=%s state=%s servers=%d pending=%s',
            ARGV[0], result, s.state ?? 'unknown', length(state.nodes ?? []), fs.stat(BASE + '/pending.json') ? 'yes' : 'no')]);
    } catch (e) { /* Diagnostics cannot turn a committed operation into a failure. */ }
}

function measurement_finished(kind, id, error) {
    if (index(['latency', 'service', 'speed'], kind) < 0) return;
    let previous = load(TMP + '/status.json', {}).measurement;
    status_update({ measurement: { sequence: (previous?.sequence ?? 0) + 1, kind, id, ok: !error, error } });
}

let command = ARGV[0], id = ARGV[1];
// Read RPC stdin before spawning helpers, which otherwise inherit it.
let source_payload = command == 'source' ? fs.stdin.read(8193) : null;
try {
    if (command == 'history-restore') { history_restore(); fs.writefile(TMP + '/history-ready','1'); print('{"ok":true}\n'); exit(0); }
    if (command == 'statistics') { try { history_restore(); fs.writefile(TMP + '/history-ready','1'); } catch(e) {} print(sprintf('%J\n', history_query(id, ARGV[2]))); exit(0); }
    if (command == 'history-save') { if (cfg('enabled','0') == '1') history_snapshot(time()); print('{"ok":true}\n'); exit(0); }
    if (command == 'status') { print(sprintf('%J\n', public_status())); exit(0); }
    if (command == 'batch') {
        try { batch_request = json(id); } catch (e) { die('invalid_settings'); }
        if (type(batch_request?.token) != 'string' || !match(batch_request.token, /^[a-f0-9]{64}$/)) die('invalid_settings');
    }
    if (index(['check', 'health', 'due'], command) >= 0 && cfg('enabled', '0') != '1') { print('{"ok":true,"disabled":true}\n'); exit(0); }
    if (command == 'migrate' && fs.stat(BASE + '/transaction.json')) die('recovery_required');
    if (fs.stat(BASE + '/transaction.json') && index(['source', 'fetch', 'check'], command) < 0) {
        rollback(); fs.unlink(BASE + '/transaction.json');
        if (command == 'rollback') { print('{"ok":true}\n'); exit(0); }
    }
    if (command == 'health') execution_deadline = monotime() + 15;
    require_operation(command);
    if (command == 'source') {
        let payload = source_payload;
        if (!payload || length(payload) > 8192) die('invalid_url');
        let request; try { request = json(payload); } catch (e) { die('invalid_url'); }
        check_url(request.url); if (length(request.url) > 4096) die('invalid_url');
        if (ctx.get('podkop_tools_subscription', 'main', 'url') != request.url) {
            if (!ctx.set('podkop_tools_subscription', 'main', 'url', request.url) || !ctx.commit('podkop_tools_subscription')) die('state_write_failed');
            fs.chmod('/etc/config/podkop_tools_subscription', 0600);
            fs.unlink(BASE + '/pending.json');
            fs.unlink(BASE + '/change-series.json'); fs.unlink(BASE + '/download.json');
            status_update({ state: 'source_saved', error: null, last_success: null, downloaded_count: null, fetch_stage_error: null, fetch_path: null, pending: false });
        }
    }
    else if (command == 'migrate') migrate_state();
    else if (command == 'seed') state_seed();
    else if (command == 'fetch' || command == 'check') fetch();
    else if (command == 'health') check_active();
    else if (command == 'apply') apply_pending(true, id);
    else if (command == 'due') apply_pending(false);
    else if (command == 'select') { let state = state_seed(); actual_selection(state); select_node(state, id, 'selected'); }
    else if (command == 'speed') speed(id);
    else if (command == 'latency') latency(id);
    else if (command == 'service') service(id);
    else if (command == 'batch') batch(batch_request);
    else if (command == 'restore') {
        let state = load(BASE + '/state.json');
        if (state) { selection_state(state, true); }
    }
    else if (command == 'rollback') { rollback(); fs.unlink(BASE + '/transaction.json'); }
    else die('invalid_command');
    stop_probe();
    measurement_finished(command, id, null);
    task_log('ok');
    print('{"ok":true}\n');
} catch (e) {
    stop_probe();
    // Never serialize parser/native/curl exceptions or credentials into diagnostics.
    let known = ['budget_exhausted', 'generator_unavailable', 'dependency_missing', 'sing_box_unavailable', 'unsupported_main', 'unsupported_runtime', 'api_unavailable', 'runtime_unavailable', 'state_conflict',
        'uci_changed', 'uci_changed_after_write', 'uci_busy', 'recovery_conflict', 'recovery_required', 'invalid_url', 'invalid_settings', 'unknown_node', 'validation_failed', 'generation_failed', 'generated_nodes_mismatch', 'routing_changed',
        'subscription_unavailable_or_invalid', 'fallback_not_verified', 'ambiguous_identity', 'unrepresentable_stock_uri', 'antigravity_node_missing',
        'apply_rolled_back', 'rollback_failed', 'rollback_unavailable', 'selection_changed', 'speed_cooldown', 'router_busy', 'probe_start_failed',
        'pending_changed', 'pending_expired', 'selected_endpoint_unreachable', 'batch_failed', 'speed_cap_changed'];
    if (command == 'health' && !fs.stat(BASE + '/transaction.json')) fs.unlink(TMP + '/health-v2.json');
    let code = index(known, e.message) >= 0 ? e.message : 'operation_failed';
    status_update({ state: 'error', error: code });
    if (batch_request?.token && match(batch_request.token, /^[a-f0-9]{64}$/)) batch_receipt({ token: batch_request.token, state: 'failed', done: 0, total: length(batch_request.ids ?? []), error: code });
    if (command == 'fetch' || command == 'check') status_update({ fetch_error: code });
    if (command == 'due' || command == 'apply') status_update({ apply_blocked_reason: code, last_apply_error: code });
    measurement_finished(command, id, code);
    task_log(code);
    print(sprintf('%J\n', { ok: false, error: code })); exit(1);
}
