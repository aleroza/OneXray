# OneXray App

Cross-platform Flutter Xray-core client. [Current contracts](docs/README.md)
describe shipped behavior; Git history holds retired plans and progress logs.

> This checkout is our fork of <https://github.com/YuanDevTeam/OneXray>.
> Read [fork knowledge base](docs/fork/KNOWLEDGE_BASE.md) before changing
> connection, configuration or tunnel code; it maps the internals.

## Fork rules

- This fork is updated by rebasing our own commits on top of upstream. Keep the
  diff minimal: no refactoring, renaming, reformatting, decoration, dependency
  bumps or unrelated cleanups. Every extra edit is a future merge conflict.
- Extend existing extension points instead of rewriting the surrounding code.
- Default values of new settings must reproduce current upstream behavior
  exactly, so an update never changes a user's mode on its own.
- Never edit generated output (Drift, Pigeon, FFI, localization) by hand; edit
  the source and regenerate.
- One logical change per commit. Track fork decisions in
  [docs/fork/KNOWLEDGE_BASE.md](docs/fork/KNOWLEDGE_BASE.md).

## Engineering rules

- Dependencies flow `pages → service → core`. Services own business logic;
  custom page controllers extend `PageCubit` and expose Bloc state.
  Text, scroll, focus and third-party controllers remain UI resources.
- Prefer shared `lib/pages/theme/` changes: `AppTheme.appBarTheme`,
  `ThemeData.textTheme` / `AppTypography`, and `LucideIcons`. Keep typography
  out of individual pages. UI-only changes preserve behavior and data contracts.
- Verify dependency maintenance and SDK/platform compatibility before adoption:
  archive status, dated releases, substantive commits and maintainer responses.
- Use upstream dependencies without vendoring or modifying third-party source,
  including SDKs and package caches. Update dependencies or adapt OneXray's
  integration. Retain supported compatibility settings when upstream blocks
  a migration.
- Keep `LIBXRAY_REF` in `.github/workflows/build.yml` set to `main` unless the
  user explicitly requests a different ref.
- Edit source models, ARB, Pigeon and FFI definitions, then regenerate outputs.
  Generated Dart, Kotlin, Swift, Drift, FFI and localization files are not sources.

## Commit messages

- Write one English line of at most 72 characters: `<type>(<scope>): <summary>`.
  Scope is optional; the complete message stays on one line.
- Use `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci` or `chore`.
- Name the concrete change with an imperative verb, for example
  `fix(vpn): retry failed connections`.
- Keep each commit focused on one logical change.

## Read for the task

- Startup, permissions, navigation, UI or desktop windows: [App behavior](docs/app.md).
- Configuration, validation, connection lifecycle, native VPN or traffic:
  [Xray configuration](docs/xray-configuration.md).
- Database, Geodata, queues, updates or cleanup: [data management](docs/data-management.md).
- Import, subscriptions, age or sharing: [servers and sharing](docs/subscriptions-and-sharing.md).
- Backup protocol, restore or cloud storage: [backup](docs/backup.md).
- Local HTTP API, Android broadcasts or command authorization:
  [external interfaces](docs/external-interfaces.md).
- Packaging, signing or CI releases: [build scripts](build_scripts/README.md).
  Apple/Android release commands may upload to stores; they are not local checks.
- Visual parity: use the relevant [prototype source](../references/onexray-app-prototype/src/)
  and approved translations. Current App contracts take precedence over the prototype.
- Native bridge changes: inspect `pigeon/message.dart`, `lib/core/pigeon/`,
  Swift/Kotlin consumers and the [libXray API](../libXray/README.md#api).

## Skill configuration

- Issue, PR or review work: [issue tracker](docs/agents/issue-tracker.md).
- Triage: [canonical labels](docs/agents/triage-labels.md).
- Codebase exploration or domain/ADR work: [domain guidance](docs/agents/domain.md).

## Verification

All Flutter/Dart commands run serially across terminals and agents because
`.dart_tool` and native build state are shared. Use [verification](docs/validation.md)
for scenario selection, checks and platform-specific acceptance.

- Android emulator validation may start VPN. On macOS, do not start VPN or take
  screenshots; Windows/Linux builds and runs require their own hosts.
- Keep demos, fixtures and evidence in workspace `references/`, with isolated
  data and minimal setup; never validate against the developer's main database.
- Match checks to the change and run `git diff --check`. Documentation-only work
  needs path/link checks, not App tests. Report static, automated, device and
  release results separately. Commit, push and PR actions require user authority.
