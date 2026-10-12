// SPDX-License-Identifier: GPL-2.0-only
// Pure subscription/selection/measurement contracts. No routing policy here.
import { urlencode, urldecode } from 'lucihttp';

function canonical(v) {
    if (type(v) == 'array') return '[' + join(',', map(v, canonical)) + ']';
    if (type(v) == 'object') {
        return '{' + join(',', map(sort(keys(v)), k => sprintf('%J', k) + ':' + canonical(v[k]))) + '}';
    }
    return sprintf('%J', v);
}

function require_value(ok, code) { if (!ok) die(code); }
function encode(v) { return urlencode('' + v, 1); }
function decode(v) { return urldecode(v, 0); }

function parse_provider(raw) {
    require_value(length(raw) <= 2097152, 'body_too_large');
    let configs;
    try { configs = json(raw); } catch (e) { die('invalid_json'); }
    require_value(type(configs) == 'array' && length(configs) > 0 && length(configs) <= 256, 'invalid_root');
    let nodes = [], skipped = [], connections = {};
    for (let profile in configs) {
        require_value(type(profile) == 'object' && type(profile.outbounds) == 'array', 'invalid_profile');
        for (let ob in profile.outbounds) {
            require_value(type(ob) == 'object', 'invalid_outbound');
            if (index(['freedom', 'blackhole', 'dns'], ob.protocol) >= 0) continue;
            if (ob.protocol != 'vless') { push(skipped, 'unsupported_protocol'); continue; }
            let stream = ob.streamSettings ?? {}, network = stream.network ?? 'tcp';
            if (index(['tcp', 'grpc'], network) < 0) { push(skipped, 'unsupported_transport'); continue; }
            if (stream.sockopt?.dialerProxy || stream.grpcSettings?.multiMode ||
                (network == 'tcp' && (stream.tcpSettings?.header?.type ?? 'none') != 'none')) {
                push(skipped, 'unsupported_transport_options'); continue;
            }
            let peers = ob.settings?.vnext, peer = peers?.[0], users = peer?.users, user = users?.[0];
            require_value(type(peers) == 'array' && length(peers) == 1 && type(users) == 'array' && length(users) == 1, 'ambiguous_account');
            require_value(type(peer.address) == 'string' && length(peer.address) > 0 && !match(peer.address, /[[:space:][:cntrl:]]/) &&
                type(peer.port) == 'int' && peer.port > 0 && peer.port < 65536 &&
                type(user.id) == 'string' && match(user.id, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/), 'invalid_peer');
            if ((user.encryption ?? 'none') != 'none') { push(skipped, 'unsupported_vless_encryption'); continue; }
            let out = { type: 'vless', server: peer.address, server_port: peer.port, uuid: lc(user.id) };
            if (user.flow) out.flow = user.flow;
            let security = stream.security ?? 'none';
            if (index(['none', 'tls', 'reality'], security) < 0) { push(skipped, 'unsupported_security'); continue; }
            if (security != 'none') {
                let tls = (security == 'reality' ? stream.realitySettings : stream.tlsSettings) ?? {};
                out.tls = { enabled: true, server_name: tls.serverName ?? '' };
                if (tls.fingerprint) out.tls.utls = { enabled: true, fingerprint: tls.fingerprint };
                if (tls.alpn) out.tls.alpn = tls.alpn;
                if (tls.allowInsecure) out.tls.insecure = true;
                if (security == 'reality') {
                    require_value(type(tls.publicKey) == 'string' && length(tls.publicKey) > 0, 'missing_reality_key');
                    out.tls.reality = { enabled: true, public_key: tls.publicKey, short_id: tls.shortId ?? '' };
                }
            }
            if (network == 'grpc') out.transport = { type: 'grpc', service_name: stream.grpcSettings?.serviceName ?? '' };
            let name = profile.remarks ?? ob.tag;
            require_value(type(name) == 'string' && length(trim(name)) > 0 && length(name) <= 256 && !match(name, /[[:cntrl:]]/), 'invalid_display_name');
            let signature = canonical(out);
            if (connections[signature]) { push(skipped, 'duplicate_connection'); continue; }
            connections[signature] = true;
            push(nodes, { name, outbound: out });
        }
    }
    require_value(length(nodes) > 0 && length(nodes) <= 128, 'empty_compatible_set');
    return { nodes, skipped };
}

function reconcile(previous, incoming, hash) {
    let assigned = {}, consumed = {};
    for (let i = 0; i < length(incoming); i++) {
        let matches = filter(previous, old => !consumed[old.id] && canonical(old.outbound) == canonical(incoming[i].outbound));
        if (length(matches) == 1) { assigned[i] = matches[0].id; consumed[matches[0].id] = true; }
    }
    for (let i = 0; i < length(incoming); i++) {
        if (assigned[i]) continue;
        let remaining = filter(incoming, (n, j) => !assigned[j] && trim(n.name) == trim(incoming[i].name));
        let matches = filter(previous, old => !consumed[old.id] && trim(old.name) == trim(incoming[i].name));
        if (length(matches) == 1 && length(remaining) == 1) { assigned[i] = matches[0].id; consumed[matches[0].id] = true; }
        else if (length(matches)) die('ambiguous_identity');
    }
    return map(incoming, (n, i) => ({ name: n.name, outbound: n.outbound, id: assigned[i] ?? hash(canonical(n.outbound)) }));
}

