// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 LuCI Subscription Toolkit contributors
'use strict';
'require view';
'require dom';
'require rpc';
'require poll';
'require ui';

const status = rpc.declare({ object: 'podkop-tools', method: 'status', params: ['token'], expect: {} });
const actions = {};
['seed', 'fetch', 'apply', 'select', 'latency', 'service', 'speed'].forEach(function(name) {
    actions[name] = rpc.declare({ object: 'podkop-tools', method: name,
        params: name === 'apply' ? ['version'] : ['select', 'latency', 'service', 'speed'].includes(name) ? ['id'] : [], expect: {} });
});
actions.batch = rpc.declare({ object: 'podkop-tools', method: 'batch', params: ['ids', 'kinds', 'speed_bytes', 'token'], expect: {} });
actions.cancel = rpc.declare({ object: 'podkop-tools', method: 'cancel', params: ['token'], expect: {} });
const labels = { latency: 'Задержка', service: 'Telegram Web', speed: 'Скорость' };
function policyLabel(value) {
    return ({manual:'Выбор пользователя', selected:'Выбор пользователя', external:'Выбор в Podkop', migrated:'Принят при обновлении',
        active_unavailable:'Нет ответа активного сервера', boot_adopted_unknown:'Принят при загрузке', outage:'Восстановление после отказа', failback:'Возврат на основной',
        profile_update:'Обновление адреса сервера', latency:'Высокая задержка', applied:'Применение подписки', recovered:'Обновление профиля', rolled_back:'Откат',
        confirm:'Подтверждение отказа', fetch:'Обновление подписки', same:'Проверка нового адреса', reserves:'Проверка резервов', node_removed:'Сервер удалён из подписки'})[value] || '—';
}
const capabilityNames = { fetch: 'Загрузка подписки', monitoring: 'Мониторинг', selector: 'Selector',
    switch: 'Переключение', apply: 'Применение', rollback: 'Откат', recovery: 'Восстановление', measurement: 'Измерения' };
const compatibilityReasons = {
    generator_unavailable: 'Нет подходящего генератора Podkop',
    unsupported_main: 'Конфигурация MAIN не поддерживает эту операцию',
    unsupported_runtime: 'Рабочая конфигурация sing-box не поддерживает эту операцию',
    api_unavailable: 'API управления sing-box недоступен', runtime_unavailable: 'Рабочая конфигурация sing-box недоступна',
    sing_box_unavailable: 'sing-box недоступен', dependency_missing: 'Отсутствует необходимая зависимость',
    rollback_unavailable: 'Нет сохранённой копии для отката', recovery_required: 'Сначала требуется восстановить прерванную транзакцию',
    validation_failed: 'sing-box отклонил подготовленную конфигурацию', generation_failed: 'Не удалось подготовить конфигурацию Podkop',
    generated_nodes_mismatch: 'Генератор изменил список серверов', routing_changed: 'Подготовленная конфигурация меняет защищённые маршруты',
    state_conflict: 'Состояние Toolkit расходится с конфигурацией Podkop', operation_failed: 'Не удалось выполнить операцию'
};
function compatibilityReason(reason) { return compatibilityReasons[reason] || 'Обнаружена несовместимость операции'; }
function capabilityBlocked(state, name) { return state.compatibility?.capabilities?.[name]?.available === false; }
function operationCapability(kind) { return ({seed: 'selector', select: 'switch', latency: 'measurement', service: 'measurement', speed: 'measurement', batch: 'measurement'})[kind] || kind; }
function timestamp(value, compact) {
    return value ? new Date(value * 1000).toLocaleString('ru-RU', compact ?
        { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' } : undefined) : '—';
}
function number(value) { return value.toLocaleString('ru-RU', { maximumFractionDigits: 1 }); }
function button(label, click, disabled) {
    return E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-action',
        disabled: disabled ? true : null, click }, label);
}
function flag(name) {
    if (/[\u{1F1E6}-\u{1F1FF}]{2}/u.test(name)) return '';
    const countries = { 'Латвия': '🇱🇻', 'Швеция': '🇸🇪', 'Германия': '🇩🇪', 'Нидерланды': '🇳🇱',
        'Финляндия': '🇫🇮', 'Франция': '🇫🇷', 'США': '🇺🇸', 'Великобритания': '🇬🇧',
        'Польша': '🇵🇱', 'Эстония': '🇪🇪', 'Литва': '🇱🇹', 'Россия': '🇷🇺', 'Турция': '🇹🇷', 'Япония': '🇯🇵' };
    const country = Object.keys(countries).find(country => name.includes(country));
    return country ? countries[country] + ' ' : '🌐 ';
}

