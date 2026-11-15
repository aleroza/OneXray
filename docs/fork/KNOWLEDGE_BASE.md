# База знаний по OneXray (наш форк)

Рабочий документ для будущих сессий. Описывает **внутреннее устройство** репозитория
OneXray так, чтобы не перечитывать весь код перед каждой задачей.

Upstream-документация репозитория лежит в `docs/` (китайский) — это контракты
поведения, их правило «одна правда в одном месте». Этот файл — карта кода и
**наши** решения в форке; он не пересказывает upstream-контракты, а указывает,
где что лежит.

- Родитель: <https://github.com/YuanDevTeam/OneXray>
- Форк: наш репозиторий, обновление — **rebase наших коммитов поверх upstream**.

---

## 0. Правила форка (главное, прочитать первым)

Задача форка — добавить своё, **не переписывая чужое**.

1. **Минимум изменений.** Никаких рефакторингов, переименований, «украшений»,
   переносов файлов, изменения форматирования, обновления зависимостей,
   массового перевода комментариев. Каждая лишняя правка — будущий конфликт
   при ребейзе.
2. **Точечные хуки.** Новое поведение встраивается в существующие точки
   расширения (`_runtimeInbound`, `_rawRuntimeMap`, `PlatformPolicy`,
   `RuntimeOptions`), а не переписывает окружающие ветки.
3. **Не трогать generated-файлы.** Drift (`*.g.dart`), Pigeon
   (`messages.g.dart` и нативные аналоги), FFI, локализация — это вывод.
   Правятся источники, потом запускается генератор.
4. **Не ломать дефолты.** Значение по умолчанию новых настроек обязано давать
   поведение, идентичное upstream. Иначе апдейт у логина пользователей
   поменяет режим работы.
