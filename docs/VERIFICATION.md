# Проверки публикационной копии / publication verification

Проверки выполнены на независимом дереве из публичных исходников. Роутер не
использовался. Docker использует host kernel; аппаратная совместимость и reboot
этими результатами не подтверждаются. Все provider/HTTPS/DNS/VLESS данные стенда
синтетические, исторические приватные APK/backup не использованы.

| Проверка | Результат |
|---|---|
| Модельные ucode | 69 PASS |
| Сервисные ucode | 15 PASS |
| Provider fixture + native sing-box check | PASS |
| LuCI rendering/RPC/permissions harness | PASS |
| APK/native integration | 53 PASS |
| Recovery | 48 PASS |
| Ownership/CAS/rollback/migration | 25 PASS |
| Bounded rotation | 10 PASS |
| Readiness/integer-only BusyBox sleep | PASS |
| Настоящий LuCI в браузере | PASS |
| Audit injection/scoped-exception regressions | 2 PASS |
| Два checkout с разными timestamp | Побайтово одинаковые APK |
| APK payload | 19 файлов, совпадают с allowlist исходников |
| APK ownership/license/conflict metadata | root / GPL-2.0-only / конфликт старого пакета |
| Gitleaks: экспортное дерево и APK payload | 0 находок |
| Ручной разбор IP/URL/UUID/ключей/путей | Не осталось неразобранных значений |

SHA256 addon APK:
`bc9e78e3f52e4aa5feb0939cadb16762a6218eb5e6993181c3a2b4c7d65f5c5d`.

Backend, model, task/generate/boot/RPC/init и defaults (10 файлов) побайтово
совпадают с r6. Публичный профиль заменяет только отпечаток локального init
sing-box на официальный; публичные названия и лицензионные уведомления описаны
в COMPATIBILITY.md и THIRD_PARTY_NOTICES.md.

Полный повторяемый запуск: `python3 tools/prepare.py --lab`, `npm ci --ignore-scripts`,
`python3 tests/run.py all`. Наборы также запускались отдельно при адресной проверке
исправлений стенда. Исторические r2/r3 бинарные обновления не сертифицированы;
синтетическая миграция старого state проверена.

Перед начальным commit проверяется всё экспортное дерево. После commit
`tools/audit.py --history --require-no-remotes` дополнительно сканирует все Git
объекты, включая недостижимые, и проверяет отсутствие remote. Локальные финальные
receipts сохраняются вне tracked-дерева, в `.build/audit-history.json` и
`.build/clean-checkout-verification.json`. Их отсутствие не заменяет успешный запуск.

Self-review выполнено основным автором: пользователь запретил субагентов.
Независимое ревью другим человеком остаётся полезным перед внешней публикацией.
Публичный GitHub, push/release и публикация APK не выполнялись.