const statistics = rpc.declare({ object: 'podkop-tools', method: 'statistics', params: ['id', 'period'], expect: {} });
const periods = { '24h': 24, '7d': 168, '30d': 720 };
function count(value) { return Number.isSafeInteger(value) && value >= 0 ? value : null; }
function metric(value) { return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null; }
function historyRows(data) {
    const rows = new Map();
    (data && Array.isArray(data.rows) ? data.rows : []).forEach(row => {
        if (!row || count(row.hour) === null || row.hour % 3600 || count(row.attempts) === null ||
            count(row.successes) === null || row.successes > row.attempts || count(row.failures) === null || count(row.switches) === null) return;
        rows.set(row.hour, row);
    });
    return Array.from(rows.values()).sort((a, b) => a.hour - b.hour);
}
function svgElement(tag, attrs, children) {
    const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
    Object.keys(attrs || {}).forEach(key => node.setAttribute(key, attrs[key]));
    (children || []).forEach(child => node.appendChild(child));
    return node;
}
function svgText(tag, attrs, value) {
    const node = svgElement(tag, attrs); node.textContent = value; return node;
}
function historyChart(title, rows, series, start, end, fixedMax) {
    const width = 640, height = 150, left = 48, right = 16, top = 15, bottom = 30;
    let maximum = fixedMax || 1;
    rows.forEach(row => series.forEach(line => { const value = line.value(row); if (metric(value) !== null) maximum = Math.max(maximum, value); }));
    const x = hour => left + (hour - start) / Math.max(3600, end - start) * (width - left - right);
    const y = value => height - bottom - value / maximum * (height - top - bottom);
    const elements = [svgText('title', {}, title),
        svgElement('path', { d: 'M' + left + ',' + top + 'V' + (height - bottom) + 'H' + (width - right), stroke: '#777', fill: 'none' }),
        svgText('text', { x: left - 4, y: top + 5, 'text-anchor': 'end', 'font-size': 11, fill: 'currentColor' }, number(maximum)),
        svgText('text', { x: left - 4, y: height - bottom, 'text-anchor': 'end', 'font-size': 11, fill: 'currentColor' }, '0'),
        svgText('text', { x: left, y: height - 6, 'font-size': 11, fill: 'currentColor' }, timestamp(start, true)),
        svgText('text', { x: width - right, y: height - 6, 'text-anchor': 'end', 'font-size': 11, fill: 'currentColor' }, timestamp(end, true))];
    const measured = new Set(rows.filter(row => row.attempts > 0).map(row => row.hour));
    // Every missing hour has its own mark; lines below only join adjacent measured hours.
    for (let hour = start; hour <= end; hour += 3600) {
        if (!measured.has(hour)) elements.push(svgElement('line', { x1: x(hour), x2: x(hour), y1: height - bottom + 2, y2: height - bottom + 6, stroke: '#999', 'data-gap-hour': hour }));
    }
    series.forEach(line => {
        let segment = [];
        const flush = () => {
            if (segment.length > 1) elements.push(svgElement('polyline', { points: segment.map(p => x(p.hour) + ',' + y(p.value)).join(' '), fill: 'none', stroke: line.color, 'stroke-width': 2 }));
            segment = [];
        };
        rows.forEach(row => {
            const value = line.value(row);
            if (metric(value) === null || row.hour < start || row.hour > end) { flush(); return; }
            if (segment.length && row.hour - segment[segment.length - 1].hour !== 3600) flush();
            segment.push({ hour: row.hour, value });
            elements.push(svgElement('circle', { cx: x(row.hour), cy: y(value), r: 3, fill: line.color }, [
                svgText('title', {}, timestamp(row.hour) + ' · ' + line.label + ': ' + number(value))]));
        });
        flush();
    });
    return E('figure', { style: 'margin:12px 0' }, [E('figcaption', {}, title + ' · ' + series.map(line => line.label).join(' / ')),
        svgElement('svg', { viewBox: '0 0 ' + width + ' ' + height, role: 'img', 'aria-label': title, style: 'width:100%;max-width:900px;height:auto' }, elements),
        E('p', {}, series.map(line => E('span', { style: 'color:' + line.color + ';margin-right:16px' }, line.label)))]);
}

