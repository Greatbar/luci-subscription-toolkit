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
        [5, 10, 15, 20, 30, 60].forEach(m => o.value(String(m), m + ' мин')); o.default = '15';
        o = s.option(form.Value, 'pending_max_age_hours', 'Свежесть последней проверки кандидата, ч', 'После истечения кандидат удаляется. Перед любым обычным apply источник проверяется повторно.'); o.datatype = 'range(1,72)'; o.default = '12';
        o = s.option(form.ListValue, 'apply_policy', 'Применение обычных изменений');
        o.value('manual', 'Вручную'); o.value('window', 'В отложенном окне');
        o = s.option(form.Value, 'apply_hour', 'Час окна (местное время роутера)'); o.datatype = 'range(0,23)'; o.depends('apply_policy', 'window');
        o = s.option(form.Value, 'defer_hours', 'Минимальная отсрочка, ч'); o.datatype = 'range(1,168)'; o.depends('apply_policy', 'window');
        o = s.option(form.Value, 'max_defer_hours', 'Максимальное ожидание серии изменений, ч', 'В ближайшем ночном окне после этого срока проверяется и применяется свежая версия, даже при частой ротации. Ошибка загрузки или проверки блокирует apply. Значение не меньше минимальной отсрочки.'); o.datatype = 'range(1,168)'; o.default = '24'; o.depends('apply_policy', 'window');
        o = s.option(form.Flag, 'priority_recovery', 'Восстановление при отказе активного сервера',
            'Два отказа в разных интервалах health-check. Сначала обновляется подписка и проверяется новый адрес выбранного ID, затем сохранённые резервы. Между попытками восстановления минимум 30 минут. HTTP 204 не доказывает работу приложений.'); o.rmempty = false;
        o = s.option(form.ListValue, 'fallback_id', 'Предпочтительный резерв'); o.value('', 'Первый проверенный совместимый сервер');
        (state.nodes || []).forEach(n => o.value(n.id, n.name));
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
