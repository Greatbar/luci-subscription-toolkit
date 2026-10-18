// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 LuCI Subscription Toolkit contributors
'use strict';
'require view';
'require form';
'require rpc';
'require ui';

const status = rpc.declare({ object: 'podkop-tools', method: 'status', expect: {} });
const source = rpc.declare({ object: 'podkop-tools', method: 'source', params: ['url'], expect: {} });
const schedule = rpc.declare({ object: 'podkop-tools', method: 'schedule', expect: {} });
return view.extend({
    load: function() { return status(); },
    render: function(state) {
        document.addEventListener('uci-applied', () => schedule().catch(() => ui.addNotification(null, E('p', {}, 'Не удалось обновить расписание'), 'warning')), { once: true });
        const m = new form.Map('podkop_tools', 'Subscription Toolkit: настройки',
            'Получение подписки отделено от применения. Файлы официального Podkop не изменяются. URL хранится приватно и не включается в диагностику.');
        const s = m.section(form.NamedSection, 'main', 'tools'); s.anonymous = true;
        let o = s.option(form.Flag, 'enabled', 'Периодические проверки и восстановление выбора при старте'); o.rmempty = false;
        o = s.option(form.Value, 'subscription_url', 'URL подписки'); o.password = true;
        o.description = state.subscription_configured ? 'Подписка настроена. Для замены введите новый URL; оставьте пустым для сохранения.' : 'Введите HTTPS URL подписки. Он сохраняется отдельно от общих изменений LuCI.';
        o.cfgvalue = () => '';
        o.write = async function(section, value) {
            if (!value) return;
            const result = await source(value);
            if (result.ok === false) throw new Error(result.error || 'Не удалось сохранить подписку');
        };
        o.remove = () => {};
        o.validate = function(section, value) {
            return !value || /^https:\/\/[^\s@/]+\//.test(value) && !/[\x00-\x20\x7f]/.test(value) ? true : 'Нужен HTTPS URL без пробелов и userinfo';
        };
        o = s.option(form.ListValue, 'fetch_hours', 'Интервал получения');
        [1, 2, 3, 4, 6, 8, 12, 24].forEach(h => o.value(String(h), h + ' ч'));
        o = s.option(form.ListValue, 'health_minutes', 'Интервал контрольного health-check');
        [1].forEach(m => o.value(String(m), m + ' мин')); o.default = '1';
        o = s.option(form.Value, 'pending_max_age_hours', 'Свежесть последней проверки кандидата, ч', 'После истечения кандидат удаляется. Перед любым обычным apply источник проверяется повторно.'); o.datatype = 'range(1,72)'; o.default = '12';
        o = s.option(form.ListValue, 'apply_policy', 'Применение обычных изменений');
        o.value('manual', 'Вручную'); o.value('window', 'В отложенном окне');
        o = s.option(form.Value, 'apply_hour', 'Час окна (местное время роутера)'); o.datatype = 'range(0,23)'; o.depends('apply_policy', 'window');
        o = s.option(form.Value, 'defer_hours', 'Минимальная отсрочка, ч'); o.datatype = 'range(1,168)'; o.depends('apply_policy', 'window');
        o = s.option(form.Value, 'max_defer_hours', 'Максимальное ожидание серии изменений, ч', 'В ближайшем ночном окне после этого срока проверяется и применяется свежая версия, даже при частой ротации. Ошибка загрузки или проверки блокирует apply. Значение не меньше минимальной отсрочки.'); o.datatype = 'range(1,168)'; o.default = '24'; o.depends('apply_policy', 'window');
        o = s.option(form.Flag, 'priority_recovery', 'Восстановление при отказе активного сервера',
            'Отказ подтверждается числом последовательных ошибок и временем. Затем проверяется свежий профиль предпочтительного сервера и резервы. HTTPS-проба не подтверждает работу приложений.'); o.rmempty = false;
        o = s.option(form.DynamicList, 'priority_ids', 'Порядок резервных серверов',
            'Выберите резервные серверы по порядку предпочтения. Серверы вне списка проверяются последними. Основной выбирается на странице серверов.');
        (state.nodes || []).forEach(n => o.value(n.id, n.name));
        o.validate = (section, value) => !value || /^[a-f0-9]{64}$/.test(value) ? true : 'Выберите сервер из списка';
        const numeric = (key, label, value, range, description) => {
            const field = s.option(form.Value, key, label, description);
            field.datatype = range; field.default = value; field.rmempty = false;
            return field;
        };
        numeric('probe_timeout_seconds', 'Таймаут HTTPS-пробы, с', '5', 'range(1,5)');
        numeric('failure_seconds', 'Минимальная длительность отказа, с', '120', 'range(1,86400)');
        numeric('failure_count', 'Последовательных ошибок для отказа', '3', 'range(1,100)');
        o = s.option(form.Flag, 'latency_enabled', 'Переключение при устойчивой высокой задержке',
            'По умолчанию выключено. При включении резерв должен пройти HTTPS-пробу и улучшить задержку на оба заданных порога.');
        o.default = '0'; o.rmempty = false;
        numeric('latency_threshold_ms', 'Порог задержки, мс', '1000', 'range(1,60000)').depends('latency_enabled', '1');
        numeric('latency_duration_seconds', 'Выдержка высокой задержки, с', '300', 'range(1,86400)').depends('latency_enabled', '1');
        numeric('improvement_percent', 'Минимальное улучшение, %', '20', 'range(0,100)').depends('latency_enabled', '1');
        numeric('improvement_ms', 'Минимальное улучшение, мс', '50', 'range(0,60000)').depends('latency_enabled', '1');
        numeric('cooldown_seconds', 'Пауза между автоматическими переключениями, с', '600', 'range(0,86400)');
        o = s.option(form.Flag, 'failback_enabled', 'Возвращаться к предпочтительному серверу',
            'Возврат после устойчивых успешных HTTPS-проб предпочтительного сервера.'); o.default = '1'; o.rmempty = false;
        numeric('failback_seconds', 'Выдержка перед возвратом, с', '600', 'range(1,86400)').depends('failback_enabled', '1');
        numeric('failback_successes', 'Успешных проб перед возвратом', '3', 'range(1,100)').depends('failback_enabled', '1');
        o = s.option(form.Value, 'bootstrap_dns', 'Bootstrap DNS'); o.datatype = 'ip4addr';
        o = s.option(form.Value, 'bootstrap_port', 'Порт Bootstrap DNS'); o.datatype = 'port';
        s.option(form.Value, 'health_url', 'Endpoint проверки доступности', 'HTTPS; успешный ответ должен быть HTTP 204.');
        o = s.option(form.Value, 'service_url', 'HTTPS endpoint сервиса', 'Лимит 512 КиБ / 8 с. Без редиректов; только выбранный VLESS. HTTP не проверяет сообщения или звонки.');
        o.default = 'https://web.telegram.org/k/';
        o.validate = (section, value) => /^https:\/\/[^\s@/]+\//.test(value) && !/[\x00-\x20\x7f]/.test(value) ? true : 'Нужен HTTPS URL';
        o = s.option(form.Value, 'service_status', 'Ожидаемый HTTP статус'); o.datatype = 'range(200,299)'; o.default = '200';
        o = s.option(form.Value, 'service_content_type', 'Ожидаемый Content-Type'); o.default = 'text/html';
        o = s.option(form.DynamicList, 'service_markers', 'Обязательные фрагменты ответа', 'Все фрагменты должны присутствовать. Для другого endpoint задайте его собственный контракт.');
        o.default = ['<title>Telegram Web</title>', 'content="https://web.telegram.org/k/"', '<script type="module"']; o.rmempty = false;
        s.option(form.Value, 'speed_url', 'Endpoint скорости', 'HTTPS, несжимаемые данные, без редиректов. {bytes} заменяется лимитом объёма.');
        o = s.option(form.Value, 'speed_bytes', 'Лимит загрузки, байт'); o.datatype = 'range(262144,16777216)';
        o = s.option(form.Value, 'speed_seconds', 'Лимит времени загрузки, с'); o.datatype = 'range(2,15)';
        return m.render();
    }
});
