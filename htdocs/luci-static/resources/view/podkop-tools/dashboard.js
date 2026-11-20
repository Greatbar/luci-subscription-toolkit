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
        confirm:'Подтверждение отказа', fetch:'Обновление подписки', same:'Проверка нового адреса', reserves:'Проверка резервов',
        node_removed:'Сервер удалён из подписки'})[value] || '—';
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
function latencyBadge(value) {
    const level = value <= 150 ? 'low' : value <= 300 ? 'medium' : 'high';
    return E('span', { 'class': 'stk-latency stk-latency-' + level }, [
        E('span', { 'class': 'stk-latency-indicator', 'aria-hidden': 'true' }),
        number(value) + ' мс'
    ]);
}
function button(label, click, disabled) {
    return E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-action',
        disabled: disabled ? true : null, click }, [label]);
}
function field(label, value) {
    return E('div', {}, [E('dt', {}, [label]), E('dd', {}, [value])]);
}
function detailFields(rows) {
    return E('dl', { 'class': 'stk-detail-fields' }, rows
        .filter(([, value]) => value != null && value !== '')
        .map(([label, value]) => field(label, value)));
}
function diagnosticCard(title, rows, note) {
    return E('section', { 'class': 'stk-card' }, [
        E('h4', {}, [title]), detailFields(rows), ...(note ? [E('p', { 'class': 'stk-note' }, [note])] : [])
    ]);
}
const measurementErrors = {
    latency_failed: 'Замер не удался',
    speed_failed: 'Не удалось измерить скорость',
    speed_cooldown: 'Между замерами нужна пауза в минуту',
    router_busy: 'Роутер выполняет другое задание',
    probe_start_failed: 'Не удалось запустить проверку',
    unexpected_http_status: 'Неожиданный код HTTP',
    transfer_failed: 'Не удалось скачать данные',
    invalid_sample: 'Некорректная выборка',
    insufficient_sample: 'Недостаточно данных для замера',
    service_tls_failed: 'Не удалось проверить TLS',
    service_timeout: 'Сайт не ответил вовремя',
    service_unexpected_http_status: 'Неожиданный код HTTP',
    service_response_too_large: 'Ответ сайта слишком большой',
    service_transfer_failed: 'Не удалось получить ответ сайта',
    service_content_type_mismatch: 'Неожиданный тип содержимого',
    service_content_mismatch: 'В ответе нет ожидаемого содержимого',
    service_block_page: 'Сайт вернул страницу блокировки',
    service_invalid_contract: 'Некорректные параметры проверки',
    service_probe_failed: 'Не удалось проверить сайт'
};
function diagnosticError(code) {
    if (Object.hasOwn(compatibilityReasons, code)) return compatibilityReasons[code];
    return Object.hasOwn(measurementErrors, code) ? measurementErrors[code] : code;
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
    return E('figure', { style: 'margin:12px 0' }, [
        E('figcaption', {}, title),
        svgElement('svg', { viewBox: '0 0 ' + width + ' ' + height, role: 'img', 'aria-label': title, style: 'width:100%;max-width:900px;height:auto' }, elements),
        ...(series.length > 1 ? [E('p', {}, series.map(line => E('span', { style: 'color:' + line.color + ';margin-right:16px' }, line.label)))] : [])
    ]);
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
            } }, nodes.map(n => E('option', { value: n.id, selected: n.id === this.statisticsId ? true : null }, [n.name])))]),
            E('label', {}, ['Период: ', E('select', { 'aria-label': 'Период статистики', change: event => {
                if (!periods[event.target.value]) return;
                this.statisticsPeriod = event.target.value; return this.loadStatistics();
            } }, Object.keys(periods).map(key => E('option', { value: key, selected: key === period ? true : null }, { '24h': '24 часа', '7d': '7 дней', '30d': '30 дней' }[key])))])
        ]);
        let body = [];
        if (this.openDetails.statistics) {
            if (this.statisticsLoading) body = [E('p', { role: 'status' }, 'Загрузка статистики…')];
            else if (this.statisticsError) body = [E('p', { role: 'status' }, 'Не удалось загрузить статистику. Смените сервер или период.')];
            else if (!rows.length || !totals.attempts && !totals.switches && !totals.failures) body = [E('p', {}, 'Нет проб за выбранный период')];
            else {
                const delay = (row, kind) => row.successes > 0 && metric(row.delay_sum) !== null && metric(row.delay_min) !== null &&
                    metric(row.delay_max) !== null && row.delay_min <= row.delay_max ?
                    (kind === 'avg' ? row.delay_sum / (count(row.delay_count) === null ? row.successes : row.delay_count || 1) : row['delay_' + kind]) : null;
                body = [
                    E('p', {}, 'Успешных проб: ' + number(totals.successes) + ' из ' + number(totals.attempts) +
                        (totals.attempts ? ' (' + number(totals.successes / totals.attempts * 100) + ' %)' : '') +
                        '. Ошибок: ' + number(totals.failures) + '. Переключений: ' + number(totals.switches) + '.'),
                    E('p', {}, 'Часов с пробами: ' + sampled.length + ' из ' + periods[period] + '.' +
                        (sampled.length ? ' Первый час с пробами: ' + timestamp(sampled[0].hour) + '. Последний: ' + timestamp(sampled[sampled.length - 1].hour) + '.' : '') +
                        (data && metric(data.coverage_start) !== null ? ' История с: ' + timestamp(data.coverage_start) + '.' : '') +
                        (data && data.truncated ? ' История неполная.' : '')),
                    E('p', {}, 'Часы без проб не входят в расчёт доступности и отмечены серым.'),
                    historyChart('Доступность по HTTPS-пробам, %', rows, [{ label: 'Успешные пробы, %', color: '#198754', value: row => row.attempts ? row.successes / row.attempts * 100 : null }], start, end, 100),
                    historyChart('Задержка успешных HTTPS-проб, мс', rows, [
                        { label: 'Средняя', color: '#287ac1', value: row => delay(row, 'avg') },
                        { label: 'Минимум', color: '#198754', value: row => delay(row, 'min') },
                        { label: 'Максимум', color: '#b56a00', value: row => delay(row, 'max') }], start, end),
                    historyChart('Ошибки проб и переключения', rows, [
                        { label: 'Ошибки', color: '#c43b3b', value: row => row.attempts || row.switches || row.failures ? row.failures : null },
                        { label: 'Переключения', color: '#8051b0', value: row => row.attempts || row.switches || row.failures ? row.switches : null }], start, end)
                ];
            }
        }
        return E('details', { open: this.openDetails.statistics ? true : null, toggle: event => {
            const changed = this.openDetails.statistics !== event.target.open;
            this.openDetails.statistics = event.target.open;
            if (changed && event.target.open) return this.loadStatistics();
        } }, [E('summary', {}, 'Статистика HTTPS'), controls].concat(body));
    },
    routingPanel: function(s, seedDisabled) {
        const control = s.control, recovery = s.recovery, policy = s.policy;
        const applyIssue = s.last_apply_error || s.apply_blocked_reason;
        const path = { system: 'Системное подключение', direct: 'Изолированное прямое подключение',
            saved_server: 'Сохранённый сервер подписки' }[s.fetch_path];
        return this.details('page', 'Подписка и маршрутизация', [
            E('div', { 'class': 'stk-grid stk-diagnostic-grid' }, [
                diagnosticCard('Подписка', [
                    ['Путь загрузки', path],
                    ['Последнее применение', s.last_apply ? timestamp(s.last_apply) : null],
                    ['Попытка применения', s.last_apply_attempt ? timestamp(s.last_apply_attempt) : null],
                    ['Причина', applyIssue !== s.fetch_stage_error ? diagnosticError(applyIssue) : null],
                    ['Ошибка загрузки', diagnosticError(s.fetch_error)],
                    ['Кандидат', s.pending_stale ? 'Устарел' : s.pending ? 'Ожидает применения' : 'Нет']
                ]),
                diagnosticCard('Маршрутизация', [
                    ['Источник выбора', policyLabel(s.selection_origin)],
                    ['Причина переключения', policyLabel(s.last_switch_reason)],
                    ['По задержке', policy?.latency_enabled ? 'Включено' : 'Выключено'],
                    ['Пауза до', policy?.latency_enabled && policy.cooldown_until ? timestamp(policy.cooldown_until) : null],
                    ['Восстановление', recovery?.stage ? policyLabel(recovery.stage) : null],
                    ['Позиция', recovery?.cursor]
                ]),
                diagnosticCard('Контроль HTTPS', [
                    ['Ответ сайта', control ? (control.ok === true ? 'Получен' : control.ok === false ? 'Нет ответа' : 'Неизвестно') : 'Не проверен'],
                    ['Время пробы', control?.at ? timestamp(control.at) : null],
                    ['Неудачные пробы', control?.failures]
                ])
            ]),
            this.details('routing-technical', 'Технические данные', [
                detailFields([
                    ['Код состояния', s.state || 'Не инициализировано'],
                    ['Ошибка', diagnosticError(s.error)],
                    ['Код ошибки применения', applyIssue && applyIssue === s.fetch_stage_error ? applyIssue : null],
                    ['Задание', s.busy ? 'Выполняется' : null],
                    ['Пауза до', !policy?.latency_enabled && policy?.cooldown_until ? timestamp(policy.cooldown_until) : null],
                    ['Версия кандидата', s.pending_version],
                    ['Кандидат получен', s.pending_version_at ? timestamp(s.pending_version_at) : null],
                    ['Кандидат проверен', s.pending_verified_at ? timestamp(s.pending_verified_at) : null],
                    ['Начало ожидания', s.pending_series_started_at ? timestamp(s.pending_series_started_at) : null],
                    ['Ожидание до', s.pending_deadline_at ? timestamp(s.pending_deadline_at) : null]
                ]),
                E('p', { 'class': 'stk-note' }, 'Замеры хранятся в оперативной памяти и используют принятые профили.')
            ]),
            E('div', { 'class': 'stk-buttons stk-diagnostic-action' }, [
                button('Прочитать текущий MAIN', () => this.operation('seed'), seedDisabled)
            ])
        ]);
    },
    compatibilityPanel: function(s) {
        const compatibility = s.compatibility;
        if (!compatibility) return null;
        const versions = compatibility.versions || {}, capabilities = compatibility.capabilities || {};
        const operations = Object.entries(capabilityNames);
        const available = operations.filter(([key]) => capabilities[key]?.available === true).map(([, label]) => label);
        const unchecked = operations.filter(([key]) => capabilities[key]?.available == null).map(([, label]) => label);
        const blocked = operations.filter(([key]) => capabilities[key]?.available === false);
        return this.details('compatibility', 'Совместимость', [
            E('div', { 'class': 'stk-grid stk-diagnostic-grid' }, [
                diagnosticCard('Версии', [
                    ['OpenWrt', versions.openwrt || 'Не определена'],
                    ['Podkop', versions.podkop || 'Не определена'],
                    ['sing-box', versions.sing_box || 'Не определена']
                ], compatibility.warnings?.includes('untested_versions') ? 'Эта связка версий не проверена.' : null),
                diagnosticCard('Проверка операций', [
                    ['Предварительно доступны', available.length === operations.length ? 'Все операции' : available.join(', ')],
                    ['Не проверены', unchecked.join(', ')],
                    ...blocked.map(([key, label]) => [label, 'Недоступно. ' + compatibilityReason(capabilities[key].reason)])
                ])
            ])
        ]);
    },
    selectedTests: function() { return Object.keys(labels).filter(kind => this.tests[kind]); },
    notify: function(message) { ui.addNotification(null, E('p', {}, [message]), 'warning'); },
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
            E('p', {}, 'Podkop может перечитать конфигурацию sing-box. Соединения могут ненадолго прерваться.'),
            E('div', { 'class': 'stk-buttons right' }, [button('Отмена', ui.hideModal),
                button('Применить', () => { ui.hideModal(); return this.operation('apply', version); })])
        ]);
    },
    startTests: function(ids, kinds) {
        if (!ids.length || !kinds.length || this.running || this.localBusy || this.state.busy || !this.canWrite || capabilityBlocked(this.state, 'measurement')) return;
        const cap = this.state.speed_bytes;
        if (kinds.includes('speed')) {
            if (!Number.isFinite(cap)) { this.notify('Лимит трафика неизвестен. Обновите список.'); return; }
            this.localBusy = true; this.redraw();
            const cancel = () => { ui.hideModal(); this.localBusy = false; this.redraw(); };
            ui.showModal('Запустить проверку скорости?', [
                E('p', {}, 'До ' + number(Math.ceil(ids.length * cap / 1048576 * 10) / 10) + ' МиБ на проверку скорости (' +
                    ids.length + ' × ' + number(Math.ceil(cap / 1048576 * 10) / 10) + ' МиБ). Скорость проверяется по одному серверу.'),
                E('div', { 'class': 'stk-buttons right' }, [button('Отмена', cancel), button('Запустить', () => {
                    cancel(); return this.runTests(ids, kinds, cap);
                })])
            ]);
            return;
        }
        return this.runTests(ids, kinds);
    },
    stopTests: function() { this.stopping = true; this.redraw(); },
    latencyCell: function(id, test) {
        if (this.running && this.latencyIds.has(id)) {
            const receipt = this.state.batch;
            if (!this.batchToken || !receipt || receipt.token !== this.batchToken) return 'Проверяется…';
            if (receipt.latency) {
                if (!Object.prototype.hasOwnProperty.call(receipt.latency, id)) return 'Проверяется…';
                const value = receipt.latency[id];
                return value == null ? 'Замер не удался' : latencyBadge(value);
            }
        }
        if (test.latency_stale && (test.latency_at || test.latency != null)) return 'Устарела';
        if (test.latency != null) return latencyBadge(test.latency);
        return test.latency_error ? 'Замер не удался' : '—';
    },
    serverDetails: function(id, test, serviceName) {
        const service = test.service;
        const failures = Object.entries(this.failures[id] || {});
        const hasLatency = test.latency_at || test.latency_error;
        const hasSpeed = test.at || test.error || test.bytes != null || test.seconds != null;
        const groups = [
            ...(hasLatency ? [diagnosticCard('Задержка', [
                [test.latency_stale ? 'Прежний замер' : 'Время', test.latency_at ? timestamp(test.latency_at, true) : null],
                ['Ошибка', diagnosticError(test.latency_error)]
            ])] : []),
            ...(service ? [diagnosticCard(serviceName, [
                [service.stale ? 'Прежняя проверка' : 'Время', service.at ? timestamp(service.at, true) : null],
                ['HTTP', service.http_status],
                ['Ответ', service.bytes != null ? number(service.bytes / 1024) + ' КиБ' : null],
                ['TLS', service.tls_verified ? 'Проверен' : 'Нет подтверждения'],
                ['Ошибка', diagnosticError(service.error)]
            ])] : []),
            ...(hasSpeed ? [diagnosticCard('Скорость', [
                [test.speed_stale ? 'Прежний замер' : 'Время', test.at ? timestamp(test.at, true) : null],
                ['Объём', test.bytes != null ? number(test.bytes / 1048576) + ' МиБ' : null],
                ['Длительность', test.seconds != null ? number(test.seconds) + ' с' : null],
                ['Выборка', test.short_sample ? 'Короткая' : null],
                ['Ошибка', diagnosticError(test.error)]
            ])] : []),
            ...(failures.length ? [diagnosticCard('Ошибки запуска', failures.map(([kind, code]) =>
                [kind === 'service' ? serviceName : labels[kind], diagnosticError(code)]))] : [])
        ];
        return this.details(id, 'Подробности', [
            groups.length ? E('div', { 'class': 'stk-server-diagnostics' }, groups) :
                E('p', { 'class': 'stk-note' }, 'Нет подробностей о замерах.'),
            detailFields([['ID сервера', E('code', {}, [id])]])
        ]);
    },
    runTests: async function(ids, kinds, cap) {
        if (this.running || this.localBusy || !this.canWrite || capabilityBlocked(this.state, 'measurement')) return;
        this.running = true; this.stopping = false;
        this.batchToken = null;
        this.latencyIds = new Set(kinds.includes('latency') ? ids : []);
        this.progress = { done: 0, total: ids.length, message: kinds.map(kind => kind === 'service' ? this.state.service_name || labels[kind] : labels[kind]).join(', ') };
        this.redraw();
        let message = 'Проверка завершена', cancelSent = false;
        try {
            const s = await this.refresh();
            if (capabilityBlocked(s, 'measurement')) throw new Error(compatibilityReason(s.compatibility.capabilities.measurement.reason));
            if (s.busy) throw new Error('Роутер выполняет другое задание');
            if (kinds.includes('speed') && s.speed_bytes !== cap) throw new Error('Лимит трафика изменился. Подтвердите запуск заново.');
            if (this.stopping || this.container && this.container.isConnected === false) {
                message = 'Проверка остановлена'; return;
            }
            this.batchToken = (Date.now().toString(16) + Math.random().toString(16).slice(2)).padStart(64, '0');
            const result = await actions.batch(ids, kinds, cap || 0, this.batchToken);
            if (result.ok === false) throw new Error(result.error || 'Операция отклонена');
            const deadline = Date.now() + 250000;
            while (Date.now() < deadline) {
                const current = await status(this.batchToken), receipt = current.batch;
                this.state = current;
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
                        message = receipt.state === 'cancelled' ? 'Проверка остановлена' : receipt.state === 'failed' ? 'Проверка не завершена. ' + (receipt.error || 'Ошибка задания') : 'Проверка завершена';
                        return;
                    }
                }
                this.redraw();
                await new Promise(resolve => setTimeout(resolve, 1000));
            }
            message = 'Не удалось подтвердить завершение. Обновите список.';
        } catch (error) { message = error.message || 'Связь потеряна. Обновите список.'; }
        finally { this.running = false; this.progress.message = message; this.redraw(); }
    },
    content: function(s) {
        const disabled = !!s.busy || !this.canWrite || this.running || this.localBusy;
        const unavailable = capability => disabled || capabilityBlocked(s, capability);
        const nodes = s.nodes || [], active = nodes.find(n => n.selected), preferred = nodes.find(n => n.id === s.preferred_id), serviceName = s.service_name || 'Telegram Web';
        const cards = nodes.map(n => {
            const t = n.test || {}, service = t.service;
            const times = [!t.latency_stale && t.latency_at, service && !service.stale && service.at, !t.speed_stale && t.at].filter(Boolean);
            const details = this.serverDetails(n.id, t, serviceName);
            const more = this.details('more-' + n.id, 'Отдельные проверки', [E('div', { 'class': 'stk-buttons stk-individual-tests' },
                Object.keys(labels).map(kind => button(kind === 'service' ? serviceName : labels[kind], () => this.startTests([n.id], [kind]), unavailable('measurement'))))]);
            const roles = [n.selected && 'Активный', n.id === s.preferred_id && 'Предпочтительный'].filter(Boolean);
            return E('article', { 'class': 'stk-card stk-server' + (n.selected ? ' stk-server-active' : '') }, [
                E('h4', {}, [n.name]),
                ...(roles.length ? [E('p', { 'class': 'stk-server-role' }, roles.join(', '))] : []),
                E('dl', { 'class': 'stk-metrics' }, [
                    field('Задержка', this.latencyCell(n.id, t)),
                    field(serviceName, service && service.stale ? 'Устарел' : service ? (service.ok ? 'Доступен' : 'Недоступен') : 'Не проверен'),
                    field('Скорость', t.speed_stale && (t.at || t.mbps != null) ? 'Устарела' :
                        t.mbps != null ? number(t.mbps) + ' Мбит/с' + (t.short_sample ? ' (короткая выборка)' : '') : '—'),
                    ...(times.length ? [field('Проверено', timestamp(Math.max.apply(null, times), true))] : [])
                ]),
                E('div', { 'class': 'stk-buttons stk-server-actions' }, [
                    button('Выбрать', () => this.operation('select', n.id), unavailable('switch') || n.selected && n.id === s.preferred_id),
                    button('Проверить', () => this.startTests([n.id], this.selectedTests()), unavailable('measurement') || !this.selectedTests().length)
                ]),
                E('div', { 'class': 'stk-server-links' }, [details, more])
            ]);
        });
        return E('div', { 'class': 'stk-dashboard' }, [
            E('style', {}, `
                .stk-dashboard { --stk-border: color-mix(in srgb, currentColor 23%, transparent); }
                .stk-dashboard .stk-section { margin-bottom: 18px; }
                .stk-dashboard .stk-panel { padding: 14px; }
                .stk-dashboard .stk-controls, .stk-dashboard .stk-buttons, .stk-dashboard .stk-server-header {
                    display: flex; flex-wrap: wrap; align-items: center; gap: 8px;
                }
                .stk-dashboard .stk-controls { gap: 12px 16px; }
                .stk-dashboard label { display: inline-flex; align-items: center; gap: 6px; }
                .stk-dashboard .stk-buttons .cbi-button { margin: 0; }
                .stk-dashboard .stk-grid {
                    display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 15rem), 1fr)); gap: 10px;
                }
                .stk-dashboard .stk-summary {
                    grid-template-columns: repeat(auto-fit, minmax(min(100%, 9rem), 1fr)); margin-bottom: 12px;
                }
                .stk-dashboard .stk-summary dd { margin: 4px 0 0; }
                .stk-dashboard .stk-servers { margin-top: 12px; }
                .stk-dashboard .stk-servers:has(.stk-server-links details[open]) { align-items: start; }
                .stk-dashboard .stk-card {
                    min-width: 0; padding: 12px; border: 1px solid var(--stk-border); border-radius: 6px;
                    background: color-mix(in srgb, currentColor 3%, transparent); overflow-wrap: anywhere;
                }
                .stk-dashboard .stk-card h4, .stk-dashboard .stk-server-header h3 {
                    margin: 0; color: inherit; letter-spacing: normal; text-transform: none;
                }
                .stk-dashboard .stk-card h4 { font-size: 1rem; line-height: 1.35; }
                .stk-dashboard .stk-server-header { justify-content: space-between; margin-bottom: 12px; }
                .stk-dashboard .stk-server-heading { display: flex; align-items: baseline; gap: 8px; }
                .stk-dashboard .stk-server-active { border-color: #22866e; box-shadow: inset 0 2px #22866e; }
                .stk-dashboard .stk-server-role { font-size: .875rem; margin: 4px 0 0; }
                .stk-dashboard .stk-metrics { display: grid; gap: 4px; margin: 8px 0 0; }
                .stk-dashboard .stk-metrics > div { display: flex; justify-content: space-between; gap: 8px; }
                .stk-dashboard .stk-metrics dt, .stk-dashboard .stk-metrics dd { margin: 0; }
                .stk-dashboard .stk-metrics dt { font-weight: normal; }
                .stk-dashboard .stk-metrics dd { min-width: 0; text-align: right; }
                .stk-dashboard .stk-server-actions {
                    margin-top: 10px; padding-top: 10px; border-top: 1px solid var(--stk-border);
                }
                .stk-dashboard .stk-server-links { display: flex; flex-wrap: wrap; column-gap: 14px; }
                .stk-dashboard .stk-server-links details[open] { flex-basis: 100%; min-width: 0; }
                .stk-dashboard .stk-disclosure-stack { display: grid; gap: 8px; margin-top: 12px; }
                .stk-dashboard .stk-disclosure-stack > details, .stk-dashboard .stk-notice {
                    margin: 0; padding: 10px 12px; border: 1px solid var(--stk-border); border-radius: 6px;
                }
                .stk-dashboard .stk-disclosure-stack > details > summary { font-weight: 600; }
                .stk-dashboard .stk-notice { margin-top: 12px; border-inline-start: 3px solid #b8791b; }
                .stk-dashboard .stk-notice p { margin: 4px 0 0; }
                .stk-dashboard .stk-diagnostic-grid {
                    grid-template-columns: repeat(auto-fit, minmax(min(100%, 15rem), 1fr)); margin-top: 10px;
                }
                .stk-dashboard .stk-detail-fields { display: grid; gap: 6px; margin: 8px 0 0; }
                .stk-dashboard .stk-detail-fields > div {
                    display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.25fr); gap: 8px;
                }
                .stk-dashboard .stk-detail-fields dt, .stk-dashboard .stk-detail-fields dd { margin: 0; }
                .stk-dashboard .stk-detail-fields dt { font-weight: normal; }
                .stk-dashboard .stk-detail-fields dd { text-align: right; }
                .stk-dashboard .stk-detail-fields code { white-space: normal; }
                .stk-dashboard .stk-diagnostic-action { margin-top: 12px; }
                .stk-dashboard .stk-server-diagnostics, .stk-dashboard .stk-individual-tests { display: grid; gap: 6px; margin-top: 8px; }
                .stk-dashboard .stk-individual-tests .cbi-button { white-space: normal; }
                .stk-dashboard .stk-note { margin: 8px 0 0; }
                .stk-dashboard details { overflow-wrap: anywhere; margin-top: 8px; }
                .stk-dashboard details p { margin: 8px 0; }
                .stk-dashboard summary { cursor: pointer; }
                .stk-dashboard summary:focus-visible { outline: 2px solid currentColor; outline-offset: 2px; }
                .stk-dashboard .stk-latency {
                    display: inline-flex; align-items: center; gap: .45em; white-space: nowrap; font-variant-numeric: tabular-nums;
                }
                .stk-dashboard .stk-latency-indicator { width: .6em; height: .6em; border-radius: 50%; background: var(--stk-latency-color); }
                .stk-dashboard .stk-latency-low { --stk-latency-color: #27a66c; }
                .stk-dashboard .stk-latency-medium { --stk-latency-color: #c48120; }
                .stk-dashboard .stk-latency-high { --stk-latency-color: #da5555; }
                .stk-dashboard .stk-progress { margin: 0 0 12px; }
                .stk-dashboard .stk-progress progress { display: block; width: min(100%, 24rem); height: .65rem; margin: .4em 0; }
            `),
            E('h2', {}, 'Серверы и подписка'),
            E('section', { 'class': 'stk-section' }, [
                E('dl', { 'class': 'stk-summary stk-grid', 'aria-label': 'Сводка' }, [
                    ['Активный сервер', active ? active.name : '—'],
                    ['Предпочтительный сервер', preferred ? preferred.name : s.preferred_id || '—'],
                    ['Подписка', s.pending ? 'Ожидает применения' : s.fetch_stage_error ? 'Нет готового обновления' : 'Нет изменений', timestamp(s.last_success)],
                    ['Автоматизация', s.enabled ? 'Включена' : 'Выключена'],
                    ...(s.antigravity ? [['Antigravity', nodes.find(n => n.id === s.antigravity.selected_id)?.name || '—',
                        policyLabel(s.antigravity.reason)]] : [])
                ].map(([label, value, note]) => E('div', { 'class': 'stk-card' }, [
                    E('dt', {}, label),
                    E('dd', {}, [
                        E('strong', {}, [value]),
                        ...(note && note !== '—' ? [E('div', {}, [note])] : [])
                    ])
                ]))),
                E('div', { 'class': 'stk-buttons' }, [button('Обновить список', () => this.refresh().catch(() => this.notify('Не удалось обновить список')), this.running || this.localBusy),
                    button('Проверить подписку', () => this.operation('fetch'), unavailable('fetch'))
                ].concat(s.pending ? [button('Применить изменения', () => this.confirmApply(s.pending_version), unavailable('apply') || s.pending_stale || !s.pending_version)] : [])),
                ...(s.fetch_stage_error ? [E('div', { 'class': 'stk-notice', role: 'status' }, [
                    E('strong', {}, 'Подписка скачана, подготовка не удалась'),
                    E('p', {}, [compatibilityReason(s.fetch_stage_error)]),
                    ...(count(s.downloaded_count) !== null ? [E('p', {}, 'Скачано серверов: ' + s.downloaded_count)] : [])
                ])] : []),
                E('div', { 'class': 'stk-disclosure-stack' }, [
                    this.routingPanel(s, unavailable('selector')),
                    ...(s.compatibility ? [this.compatibilityPanel(s)] : [])
                ])
            ]),
            E('section', { 'class': 'cbi-section stk-panel stk-section', 'aria-labelledby': 'stk-servers-title' }, [
                E('div', { 'class': 'stk-server-header' }, [
                    E('div', { 'class': 'stk-server-heading' }, [
                        E('h3', { id: 'stk-servers-title' }, 'Серверы'), E('span', {}, String(nodes.length))
                    ]),
                    E('div', { 'class': 'stk-buttons' }, [
                        button('Проверить задержку всех серверов', () => this.startTests(nodes.map(n => n.id), ['latency']), unavailable('measurement') || !nodes.length),
                        ...(this.running ? [button('Остановить', () => this.stopTests(), this.stopping)] : [])
                    ])
                ]),
                ...(this.progress ? [E('div', { 'class': 'stk-progress' }, [
                    E('div', { role: 'status', 'aria-live': 'polite' }, ['Проверено ' + this.progress.done + ' из ' + this.progress.total + '. ' +
                        (this.stopping && this.running ? 'Останавливаем проверку…' : this.progress.message)]),
                    E('progress', { value: this.progress.done, max: this.progress.total, 'aria-label': 'Прогресс проверки серверов' })
                ])] : []),
                this.details('tests', 'Параметры проверки', [E('div', { 'class': 'stk-controls' }, Object.keys(labels).map(kind =>
                    E('label', {}, [E('input', { type: 'checkbox', checked: this.tests[kind] ? true : null, disabled: this.running || this.localBusy ? true : null,
                        change: event => { this.tests[kind] = event.target.checked; this.redraw(); } }), kind === 'service' ? serviceName : labels[kind]])
                ).concat([
                    E('label', {}, ['Область: ', E('select', { 'class': 'cbi-input-select', disabled: this.running || this.localBusy ? true : null,
                        change: event => { this.scope = event.target.value; } }, [
                        E('option', { value: 'all', selected: this.scope === 'all' ? true : null }, 'Все серверы'),
                        E('option', { value: 'active', selected: this.scope === 'active' ? true : null }, 'Только активный')])]),
                    button('Запустить проверку', () => this.startTests(nodes.filter(n => this.scope === 'all' || n.selected).map(n => n.id), this.selectedTests()),
                        unavailable('measurement') || !this.selectedTests().length || !nodes.some(n => this.scope === 'all' || n.selected))
                ]))]),
                this.statisticsPanel(nodes),
                cards.length ? E('div', { 'class': 'stk-grid stk-servers' }, cards) :
                    E('p', {}, 'Серверов пока нет. В разделе «Подписка и маршрутизация» нажмите «Прочитать текущий MAIN».')
            ])
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
            if (this.running) return;
            const token = this.batchToken;
            try {
                const state = await status(token || '');
                if (!this.running && this.batchToken === token) this.redraw(state);
            } catch (_) { /* Keep the last successful state during a transient RPC failure. */ }
        }, 3);
        return this.container;
    },
    handleSave: null,
    handleSaveApply: null,
    handleReset: null
});
