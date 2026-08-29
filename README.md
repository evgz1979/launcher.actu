# Launcher

- **Версия документации:** 4.0.0
- **Статус:** актуальная
- **Обновлено:** 2026-08-29

Нативный лаунчер для строки меню macOS. Он обнаруживает настроенные проекты в
`~/Documents`, запускает их локальные сервисы и показывает ссылки на удалённые
проекты.

## Документация

- [Оглавление документации](docs/README.md)
- [Архитектура](docs/architecture.md)
- [Формат проектного `launcher.json`](docs/project-config.md)
- [Scanner CLI](docs/scanner-cli.md)
- [Удалённые проекты](docs/remote-config.md)
- [Версии документации](docs/VERSIONS.md)

## Обнаружение локальных проектов

При запуске Launcher просматривает только непосредственные дочерние каталоги
`~/Documents`. Проектом считается каталог, в корне которого есть
`launcher.json`:

```text
~/Documents/<project>/launcher.json
```

Рекурсивного поиска и эвристического распознавания во время запуска нет. Поэтому
архивы, служебные каталоги и исходники без `launcher.json` в меню не попадают.
Файлы из `configs/` больше не используются приложением во время запуска.

Относительные команды и рабочие каталоги разрешаются от корня соответствующего
проекта. Автоматически запускаются только сервисы с явным
`"autoStart": true`.

## Scanner CLI

```bash
./scripts/launcher-config scan
./scripts/launcher-config check
./scripts/launcher-config show
```

- `scan` помогает создать или уточнить проектные `launcher.json`;
- `check` проверяет все настроенные проекты каталога без записи;
- `show` выводит эффективные проекты с разрешёнными абсолютными путями.

После фактического изменения проектных файлов запущенный Launcher
перезапускается и заново сканирует каталог.

## Запуск при разработке

```bash
swift run
```

## Проверка

```bash
swift test
python3 -m unittest discover -s tests -v
./scripts/launcher-config check
```

## Сборка приложения

```bash
./scripts/build-app.sh
open build/Launcher.app
```

## Автозапуск при входе в macOS

После сборки установите LaunchAgent:

```bash
mkdir -p "$HOME/Library/LaunchAgents"
cp local.launcher.menubar.plist "$HOME/Library/LaunchAgents/"
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.launcher.menubar.plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.launcher.menubar.plist"
launchctl kickstart -k "gui/$(id -u)/local.launcher.menubar"
```

Чтобы удалить Launcher из автозапуска:

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.launcher.menubar.plist"
rm "$HOME/Library/LaunchAgents/local.launcher.menubar.plist"
```
