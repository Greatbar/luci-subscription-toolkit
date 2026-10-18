// SPDX-License-Identifier: GPL-2.0-only
import * as fs from 'fs';
import { history_record, history_query, history_snapshot, history_restore } from '/usr/libexec/podkop-tools/statistics.uc';
let count = 0;
function assert(ok, msg) { if (!ok) die(msg); count++; }
let now = int(time() / 3600) * 3600;
let ID = sprintf('%064x', 1);
assert(history_record(ID, now, true, 100, null), 'record_success');
assert(history_record(ID, now + 10, false, null, null), 'record_failed_sample');
assert(history_record(ID, now + 20, null, null, 'outage'), 'confirmed_outage');
assert(history_record(ID, now + 30, null, null, 'manual'), 'manual_switch');
let q = history_query(ID, '24h');
assert(length(q.rows) == 1 && q.rows[0].hour == now, 'hour_bucket');
assert(q.totals.attempts == 2 && q.totals.successes == 1 && q.totals.availability == 50, 'availability');
assert(q.totals.failures == 1 && q.totals.switches == 1, 'episodes_separate_samples');
assert(q.totals.delay_avg == 100 && q.rows[0].delay_min == 100, 'latency');
assert(!length(history_query('renamed-label', '24h').rows), 'identity_only');
assert(!history_record('../bad', now, true, 1, null), 'reject_invalid_id');
assert(history_snapshot(now), 'snapshot');
let packed = fs.popen('gzip -dc /etc/podkop-tools/history.json.gz', 'r');
let unpacked = packed.read('all'); packed.close();
assert(length(split(unpacked, ID)) == 2, 'stable_id_once_globally');
let before_query = length(fs.lsdir('/tmp/podkop-tools/history'));
assert(length(history_query(ID, '30d').rows) > 0, 'known_id_rows');
history_query(sprintf('%064x', 999), '30d');
assert(length(fs.lsdir('/tmp/podkop-tools/history')) == before_query, 'query_does_not_create_missing_hours');
let stored = json(fs.readfile('/tmp/podkop-tools/history/' + int(now / 3600) + '.json'));
assert(stored['0'] != null && stored[ID] == null, 'numeric_shard_keys');
assert(!history_snapshot(now + 1), 'clean_snapshot_not_written');
assert(history_record('node-b', now, true, 10, null), 'dirty_after_snapshot');
assert(!history_snapshot(int(time()) + 1), 'dirty_six_hour_guard');
fs.unlink('/tmp/podkop-tools/history/' + int(now / 3600) + '.json');
assert(history_restore(), 'restore');
assert(history_query(ID, '30d').totals.attempts == 2, 'restore_samples');
assert(history_record(ID, now - 721 * 3600, true, 10, null) == false, 'reject_expired');
assert(!history_query(ID, 'invalid').rows, 'invalid_period');
assert(history_record(ID, now - 10 * 3600, true, 50, null), 'late_sample');
assert(history_query(ID, '24h').totals.attempts == 3, 'late_sample_preserves_newer');
let outside = '/tmp/statistics-outside'; fs.writefile(outside, 'secret'); fs.chmod(outside, 0600);
let linked = '/tmp/podkop-tools/history/' + int((now - 2 * 3600) / 3600) + '.json';
fs.symlink(outside, linked);
assert(history_record(ID, now, true, 200, null), 'symlink_shard_safe');
assert(fs.readfile(outside) == 'secret', 'symlink_target_untouched');
let locked = fs.open('/tmp/podkop-tools/history.lock', 'r+'); locked.lock('x');
// A separate process must fail immediately, even while another history operation owns the lock.
let proc = fs.popen("ucode -e 'import { history_record } from \"/usr/libexec/podkop-tools/statistics.uc\"; exit(history_record(\"node-a\",int(time()),true,1,null) ? 1 : 0)'", 'r');
assert(proc.close() == 0, 'busy_history_best_effort'); locked.close();
print(sprintf('%J\n', { passed: count }));
// Real64-hex-ID cases report retention depth and total serialized RAM, including metadata.
function hwm() { return +match(fs.readfile('/proc/self/status'), /VmHWM:[[:space:]]+([0-9]+)/)[1]; }
function compact(v) { return replace(sprintf('%J', v), /[[:space:]]/g, ''); }
function snapshot_id_count(id) {
    let f = fs.popen('gzip -dc /etc/podkop-tools/history.json.gz', 'r'), buffer = '', hits = 0;
    while (true) {
        let chunk = f.read(4096); if (!length(chunk)) break;
        buffer += chunk; hits += length(split(buffer, id)) - 1;
        buffer = substr(buffer, max(0, length(buffer) - length(id) + 1));
    }
    assert(f.close() == 0, 'snapshot_valid_gzip'); return hits;
}
function clear_history() { for (let n in fs.lsdir('/tmp/podkop-tools/history')) fs.unlink('/tmp/podkop-tools/history/' + n); }
let baseline = hwm();
for (let servers in [11, 32, 128]) {
    clear_history();
    let seeded = { truncated: false, dirty: true, snapshot_at: 0, bytes: 0, sizes: {}, ids: [], order: [], hour: int(now / 3600) };
    for (let j = 0; j < servers; j++) { push(seeded.ids, sprintf('%064x', j + 1)); push(seeded.order, j); }
    let d = {};
    for (let j = 0; j < servers; j++) d['' + j] = [100, 97, 9700, 50, 200, 1, 2, 97];
    let raw = compact(d);
    for (let i = 0; i < 720; i++) {
        let hour = int(now / 3600) - i, p = '/tmp/podkop-tools/history/' + hour + '.json';
        fs.writefile(p, raw); fs.chmod(p, 0600);
        seeded.sizes['' + hour] = length(raw); seeded.bytes += length(raw);
    }
    fs.writefile('/tmp/podkop-tools/history/meta', compact(seeded)); fs.chmod('/tmp/podkop-tools/history/meta', 0600);
    assert(history_record(ID, now, true, 100, null), 'capacity_record');
    let bytes = fs.stat('/tmp/podkop-tools/history/meta').size;
    for (let n in fs.lsdir('/tmp/podkop-tools/history')) if (match(n, /^[0-9]+\.json$/)) bytes += fs.stat('/tmp/podkop-tools/history/' + n).size;
    assert(bytes <= 1048576, 'serialized_ram_cap_includes_dictionary_and_index');
    q = history_query(ID, '30d');
    assert(length(q.rows) <= 720 && (length(q.rows) == 720 || q.truncated), 'depth_reports_truncation');
    if (servers == 11 || servers == 32) assert(length(q.rows) == 720, 'small_provider_full_retention');
    assert(q.coverage_start == q.rows[0].hour, 'accurate_coverage_start');
    assert(hwm() - baseline <= 8192, 'additional_peak_rss');
    assert(history_snapshot(int(time())), 'capacity_snapshot');
    assert(fs.stat('/etc/podkop-tools/history.json.gz').size <= 262144, 'compressed_snapshot_cap');
    assert(snapshot_id_count(ID) == 1, 'stable_id_once_across_all_hours');
    print(sprintf('%J\n', { servers, hours: length(q.rows), serialized_bytes: bytes, compressed_bytes: fs.stat('/etc/podkop-tools/history.json.gz').size, additional_peak_kib: hwm() - baseline }));
}
// A full global dictionary never makes the tick scan or rewrite historical shards.
clear_history();
for (let j = 0; j < 256; j++) assert(history_record(sprintf('%064x', j + 1), now, true, 10, null), 'dictionary_register');
let overflow = sprintf('%064x', 257);
assert(!history_record(overflow, now, true, 10, null), 'dictionary_full_best_effort');
assert(history_record(sprintf('%064x', 2), now, true, 10, null), 'known_id_works_when_dictionary_full');
assert(history_query(ID, '24h').sampling_lost, 'dictionary_overflow_visible');
assert(history_snapshot(int(time())), 'maintenance_evicts_oldest_id_rows');
assert(history_record(overflow, now, true, 10, null), 'dictionary_slot_reused_after_removal');
assert(!length(history_query(ID, '24h').rows), 'evicted_id_not_aliased');
assert(history_query(overflow, '24h').totals.attempts == 1, 'slot_reuse_no_old_samples');
assert(length(json(fs.readfile('/tmp/podkop-tools/history/meta')).ids) == 256, 'dictionary_remains_bounded');