function plan(previous, incoming, selected, hash, fallback) {
    let nodes = reconcile(previous, incoming, hash), by_id = {}, old = {}, current = {}, old_names = {}, names = {};
    for (let n in previous) { old[n.id] = n.outbound; old_names[n.id] = n.name; }
    for (let n in nodes) { by_id[n.id] = n; current[n.id] = n.outbound; names[n.id] = n.name; }
    let chosen = selected;
    if (!by_id[chosen]) {
        require_value(by_id[fallback] != null, 'fallback_not_verified');
        chosen = fallback;
    }
    let prior = map(previous, n => n.id), order = filter(prior, id => by_id[id] != null);
    for (let id in sort(keys(by_id))) if (index(order, id) < 0) push(order, id);
    let position = index(prior, selected);
    if (position < 0 || position >= length(order)) position = 0;
    order = filter(order, id => id != chosen);
    splice(order, position, 0, chosen);
    return { nodes: map(order, id => by_id[id]), selected_id: chosen, selected_tag: sprintf('main-%d-out', position + 1),
        runtime_changed: canonical(old) != canonical(current), labels_changed: canonical(old_names) != canonical(names), fallback_used: selected != chosen };
}

function proxy_uri(node) {
    let o = node.outbound, query = { encryption: 'none', type: o.transport?.type ?? 'tcp', security: o.tls?.reality ? 'reality' : o.tls?.enabled ? 'tls' : 'none' };
    if (o.flow) query.flow = o.flow;
    if (o.tls?.enabled) {
        query.sni = o.tls.server_name;
        if (o.tls.utls?.enabled) query.fp = o.tls.utls.fingerprint;
        if (o.tls.alpn) query.alpn = join(',', o.tls.alpn);
        if (o.tls.insecure) query.allowInsecure = '1';
        if (o.tls.reality) { query.pbk = o.tls.reality.public_key; query.sid = o.tls.reality.short_id; }
    }
    if (o.transport?.type == 'grpc') query.serviceName = o.transport.service_name;
    // Stock 0.7.22 decodes the whole URI before parsing query parameters.
    for (let k, v in query) require_value(!match('' + v, /[&?#%+[:space:][:cntrl:]]/), 'unrepresentable_stock_uri');
    let host = index(o.server, ':') >= 0 ? '[' + o.server + ']' : o.server;
    return 'vless://' + o.uuid + '@' + host + ':' + o.server_port + '?' +
        join('&', map(sort(keys(query)), k => k + '=' + encode(query[k]))) + '#' + encode(node.name);
}

function sample(metrics, result, cap, min_bytes, min_seconds) {
    let bytes = +metrics.size_download, body = +metrics.time_total - +metrics.time_starttransfer;
    if (+metrics.http_code != 200) return { error: 'unexpected_http_status' };
    if (index([0, 28, 63], result) < 0) return { error: 'transfer_failed' };
    if (bytes > cap || body <= 0) return { error: 'invalid_sample' };
    let complete = result == 0 && bytes == cap;
    if (bytes < min_bytes || (body < min_seconds && !complete)) return { error: 'insufficient_sample', bytes, seconds: body };
    return { mbps: bytes * 8.0 / body / 1000000.0, bytes, seconds: body,
        short_sample: body < min_seconds,
        limit: result == 28 ? 'time' : result == 63 || bytes == cap ? 'bytes' : 'complete' };
}

function service_sample(metrics, result, body, expected, mime, markers) {
    let fail = code => ({ ok: false, error: code });
    if (expected < 200 || expected > 299 || type(markers) != 'array' || !length(markers)) return fail('service_invalid_contract');
    if (result == 60 || +metrics.ssl_verify_result != 0) return fail('service_tls_failed');
    if (result != 0) return fail(result == 28 ? 'service_timeout' : result == 63 ? 'service_response_too_large' : 'service_transfer_failed');
    if (+metrics.num_redirects != 0 || +metrics.http_code != expected) return fail('service_unexpected_http_status');
    if (length(body) > 524288) return fail('service_response_too_large');
    if (lc(trim(split(metrics.content_type ?? '', ';')[0])) != lc(mime)) return fail('service_content_type_mismatch');
    if (match(lc(body), /access denied|request blocked|access blocked|just a moment|attention required|captcha|доступ запрещен|доступ ограничен/)) return fail('service_block_page');
    for (let marker in markers) if (!length(marker) || index(body, marker) < 0) return fail('service_content_mismatch');
    return { ok: true, http_status: +metrics.http_code, bytes: length(body), tls_verified: true };
}

// Decides only when to re-fetch/apply, never whether data is safe to activate.
function deferred_gate(candidate, series, now, delay, max_wait) {
    let version = candidate?.version_at ?? candidate?.first_seen ?? 0;
    let started = series?.started_at ?? 0;
    if (started > 0 && started <= now && now - started >= max_wait) return { ready: true, trigger: 'series_deadline' };
    if (version > 0 && version <= now && now - version >= delay) return { ready: true, trigger: 'stable_version' };
    return { ready: false, trigger: 'version_hold' };
}

export { canonical, encode, decode, parse_provider, reconcile, plan, proxy_uri, sample, service_sample, deferred_gate };
