// SPDX-License-Identifier: GPL-2.0-only
// Hourly sparse numeric counters. Never imported into the routing job lock.
import * as fs from 'fs';
const BASE = '/tmp/podkop-tools', DIR = BASE + '/history';
const PERSIST = '/etc/podkop-tools/history.json.gz';
const LIMIT = 1048576, SHARD = 65536, META_RESERVE = 65536;
// Values contain only numeric counters and validated whitespace-free identifiers.
function compact(value) { return replace(sprintf('%J', value), /[[:space:]]/g, ''); }
// Row: attempts, successes, delay sum, min, max, outages, switches, delay count.
function private_dir(path) {
    let s = fs.lstat(path);
    if (!s) { if (!fs.mkdir(path, 0700)) return false; s = fs.lstat(path); }
    return s?.type == 'directory' && s.uid == 0 && fs.chmod(path, 0700);
}
function safe(path, cap) {
    let s = fs.lstat(path);
    return s?.type == 'file' && s.uid == 0 && s.nlink == 1 && s.size <= cap && (s.mode & 077) == 0;
}
function atom(path, text) {
    let tmp = path + '.new';
    if (fs.lstat(tmp)) {
        if (!safe(tmp, LIMIT + SHARD)) return false;
        fs.unlink(tmp);
    }
    let f = fs.open(tmp, 'wx', 0600);
    if (!f) return false;
    let ok = f.write(text) == length(text); f.close();
    if (!ok || !fs.rename(tmp, path)) { fs.unlink(tmp); return false; }
    return true;
}
function lock() {
    if (!private_dir(BASE) || !private_dir(DIR)) return null;
    let p = BASE + '/history.lock', s = fs.lstat(p);
    if (s && !safe(p, 64)) return null;
    let f = fs.open(p, s ? 'r+' : 'wx', 0600);
    if (!f || !f.lock('xn')) { if (f) f.close(); return null; }
    return f;
}
function hours() {
    return sort(filter(fs.lsdir(DIR) ?? [], n => !!match(n, /^[0-9]+\.json$/)), (a, b) => int(a) - int(b));
}
function read(path) {
    if (!safe(path, SHARD)) return null;
    try { return json(fs.readfile(path, SHARD)); } catch (e) { return null; }
}
function valid_id(id) { return type(id) == 'string' && length(id) >= 1 && length(id) <= 128 && !!match(id, /^[a-zA-Z0-9_-]+$/); }
function valid_dictionary(ids) {
    if (type(ids) != 'array' || length(ids) > 256) return false;
    let seen = {};
    for (let id in ids) {
        if (id == null) continue;
        if (!valid_id(id) || seen[id]) return false;
        seen[id] = true;
    }
    return true;
}
function valid_order(order, ids) {
    if (type(order) != 'array' || length(order) > 256) return false;
    let seen = {};
    for (let slot in order) {
        if (type(slot) != 'int' || slot < 0 || slot >= 256 || !ids[slot] || seen[slot]) return false;
        seen[slot] = true;
    }
    return length(order) == length(filter(ids, id => id != null));
}
function valid_data(data, ids) {
    if (type(data) != 'object' || length(keys(data)) > 256) return false;
    for (let id, r in data) {
        if (!match(id, /^[0-9]+$/) || '' + int(id) != id || int(id) >= 256 || (ids && !ids[int(id)]) || type(r) != 'array' || length(r) != 8) return false;
        for (let i = 0; i < 8; i++) {
            if ((i == 3 || i == 4) && r[i] == null) continue;
            if ((type(r[i]) != 'int' && type(r[i]) != 'double') || r[i] < 0 || r[i] > 1e15) return false;
        }
        if (r[1] > r[0] || r[7] > r[1]) return false;
    }
    return true;
}
function meta() {
    let fresh = { truncated: false, dirty: false, snapshot_at: 0, bytes: 0, sizes: {}, hour: null, ids: [], order: [] };
    if (!fs.lstat(DIR + '/meta')) return fresh;
    let m = read(DIR + '/meta');
    return type(m) == 'object' ? m : { broken: true, truncated: true };
}
function trim_meta(m, now, reserve) {
    let current = int(now / 3600), changed = false;
    // The index is bounded to 720 compact hour/size entries; no shard scan on a tick.
    let ordered = sort(keys(m.sizes), (a, b) => int(a) - int(b));
    for (let n in ordered) {
        if ((int(n) >= current - 719 && int(n) <= current) && m.bytes + reserve <= LIMIT - META_RESERVE) continue;
        fs.unlink(DIR + '/' + n + '.json'); m.bytes -= m.sizes[n]; delete m.sizes[n]; changed = true;
    }
    if (changed) { m.truncated = true; m.dirty = true; }
    m.hour = current;
}
function prune(now, reserve) {
    let m = meta(); delete m.broken; m.bytes = 0; m.sizes = {};
    for (let n in hours()) {
        let p = DIR + '/' + n;
        if (!safe(p, SHARD)) { fs.unlink(p); m.truncated = true; continue; }
        m.sizes[int(n)] = fs.lstat(p).size; m.bytes += m.sizes[int(n)];
    }
    trim_meta(m, now, reserve); atom(DIR + '/meta', compact(m));
}
function history_record(id, now, ok, delay, reason) {
    let f;
    try {
        if (!valid_id(id) || type(now) != 'int' || now < 0 || int(now / 3600) < int(time() / 3600) - 719 || now > time() + 3600 ||
            (ok != null && type(ok) != 'bool')) return false;
        if (ok == null && (type(reason) != 'string' || !length(reason))) return false;
        f = lock(); if (!f) return false;
        let m = meta();
        if ((!fs.lstat(DIR + '/meta') && length(fs.lsdir(DIR) ?? [])) || m.broken || type(m.bytes) != 'int' || m.bytes < 0 || type(m.sizes) != 'object' || length(keys(m.sizes)) > 720 || !valid_dictionary(m.ids) || !valid_order(m.order, m.ids)) { f.close(); return false; }
        if (m.hour != int(time() / 3600)) trim_meta(m, int(time()), 0);
        let slot = index(m.ids, id);
        if (slot < 0) {
            slot = index(m.ids, null);
            if (slot < 0 && length(m.ids) < 256) slot = length(m.ids);
            if (slot < 0) {
                m.dictionary_full = true; m.sampling_lost = true; m.truncated = true; m.dirty = true;
                atom(DIR + '/meta', compact(m)); f.close(); return false;
            }
            m.ids[slot] = id; push(m.order, slot);
        }
        let path = DIR + '/' + int(now / 3600) + '.json', d = read(path) ?? {};
        if (!valid_data(d, m.ids)) d = {};
        let r = d['' + slot] ?? [0, 0, 0, null, null, 0, 0, 0];
        if (ok != null) {
            r[0]++; if (ok) r[1]++;
            if (ok && (type(delay) == 'int' || type(delay) == 'double') && delay >= 0 && delay <= 3600000) {
                r[2] += delay; r[3] = r[3] == null ? delay : min(r[3], delay);
                r[4] = r[4] == null ? delay : max(r[4], delay); r[7]++;
            }
        } else if (reason == 'outage') r[5]++; else r[6]++;
        d['' + slot] = r;
        let raw = compact(d);
        if (length(raw) > SHARD) { f.close(); return false; }
        let key = '' + int(now / 3600), previous = m.sizes[key] ?? 0;
        if (m.bytes - previous + length(raw) > LIMIT - META_RESERVE) {
            trim_meta(m, int(time()), max(0, length(raw) - previous)); previous = m.sizes[key] ?? 0;
        }
        if (!atom(path, raw)) { f.close(); return false; }
        m.bytes = m.bytes - previous + length(raw); m.sizes[key] = length(raw);
        m.dirty = true;
        if (!atom(DIR + '/meta', compact(m))) { fs.unlink(path); f.close(); return false; }
        f.close(); return true;
    } catch (e) { if (f) f.close(); return false; }
}
function history_query(id, period) {
    let spans = { '24h': 24, '7d': 168, '30d': 720 }, span = spans[period];
    if (!valid_id(id) || !span) return { error: 'invalid_history_query' };
    let q = { id, period, rows: [], totals: { attempts: 0, successes: 0, availability: null, delay_avg: null, failures: 0, switches: 0 },
        truncated: false, coverage_start: null, basis: 'HTTPS_CONTROL_ENDPOINT' };
    try {
        let end = int(time() / 3600), start = end - span + 1, sum = 0, delays = 0;
        let m = meta(); q.truncated = !!m.truncated; q.sampling_lost = !!m.sampling_lost;
        if (!valid_dictionary(m.ids)) { q.truncated = true; return q; }
        let slot = index(m.ids, id); if (slot < 0) return q;
        for (let n in hours()) {
            let h = int(n); if (h < start || h > end) continue;
            let d = read(DIR + '/' + n);
            if (type(d) != 'object') { q.truncated = true; continue; }
            let r = d['' + slot]; if (!r) continue;
            let selected = {}; selected['' + slot] = r;
            if (!valid_data(selected, m.ids)) { q.truncated = true; continue; }
            push(q.rows, { hour: h * 3600, attempts: r[0], successes: r[1], delay_sum: r[2], delay_count: r[7], delay_min: r[3], delay_max: r[4], failures: r[5], switches: r[6] });
            q.totals.attempts += r[0]; q.totals.successes += r[1]; q.totals.failures += r[5]; q.totals.switches += r[6]; sum += r[2]; delays += r[7];
            if (q.coverage_start == null) q.coverage_start = h * 3600;
        }
        if (q.totals.attempts) q.totals.availability = 100.0 * q.totals.successes / q.totals.attempts;
        if (delays) q.totals.delay_avg = sum / delays;
    } catch (e) { q.truncated = true; }
    return q;
}
function history_snapshot(now) {
    let f, out;
    try {
        f = lock(); if (!f) return false;
        let m = meta();
        if (!m.dirty || (m.snapshot_at && now - m.snapshot_at < 21600) || !private_dir('/etc/podkop-tools')) { f.close(); return false; }
        // Only maintenance scans rows to reclaim a full dictionary. Never the tick path.
        if (m.dictionary_full || (length(m.ids) == 256 && index(m.ids, null) < 0)) {
            let victim = m.order[0];
            if (type(victim) != 'int' || !m.ids[victim]) { f.close(); return false; }
            for (let n in hours()) {
                let p = DIR + '/' + n, d = read(p);
                if (!valid_data(d, m.ids)) { fs.unlink(p); continue; }
                delete d['' + victim];
                if (length(keys(d))) { if (!atom(p, compact(d))) { f.close(); return false; } }
                else fs.unlink(p);
            }
            m.ids[victim] = null; shift(m.order); m.dictionary_full = false; m.truncated = true;
            if (!atom(DIR + '/meta', compact(m))) { f.close(); return false; }
        }
        prune(now, 0);
        let tmp = BASE + '/history.snapshot.gz';
        if (fs.lstat(tmp) && safe(tmp, LIMIT + SHARD)) fs.unlink(tmp);
        if (fs.lstat(tmp) || (fs.lstat(PERSIST) && !safe(PERSIST, 262144))) { f.close(); return false; }
        for (let retry = 0; retry < 64; retry++) {
            // Shell creates a private exclusive file; all paths are constant.
            out = fs.popen('(umask 077; set -C; gzip -c > /tmp/podkop-tools/history.snapshot.gz) 2>/dev/null', 'w');
            if (!out) break;
            m = meta();
            out.write('{"version":2,"ids":' + compact(m.ids) + ',"order":' + compact(m.order) + ',"sampling_lost":' + (m.sampling_lost ? 'true' : 'false') + ',"truncated":' + (m.truncated ? 'true' : 'false') + ',"hours":[\n');
            let first = true;
            for (let n in hours()) {
                let d = read(DIR + '/' + n); if (!valid_data(d, m.ids)) continue;
                out.write((first ? '' : ',') + compact([int(n), d]) + '\n'); first = false;
            }
            out.write(']}\n'); let status = out.close(); out = null;
            if (status != 0 || !safe(tmp, LIMIT)) { fs.unlink(tmp); break; }
            if (fs.lstat(tmp).size <= 262144) {
                // Reserve the flash interval before touching flash, including failed attempts.
                m = meta(); m.snapshot_at = now;
                if (!atom(DIR + '/meta', compact(m))) break;
                let target = PERSIST + '.new';
                if (fs.lstat(target) && safe(target, 262144)) fs.unlink(target);
                if (fs.lstat(target)) break;
                let dest = fs.open(target, 'wx', 0600), source = fs.open(tmp, 'r');
                if (!dest || !source) { if (dest) dest.close(); if (source) source.close(); break; }
                let copied = true;
                while (true) { let chunk = source.read(4096); if (!length(chunk)) break; if (dest.write(chunk) != length(chunk)) { copied = false; break; } }
                source.close(); dest.close();
                if (!copied || !fs.rename(target, PERSIST)) { fs.unlink(target); break; }
                fs.unlink(tmp);
                prune(now, 0); m = meta(); m.dirty = false; m.snapshot_at = now; atom(DIR + '/meta', compact(m)); f.close(); return true;
            }
            fs.unlink(tmp);
            let files = hours(); if (!length(files)) break;
            // At most sixty-four bounded retries, each drops a fixed fraction in tmpfs.
            let batch = max(1, int((length(files) + 7) / 8));
            for (let i = 0; i < batch; i++) fs.unlink(DIR + '/' + files[i]);
            m = meta(); m.truncated = true; atom(DIR + '/meta', compact(m));
        }
        fs.unlink(tmp); f.close(); return false;
    } catch (e) { if (out) out.close(); if (f) f.close(); return false; }
}
function history_restore() {
    let f, input;
    try {
        f = lock(); if (!f) return false;
        if (length(hours()) || !safe(PERSIST, 262144)) { f.close(); return false; }
        input = fs.popen('gzip -dc /etc/podkop-tools/history.json.gz 2>/dev/null', 'r');
        if (!input) { f.close(); return false; }
        let total = 0, buffer = '', header = null, end = false, seen = {}, staged = [];
        // Bounded chunks and lines: never parse or retain the complete history.
        while (true) {
            let chunk = input.read(4096); if (!length(chunk)) break;
            total += length(chunk); if (total > LIMIT + 65536) die('history_size');
            buffer += chunk;
            while (index(buffer, '\n') >= 0) {
                let pos = index(buffer, '\n'), line = substr(buffer, 0, pos); buffer = substr(buffer, pos + 1);
                if (length(line) > SHARD + 64 || end) die('history_line');
                if (!header) {
                    header = json(line + ']}');
                    if (header.version != 2 || type(header.truncated) != 'bool' || !valid_dictionary(header.ids) || !valid_order(header.order, header.ids)) die('history_version');
                } else if (line == ']}') end = true;
                else {
                    if (substr(line, 0, 1) == ',') line = substr(line, 1);
                    let row = json(line);
                    if (type(row) != 'array' || length(row) != 2 || type(row[0]) != 'int' || row[0] < 0 || seen[row[0]] || !valid_data(row[1], header.ids) || length(staged) >= 720) die('history_row');
                    seen[row[0]] = true;
                    let name = DIR + '/' + row[0] + '.restore';
                    if (!atom(name, compact(row[1]))) die('history_write');
                    push(staged, name);
                }
            }
            if (length(buffer) > SHARD + 64) die('history_line');
        }
        let status = input.close(); input = null;
        if (status != 0 || !end || length(buffer)) die('history_incomplete');
        for (let name in staged) fs.rename(name, replace(name, /\.restore$/, '.json'));
        atom(DIR + '/meta', compact({ truncated: header.truncated, sampling_lost: !!header.sampling_lost, ids: header.ids, order: header.order, dirty: false, snapshot_at: int(time()) }));
        prune(int(time()), 0); f.close(); return true;
    } catch (e) {
        if (input) input.close();
        for (let n in fs.lsdir(DIR) ?? []) if (match(n, /^[0-9]+\.restore(\.new)?$/)) fs.unlink(DIR + '/' + n);
        if (f) f.close(); return false;
    }
}
export { history_record, history_query, history_snapshot, history_restore };
