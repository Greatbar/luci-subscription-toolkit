# Проверки публикационной копии / publication verification

Начальные результаты ниже относятся к предыдущей публикационной копии.
Текущее состояние проверяется по процедуре в PUBLICATION.md; локальные receipts
и хеши артефактов находятся в `.build/prepublish.json` и `dist/SHA256SUMS`.

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
| Source/link/release/clone attack regressions | 11 PASS |
| Два checkout с разными timestamp | Побайтово одинаковые APK |
| APK payload | 19 файлов, совпадают с allowlist исходников |
| APK ownership/license/conflict metadata | root / GPL-2.0-only / конфликт старого пакета |
| Gitleaks: экспортное дерево и APK payload | 0 находок |
| Ручной разбор IP/URL/UUID/ключей/путей | Не осталось неразобранных значений |

SHA256 addon APK:
`bc9e78e3f52e4aa5feb0939cadb16762a6218eb5e6993181c3a2b4c7d65f5c5d`.

До обновления интерфейса ниже backend, model, task/generate/boot/RPC/init и
defaults (10 файлов) побайтово совпадали с r6. Публичный профиль заменяет только
отпечаток локального init
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

## Security hardening verification

The required gate is `python3 -B tools/prepublish.py`. It freezes the complete
candidate as a temporary Git tree, scans the current sources and every existing
Git object, validates pinned tools and generated fixtures, builds/extracts the APK,
and checks the exact three release files. The receipt in .build/prepublish.json
identifies the candidate tree; it is a local report, never a release attachment.

The pre-push hook runs the same gate with --require-head. Current uncommitted
infrastructure changes require separate commit authorization; the hook rejects
an old HEAD even if a working candidate passes. No commit/push/tag/release was run.

Temporary clone attacks cover hidden files, external file/directory links, nested
.build, changed payload bytes, a synthetic API-key canary in README and ignored
.env. Both build/staging and prepublish must return failure with the policy reason.
Historical fixtures are also compared byte-for-byte with explicitly constructed
synthetic TLS data; current fixtures are generated synthetic Reality data.

Before the interface update below, the addon payload was byte-identical to r6.
Tests/reproducibility.py uses
two fresh clones overlaid with the frozen candidate, without committing, and
compares both normalized APKs with the release APK. At that stage
runtime root/htdocs/scripts
files remained unchanged. Full tests use only the isolated public-input lab.

## Компактная страница серверов (2026-10-12)

Сохранены Bootstrap и существующие RPC проверок. Status дополнен фактическим
лимитом speed-теста, временем следующего допустимого запуска, признаками свежести
метрик и отметкой завершения диагностики. Приватные сигнатуры профилей хранятся
только в защищённом RAM-файле результатов и удаляются из публичного ответа.
Маршрутизация, импорт, cron, auto-apply, recovery и stable IDs не изменены.

Очередь принадлежит открытой странице: по одному заданию, с интервалом скорости
60 секунд. Отмена удаляет оставшиеся задания; текущая ограниченная проба завершает
штатную очистку. Уход со страницы также прекращает очередь. Проверки pending
не предлагаются: существующие методы адресуют только принятые профили.

Адресные проверки: `npm test`, `python3 -B tests/run.py integration`,
`python3 -B tests/run.py browser`. Браузер использует настоящий LuCI Bootstrap в
изолированном OpenWrt с 11 синтетическими серверами, ширинами 1440 и 390 px и
светлым/тёмным оформлением. Отдельные пробы выполняются через настоящий RPC;
массовые ошибки, прогресс, отмена и лимит 44 МиБ проверяются также с управляемыми
ответами RPC без массовой загрузки данных. Интервал speed проверен виртуальными
часами в JS, фактическое ограничение — в backend-интеграции. Снимки находятся
в игнорируемом `test-results/`. Сравниваются MAIN, конфигурация, PID и Selector;
проверяется отсутствие временных проб. Проверены сохранение настроек, приватный
URL и обработчик расписания. Рабочий роутер не использован; commit/push/release
не выполнялись. Полный публикационный gate для этого изменения не запускался.

## Финальная подготовка к публикации

UI принят пользователем. Новые функции не добавляются. Security hardening и
изменения интерфейса проверяются вместе, затем фиксируются локально. В ревью
исправлено занижение верхней границы трафика при лимите, не кратном МиБ:
значения подтверждения округляются вверх; добавлен регрессионный сценарий
10 000 000 байт → до 9,6 МиБ.

Обязательные финальные проверки: полный `tests/run.py all`, затем
`tools/prepublish.py --require-head` на зафиксированном HEAD и
`tests/reproducibility.py`. Gate сканирует исходники, все Git-объекты и историю,
проверяет побайтовое происхождение fixtures, инструменты, извлечённый APK и
точные три release-артефакта. До успешного завершения этих команд состояние
нельзя считать готовым к публикации. Receipt должен совпадать с HEAD tree;
последующие изменения требуют нового gate. Создание репозитория, push/tag/release
и установка на роутер в эту подготовку не входят.
