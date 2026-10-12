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
    selectedTests: function() { return Object.keys(labels).filter(kind => this.tests[kind]); },
    notify: function(message) { ui.addNotification(null, E('p', {}, message), 'warning'); },
    operation: async function(kind, arg) {
        if (this.running || this.localBusy || this.state.busy || !this.canWrite || this.state.compatible === false) return;
        this.localBusy = true; this.redraw();
        try {
            const result = await actions[kind](arg);
            if (result.ok === false) this.notify(result.error || 'Операция отклонена');
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
        if (!ids.length || !kinds.length || this.running || this.localBusy || this.state.busy || !this.canWrite || this.state.compatible === false) return;
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
        if (this.running || this.localBusy || !this.canWrite) return;
        this.running = true; this.stopping = false;
        this.progress = { done: 0, total: ids.length, message: kinds.map(k => k === 'service' ? this.state.service_name || labels[k] : labels[k]).join(' · ') };
        this.redraw();
        let message = 'Проверка завершена', cancelSent = false;
        try {
            const s = await this.refresh();
            if (s.compatible === false) throw new Error('Несовместимое состояние');
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
        const disabled = !!s.busy || s.compatible === false || !this.canWrite || this.running || this.localBusy;
        const nodes = s.nodes || [], active = nodes.find(n => n.selected), serviceName = s.service_name || 'Telegram Web';
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
                Object.keys(labels).map(kind => button(kind === 'service' ? serviceName : labels[kind], () => this.startTests([n.id], [kind]), disabled)))]);
            return E('tr', { 'class': 'tr' + (n.selected ? ' active' : '') }, [
                E('td', { 'class': 'td' }, [E(n.selected ? 'strong' : 'span', {}, flag(n.name) + n.name), details]),
                E('td', { 'class': 'td' }, n.selected ? 'Активный' : '—'),
                E('td', { 'class': 'td' }, t.latency_stale && (t.latency_at || t.latency != null) ? 'Устарела' : t.latency != null ? t.latency + ' мс' : '—'),
                E('td', { 'class': 'td' }, service && service.stale ? 'Устарел' : service ? (service.ok ? 'Доступен' : 'Недоступен') : 'Не проверен'),
                E('td', { 'class': 'td' }, t.speed_stale && (t.at || t.mbps != null) ? 'Устарела' : t.mbps != null ? number(t.mbps) + ' Мбит/с' + (t.short_sample ? ' · короткая выборка' : '') : '—'),
                E('td', { 'class': 'td', title: 'Последняя актуальная проверка; время каждого теста — в подробностях' }, timestamp(times.length ? Math.max.apply(null, times) : null, true)),
                E('td', { 'class': 'td' }, E('div', { 'class': 'stk-buttons' }, [
                    button('Выбрать', () => this.operation('select', n.id), disabled || n.selected),
                    button('Тест', () => this.startTests([n.id], this.selectedTests()), disabled || !this.selectedTests().length), more
                ]))
            ]);
        });
        return E('div', { 'class': 'stk-dashboard' }, [
            E('style', {}, '.stk-dashboard .stk-section{margin-bottom:20px}.stk-dashboard .stk-panel{padding:14px}.stk-dashboard .stk-controls,.stk-dashboard .stk-buttons,.stk-dashboard .stk-summary{display:flex;flex-wrap:wrap;align-items:center;gap:8px}.stk-dashboard .stk-summary{gap:8px 24px;margin-bottom:12px}.stk-dashboard .stk-controls{gap:12px 16px}.stk-dashboard label{display:inline-flex;align-items:center;gap:6px}.stk-dashboard .stk-table{overflow-x:auto}.stk-dashboard table{min-width:780px}.stk-dashboard .stk-table .table{display:table!important}.stk-dashboard .stk-table .tr{display:table-row!important}.stk-dashboard .stk-table .th,.stk-dashboard .stk-table .td{display:table-cell!important}.stk-dashboard .stk-table .tr::before,.stk-dashboard .stk-table .td::before{display:none!important}.stk-dashboard .td,.stk-dashboard .th{text-align:left;vertical-align:top;padding:10px 8px}.stk-dashboard details{overflow-wrap:anywhere}.stk-dashboard details p{margin:8px 0}.stk-dashboard summary{cursor:pointer}.stk-dashboard td details{margin-top:6px}.stk-dashboard .stk-progress{margin:12px 0 0}.stk-dashboard .stk-buttons .cbi-button{margin:0}'),
            E('h2', {}, 'Серверы и подписка'),
            E('section', { 'class': 'stk-section' }, [
                E('div', { 'class': 'stk-summary' }, [
                    E('span', {}, [E('strong', {}, 'Активный сервер: '), active ? active.name : '—']),
                    E('span', {}, [E('strong', {}, 'Серверов: '), String(nodes.length)]),
                    E('span', {}, [E('strong', {}, 'Подписка: '), timestamp(s.last_success)]),
                    E('span', {}, [E('strong', {}, 'Обновления: '), s.pending ? 'ожидают применения' : 'нет']),
                    E('span', {}, [E('strong', {}, 'Автоматизация: '), s.enabled ? 'включена' : 'выключена'])
                ]),
                E('div', { 'class': 'stk-buttons' }, [button('Обновить список', () => this.refresh().catch(() => this.notify('Не удалось обновить список')), this.running || this.localBusy),
                    button('Проверить подписку', () => this.operation('fetch'), disabled)
                ].concat(s.pending ? [button('Применить изменения', () => this.confirmApply(s.pending_version), disabled || s.pending_stale || !s.pending_version)] : [])),
                this.details('page', 'Подробности', [
                    E('p', {}, 'Состояние: ' + (s.state || 'не инициализировано') + ' · ' + (s.error || '—') + (s.busy ? ' · Выполняется задание' : '')),
                    E('p', {}, 'Ошибка подписки: ' + (s.fetch_error || '—') + ' · Применение: ' + timestamp(s.last_apply)),
                    E('p', {}, 'Контроль HTTPS (control_checked): ' + timestamp(s.control && s.control.at) + ' · ' + (s.control ? (s.control.ok ? 'HTTP 204' : 'Ошибка') + ' · Отказов: ' + s.control.failures : 'Не проверен')),
                    E('p', {}, 'HTTPS-проба не подтверждает полноценную работу Telegram/Discord, сообщений или звонков.'),
                    E('p', {}, 'Pending: ' + (s.pending_stale ? 'устарел' : s.pending ? 'ожидает' : 'нет') + ' · Версия: ' + (s.pending_version || '—') + ' · Получена: ' + timestamp(s.pending_version_at) + ' · Проверен: ' + timestamp(s.pending_verified_at)),
                    E('p', {}, 'Начало выдержки: ' + timestamp(s.pending_series_started_at) + ' · Граница ожидания: ' + timestamp(s.pending_deadline_at)),
                    E('p', {}, 'Последняя попытка apply: ' + timestamp(s.last_apply_attempt) + ' · ' + (s.last_apply_error || s.apply_blocked_reason || '—')),
                    E('p', {}, 'Измерения хранятся в RAM. Скорость — ограниченная выборка, не максимум линии. Проверки используют принятые профили.'),
                    button('Прочитать текущий MAIN', () => this.operation('seed'), disabled)
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
                        disabled || !this.selectedTests().length || !nodes.some(n => this.scope === 'all' || n.selected)),
                    ...(this.running ? [button('Остановить', () => this.stopTests(), this.stopping)] : [])
                ])),
                ...(this.progress ? [E('p', { 'class': 'stk-progress', role: 'status', 'aria-live': 'polite' }, 'Проверено ' + this.progress.done + ' из ' + this.progress.total + ' · ' +
                    (this.stopping && this.running ? 'Остановка: текущая проба завершится и очистит процессы' : this.progress.message))] : [])
            ]),
            E('div', { 'class': 'stk-table stk-section', tabindex: '0', 'aria-label': 'Таблица серверов' }, E('table', { 'class': 'table' }, [
                E('tr', { 'class': 'tr table-titles' }, ['Сервер', 'Статус', 'Задержка', serviceName, 'Скорость', 'Проверено', 'Действия'].map(title => E('th', { 'class': 'th', scope: 'col' }, title)))
            ].concat(rows.length ? rows : [E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', colspan: '7' }, 'Серверов пока нет. Прочитайте текущий MAIN в подробностях.'))])))
        ]);
    },
    render: function(data) {
        this.canWrite = !L.hasViewPermission || L.hasViewPermission();
        this.tests = { latency: true, service: true, speed: false }; this.scope = 'all'; this.openDetails = {}; this.failures = {};
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
