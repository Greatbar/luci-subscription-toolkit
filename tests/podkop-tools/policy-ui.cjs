// SPDX-License-Identifier: GPL-2.0-only
// Runs actual LuCI views; statistics are loaded only by explicit panel interactions.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../htdocs/luci-static/resources/view/podkop-tools');
function E(tag, attrs = {}, children = []) { return { tag, attrs, children: Array.isArray(children) ? children : [children] }; }
function walk(n) { return n && typeof n === 'object' ? [n, ...n.children.flatMap(walk)] : []; }
function text(n) { return n == null ? '' : typeof n === 'object' ? n.children.map(text).join(' ') : String(n); }
function harness() {
  const requests = [], polls = [], options = [];
  const a = 'a'.repeat(64), b = 'b'.repeat(64), hour = Math.floor(Date.now() / 3600000) * 3600;
  const state = { preferred_id: a, selection_origin: 'failure', last_switch_reason: 'active_unavailable', recovery: { stage: 'reserves', cursor: 2 },
    policy: { latency_enabled: true, cooldown_until: hour + 600 }, nodes: [{ id: a, name: 'Предпочтение' }, { id: b, name: '<script>bad</script>', selected: true }] };
  let response = { basis: 'HTTPS_CONTROL_ENDPOINT', coverage_start: hour - 10800, rows: [
    { hour: hour - 10800, attempts: 2, successes: 1, delay_sum: 40, delay_min: 40, delay_max: 40, failures: 1, switches: 0 },
    { hour: hour - 3600, attempts: 2, successes: 2, delay_sum: 100, delay_min: 40, delay_max: 60, failures: 0, switches: 1 },
    { hour, attempts: 0, successes: 0, delay_sum: 0, delay_min: null, delay_max: null, failures: 0, switches: 0 }
  ], totals: { attempts: 4, successes: 3, failures: 1, switches: 1 } };
  const rpc = { declare: spec => async (...args) => { requests.push({ method: spec.method, args }); return spec.method === 'status' ? state : spec.method === 'statistics' ? response : { ok: true }; } };
  const document = { addEventListener() {}, createElementNS(ns, tag) { const el = E(tag); el.ns = ns; el.setAttribute = (k, v) => { el.attrs[k] = String(v); }; el.appendChild = c => el.children.push(c); return el; } };
  const form = { NamedSection: 0, Flag: 1, Value: 2, ListValue: 3, DynamicList: 4, Map: class { section() { return { option(type, name) { const o = { name, type, values: [], value(k,v) { this.values.push([k,v]); }, depends() {} }; options.push(o); return o; } }; } render() { return E('form'); } } };
  const globals = { E, rpc, document, form, view: { extend: v => v }, dom: { content: (n, c) => { n.children = [c]; } }, poll: { add: f => polls.push(f) }, ui: { addNotification() {} }, L: { hasViewPermission: () => true } };
  return { a, b, state, requests, polls, options, setResponse(v) { response = v; }, load(name) { return new Function(...Object.keys(globals), fs.readFileSync(path.join(root, name + '.js'), 'utf8'))(...Object.values(globals)); } };
}
(async () => {
  const h = harness(), v = h.load('dashboard'), tree = v.render(await v.load());
  assert.ok(text(tree).includes('Предпочтительный сервер:'));
  assert.ok(text(tree).includes('Нет ответа активного сервера'));
  assert.ok(text(tree).includes('Проверка резервов'));
  const probeHarness = harness(), probeView = probeHarness.load('dashboard');
  probeHarness.state.control = {ok: null, at: 1700000000, failures: 0};
  assert.ok(text(probeView.render(await probeView.load())).includes('Неизвестно'));
  probeHarness.state.control.ok = true;
  assert.ok(text(probeView.render(await probeView.load())).includes('Получен HTTPS-ответ'));
  assert.equal(h.requests.filter(r => r.method === 'statistics').length, 0);
  const panel = walk(tree).find(n => n.tag === 'details' && text(n.children[0]) === 'Статистика HTTPS');
  assert.ok(panel);
  await panel.attrs.toggle({ target: { open: true } });
  assert.deepEqual(h.requests.at(-1), { method: 'statistics', args: [h.a, '24h'] });
  assert.ok(text(tree).includes('75 %'));
  assert.ok(text(tree).includes('Проб: 4'));
  assert.ok(text(tree).includes('Нет проб'));
  assert.ok(text(tree).includes('разрывы'));
  assert.equal(walk(tree).filter(n => n.tag === 'svg').length, 3);
  assert.ok(walk(tree).filter(n => n.tag === 'svg').every(n => n.ns === 'http://www.w3.org/2000/svg'));
  // The two populated hours have a gap; no graph line bridges it.
  assert.equal(walk(tree).filter(n => n.tag === 'polyline').length, 0);
  assert.ok(!JSON.stringify(tree).includes('innerHTML'));
  await h.polls[0](); await h.polls[0]();
  assert.equal(h.requests.filter(r => r.method === 'statistics').length, 1);
  const period = walk(tree).find(n => n.tag === 'select' && n.attrs['aria-label'] === 'Период статистики');
  await period.attrs.change({ target: { value: '7d' } });
  assert.deepEqual(h.requests.at(-1).args, [h.a, '7d']);
  const server = walk(tree).find(n => n.tag === 'select' && n.attrs['aria-label'] === 'Сервер статистики');
  await server.attrs.change({ target: { value: h.b } });
  assert.deepEqual(h.requests.at(-1).args, [h.b, '7d']);
  h.setResponse({ rows: [null, { hour: 'bad', attempts: -1 }, { hour: Infinity, attempts: 10 }], totals: {} });
  await period.attrs.change({ target: { value: '30d' } });
  assert.ok(text(tree).includes('Нет проб за выбранный период'));
  assert.ok(!JSON.stringify(tree).includes('NaN'));
  h.setResponse(null); await server.attrs.change({ target: { value: h.a } });
  assert.ok(text(tree).includes('Нет проб за выбранный период'));
  // Out-of-order requests must not replace the current selection's history.
  let resolveOld;
  h.setResponse(new Promise(resolve => { resolveOld = resolve; }));
  const oldRequest = server.attrs.change({ target: { value: h.b } });
  h.setResponse({ rows: [], totals: {} });
  await period.attrs.change({ target: { value: '24h' } });
  resolveOld({ rows: [{ hour: Math.floor(Date.now() / 3600000) * 3600, attempts: 999, successes: 999, failures: 0, switches: 0 }] });
  await oldRequest;
  assert.ok(text(tree).includes('Нет проб за выбранный период'));
  assert.ok(!text(tree).includes('Проб: 999'));
  h.setResponse(Promise.reject(new Error('unavailable')));
  await server.attrs.change({ target: { value: h.a } });
  assert.ok(text(tree).includes('Не удалось загрузить статистику'));
  // A successful hour with no latency samples is never plotted as zero delay.
  h.setResponse({ rows: [{ hour: Math.floor(Date.now() / 3600000) * 3600, attempts: 1, successes: 1, failures: 0, switches: 0, delay_sum: null, delay_min: null, delay_max: null }] });
  await period.attrs.change({ target: { value: '24h' } });
  const delayGraph = walk(tree).find(n => n.tag === 'svg' && n.attrs['aria-label'] === 'Задержка успешных HTTPS-проб, мс');
  assert.equal(walk(delayGraph).filter(n => n.tag === 'circle').length, 0);
  const statsReads = h.requests.filter(r => r.method === 'statistics').length;
  const currentPanel = walk(tree).find(n => n.tag === 'details' && text(n.children[0]) === 'Статистика HTTPS');
  await currentPanel.attrs.toggle({ target: { open: false } });
  await period.attrs.change({ target: { value: '7d' } });
  assert.equal(h.requests.filter(r => r.method === 'statistics').length, statsReads);
  const settings = h.load('settings'); settings.render(h.state);
  const expected = { probe_timeout_seconds: '5', failure_seconds: '120', failure_count: '3', latency_threshold_ms: '1000', latency_duration_seconds: '300', improvement_percent: '20', improvement_ms: '50', cooldown_seconds: '600', failback_seconds: '600', failback_successes: '3' };
  for (const [key, value] of Object.entries(expected)) assert.equal(h.options.find(o => o.name === key)?.default, value, key);
  assert.equal(h.options.find(o => o.name === 'health_minutes').default, '1');
  assert.equal(h.options.find(o => o.name === 'priority_ids').type, 4);
  assert.ok(h.options.find(o => o.name === 'priority_ids').values.some(([id]) => id === h.a));
  assert.equal(h.options.find(o => o.name === 'latency_enabled').default, '0');
  assert.equal(h.options.find(o => o.name === 'failback_enabled').default, '1');
  assert.ok(!h.options.some(o => o.name === 'fallback_id'));
  console.log('PASS policy UI: preferred/active, policy settings, lazy statistics, periods/IDs, SVG gaps, corrupt data');
})().catch(error => { console.error(error); process.exitCode = 1; });