5. **Коммит = одна логическая перемена.** Сообщения в стиле репозитория:
   `<type>(<scope>): <summary>`, английский, одна строка, до 72 символов.
   Типы: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore`.
6. **Обновление от родителя.** Перед ребейзом: `git fetch upstream`,
   `git rebase upstream/main`. Конфликты разрешаются в пользу **нашей**
   семантики поверх нового кода родителя.

Полезно держать список своих коммитов, чтобы при ребейзе понимать, что «наше»:
`git log --oneline upstream/main..HEAD`.

---

## 1. Что это за проект

- Flutter-приложение (Dart), кроссплатформенный клиент Xray-core.
- Версия в `pubspec.yaml`: `26.11.4+1`. Требует **Flutter >= 3.50.0**, **Dart SDK >= 3.14.0**.
- Нативные части: Android (Kotlin), Apple (Swift), Windows (Dart FFI + внешний
  `OneXrayCore`), Linux (Dart FFI + процесс `OneXrayCore`).
- Ядро Xray приезжает из отдельного репозитория **libXray**
  (`XTLS/libXray`), собирается в `build_scripts/`. Версия ядра — не в этом
  репозитории.
- Три независимых «режима конфигурации»:
  - **обычный** — App сам собирает конфиг из узлов (Smart / AllVPN / Custom);
  - **продвинутый шаблон** — JSON-шаблон с пустыми слотами под узлы;
  - **эксперт (Raw)** / **полный конфиг провайдера (Remnawave)** — целый чужой
    граф Xray, App только дополняет его.

---

## 2. Слои и правило зависимостей

Проверяется скриптом `tool/check_layer_dependencies.dart`:

```
lib/core  →  не может зависеть от lib/service и lib/pages
lib/service → не может зависеть от lib/pages
lib/pages  → может зависеть от core и service
```

Поток: `pages → service → core`.

- `lib/core` — модели, БД (Drift), pigeon/FFI, константы, утилиты. Никакой
  бизнес-логики и Flutter-UI.
- `lib/service` — вся бизнес-логика: компиляция конфига, координатор
  подключения, подписки, политики, бэкап, локальный API.
- `lib/pages` — UI. Страницы наследуют `PageCubit`/контроллеры и держат
  состояние в Bloc. Свои контроллеры — в `lib/pages/<area>/controller.dart`.

Тексты, скролл, фокус, сторонние контроллеры — UI-ресурсы, не бизнес-логика.

---

## 3. Карта каталогов

```
lib/core/
  backup/           протокол бэкапа: codec, model, storage
  constants/        preferences.dart — shared_preferences (namespace "app2.")
  db/               Drift: database/, table/, dao/, enum.dart
  desktop_startup/  автозапуск/стартап-адаптеры по ОС
  desktop_window/   нативное окно
  errors/           failure.dart, json_diagnostic.dart
  ffi/              base_ffi_api, linux_ffi_api, windows/* (exe/msix)
  model/            xray_json.dart (модели Xray), tun_json.dart, geo_dat, ...
  network/          константы сети (NetConstants.proxyHost = 127.0.0.1)
  pigeon/           constants.dart, host_api, flutter_api, model_writer
  tools/            json.dart (JsonTool), json_document, traffic_format
lib/service/
  advanced/         platform_policy.dart, local_api/, xray/, tunnel/
  connect/          ★ ядро подключения: compiler, preparation, coordinator,
                    runtime, runtime_host, settings, resolver, routing/
  launch/           bootstrap, setup, splash
  servers/          subscription/, outbound/, каталог узлов
  settings/         app_update, backup, language, data_cleanup
  shared/           xray/ (runtime_inbounds, vpn_config, remnawave,
                    validation, fake_dns, fragment, metrics), event_bus,
                    menu, notification, ping, share
lib/pages/
  connect/  servers/  routing/  advanced/(tunnel,xray)  settings/  main/
lib/l10n/           app_{en,ru,zh,zh_Hant,fa}.arb → lib/l10n/localizations/
pigeon/             message.dart — схема Pigeon (источник для 3 платформ)
android/ swift/ ios/ linux/ windows/ macos/   нативный код
tool/               генераторы и проверки
test/               230+ *_test.dart по слоям (core/service/pages/native/tool)
docs/               контракты поведения (кит.) + наш docs/fork/
```

---

## 4. Хранилище настроек

### 4.1 БД (SQLite, Drift)

| Таблица | Что хранит |
|---|---|
| `connection_config` | **одна строка** (id=1), `configurationJson` = `{connection: {...}, policy: {...}}` |
| `core_config` | узлы (`type=outbound`), Raw (`type=raw`), полные конфиги провайдера (`type=Remnawave`) |
| `subscription` | источники подписок, `mode` = `appManaged` \| `providerManaged`, `panel` |
| `routing_profile` | обычные и продвинутые шаблоны маршрутизации |
| `manual_server_group` | ручные группы узлов |
| `geo_data` | индексы geodata |

`ConnectionConfiguration` (`lib/service/connect/runtime.dart:11`) = две секции:

- `connection` → `ConnectionSettings` (`lib/service/connect/settings.dart:125`):
  `expert`, `rawId`, `selection` (kind/id), `trafficMode`, `customId`,
  `rememberedOrdinarySelection`, `smart` (SmartRoutingSettings).
- `policy` → `PlatformPolicy` (`lib/service/advanced/platform_policy.dart:28`):
  **устройство**: `ipv6Enabled`, `dialing`, `dnsIpv4Address`, `dnsIpv6Address`,
  `dnsServerName`, `xrayOutboundInterfaceName`, `lanProxy{enabled,port}`,
  `android{...}`, `apple{...}`, `windows{...}`, `log{...}`.

`PlatformPolicy` — **строгий** парсер: `_readPolicyObject` (`platform_policy.dart:304`)
падает на неизвестном поле (`'Unknown platform policy field'`) и на несовпадении
типа. Новое поле = добавить в `_defaults` (`:262`) **и** в валидацию
(`fromJson`, `:35`). Значения по умолчанию задаются только в `_defaults`.

### 4.2 SharedPreferences (`lib/core/constants/preferences.dart`)

Только UI/десктопные предпочтения: тема, язык, сортировка, privacy accepted,
автообновление, бэкап, hideDockIcon, desktopStartHidden, connectOnAppLaunch,
ping state, localApi. Namespace — `"app2."`.

**Правило:** если флаг влияет на эффективный конфиг Xray — он НЕ в
Preferences, а в `ConnectionSettings` или `PlatformPolicy`.

---

## 5. Конвейер: подписка → эффективный конфиг → запуск

```
Подписка
  service/servers/subscription/reader.dart
    :54  read(text, input) → классификация: «полный конфиг» vs «обычные узлы»
         «полный» = panel=remnawave | JSON-массив | объект без ключа outbounds
         обычный → mode=appManaged, строки-узлы (type=outbound)
  service/servers/subscription/service.dart  → запись в core_config/subscription

Выбор узла
  service/connect/resolver.dart  → List<ResolvedServer> | ResolvedProfile

Подготовка
  service/connect/preparation.dart
    :152 prepare(...)  → tun = policy.toTun(platform)
                        → ports = allocateRuntimePorts(...)   [socksPort, metricsPort]
                        → compiled = ConnectionCompiler.compile(...)
                        → request = StartVpnRequest(tun, socksPort, metricsPort, coreInvokeText)

Компиляция (чистая функция, без БД/файлов/портов)
  service/connect/compiler.dart
    :263 compile(...)  → три ветки:
        profile != null          → RemnawaveAdapter.adapt → _fullRuntimeMap
        settings.expert          → VpnConfigAdapter.adapt(raw) → _fullRuntimeMap
        иначе                   → обычный XrayJson (в т.ч. продвинутый шаблон)

Запуск
  service/connect/runtime_host.dart
    :287 _start → host.startVpn(windowsConfigYaml?, windowsNetworkSettings?, windowsPolicy?)
    core/ffi/linux_ffi_api.dart  :85 startVpn → :143 startCore(request, tun)
      → процесс `OneXrayCore run -dns <ip>:53 -interface <if> -config <path> -error-file <path>`
    core/ffi/base_ffi_api.dart :109 materializeRunXrayConfig → run/core-inputs/input-*/xray.json
  run/start.json — единственный нативный запрос запуска

