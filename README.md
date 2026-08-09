# Launcher

Нативный лаунчер для строки меню macOS, запускающий локальные скрипты и сервисы.

## Документация

- [Оглавление документации](docs/README.md)
- [Архитектура](docs/architecture.md)
- [Формат проектного `launcher.json`](docs/project-config.md)
- [Спецификация Scanner CLI](docs/scanner-cli.md)

Описанные в документации Scanner CLI и проектные `launcher.json` согласованы,
но пока не реализованы.

## Текущая конфигурация

Машинные JSON-файлы находятся в `configs/`. Launcher читает их непосредственно
из репозитория и выбирает файл, в массиве `machines` которого содержится текущий
macOS `LocalHostName`.

- `port` и `url` необязательны.
- `autoStart` необязателен и в текущем формате машинной конфигурации по умолчанию
  равен `true`; значение `false` оставляет сервис только для ручного запуска.
- Если указан `port`, Launcher освобождает его перед запуском сервиса.
- Если подходящая конфигурация не найдена, сервисы не запускаются, а в меню
  отображается соответствующий статус.

## Запуск при разработке

```bash
swift run
```

## Сборка приложения

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open build/Launcher.app
```

Приложение читает `configs/` из репозитория во время запуска, поэтому после
изменения JSON пересборка не требуется.

## Автозапуск при входе в macOS

Сначала соберите приложение, затем установите LaunchAgent:

```bash
mkdir -p "$HOME/Library/LaunchAgents"
cp local.launcher.menubar.plist "$HOME/Library/LaunchAgents/"
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.launcher.menubar.plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.launcher.menubar.plist"
```

Чтобы запустить его сразу без повторного входа в систему:

```bash
launchctl kickstart -k "gui/$(id -u)/local.launcher.menubar"
```

Чтобы удалить Launcher из автозапуска:

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.launcher.menubar.plist"
rm "$HOME/Library/LaunchAgents/local.launcher.menubar.plist"
```
