# Launcher

Native macOS menu bar launcher for local project scripts and services.

## Configure

`launcher.json` groups launch entries by project:

- `actu (data+view)` contains the current local Actu services in `/Users/evgz/Documents/actu`.
- `actu (manager)` runs the manager command from iCloud Drive.
- `actu (trade+lang)`, `thai`, `e-mail`, `recoder`, and `media-lib` are ready for future scripts.
- `port` and `url` are optional, so simple scripts can be added with only `id`, `name`, `command`, and `workingDirectory`.
- `autoStart` is optional and defaults to `true`; set it to `false` for menu-only scripts.
- When `port` is present, the launcher clears it before starting the entry.

## Run during development

```bash
LAUNCHER_CONFIG="$PWD/launcher.json" swift run
```

## Build an app bundle

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open build/Launcher.app
```

The built app copies `launcher.json` into `Launcher.app/Contents/Resources`.
Rebuild after changing the bundled config.
