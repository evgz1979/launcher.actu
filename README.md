# Launcher

- **Версия документации:** 3.1.0
- **Статус:** актуальная
- **Обновлено:** 2026-08-09

Нативный лаунчер для строки меню macOS, запускающий локальные скрипты и сервисы.

## Документация

- [Оглавление документации](docs/README.md)
- [Архитектура](docs/architecture.md)
- [Формат проектного `launcher.json`](docs/project-config.md)
- [Спецификация Scanner CLI](docs/scanner-cli.md)
- [Удалённые проекты](docs/remote-config.md)
- [Версии документации](docs/VERSIONS.md)

Scanner CLI и проектные `launcher.json` реализованы согласно документации.

## Текущая конфигурация

Машинные JSON-файлы находятся в `configs/`. Launcher читает их непосредственно
из репозитория и выбирает файл, в массиве `machines` которого содержится текущий
macOS `LocalHostName`.

- `port` и `url` необязательны.
- `autoStart` необязателен и в текущем формате машинной конфигурации по умолчанию
  равен `true`; значение `false` оставляет сервис только для ручного запуска.
- Если указан `port`, Launcher освобождает его перед запуском сервиса.
- Действие `Start` запускает сервис и открывает его `url`; отдельного пункта
  открытия браузера нет.
- Если подходящая конфигурация не найдена, сервисы не запускаются, а в меню
  отображается соответствующий статус.

Удалённые проекты описываются вручную в `remote/remotes.json`. Launcher не
управляет другой машиной: нажатие на проект открывает её сетевой URL.

## Запуск при разработке

```bash
swift run
```

## Scanner CLI

```bash
./scripts/launcher-config scan
./scripts/launcher-config check
./scripts/launcher-config show
```

`scan` интерактивно сканирует проекты в `~/Documents`, предлагает создать
отсутствующие проектные `launcher.json` и обновляет конфигурацию текущей машины.
Порт и URL определяются автоматически из README и статического анализа Python.
После фактического изменения конфигурации запущенный Launcher автоматически
перезапускается.
Сам Scanner CLI добавлен в проектный `launcher.json` этого репозитория и доступен
в меню Launcher только для ручного запуска.

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