// Corrupt and expanding compressed input never produces visible shards or affects control callers.
for (let n in fs.lsdir('/tmp/podkop-tools/history')) fs.unlink('/tmp/podkop-tools/history/' + n);
fs.writefile('/etc/podkop-tools/history.json.gz', 'broken'); fs.chmod('/etc/podkop-tools/history.json.gz', 0600);
assert(!history_restore(), 'corrupt_gzip_rejected');
let invalid_dictionary = fs.popen('gzip -c > /etc/podkop-tools/history.json.gz', 'w');
invalid_dictionary.write('{"version":2,"truncated":false,"ids":' + compact([ID, ID]) + ',"order":[0,1],"hours":[\n]}\n');
assert(invalid_dictionary.close() == 0, 'duplicate_dictionary_fixture');
assert(!history_restore(), 'duplicate_dictionary_ids_rejected');
let bomb = fs.popen('head -c 2097152 /dev/zero | gzip -c > /etc/podkop-tools/history.json.gz', 'r');
assert(bomb.close() == 0, 'compressed_bomb_fixture');
assert(!history_restore(), 'bounded_decompression');
assert(!length(filter(fs.lsdir('/tmp/podkop-tools/history'), n => !!match(n, /^[0-9]+\.json$/))), 'restore_failure_no_partial_history');
assert(history_record(ID, now, true, 1, null), 'record_survives_corrupt_snapshot');
let started = time();
for (let i = 0; i < 100; i++) assert(history_record(ID, now, true, i, null), 'normal_tick_record');
print(sprintf('%J\n', { passed: count, hundred_records_seconds: time() - started }));