Учёт трафика
  GET http://127.0.0.1:<metricsPort>/debug/vars → stats.inbound.tunIn
  service/shared/xray/metrics/model.dart:13
```

---

## 6. ★ Подсистема инбаундов (то, что мы правим)

### 6.1 Фабрики — `lib/service/shared/xray/runtime_inbounds.dart` (весь файл, 57 строк)

| Символ | Протокол | listen | порт | tag |
|---|---|---|---|---|
| `createTunInbound(...)` | `tun` | `127.0.0.1` | — | `tunIn` |
| `createSocksInbound(port, ...)` | `socks` | `127.0.0.1` | строка | `tunIn` |
| `createLanProxyInbound(port, ...)` | `socks` | `0.0.0.0` | строка | `app-lan-proxy` |

Константы: `lanProxyInboundTag = 'app-lan-proxy'`, `defaultLanProxyPort = 11024`.
`NetConstants.proxyHost = '127.0.0.1'` (`core/network/constants.dart`).
`VpnConstants.tunMtu = 1500` (`core/pigeon/constants.dart`).

**Важно:** тег `tunIn` одинаков и для TUN, и для SOCKS. Маршруты и метрики
опираются на `tunIn`, а не на протокол. Поэтому «TUN → SOCKS» — это смена
протокола, а не смена тега.

### 6.2 Решение TUN vs SOCKS — `compiler.dart:587` `_runtimeInbound(options)`

```dart
if (options.usesWindowsSystemVpn) {          // Windows + WindowsMode.msix
  return createSocksInbound('${options.socksPort}', ...);
}
final nativeTun = platform == linux || platform == windows;
return createTunInbound(
  gateway: nativeTun ? ['198.18.0.1/15', if (ipv6) 'fc00::1/64'] : null,
  dns: nativeTun ? [tunDnsIpv4, if (ipv6) tunDnsIpv6] : null,
  autoSystemRoutingTable: nativeTun ? ['0.0.0.0/0', if (ipv6) '::/0'] : null,
  autoOutboundsInterface: nativeTun ? interfaceName : null,
  autoSystemWfpBlockLeak: platform == windows ? ['dns'] : null,
);
```

`RuntimeOptions.usesWindowsSystemVpn` (`compiler.dart:156`).

`WindowsMode` — **compile-time** переключатель, не пользовательская настройка:
`core/ffi/windows/mode.dart:1`, `String.fromEnvironment('ONEXRAY_WINDOWS_MODE')`,
дефолт `exe`.

### 6.3 Где управляемый инбаунд добавляется/перезаписывается (4 места)

| # | Файл:строка | Сценарий | Что происходит |
|---|---|---|---|
| 1 | `compiler.dart:475-487` | обычный режим | `inbounds: [_runtimeInbound(...), if (lanProxy) createLanProxyInbound(...)]` |
| 2 | `compiler.dart:330-342` | продвинутый шаблон | шаблонный placeholder `tunIn` перекрывается сгенерированным (пользовательский sniffing выигрывает) |
| 3 | `compiler.dart:689-734` (`_rawRuntimeMap`) | Raw / провайдер | если `tunIn` нет — `inbounds.insert(0, generated)`; если есть — перезаписываются только platform-поля (`name`, `mtu`, `gateway`, `dns`, `autoSystemRoutingTable`, `autoOutboundsInterface`), `autoSystemWpfBlockLeak` — через `putIfAbsent` |
| 4 | `vpn_config.dart:36-41` / `remnawave.dart:36-47` | адаптеры (сохранение/копирование/поделиться) | если `tunIn` нет — создаётся TUN-инбаунд |

Дополнительно: `remnawave.dart` переиспользует существующий `protocol=tun`
инбаунд (приоритет — тот, у кого уже tag `tunIn`), иначе первый TUN; его tag
приводится к `tunIn`, а `routing.rules.inboundTag` синхронизируется.
`vpn_config.dart` при отсутствии `tunIn` **всегда** добавляет именно TUN —
это и есть «автоматическое добавление», на которое жалуется пользователь.

### 6.4 Проверки, которые надо учитывать при правках

- `compiler.dart:674-676` — Raw не может содержать второй `protocol=tun`
  (кроме `tunIn`): `'Use the App-managed tunIn tunnel'`.
- `compiler.dart:685-688` — только один `tunIn`.
- `compiler.dart:677-683` — порт пользовательского инбаунда не может совпадать
  с `metricsPort` (всегда) и `socksPort` (только MSIX).
- `preparation.dart:25-48` — `allocateRuntimePorts` не выдаёт порты, занятые
  пользовательскими инбаундами и портом локального HTTP API.
- `preparation.dart:50-122` — конфликт пользовательского инбаунда с портом
  HTTP API (`_inboundConflictsWithHttpApi`).
- `compiler.dart:206-218` — `validateLanProxyInbounds` (tag `app-lan-proxy`
  занят App; порт не должен пересекаться).
- `preparation.dart:354-355` — LAN proxy добавляется **только** в обычном/
  custom режиме; Raw и провайдер его не получают.

### 6.5 Платформенные особенности

- **Linux / Windows EXE**: TUN создаёт сам Xray из секции `settings` инбаунда
  (`autoSystemRoutingTable`, `autoOutboundsInterface`, `gateway`, `dns`).
  `tun` из `StartVpnRequest` используется только для `-dns` и `-interface`
  аргументов процесса. → **Без TUN-инбаунда ядро просто работает как локальный
  прокси**, системной маршрутизации нет.
- **Windows MSIX**: SOCKS-инбаунд + Vole (UWP) строят системный туннель
  поверх локального SOCKS (`core/ffi/windows/tun2socks.dart:1`,
  `runtime_host.dart:287`).
- **Android**: нативный `VpnService` создаёт TUN и подставляет FD в
  `env["xray.tun.fd"]` (`android/.../vpn/RuntimeTunConfig.kt:21`). Без
  TUN-инбаунда в конфиге FD не потребляется → трафик уходит в никуда.
- **iOS/macOS**: `NEPacketTunnelProvider`, FD из нативного расширения
  (`swift/All/RuntimeEnv.swift:110`). Без TUN-инбаунда туннель не работает.
- **iOS Simulator**: нативный Swift переписывает `tunIn` в SOCKS
  (`swift/App/SimulatorProxy.swift:47`).

### 6.6 Маршруты и метрики, завязанные на `tunIn`

`compiler.dart:518-529` — правила `app-tunnel-dns` (порт 53 → `dnsOutbound`) и
`app-tunnel-dot` (порт 853 → balancer proxy), оба с `inboundTag: ['tunIn']`.
`compiler.dart:531-539` — `app-proxy-catchall` (catchall proxy для `tunIn`
и, если включён, `app-lan-proxy`), добавляется только при `selection.automatic`.

Метрики: `service/shared/xray/metrics/model.dart:13` — только `stats.inbound.tunIn`
(и то же в Android `TrafficSample.kt:30`). LAN proxy в трафик не входит.

---

## 7. Режимы и переключатели, которые уже есть

| Что | Где | Значения | Влияет на инбаунды? |
|---|---|---|---|
| `TrafficMode` | `connect/settings.dart:7` | `smart`, `allVpn`, `custom` | Нет — только маршрутизация/DNS/fragment |
| `SelectionKind` | `connect/settings.dart:5` | `automatic`, `source`, `server` | Нет |
| `ConnectionPlatform` | `connect/settings.dart:3` | ios/macos/android/windows/linux | Да — какие platform-поля у TUN |
| `WindowsMode` | `core/ffi/windows/mode.dart:1` | `exe`, `msix` | **Да** — MSIX = SOCKS + Vole |
| `SubscriptionMode` | `core/db/database/enum.dart:28` | `appManaged`, `providerManaged` | Да — узлы vs полный граф |
| `CoreConfigType` | `core/db/database/enum.dart:3` | `outbound`, `raw`, `Remnawave` | Да — путь компиляции |
| `lanProxyEnabled/Port` | `advanced/platform_policy.dart:97` | bool / 1024–65535 | Да — добавляет `app-lan-proxy` |
| `TrafficMode`/`PlatformPolicy` | `ConnectionSettings` / `PlatformPolicy` | | хранятся в БД, `connection_config` |

**Пользовательского переключателя «какой инбаунд создавать» в аппе нет.**
Единственный переключатель TUN↔SOCKS — compile-time `WindowsMode`.

---

## 8. UI

- Корневые вкладки: `connect`, `servers`, `routing`, `tunnel` (Advanced→Туннель),
  `xray` (Advanced→Xray), `settings`. Реестр — `lib/pages/main/navigation.dart`
  (`AppPageDestination`, ~50 маршрутов).
- Роутинг: go_router + `StatefulNavigationShell` (вложенные ветки).
- Каждая страница: `page.dart` (view) + `controller.dart` (состояние) +
  при необходимости `view.dart`/`widgets.dart`.
- Переиспользуемые виджеты: `lib/pages/shared/widgets/`,
  тема — `lib/pages/theme/` (`AppTheme`, `AppTypography`, `ColorManager`,
  `AppSpacing`, `AppLayout`).
- Иконки — `LucideIcons`.
- Платформенные подстраницы политики: `pages/advanced/tunnel/{android,apple,windows,interface}`,
  LAN proxy — `pages/advanced/xray/lan_proxy/` (образец: страница + контроллер
  на `PolicyEditorController`).

### Редактор политики

`lib/service/advanced/policy_editor.dart` — общий механизм:
`PolicyEditorDraft` (черновик JSON), `PolicyEditorService.load/prepare/save`,
`sameRuntime(...)` — сравнение «эффективного» рантайма для решения «нужен ли
реконнект». Контроллеры страниц наследуют `PolicyEditorController`.

---

## 9. Локализация

- Источник: `lib/l10n/app_{en,ru,zh,zh_Hant,fa}.arb`.
- Генерат: `lib/l10n/localizations/app_localizations*.dart` (сгенерировано, не правим руками).
- Конфиг: `l10n.yaml` (`output-dir: lib/l10n/localizations`).
- Команда: `flutter gen-l10n`.
- **Новые строки → во все 5 ARB**, затем `flutter gen-l10n`. Генерируемые файлы
  в коммит входят, но правится только ARB.

---

## 10. Нативный мост

- **Pigeon**: схема `pigeon/message.dart` → генерация `dart run tool/generate_pigeon.dart`
  → `lib/core/pigeon/messages.g.dart`, `android/.../pigeon/Messages.g.kt`,
  `swift/*/pigeon/Messages.g.swift`.
- **FFI**: `lib/core/ffi/`; десктопный `OneXrayCore` — отдельный бинарь;
  `tool/ffigen.dart` — генерация bindings.
- **Контракты**: `lib/core/pigeon/model.dart` (`StartVpnRequest`, `TunJson`,
  `LibXrayInvokeRequest`, `RunXrayRequest`), `model_writer.dart`
  (`writeToStartFile` → `run/start.json`).
- Проверка: `dart run tool/check_native_model_contract.dart` (только имена полей).

---

## 11. Сборка и проверки

Требуется Flutter ≥ 3.50 (в nixpkgs на данный момент 3.41.9 — **не подходит**;
нужно поставить SDK 3.50 вручную или использовать `fvm`).

```shell
flutter gen-l10n                      # после правки ARB
dart run tool/generate_pigeon.dart     # после правки pigeon/message.dart
dart run build_runner build           # после правки Drift-моделей
dart run tool/ffigen.dart              # после правки FFI
dart run tool/check_layer_dependencies.dart
dart format --output=none --set-exit-if-changed <изменённые .dart>
flutter analyze
flutter test
git diff --check
```

Нативные проверки:

```shell
# Android
cd android && ./gradlew :app:testDebugUnitTest
# Swift (без Xcode-сборки целиком)
bash tool/test_runtime_env.sh
bash tool/test_apple_widget.sh
bash tool/test_backup_file_store.sh
bash tool/test_dat_file_transfer.sh
bash tool/test_system_extension_activation.sh
# build_scripts
cd build_scripts && python -m unittest discover -s tests
```

Все Flutter/Dart-команды — **строго последовательно** (общие `.dart_tool` и
native build state).

---

## 12. Тесты

`test/` зеркалит `lib/`: `core/`, `service/`, `pages/`, `native/`, `tool/`, `support/`.
230+ файлов. Ключевые для нашей задачи:

- `test/service/connect/compiler_test.dart` — компиляция: MSIX SOCKS vs TUN
  (`:342`), LAN proxy (`:523`), ownership полей Raw-`tunIn` (`:612`),
  native TUN DNS (`:941`).
- `test/service/connect/preparation_test.dart` — аллокация портов, конфликты.
- `test/service/connect/routing/custom/advanced_test.dart` — шаблон `tunIn`.
- `test/service/advanced/policy_editor_test.dart` — политика.
- `test/service/shared/xray/remnawave_test.dart` — адаптер провайдера.

Правило репозитория: тест проверяет **поведение**, а не реализацию; нельзя
проверять исходный код строками или считать приватные вызовы.

---

## 13. Карта «куда лезть» по типовым задачам

| Задача | Файлы |
|---|---|
| Сменить/добавить управляемый инбаунд | `service/connect/compiler.dart` (`_runtimeInbound`), `service/shared/xray/runtime_inbounds.dart` |
| Изменить, что попадает в эффективный конфиг | `service/connect/compiler.dart` (`compile`, `_rawRuntimeMap`) |
| Новое устройство/политика | `service/advanced/platform_policy.dart` (`_defaults` + `fromJson` + getter) |
| Новый флаг подключения | `service/connect/settings.dart` (`ConnectionSettings` + `toJson/fromJson`) |
| Пробросить настройку до компилятора | `service/connect/preparation.dart` (`RuntimeOptions`) → `compiler.dart` (`RuntimeOptions`) |
| Настройка применяется при следующем старте | `service/advanced/policy_editor.dart` (`sameRuntime`) |
| Новый UI-пункт настроек | `pages/main/navigation.dart` (+ `url.dart`), `pages/advanced/...` |
| Новые строки UI | `lib/l10n/app_*.arb` → `flutter gen-l10n` |
| Реальный старт ядра | `service/connect/runtime_host.dart`, `core/ffi/*` |

---

## 14. Полезные команды

```shell
git log --oneline upstream/main..HEAD     # наши коммиты (при ребейзе)
git diff upstream/main...HEAD --stat       # объём наших правок
dart run tool/check_layer_dependencies.dart
flutter test test/service/connect/compiler_test.dart
```

---

## 15. Журнал решений форка

Здесь — краткие записи по нашим изменениям (что, зачем, где в коде).

### F-001. Переключатель режима инбаунда (tun / socks)

- **Задача**: обычная подписка (список vless-ссылок) всегда порождает TUN-инбаунд
  в эффективном конфиге. Нужен тоггл, чтобы выбрать режим: системный TUN или
  локальный SOCKS-порт, и чтобы управлять тем, какие инбаунды берутся из
  пользовательского конфига.
- **Решение пользователя**: два независимых тумблера + отдельный тумблер
  «инбаунды из конфига»; SOCKS-порт фиксированный и настраиваемый; переключатель
  живёт на странице Connect; режим должен работать на всех платформах.
- **Хранение**: новая секция `policy.inbound` в `PlatformPolicy`
  (`tunEnabled`, `socksEnabled`, `socksPort`, `keepConfigInbounds`).
  Дефолты воспроизводят прежнее поведение: `tunEnabled=true`, `socksEnabled=false`,
  `socksPort=10808`, `keepConfigInbounds=true`.
- **Точка расширения**: `ConnectionCompiler._managedInbounds()` и
  `_managedInboundTags()` (вместо прежнего `_runtimeInbound`), плюс
  `RuntimeOptions` (`tunEnabled`, `socksEnabled`, `localSocksPort`,
  `keepConfigInbounds`) и `ConnectionCompiler.managedTunEnabled()`.
- **Семантика**:
  - `tunIn` — тег управляемого входа (TUN или SOCKS); маршруты и метрики не меняются.
  - TUN выкл + SOCKS вкл → SOCKS занимает `tunIn`.
  - TUN вкл + SOCKS вкл → SOCKS получает тег `app-socks` (дополнительный порт).
  - `keepConfigInbounds=false` → инбаунды из конфига (Raw/провайдер/шаблон) вырезаются.
  - Слой `tunIn` в конфиге всегда принадлежит App: без управляемого TUN он не используется.
  - Нет ни одного входа → `FormatException('The configuration has no inbound')`.
- **Нативная часть**: `StartVpnRequest.tunnelEnabled` (новое поле, `false` = не
  захватывать трафик). Dart `lib/core/pigeon/model.dart` + json_serializable,
  Kotlin `pigeon/Model.kt`, Swift `All/Model.swift`. Android
  (`OneVpnService`) не вызывает `builder.establish()` и не подставляет FD;
  Apple (`PacketTunnelProvider`) не добавляет маршрут по умолчанию и не требует FD.
  Статус локального прокси на Android держит маркер `run/vpn.local-proxy`.
- **Файлы**: `service/advanced/platform_policy.dart`, `service/connect/compiler.dart`,
  `service/connect/preparation.dart`, `service/shared/xray/runtime_inbounds.dart`,
  `pages/connect/{controller,page,view}.dart`, `pages/connect/inbound_mode.dart`,
  `core/pigeon/model.dart`, `android/.../vpn/{OneVpnService,VpnController}.kt`,
  `android/.../pigeon/Model.kt`, `swift/All/{Model,RuntimeEnv}.swift`,
  `swift/Tunnel/PacketTunnelProvider.swift`, l10n (5 ARB).
- **Тесты**: `test/service/connect/inbound_mode_test.dart` (14 кейсов),
  кейс подготовки в `test/service/connect/preparation_test.dart`,
  Swift-кейс в `test/native/RuntimeEnvTests.swift`.

### F-002. Локальная сборка и проверки

- Flutter 3.50.0 в `~/opt/flutter` (nixpkgs даёт только 3.41.9 — проекту нужен ≥ 3.50).
- **Native assets (`cnativeapi`) требуют GTK3/X11/Xi dev-заголовков и C++ stdlib.**
  Dart build hook чистит `PKG_CONFIG_PATH` (PATH наследует, а переменные — нет), поэтому:
  - `/tmp/opencode/bin/pkg-config` — обёртка, подставляющая `PKG_CONFIG_PATH` из `/tmp/opencode/pkgconfig.path`;
  - `/tmp/opencode/bin/clang` — обёртка над nix clang-wrapper + `-isystem` к gcc/wayland/xorgproto/libxext;
  - `/tmp/opencode/devshell.sh` — PATH + PKG_CONFIG_PATH (source перед flutter-командами).
  Сборка `pkgconfig.path` = `ls -d /nix/store/*/lib/pkgconfig /nix/store/*/share/pkgconfig`.
- `lib/core/ffi/generated_bindings.dart` — сгенерированный, в gitignore; без
  `dart run tool/ffigen.dart` анализ не проходит. Заглушку можно написать руками.

### F-003. Рецепт локальной сборки Linux и Android (проверено)

Рабочие пути: Flutter `~/opt/flutter`, Go 1.27.3 `~/opt/go` (libXray требует go ≥ 1.27.3;
nixpkgs даёт 1.26.8), Android SDK `~/opt/android-sdk`, gomobile `~/opt/gopath/bin`,
JDK 21 `~/nix/store/7q4av7wzjw098rcc83v1bb1blss1wccx-openjdk-21.0.12+2`.

1. **Ядро libXray** (клон `XTLS/libXray` рядом с OneXray):
   - Linux: `python3 ../libXray/build/main.py linux` → `linux_so/libXray.so`, `bin/xray`, `dat/*`.
   - Android: `gomobile init`, затем `python3 ../libXray/build/main.py android`
     (нужны `ANDROID_HOME`, `ANDROID_NDK_HOME`, JDK в PATH) → `libXray.aar`, `libXray-sources.jar`.
2. **Копирование** (см. `readme/FIRST_RUN.md`):
   `linux_so/libXray.so → linux/app/`, `bin/xray → linux/app/OneXrayCore` (+x),
   `dat/* → assets/dat/`, `libXray.aar` + `libXray-sources.jar → android/app/libs/`.
3. **Сборка**: `flutter build linux --release`, `flutter build apk --release`.
4. **Окружение nix** (`/tmp/opencode/build-env.nix`): gcc, python3, clang, cmake, ninja,
   pkg-config, gtk3/glib/pango/cairo/atk/gdk-pixbuf/harfbuzz/libepoxy/fontconfig/wayland/
   libX11/libXi/libxkbcommon/xz/libsecret/libayatana-appindicator.
   Обязательно: `PKG_CONFIG_PATH` = **все** `/nix/store/*/lib/pkgconfig` (иначе теряются
   pcre2/wayland), `NIX_LDFLAGS` и `LD_LIBRARY_PATH` = lib-каталоги пакетов
   (иначе линкер не находит `libepoxy.so.0`).
5. **RPATH готового bundle**: `patchelf --set-rpath '$ORIGIN/lib:<nix lib dirs>'` для
   `OneXray` и всех `bundle/lib/*.so` — иначе `ldd` показывает `libepoxy.so.0 => not found`.
6. **Android SDK**: cmdline-tools zip → `sdkmanager --install "platform-tools"
   "platforms;android-37.0" "build-tools;37.0.0" "ndk;30.0.16248370"` (лицензии через `yes |`).
   В `build.gradle.kts` стоит `compileSdk = 37`, а платформа называется `android-37.0`.
7. **Результаты**: `build/linux/x64/release/bundle/` (OneXray + OneXrayCore + lib/) и
   `build/app/outputs/flutter-apk/app-release.apk` (~149 МБ, arm64-v8a + x86_64).
   Gradle `assembleRelease` — ~22 мин.
8. **Не проверено локально**: Swift/Apple (нет Swift в nix) и Windows.

