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
| Source/link/release/clone attack regressions | 11 PASS |
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

The addon payload remains byte-identical to r6. Tests/reproducibility.py now uses
two fresh clones overlaid with the frozen candidate, without committing, and
compares both normalized APKs with the release APK. Runtime root/htdocs/scripts
files remain unchanged. Full tests use only the isolated public-input lab.
