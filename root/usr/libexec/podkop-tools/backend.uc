// SPDX-License-Identifier: GPL-2.0-only
import * as fs from 'fs';
import { cursor } from 'uci';
import { canonical, parse_provider, reconcile, plan, proxy_uri, encode, decode, sample, service_sample, deferred_gate } from '/usr/libexec/podkop-tools/model.uc';

const BASE = '/etc/podkop-tools', TMP = '/tmp/podkop-tools', JOB = TMP + '/job';
let ctx = cursor(), probe_pid = null, batch_request = null;
function q(v) { return "'" + replace('' + v, /'/g, "'\\''") + "'"; }
function run(args) {
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
function number(key, fallback, min, max) {
    let n = int(cfg(key, '' + fallback));
    if (n == null || n < min || n > max) die('invalid_settings');
    return n;
}
function runtime() { let r = load('/etc/sing-box/config.json'); if (!r) die('runtime_unavailable'); return r; }
function status_update(values) {
    let status = load(TMP + '/status.json', {});
    for (let k, v in values) status[k] = v;
    save(TMP + '/status.json', status);
}
function implementation_compatible() {
    if (run(['/usr/bin/sha256sum', '-c', '/usr/share/podkop-tools/compat.sha256']).code ||
        index(must(['/usr/bin/sing-box', 'version'], 'incompatible'), 'sing-box version 1.14.2\n') != 0) die('incompatible');
}
function compatible() {
    implementation_compatible();
    let sections = 0;
    ctx.foreach('podkop', 'section', s => { sections++; });
    if (sections != 1 || ctx.get('podkop', 'main', 'proxy_config_type') != 'selector' ||
        ctx.get('podkop', 'settings', 'config_path') != '/etc/sing-box/config.json' ||
        ctx.get('podkop', 'main', 'connection_type') != 'proxy') die('unsupported_main');
    let r = runtime(), selector = filter(r.outbounds, o => o.tag == 'main-out' && o.type == 'selector');
    if (length(selector) != 1 || r.route?.final != 'direct-out') die('unsupported_runtime');
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
    let r = run(['/usr/bin/curl', '--disable', '--proto', '=https', '--proto-redir', '=https', '--max-redirs', '0', '--config', JOB + '/curl.cfg', '--silent', '--connect-timeout', '3', '--max-time', '' + seconds,
        '--max-filesize', '' + cap, '--output', output, '--write-out', '%{json}', '--header', 'Accept-Encoding: identity']);
    let metrics = {};
    try { metrics = json(r.out); } catch (e) { }
    fs.unlink(JOB + '/curl.cfg');
    return { code: r.code, metrics };
}
function api(path, method, payload) {
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
    let result = run(['/usr/bin/curl', '--disable', '-fsS', '--config', config_file, '--connect-timeout', '2', '--max-time', '8']);
    fs.unlink(config_file);
    if (result.code) die('api_unavailable');
    if (!length(result.out)) return {};
    try { return json(result.out); } catch (e) { die('api_unavailable'); }
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
    let actual = filter(r.outbounds, o => o.type == 'vless');
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
    let wanted = cfg('fallback_id', '');
    let order = filter(nodes, n => n.id != chosen && n.id == wanted);
    for (let n in nodes) if (n.id != chosen && n.id != wanted) push(order, n);
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
function stage(candidate) {
    candidate.staged_from = filehash('/etc/config/podkop');
    must(['/bin/cp', '/etc/config/podkop', JOB + '/uci/podkop'], 'staging_failed');
    let staged = cursor(JOB + '/uci', JOB + '/delta', '');
    if (!staged.set('podkop', 'main', 'selector_proxy_links', map(candidate.nodes, proxy_uri)) ||
        !staged.set('podkop', 'settings', 'config_path', JOB + '/generated.json') || !staged.commit('podkop')) die('staging_failed');
    must(['/usr/libexec/podkop-tools/generate'], 'generation_failed');
    must(['/usr/bin/sing-box', 'check', '-c', JOB + '/generated.json'], 'validation_failed');
    let generated = load(JOB + '/generated.json');
    let actual = filter(generated.outbounds, o => o.type == 'vless');
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
function select_node(state, id, reason) {
    let position = index(map(state.nodes, n => n.id), id);
    if (position < 0) die('unknown_node');
    api('/proxies/main-out', 'PUT', { name: sprintf('main-%d-out', position + 1) });
    if (api('/proxies/main-out').now != sprintf('main-%d-out', position + 1)) die('selection_failed');
    state.selected_id = id; save_state(BASE + '/state.json', state);
    fs.unlink(TMP + '/health.json');
    status_update({ state: reason, selected_id: id, control: null });
}
function rollback() {
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
            (filehash(BASE + '/state.json') != tx.before_state && filehash(BASE + '/state.json') != tx.after_state)) die('recovery_conflict');
    } else {
        if (live != current.managed_hash) die('state_conflict');
        actual_selection(current);
    }
    // Only undo managed servers; retain the latest independent UCI settings.
    let expected = filehash('/etc/config/podkop');
    must(['/bin/cp', '/etc/config/podkop', JOB + '/uci/podkop'], 'staging_failed');
    let staged = cursor(JOB + '/uci', JOB + '/delta', '');
    staged.set('podkop', 'main', 'selector_proxy_links', map(old.nodes, proxy_uri)); staged.commit('podkop');
    write_main(JOB + '/uci/podkop', expected);
    must(['/usr/bin/timeout', '-s', 'TERM', '120', '/etc/init.d/podkop', 'reload'], 'rollback_failed');
    for (let i = 0; i < 30; i++) {
        try {
            old.podkop_hash = filehash('/etc/config/podkop');
            select_node(old, old.selected_id, 'rolled_back');
            if (actual_selection(old) != old.selected_id ||
                run(['/usr/bin/dig', '+short', '+time=3', '+tries=1', '@127.0.0.42', 'openwrt.org', 'A']).out == '') die('rollback_failed');
            return;
        } catch (e) { run(['/bin/sleep', '2']); }
    }
    die('rollback_failed');
}
function apply_candidate(candidate, urgent) {
    let accepted_from = filehash(BASE + '/state.json');
    let state = state_seed(), selected = actual_selection(state);
    if (selected != candidate.before_selected) die('selection_changed');
    stage(candidate);
    if (filehash('/etc/config/podkop') != candidate.staged_from) die('uci_changed');
    if (actual_selection(state) != selected) die('state_conflict');
    let chosen = filter(candidate.nodes, n => n.id == candidate.selected_id)[0];
    if (!chosen || !health(chosen)) die('selected_endpoint_unreachable');
    if (actual_selection(state) != selected) die('selection_changed');
    if (filehash(BASE + '/state.json') != accepted_from) die('state_conflict');
    must(['/bin/mkdir', '-p', BASE + '/rollback'], 'backup_failed');
    for (let file in ['podkop', 'dhcp', 'sing-box']) must(['/bin/cp', '/etc/config/' + file, BASE + '/rollback/' + file], 'backup_failed');
    state.selected_id = selected; save_state(BASE + '/rollback/state.json', state);
    let checksums = '';
    for (let file in ['podkop', 'dhcp', 'sing-box', 'state.json']) checksums += filehash(BASE + '/rollback/' + file) + '  ' + BASE + '/rollback/' + file + '\n';
    fs.writefile(BASE + '/rollback/SHA256SUMS', checksums); fs.chmod(BASE + '/rollback/SHA256SUMS', 0600);
    // A durable marker makes the next boot/task restore an interrupted apply.
    let transaction = { schema_version: 2, started: time(), before_state: filehash(BASE + '/state.json'), before_managed: state.managed_hash, after_managed: hash(canonical(managed_configuration(candidate.nodes))), before_main: candidate.staged_from, after_main: filehash(JOB + '/uci/podkop') };
    // Backup state must be the exact pre-write accepted snapshot.
    transaction.backup_state = filehash(BASE + '/rollback/state.json');
    save(BASE + '/transaction.json', transaction);
    try {
        write_main(JOB + '/uci/podkop', candidate.staged_from);
        // Label-only changes are still explicit/deferred apply, but need no reload.
        if (candidate.runtime_changed)
            must(['/usr/bin/timeout', '-s', 'TERM', '120', '/etc/init.d/podkop', 'reload'], 'apply_failed');
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
        select_node(state, candidate.selected_id, urgent ? 'recovered' : 'applied');
        let live = runtime(), generated = load(JOB + '/generated.json');
        if (canonical(filter(live.outbounds, o => o.type == 'vless')) != canonical(filter(generated.outbounds, o => o.type == 'vless'))) die('apply_failed');
        actual_selection(state);
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
    expire_pending();
    let state = state_seed(), selected = actual_selection(state), url = ctx.get('podkop_tools_subscription', 'main', 'url') ?? '';
    check_url(url);
    let paths = [{ id: 'direct', outbound: { type: 'direct' } }];
    let last_path = load(TMP + '/fetch-path.json', ''), preferred = cfg('fallback_id', '');
    let alternatives = filter(state.nodes, n => n.id != selected);
    for (let wanted in [last_path, preferred]) {
        let node = filter(alternatives, n => n.id == wanted)[0];
        if (node && !length(filter(paths, n => n.id == wanted))) push(paths, node);
    }
    for (let n in alternatives) if (!length(filter(paths, p => p.id == n.id))) push(paths, n);
    // A working current profile remains a last fetch path, through an isolated probe.
    let active = filter(state.nodes, n => n.id == selected)[0];
    if (active) push(paths, active);
    let parsed = null, used = null, started = time();
    for (let path in paths) {
        if (time() - started >= 40) break;
        let response;
        try { response = get_through(path.outbound, url, JOB + '/response', 8, 2097152); } catch (e) { stop_probe(); continue; }
        if (response.code || +response.metrics.http_code != 200) continue;
        try { parsed = parse_provider(fs.readfile(JOB + '/response', 2097153) ?? ''); used = path.id; break; }
        catch (e) { }
    }
    fs.unlink(JOB + '/response');
    if (!parsed) die('subscription_unavailable_or_invalid');
    let incoming = reconcile(state.nodes, parsed.nodes, hash), verified_at = time();
    accept_snapshot(state, incoming, selected, verified_at, parsed.skipped);
    save(TMP + '/fetch-path.json', used);
    status_update({ last_success: verified_at, count: length(incoming), skipped: length(parsed.skipped), fetch_path: used == 'direct' ? 'direct' : 'saved_server', error: null, fetch_error: null });
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
function recover_active(state, selected) {
    let fresh = null, fetch_error = null;
    try { fresh = fetch(); }
    catch (e) { fetch_error = 'subscription_unavailable_or_invalid'; }
    let pending = expire_pending();
    let incoming = fresh?.nodes ?? (pending_fresh(pending) ? pending.nodes : []);
    let current = filter(state.nodes, n => n.id == selected)[0], candidates = [], seen = {};
    function add(node) {
        if (!node || (node.id == selected && canonical(node.outbound) == canonical(current.outbound))) return;
        let key = canonical(node.outbound);
        if (!seen[key]) { seen[key] = true; push(candidates, node); }
    }
    // Updated parameters of the manually selected stable ID always come first.
    add(filter(incoming, n => n.id == selected)[0]);
    let preferred = cfg('fallback_id', '');
    for (let nodes in [state.nodes, incoming]) add(filter(nodes, n => n.id == preferred && n.id != selected)[0]);
    for (let nodes in [state.nodes, incoming]) for (let node in nodes) if (node.id != selected) add(node);
    let progress = load(TMP + '/recovery.json', {});
    let priority = filter(candidates, n => n.id == selected || n.id == preferred), others = filter(candidates, n => n.id != selected && n.id != preferred);
    let cursor = progress.selected_id == selected && int(progress.cursor) >= 0 ? int(progress.cursor) : 0;
    if (length(others)) cursor %= length(others); else cursor = 0;
    let order = map(priority, n => n);
    for (let i = 0; i < length(others); i++) push(order, others[(cursor + i) % length(others)]);
    let chosen = null, deadline = time() + 90, examined = 0;
    for (let i = 0; i < length(order); i++) {
        if (time() >= deadline) break;
        let node = order[i];
        if (i >= length(priority)) examined++;
        if (health(node)) { chosen = node; break; }
    }
    // Continue a budget-limited scan next time instead of starving later reserves.
    progress.selected_id = selected;
    progress.cursor = length(others) ? (cursor + examined) % length(others) : 0;
    save(TMP + '/recovery.json', progress);
    if (actual_selection(state) != selected) die('selection_changed');
    if (!chosen) {
        status_update({ state: 'recovery_no_verified_candidate', recovery_fetch_error: fetch_error }); return;
    }
    let applied = filter(state.nodes, n => n.id == chosen.id && canonical(n.outbound) == canonical(chosen.outbound))[0];
    if (applied) {
        state.last_recovery = time();
        select_node(state, chosen.id, 'recovered_from_saved_snapshot');
    } else {
        // Change only the verified active profile; unrelated subscription updates stay deferred.
        let nodes = map(state.nodes, n => n.id == chosen.id ? chosen : n);
        if (!length(filter(nodes, n => n.id == chosen.id))) push(nodes, chosen);
        let candidate = plan(state.nodes, nodes, selected, hash, chosen.id);
        candidate.before_selected = selected; candidate.selected_id = chosen.id;
        let position = index(map(state.nodes, n => n.id), selected), target = index(map(candidate.nodes, n => n.id), chosen.id);
        let temp = candidate.nodes[position]; candidate.nodes[position] = candidate.nodes[target]; candidate.nodes[target] = temp;
        candidate.selected_tag = sprintf('main-%d-out', position + 1);
        apply_candidate(candidate, true);
    }
    if (length(incoming)) {
        let accepted = load(BASE + '/state.json');
        accept_snapshot(accepted, incoming, chosen.id, fresh?.verified_at ?? pending.verified_at, fresh?.skipped ?? pending.skipped);
    }
    status_update({ recovery_fetch_error: fetch_error, recovery_at: time(), error: null,
        control: { selected_id: chosen.id, ok: true, at: time(), failures: 0, basis: 'HTTPS_HTTP_204' } });
}
function check_active() {
    expire_pending();
    let state = state_seed(), selected = actual_selection(state), node = filter(state.nodes, n => n.id == selected)[0];
    let minutes = number('health_minutes', 15, 5, 60), key = hash(canonical({ id: selected, outbound: node.outbound })), previous = load(TMP + '/health.json');
    let ok = health(node), now = time();
    if (actual_selection(state) != selected) die('selection_changed');
    let consecutive = previous?.key == key && now >= previous.checked_at && now - previous.checked_at <= minutes * 120 + 300;
    let failures = ok ? 0 : consecutive ? previous.failures : 0;
    let gap = minutes * 60 - 30; // Allow probe-duration jitter between cron ticks.
    // A rapid retry cannot turn one failed observation into a confirmed outage.
    if (!ok && (!consecutive || now - previous.checked_at >= gap)) failures++;
    let observation = { key, selected_id: selected, checked_at: now, failures, ok, first_failed_at: ok ? null : consecutive && previous.failures > 0 ? previous.first_failed_at : now };
    if (!ok && consecutive && now - previous.checked_at < gap) observation.checked_at = previous.checked_at;
    save(TMP + '/health.json', observation);
    status_update({ state: 'control_checked', control: { selected_id: selected, ok, at: now, failures, basis: 'HTTPS_HTTP_204' } });
    if (ok || failures < 2 || cfg('priority_recovery', '1') != '1') return;
    let recovery = load(TMP + '/recovery.json', {}), last = recovery.last_attempt ?? 0, persisted = state.last_recovery ?? state.last_urgent ?? 0;
    if (persisted > last) last = persisted;
    if (now - last < 1800) { status_update({ state: 'recovery_cooldown' }); return; }
    recovery.last_attempt = now;
    save(TMP + '/recovery.json', recovery);
    recover_active(state, selected);
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
    status.compatible = true;
    try { implementation_compatible(); } catch (e) { status.compatible = false; status.error = 'incompatible'; }
    status.subscription_configured = !!ctx.get('podkop_tools_subscription', 'main', 'url');
    status.speed_bytes = number('speed_bytes', 4194304, 262144, 16777216);
    let service_url = cfg('service_url', 'https://web.telegram.org/k/');
    status.service_name = match(service_url, /^https:\/\/web\.telegram\.org\//) ? 'Telegram Web' : match(service_url, /^https:\/\/([^\/]+)/)?.[1] ?? 'Проверка HTTPS';
    if (match(ARGV[1] ?? '', /^[a-f0-9]{64}$/)) status.batch = load(TMP + '/batch-' + ARGV[1] + '.json');
    status.speed_next_at = 0; // Retained RPC field: there is no global speed cooldown.
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
    if (command == 'status') { print(sprintf('%J\n', public_status())); exit(0); }
    if (command == 'batch') {
        try { batch_request = json(id); } catch (e) { die('invalid_settings'); }
        if (type(batch_request?.token) != 'string' || !match(batch_request.token, /^[a-f0-9]{64}$/)) die('invalid_settings');
    }
    if (index(['check', 'health', 'due'], command) >= 0 && cfg('enabled', '0') != '1') { print('{"ok":true,"disabled":true}\n'); exit(0); }
    if (command == 'migrate' && fs.stat(BASE + '/transaction.json')) die('recovery_required');
    if (fs.stat(BASE + '/transaction.json')) {
        implementation_compatible(); rollback(); fs.unlink(BASE + '/transaction.json');
        if (command == 'rollback') { print('{"ok":true}\n'); exit(0); }
    }
    compatible();
    if (command == 'source') {
        let payload = source_payload;
        if (!payload || length(payload) > 8192) die('invalid_url');
        let request; try { request = json(payload); } catch (e) { die('invalid_url'); }
        check_url(request.url); if (length(request.url) > 4096) die('invalid_url');
        if (ctx.get('podkop_tools_subscription', 'main', 'url') != request.url) {
            if (!ctx.set('podkop_tools_subscription', 'main', 'url', request.url) || !ctx.commit('podkop_tools_subscription')) die('state_write_failed');
            fs.chmod('/etc/config/podkop_tools_subscription', 0600);
            fs.unlink(BASE + '/pending.json');
            fs.unlink(BASE + '/change-series.json');
            status_update({ state: 'source_saved', error: null, last_success: null, fetch_path: null, pending: false });
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
        if (state) { actual_selection(state); select_node(state, state.selected_id, 'restored'); }
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
    let known = ['incompatible', 'unsupported_main', 'unsupported_runtime', 'api_unavailable', 'runtime_unavailable', 'state_conflict',
        'uci_changed', 'uci_changed_after_write', 'uci_busy', 'recovery_conflict', 'recovery_required', 'invalid_url', 'invalid_settings', 'unknown_node', 'validation_failed', 'generation_failed', 'generated_nodes_mismatch', 'routing_changed',
        'subscription_unavailable_or_invalid', 'fallback_not_verified', 'ambiguous_identity', 'unrepresentable_stock_uri',
        'apply_rolled_back', 'rollback_failed', 'rollback_unavailable', 'selection_changed', 'speed_cooldown', 'router_busy', 'probe_start_failed',
        'pending_changed', 'pending_expired', 'selected_endpoint_unreachable', 'batch_failed', 'speed_cap_changed'];
    let code = index(known, e.message) >= 0 ? e.message : 'operation_failed';
    status_update({ state: 'error', error: code });
    if (batch_request?.token && match(batch_request.token, /^[a-f0-9]{64}$/)) batch_receipt({ token: batch_request.token, state: 'failed', done: 0, total: length(batch_request.ids ?? []), error: code });
    if (command == 'fetch' || command == 'check') status_update({ fetch_error: code });
    if (command == 'due' || command == 'apply') status_update({ apply_blocked_reason: code, last_apply_error: code });
    measurement_finished(command, id, code);
    task_log(code);
    print(sprintf('%J\n', { ok: false, error: code })); exit(1);
}