return view.extend({
    load: function() { return status(''); },
    redraw: function(s) {
        if (s) this.state = s;
        if (this.container) dom.content(this.container, this.content(this.state));
    },
    refresh: async function() { this.redraw(await status(this.batchToken || '')); return this.state; },
    details: function(key, title, children) {
        return E('details', { open: this.openDetails[key] ? true : null,
            toggle: event => { this.openDetails[key] = event.target.open; } }, [E('summary', {}, title)].concat(children));
    },
    loadStatistics: async function() {
        const id = this.statisticsId, period = this.statisticsPeriod;
        if (!this.openDetails.statistics || !id) return;
        const request = this.statisticsRequest = (this.statisticsRequest || 0) + 1;
        this.statisticsLoading = true; this.statisticsError = false; this.statisticsData = null; this.redraw();
        try {
            const data = await statistics(id, period);
            if (request === this.statisticsRequest) {
                this.statisticsData = data;
                this.statisticsError = !!(data && data.ok === false);
            }
        } catch (_) { if (request === this.statisticsRequest) this.statisticsError = true; }
        finally { if (request === this.statisticsRequest) { this.statisticsLoading = false; this.redraw(); } }
    },
    statisticsPanel: function(nodes) {
        const period = this.statisticsPeriod, data = this.statisticsData;
        const end = Math.floor(Date.now() / 3600000) * 3600, start = end - (periods[period] - 1) * 3600;
        const rows = historyRows(data).filter(row => row.hour >= start && row.hour <= end);
        const totals = rows.reduce((sum, row) => {
            ['attempts', 'successes', 'failures', 'switches'].forEach(key => { sum[key] += row[key]; }); return sum;
        }, { attempts: 0, successes: 0, failures: 0, switches: 0 });
        const sampled = rows.filter(row => row.attempts > 0);
        const controls = E('div', { 'class': 'stk-controls' }, [
            E('label', {}, ['Сервер: ', E('select', { 'aria-label': 'Сервер статистики', change: event => {
                this.statisticsId = event.target.value; return this.loadStatistics();
            } }, nodes.map(n => E('option', { value: n.id, selected: n.id === this.statisticsId ? true : null }, n.name)))]),
            E('label', {}, ['Период: ', E('select', { 'aria-label': 'Период статистики', change: event => {
                if (!periods[event.target.value]) return;
                this.statisticsPeriod = event.target.value; return this.loadStatistics();
            } }, Object.keys(periods).map(key => E('option', { value: key, selected: key === period ? true : null }, { '24h': '24 часа', '7d': '7 дней', '30d': '30 дней' }[key])))])
        ]);
        let body = [];
        if (this.openDetails.statistics) {
            if (this.statisticsLoading) body = [E('p', { role: 'status' }, 'Загрузка статистики…')];
            else if (this.statisticsError) body = [E('p', { role: 'status' }, 'Не удалось загрузить статистику. Измените сервер или период для повторной попытки.')];
            else if (!rows.length || !totals.attempts && !totals.switches && !totals.failures) body = [E('p', {}, 'Нет проб за выбранный период')];
            else {
                const delay = (row, kind) => row.successes > 0 && metric(row.delay_sum) !== null && metric(row.delay_min) !== null &&
                    metric(row.delay_max) !== null && row.delay_min <= row.delay_max ?
                    (kind === 'avg' ? row.delay_sum / (count(row.delay_count) === null ? row.successes : row.delay_count || 1) : row['delay_' + kind]) : null;
                body = [
                    E('p', {}, 'Проб: ' + number(totals.attempts) + ' · Успешных: ' + number(totals.successes) +
                        ' · Доступность по пробам: ' + (totals.attempts ? number(totals.successes / totals.attempts * 100) + ' %' : '—') +
                        ' · Ошибок: ' + number(totals.failures) + ' · Переключений: ' + number(totals.switches)),
                    E('p', {}, 'Фактическое покрытие: ' + sampled.length + ' из ' + periods[period] + ' часовых интервалов' +
                        (sampled.length ? ' · Первая проба: ' + timestamp(sampled[0].hour) + ' · Последний час с пробами: ' + timestamp(sampled[sampled.length - 1].hour) : '') +
                        (data && metric(data.coverage_start) !== null ? ' · История с: ' + timestamp(data.coverage_start) : '') +
                        (data && data.truncated ? ' · История ограничена лимитом хранения' : '')),
                    E('p', {}, 'Нет проб: разрывы и серые отметки. Час без проб не считается ни успешным, ни отказавшим; линии не соединяют пропуски.'),
                    historyChart('Доступность по HTTPS-пробам, %', rows, [{ label: 'Успешные пробы, %', color: '#198754', value: row => row.attempts ? row.successes / row.attempts * 100 : null }], start, end, 100),
                    historyChart('Задержка успешных HTTPS-проб, мс', rows, [
                        { label: 'Средняя', color: '#287ac1', value: row => delay(row, 'avg') },
                        { label: 'Минимум', color: '#198754', value: row => delay(row, 'min') },
                        { label: 'Максимум', color: '#b56a00', value: row => delay(row, 'max') }], start, end),
                    historyChart('Ошибки проб и переключения, количество', rows, [
                        { label: 'Ошибки', color: '#c43b3b', value: row => row.attempts || row.switches || row.failures ? row.failures : null },
                        { label: 'Переключения', color: '#8051b0', value: row => row.attempts || row.switches || row.failures ? row.switches : null }], start, end)
                ];
            }
        }
        return E('details', { open: this.openDetails.statistics ? true : null, toggle: event => {
            const changed = this.openDetails.statistics !== event.target.open;
            this.openDetails.statistics = event.target.open;
            if (changed && event.target.open) return this.loadStatistics();
        } }, [E('summary', {}, 'Статистика HTTPS'), controls,
            E('p', {}, 'Выборочная доступность контрольного HTTPS endpoint. Не подтверждает работу приложений, сообщений или звонков. Статистика загружается при открытии и смене выбора.')].concat(body));
    },
    compatibilityPanel: function(s) {
        const compatibility = s.compatibility;
        if (!compatibility) return E('div');
        const versions = compatibility.versions || {}, capabilities = compatibility.capabilities || {};
        return E('section', { 'class': 'cbi-section stk-panel stk-section', 'aria-label': 'Совместимость' }, [
            E('h3', {}, 'Совместимость'),
            E('p', {}, 'OpenWrt: ' + (versions.openwrt || 'не определена') + ' · Podkop: ' +
                (versions.podkop || 'не определена') + ' · sing-box: ' + (versions.sing_box || 'не определена')),
            ...((compatibility.warnings || []).includes('untested_versions') ? [E('p', { role: 'status' },
                'Эта связка версий не проверена. Это предупреждение не блокирует работу.')] : []),
            ...(s.fetch_stage_error ? [E('p', { role: 'status' }, 'Подписка загружена: ' + (count(s.downloaded_count) ?? '—') +
                ' серверов. Подготовка применения: ' + compatibilityReason(s.fetch_stage_error) + '.')] : []),
            E('ul', {}, Object.keys(capabilityNames).map(name => {
                const capability = capabilities[name];
                return E('li', {}, capabilityNames[name] + ': ' + (capability?.available === false ?
                    'недоступно — ' + compatibilityReason(capability.reason) : capability?.available === true ?
                    'предварительно доступно' : 'не проверено'));
            })),
            E('p', {}, 'Показаны предварительные проверки возможностей. Окончательная проверка выполняется при операции; применение проверяет конфигурацию перед изменением MAIN.')
        ]);
    },
    selectedTests: function() { return Object.keys(labels).filter(kind => this.tests[kind]); },
    notify: function(message) { ui.addNotification(null, E('p', {}, message), 'warning'); },
    operation: async function(kind, arg) {
        if (this.running || this.localBusy || this.state.busy || !this.canWrite || capabilityBlocked(this.state, operationCapability(kind))) return;
        this.localBusy = true; this.redraw();
        try {
            const result = await actions[kind](arg);
            if (result.ok === false) this.notify(compatibilityReasons[result.error] || result.error || 'Операция отклонена');
            // RPC enqueues work; allow the existing worker to acquire its lock before polling.
            await new Promise(resolve => setTimeout(resolve, 1000));
            let s = await this.refresh();
            while (s.busy) { await new Promise(resolve => setTimeout(resolve, 1000)); s = await this.refresh(); }
        } catch (_) { this.notify('Не удалось выполнить операцию'); }
        finally { this.localBusy = false; this.redraw(); }
    },
    confirmApply: function(version) {
        ui.showModal('Применить подписку?', [
            E('p', {}, 'Podkop выполнит reload sing-box. Текущие соединения могут кратко прерваться.'),
            E('div', { 'class': 'stk-buttons right' }, [button('Отмена', ui.hideModal),
                button('Применить', () => { ui.hideModal(); return this.operation('apply', version); })])
        ]);
    },
    startTests: function(ids, kinds) {
        if (!ids.length || !kinds.length || this.running || this.localBusy || this.state.busy || !this.canWrite || capabilityBlocked(this.state, 'measurement')) return;
        const cap = this.state.speed_bytes;
        if (kinds.includes('speed')) {
            if (!Number.isFinite(cap)) { this.notify('Лимит скорости неизвестен. Обновите список.'); return; }
            this.localBusy = true; this.redraw();
            const cancel = () => { ui.hideModal(); this.localBusy = false; this.redraw(); };
            ui.showModal('Запустить проверку скорости?', [
                E('p', {}, 'До ' + number(Math.ceil(ids.length * cap / 1048576 * 10) / 10) + ' МиБ только для speed-тестов (' +
                    ids.length + ' × ' + number(Math.ceil(cap / 1048576 * 10) / 10) + ' МиБ). Скорость измеряется по одному серверу; лёгкие проверки выполняются параллельно.'),
                E('div', { 'class': 'stk-buttons right' }, [button('Отмена', cancel), button('Запустить', () => {
                    cancel(); return this.runTests(ids, kinds, cap);
                })])
            ]);
            return;
        }
        return this.runTests(ids, kinds);
    },
    stopTests: function() { this.stopping = true; this.redraw(); },
    runTests: async function(ids, kinds, cap) {
        if (this.running || this.localBusy || !this.canWrite || capabilityBlocked(this.state, 'measurement')) return;
        this.running = true; this.stopping = false;
        this.progress = { done: 0, total: ids.length, message: kinds.map(k => k === 'service' ? this.state.service_name || labels[k] : labels[k]).join(' · ') };
        this.redraw();
        let message = 'Проверка завершена', cancelSent = false;
        try {
            const s = await this.refresh();
            if (capabilityBlocked(s, 'measurement')) throw new Error(compatibilityReason(s.compatibility.capabilities.measurement.reason));
            if (s.busy) throw new Error('Роутер выполняет другое задание');
            if (kinds.includes('speed') && s.speed_bytes !== cap) throw new Error('Лимит трафика изменился; подтвердите запуск заново');
            if (this.stopping || this.container && this.container.isConnected === false) {
                message = 'Проверка остановлена'; return;
            }
            this.batchToken = (Date.now().toString(16) + Math.random().toString(16).slice(2)).padStart(64, '0');
            const result = await actions.batch(ids, kinds, cap || 0, this.batchToken);
            if (result.ok === false) throw new Error(result.error || 'Операция отклонена');
            const deadline = Date.now() + 250000;
            while (Date.now() < deadline) {
                const current = await this.refresh(), receipt = current.batch;
                if (this.container && this.container.isConnected === false) this.stopping = true;
                if (receipt && receipt.token === this.batchToken) {
                    this.progress.done = receipt.done || 0;
                    if (this.stopping && receipt.state === 'running' && !cancelSent) {
                        const cancelled = await actions.cancel(this.batchToken);
                        cancelSent = cancelled.ok !== false;
                    }
                    if (['finished', 'cancelled', 'failed'].includes(receipt.state)) {
                        for (const id of ids) {
                            this.failures[id] = this.failures[id] || {};
                            for (const kind of kinds) {
                                if (receipt.errors && receipt.errors[id] && receipt.errors[id][kind]) this.failures[id][kind] = receipt.errors[id][kind];
                                else if (receipt.state === 'finished') delete this.failures[id][kind];
                            }
                        }
                        message = receipt.state === 'cancelled' ? 'Проверка остановлена' : receipt.state === 'failed' ? 'Проверка не завершена · ' + (receipt.error || 'Ошибка задания') : 'Проверка завершена';
                        return;
                    }
                }
                this.redraw();
                await new Promise(resolve => setTimeout(resolve, 1000));
            }
            message = 'Не удалось подтвердить завершение; обновите список';
        } catch (error) { message = error.message || 'Связь потеряна; обновите список'; }
        finally { this.running = false; this.progress.message = message; this.redraw(); }
    },
    content: function(s) {
        const disabled = !!s.busy || !this.canWrite || this.running || this.localBusy;
        const unavailable = capability => disabled || capabilityBlocked(s, capability);
        const nodes = s.nodes || [], active = nodes.find(n => n.selected), preferred = nodes.find(n => n.id === s.preferred_id), serviceName = s.service_name || 'Telegram Web';
        const rows = nodes.map(n => {
            const t = n.test || {}, service = t.service;
            const times = [!t.latency_stale && t.latency_at, service && !service.stale && service.at, !t.speed_stale && t.at].filter(Boolean);
            const details = this.details(n.id, 'Подробности', [
                E('p', {}, 'Stable ID: ' + n.id),
                E('p', {}, 'Задержка: ' + timestamp(t.latency_at) + ' · ' + (t.latency_error || '—') + (t.latency_stale ? ' · Устарела' : '')),
                E('p', {}, serviceName + ': ' + timestamp(service && service.at) + ' · ' + (service && service.error || '—') +
                    ' · HTTP ' + (service && service.http_status || '—') + (service && service.stale ? ' · Устарел' : '') +
                    ' · ' + (service && service.bytes != null ? number(service.bytes / 1024) + ' КиБ' : '—') + ' · TLS: ' + (service && service.tls_verified ? 'проверен' : '—')),
                E('p', {}, 'Скорость: ' + timestamp(t.at) + ' · ' + (t.error || '—') + (t.speed_stale ? ' · Устарела' : '') +
                    ' · ' + (t.bytes != null ? number(t.bytes / 1048576) + ' МиБ' : '—') + ' / ' + (t.seconds != null ? number(t.seconds) + ' с' : '—') + (t.short_sample ? ' · короткая выборка' : '')),
                E('p', {}, 'Последний запуск: ' + (Object.keys(this.failures[n.id] || {}).map(kind => labels[kind] + ': ' + this.failures[n.id][kind]).join(' · ') || '—'))
            ]);
            const more = this.details('more-' + n.id, 'Ещё', [E('div', { 'class': 'stk-buttons' },
                Object.keys(labels).map(kind => button(kind === 'service' ? serviceName : labels[kind], () => this.startTests([n.id], [kind]), unavailable('measurement'))))]);
            return E('tr', { 'class': 'tr' + (n.selected ? ' active' : '') }, [
                E('td', { 'class': 'td' }, [E(n.selected ? 'strong' : 'span', {}, flag(n.name) + n.name), details]),
                E('td', { 'class': 'td' }, [n.selected ? 'Активный' : '', n.id === s.preferred_id ? ' · Предпочтительный' : ''].join('') || '—'),
                E('td', { 'class': 'td' }, t.latency_stale && (t.latency_at || t.latency != null) ? 'Устарела' : t.latency != null ? t.latency + ' мс' : '—'),
                E('td', { 'class': 'td' }, service && service.stale ? 'Устарел' : service ? (service.ok ? 'Доступен' : 'Недоступен') : 'Не проверен'),
                E('td', { 'class': 'td' }, t.speed_stale && (t.at || t.mbps != null) ? 'Устарела' : t.mbps != null ? number(t.mbps) + ' Мбит/с' + (t.short_sample ? ' · короткая выборка' : '') : '—'),
                E('td', { 'class': 'td', title: 'Последняя актуальная проверка; время каждого теста — в подробностях' }, timestamp(times.length ? Math.max.apply(null, times) : null, true)),
                E('td', { 'class': 'td' }, E('div', { 'class': 'stk-buttons' }, [
                    button('Выбрать', () => this.operation('select', n.id), unavailable('switch') || n.selected && n.id === s.preferred_id),
                    button('Тест', () => this.startTests([n.id], this.selectedTests()), unavailable('measurement') || !this.selectedTests().length), more
                ]))
            ]);
        });
        return E('div', { 'class': 'stk-dashboard' }, [
            E('style', {}, '.stk-dashboard .stk-section{margin-bottom:20px}.stk-dashboard .stk-panel{padding:14px}.stk-dashboard .stk-controls,.stk-dashboard .stk-buttons,.stk-dashboard .stk-summary{display:flex;flex-wrap:wrap;align-items:center;gap:8px}.stk-dashboard .stk-summary{gap:8px 24px;margin-bottom:12px}.stk-dashboard .stk-controls{gap:12px 16px}.stk-dashboard label{display:inline-flex;align-items:center;gap:6px}.stk-dashboard .stk-table{overflow-x:auto}.stk-dashboard table{min-width:780px}.stk-dashboard .stk-table .table{display:table!important}.stk-dashboard .stk-table .tr{display:table-row!important}.stk-dashboard .stk-table .th,.stk-dashboard .stk-table .td{display:table-cell!important}.stk-dashboard .stk-table .tr::before,.stk-dashboard .stk-table .td::before{display:none!important}.stk-dashboard .td,.stk-dashboard .th{text-align:left;vertical-align:top;padding:10px 8px}.stk-dashboard details{overflow-wrap:anywhere}.stk-dashboard details p{margin:8px 0}.stk-dashboard summary{cursor:pointer}.stk-dashboard td details{margin-top:6px}.stk-dashboard .stk-progress{margin:12px 0 0}.stk-dashboard .stk-buttons .cbi-button{margin:0}'),
            E('h2', {}, 'Серверы и подписка'),
            this.compatibilityPanel(s),
            E('section', { 'class': 'stk-section' }, [
                E('div', { 'class': 'stk-summary' }, [
                    E('span', {}, [E('strong', {}, 'Активный сервер: '), active ? active.name : '—']),
                    E('span', {}, [E('strong', {}, 'Предпочтительный сервер: '), preferred ? preferred.name : s.preferred_id || '—']),
                    E('span', {}, [E('strong', {}, 'Серверов: '), String(nodes.length)]),
                    E('span', {}, [E('strong', {}, 'Подписка: '), timestamp(s.last_success)]),
                    E('span', {}, [E('strong', {}, 'Обновления: '), s.pending ? 'ожидают применения' : 'нет']),
                    E('span', {}, [E('strong', {}, 'Автоматизация: '), s.enabled ? 'включена' : 'выключена']),
                    ...(s.antigravity ? [E('span', {}, [E('strong', {}, 'Antigravity: '),
                        (nodes.find(n => n.id === s.antigravity.selected_id) || {}).name || '—',
                        ' · ' + policyLabel(s.antigravity.reason)])] : [])
                ]),
                E('div', { 'class': 'stk-buttons' }, [button('Обновить список', () => this.refresh().catch(() => this.notify('Не удалось обновить список')), this.running || this.localBusy),
                    button('Проверить подписку', () => this.operation('fetch'), unavailable('fetch'))
                ].concat(s.pending ? [button('Применить изменения', () => this.confirmApply(s.pending_version), unavailable('apply') || s.pending_stale || !s.pending_version)] : [])),
                this.details('page', 'Подробности', [
                    E('p', {}, 'Состояние: ' + (s.state || 'не инициализировано') + ' · ' + (s.error || '—') + (s.busy ? ' · Выполняется задание' : '')),
                    E('p', {}, 'Источник выбора: ' + policyLabel(s.selection_origin) + ' · Причина переключения: ' + policyLabel(s.last_switch_reason)),
                    E('p', {}, 'Восстановление: ' + policyLabel(s.recovery && s.recovery.stage) + ' · Позиция: ' + (s.recovery && s.recovery.cursor != null ? s.recovery.cursor : '—')),
                    E('p', {}, 'Переключение по задержке: ' + (s.policy && s.policy.latency_enabled ? 'включено' : 'выключено') + ' · Пауза до: ' + timestamp(s.policy && s.policy.cooldown_until)),
                    E('p', {}, 'Ошибка подписки: ' + (s.fetch_error || '—') + ' · Применение: ' + timestamp(s.last_apply)),
                    E('p', {}, 'Путь загрузки: ' + (({system: 'Системное подключение', direct: 'Изолированное прямое подключение', saved_server: 'Сохранённый сервер подписки'})[s.fetch_path] || '—')),
                    E('p', {}, 'Контроль HTTPS: ' + timestamp(s.control && s.control.at) + ' · ' + (s.control ? (s.control.ok === true ? 'Получен HTTPS-ответ' : s.control.ok === false ? 'Нет ответа' : 'Неизвестно') + ' · Неудачных проб: ' + s.control.failures : 'Не проверен')),
                    E('p', {}, 'HTTPS-проба не подтверждает полноценную работу Telegram/Discord, сообщений или звонков.'),
                    E('p', {}, 'Pending: ' + (s.pending_stale ? 'устарел' : s.pending ? 'ожидает' : 'нет') + ' · Версия: ' + (s.pending_version || '—') + ' · Получена: ' + timestamp(s.pending_version_at) + ' · Проверен: ' + timestamp(s.pending_verified_at)),
                    E('p', {}, 'Начало выдержки: ' + timestamp(s.pending_series_started_at) + ' · Граница ожидания: ' + timestamp(s.pending_deadline_at)),
                    E('p', {}, 'Последняя попытка apply: ' + timestamp(s.last_apply_attempt) + ' · ' + (s.last_apply_error || s.apply_blocked_reason || '—')),
                    E('p', {}, 'Измерения хранятся в RAM. Скорость — ограниченная выборка, не максимум линии. Проверки используют принятые профили.'),
                    button('Прочитать текущий MAIN', () => this.operation('seed'), unavailable('selector'))
                ])
            ]),
            E('section', { 'class': 'cbi-section stk-panel stk-section', 'aria-label': 'Проверить серверы' }, [
                E('div', { 'class': 'stk-controls' }, [E('strong', {}, 'Проверить серверы')].concat(Object.keys(labels).map(kind =>
                    E('label', {}, [E('input', { type: 'checkbox', checked: this.tests[kind] ? true : null, disabled: this.running || this.localBusy ? true : null,
                        change: event => { this.tests[kind] = event.target.checked; this.redraw(); } }), kind === 'service' ? serviceName : labels[kind]])
                )).concat([
                    E('label', {}, ['Область: ', E('select', { 'class': 'cbi-input-select', disabled: this.running || this.localBusy ? true : null,
                        change: event => { this.scope = event.target.value; } }, [
                        E('option', { value: 'all', selected: this.scope === 'all' ? true : null }, 'Все серверы'),
                        E('option', { value: 'active', selected: this.scope === 'active' ? true : null }, 'Только активный')])]),
                    button('Запустить проверку', () => this.startTests(nodes.filter(n => this.scope === 'all' || n.selected).map(n => n.id), this.selectedTests()),
                        unavailable('measurement') || !this.selectedTests().length || !nodes.some(n => this.scope === 'all' || n.selected)),
                    ...(this.running ? [button('Остановить', () => this.stopTests(), this.stopping)] : [])
                ])),
                ...(this.progress ? [E('p', { 'class': 'stk-progress', role: 'status', 'aria-live': 'polite' }, 'Проверено ' + this.progress.done + ' из ' + this.progress.total + ' · ' +
                    (this.stopping && this.running ? 'Остановка: текущая проба завершится и очистит процессы' : this.progress.message))] : [])
            ]),
            this.statisticsPanel(nodes),
            E('div', { 'class': 'stk-table stk-section', tabindex: '0', 'aria-label': 'Таблица серверов' }, E('table', { 'class': 'table' }, [
                E('tr', { 'class': 'tr table-titles' }, ['Сервер', 'Статус', 'Задержка', serviceName, 'Скорость', 'Проверено', 'Действия'].map(title => E('th', { 'class': 'th', scope: 'col' }, title)))
            ].concat(rows.length ? rows : [E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', colspan: '7' }, 'Серверов пока нет. Прочитайте текущий MAIN в подробностях.'))])))
        ]);
    },
    render: function(data) {
        this.canWrite = !L.hasViewPermission || L.hasViewPermission();
        this.tests = { latency: true, service: true, speed: false }; this.scope = 'all'; this.openDetails = {}; this.failures = {};
        this.statisticsId = data.preferred_id || (data.nodes || []).find(n => n.selected)?.id || (data.nodes || [])[0]?.id || '';
        this.statisticsPeriod = '24h'; this.statisticsData = null; this.statisticsLoading = false; this.statisticsError = false;
        this.state = data;
        this.container = E('div', {}, [this.content(data)]);
        poll.add(async () => {
            try { await this.refresh(); } catch (_) { /* Keep the last successful state during a transient RPC failure. */ }
        }, 3);
        return this.container;
    },
    handleSave: null,
    handleSaveApply: null,
    handleReset: null
});
