// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 LuCI Subscription Toolkit contributors
'use strict';
'require view';
'require dom';
'require rpc';
'require poll';
'require ui';

const status = rpc.declare({ object: 'podkop-tools', method: 'status', expect: {} });
const actions = {};
['seed', 'fetch', 'apply', 'select', 'latency', 'service', 'speed'].forEach(function(name) {
    actions[name] = rpc.declare({ object: 'podkop-tools', method: name,
        params: name === 'apply' ? ['version'] : ['select', 'latency', 'service', 'speed'].includes(name) ? ['id'] : [], expect: {} });
});
function timestamp(value) { return value ? new Date(value * 1000).toLocaleString() : '—'; }
function button(label, action, id, disabled, version) {
    return E('button', { 'class': 'cbi-button cbi-button-action', disabled: disabled ? true : null,
        click: async function() {
            if (action === 'apply') {
                ui.showModal('Применить подписку?', [
                    E('p', {}, 'Podkop выполнит reload sing-box. Текущие соединения могут кратко прерваться.'),
                    E('div', { 'class': 'right' }, [
                        E('button', { 'class': 'cbi-button', click: ui.hideModal }, 'Отмена'),
                        E('button', { 'class': 'cbi-button cbi-button-positive', click: async function() {
                            ui.hideModal();
                            const result = await actions.apply(version);
                            if (result.ok === false) ui.addNotification(null, E('p', {}, result.error || 'Операция отклонена'), 'warning');
                        } }, 'Применить')
                    ])
                ]);
                return;
            }
            this.disabled = true;
            try {
                const result = await actions[action](id);
                if (result.ok === false) ui.addNotification(null, E('p', {}, result.error || 'Операция отклонена'), 'warning');
            } catch (_) { ui.addNotification(null, E('p', {}, 'Не удалось запустить операцию'), 'warning'); }
        }
    }, label);
}

return view.extend({
    load: function() { return status(); },
    content: function(s) {
        const disabled = !!s.busy || s.compatible === false || !this.canWrite;
        const rows = (s.nodes || []).map(function(n) {
            const t = n.test || {};
            return E('tr', { 'class': 'tr' }, [
                E('td', { 'class': 'td' }, n.name),
                E('td', { 'class': 'td' }, n.selected ? 'Выбран' : ''),
                E('td', { 'class': 'td' }, t.latency_at ? (t.latency != null ? t.latency + ' мс' : t.latency_error || '—') + ' · ' + timestamp(t.latency_at) : '—'),
                E('td', { 'class': 'td' }, t.service ? (t.service.stale ? 'Предыдущая конфигурация: ' : '') + (t.service.ok ? 'HTTPS доступен' : t.service.error) + ' · ' + timestamp(t.service.at) : '—'),
                E('td', { 'class': 'td' }, t.mbps != null ? t.mbps.toFixed(2) + ' Мбит/с' : '—'),
                E('td', { 'class': 'td' }, t.bytes != null && t.seconds != null ? (t.bytes / 1048576).toFixed(2) + ' МиБ / ' + t.seconds.toFixed(2) + ' с' : '—'),
                E('td', { 'class': 'td' }, timestamp(t.at)),
                E('td', { 'class': 'td' }, t.error || '—'),
                E('td', { 'class': 'td' }, [
                    button('Выбрать', 'select', n.id, disabled || n.selected), ' ',
                    button('Задержка', 'latency', n.id, disabled), ' ',
                    button('Сервис', 'service', n.id, disabled), ' ',
                    button('Скорость', 'speed', n.id, disabled)
                ])
            ]);
        });
        return E('div', {}, [
            E('h2', {}, 'Subscription Toolkit: подписка и скорость'),
            E('p', {}, 'Проверка сервиса проверяет только HTTPS-страницу через указанный VLESS: TLS, статус и содержимое. Для Telegram Web это не проверка MTProto, отправки сообщений или звонков.'),
            E('p', {}, 'MAIN управляется штатным Podkop. Тест скорости не переключает MAIN; ограниченная загрузка временно занимает часть канала.'),
            E('p', {}, 'Состояние: ' + (s.state || 'не инициализировано') + (s.error ? ' · ' + s.error : '') + (s.busy ? ' · выполняется задание' : '')),
            E('p', {}, s.fetch_error ? 'Ошибка последнего fetch: ' + s.fetch_error : 'Последний fetch: ошибок не зарегистрировано.'),
            E('p', {}, 'Серверов: ' + (s.count || 0) + ' · Последняя успешная проверка: ' + timestamp(s.last_success) + ' · Применение: ' + timestamp(s.last_apply)),
            E('p', {}, s.control ? 'Контрольный HTTPS endpoint: ' + (s.control.ok ? 'HTTP 204 получен' : 'проверка неуспешна') + ' · ' + timestamp(s.control.at) + ' · Последовательных отказов: ' + s.control.failures : 'Контрольный HTTPS endpoint ещё не проверен.'),
            E('p', {}, 'Контрольный HTTP 204 не подтверждает работу приложений. Сервисные пробы — отдельные сигналы; их ошибки сами по себе не переключают сервер.'),
            E('p', {}, s.pending ? (s.pending_stale ? 'Кандидат устарел; нужна новая проверка подписки.' : 'Есть кандидат; выбранный выход будет проверен перед применением.') + ' Версия: ' + timestamp(s.pending_version_at) + ' · Проверка источника: ' + timestamp(s.pending_verified_at) : 'Ожидающих изменений нет.'),
            E('p', {}, 'Начало серии изменений: ' + timestamp(s.pending_series_started_at) + ' · Граница ожидания: ' + timestamp(s.pending_deadline_at) + ' · Причина ожидания/отказа apply: ' + (s.apply_blocked_reason || '—')),
            E('p', {}, 'Последняя попытка apply: ' + timestamp(s.last_apply_attempt) + (s.last_apply_error ? ' · Ошибка: ' + s.last_apply_error : '')),
            E('div', { 'class': 'cbi-section' }, [
                button('Прочитать текущий MAIN', 'seed', null, disabled), ' ',
                button('Проверить подписку', 'fetch', null, disabled), ' ',
                button('Применить изменения', 'apply', null, disabled || !s.pending || s.pending_stale || !s.pending_version, s.pending_version)
            ]),
            E('table', { 'class': 'table' }, [E('tr', { 'class': 'tr table-titles' },
                ['Сервер', 'Выбор', 'Задержка', 'Доступность сервиса', 'Скорость', 'Выборка', 'Время скорости', 'Ошибка скорости', 'Действия'].map(x => E('th', { 'class': 'th' }, x)))].concat(rows)),
            E('p', {}, 'Результаты тестов и отметки частых проверок хранятся в RAM. Выбор через эту страницу сохраняется для восстановления после старта. Для скорости нужна выборка ≥256 КиБ и ≥0,5 с; она не показывает максимальную скорость линии.')
        ]);
    },
    render: function(data) {
        // LuCI checks write permission for the current view.
        this.canWrite = !L.hasViewPermission || L.hasViewPermission();
        const container = E('div', {}, [this.content(data)]);
        poll.add(async () => {
            const fresh = await status();
            dom.content(container, this.content(fresh));
        }, 3);
        return container;
    },
    handleSave: null,
    handleSaveApply: null,
    handleReset: null
});
