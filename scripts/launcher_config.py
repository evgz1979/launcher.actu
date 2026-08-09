#!/usr/bin/env python3
"""Discover Python projects and build a machine-specific Launcher config."""

from __future__ import annotations

import argparse
import ast
import difflib
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlparse


Input = Callable[[str], str]
SCHEMA_VERSION = 1
IGNORED_DIRECTORIES = {".git", ".venv", "node_modules", "build", "dist"}


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class Project:
    root: Path
    config_path: Path


def machine_name() -> str:
    try:
        result = subprocess.run(
            ["/usr/sbin/scutil", "--get", "LocalHostName"],
            check=True,
            capture_output=True,
            text=True,
        )
        name = result.stdout.strip()
        if name:
            return name
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass
    return socket.gethostname().removesuffix(".local")


def slug(value: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return normalized or "machine"


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ConfigError(f"Файл не найден: {path}") from error
    except json.JSONDecodeError as error:
        raise ConfigError(f"Некорректный JSON {path}:{error.lineno}:{error.colno}: {error.msg}") from error
    if not isinstance(value, dict):
        raise ConfigError(f"Корень JSON должен быть объектом: {path}")
    return value


def formatted_json(value: dict[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def is_python_project(path: Path) -> bool:
    if not path.is_dir() or path.name in IGNORED_DIRECTORIES:
        return False
    if not (path / "README.md").is_file():
        return False
    if (path / "launcher.json").is_file():
        return True
    if (path / "pyproject.toml").is_file() or (path / "requirements.txt").is_file():
        return True
    return any(item.is_file() and item.suffix == ".py" for item in path.iterdir())


def discover_projects(documents: Path) -> list[Project]:
    if not documents.is_dir():
        raise ConfigError(f"Каталог проектов не найден: {documents}")
    return [
        Project(path, path / "launcher.json")
        for path in sorted(documents.iterdir(), key=lambda item: item.name.casefold())
        if is_python_project(path)
    ]


def require_string(value: Any, field: str, source: Path) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{source}: поле {field} должно быть непустой строкой")
    return value.strip()


def validate_project_config(value: dict[str, Any], source: Path) -> dict[str, Any]:
    if value.get("version") != SCHEMA_VERSION:
        raise ConfigError(f"{source}: version должен быть равен {SCHEMA_VERSION}")
    project_id = require_string(value.get("id"), "id", source)
    name = require_string(value.get("name"), "name", source)
    enabled = value.get("enabled", True)
    if not isinstance(enabled, bool):
        raise ConfigError(f"{source}: enabled должен быть true или false")
    services = value.get("services")
    if not isinstance(services, list):
        raise ConfigError(f"{source}: services должен быть массивом")

    normalized_services: list[dict[str, Any]] = []
    service_ids: set[str] = set()
    for index, service in enumerate(services):
        field = f"services[{index}]"
        if not isinstance(service, dict):
            raise ConfigError(f"{source}: {field} должен быть объектом")
        service_id = require_string(service.get("id"), f"{field}.id", source)
        if service_id in service_ids:
            raise ConfigError(f"{source}: повторяющийся id сервиса: {service_id}")
        service_ids.add(service_id)
        service_name = require_string(service.get("name"), f"{field}.name", source)
        command = service.get("command")
        if not isinstance(command, list) or not command or not all(
            isinstance(argument, str) and argument for argument in command
        ):
            raise ConfigError(f"{source}: {field}.command должен быть непустым массивом строк")

        normalized: dict[str, Any] = {
            "id": service_id,
            "name": service_name,
            "command": command,
            "autoStart": service.get("autoStart", False),
        }
        if not isinstance(normalized["autoStart"], bool):
            raise ConfigError(f"{source}: {field}.autoStart должен быть true или false")

        if "workingDirectory" in service:
            normalized["workingDirectory"] = require_string(
                service["workingDirectory"], f"{field}.workingDirectory", source
            )
        if "port" in service:
            port = service["port"]
            if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
                raise ConfigError(f"{source}: {field}.port должен быть числом от 1 до 65535")
            normalized["port"] = port
        if "url" in service:
            url = require_string(service["url"], f"{field}.url", source)
            if not re.match(r"^https?://", url, re.IGNORECASE):
                raise ConfigError(f"{source}: {field}.url должен начинаться с http:// или https://")
            normalized["url"] = url
        normalized_services.append(normalized)

    return {
        "version": SCHEMA_VERSION,
        "id": project_id,
        "name": name,
        "enabled": enabled,
        "services": normalized_services,
    }


def resolve_project(config: dict[str, Any], root: Path) -> dict[str, Any]:
    services: list[dict[str, Any]] = []
    for service in config["services"]:
        command = list(service["command"])
        executable = Path(command[0]).expanduser()
        if not executable.is_absolute() and "/" in command[0]:
            command[0] = str((root / executable).resolve())

        working = Path(service.get("workingDirectory", str(root))).expanduser()
        if not working.is_absolute():
            working = root / working
        generated = {**service, "command": command, "workingDirectory": str(working.resolve())}
        services.append(generated)

    return {
        "id": config["id"],
        "name": config["name"],
        "sourcePath": str(root.resolve()),
        "services": services,
    }


def validate_project_paths(config: dict[str, Any], root: Path, source: Path) -> None:
    for index, service in enumerate(config["services"]):
        working = Path(service.get("workingDirectory", str(root))).expanduser()
        if not working.is_absolute():
            working = root / working
        if not working.is_dir():
            raise ConfigError(f"{source}: services[{index}].workingDirectory не существует: {working}")

        executable_text = service["command"][0]
        executable = Path(executable_text).expanduser()
        if executable.is_absolute() or "/" in executable_text:
            if not executable.is_absolute():
                executable = root / executable
            if not executable.is_file():
                raise ConfigError(f"{source}: исполняемый файл не найден: {executable}")
        elif shutil.which(executable_text) is None:
            raise ConfigError(f"{source}: команда не найдена в PATH: {executable_text}")


def load_machine_config(configs_dir: Path, host: str) -> tuple[Path | None, dict[str, Any] | None]:
    matches: list[tuple[Path, dict[str, Any]]] = []
    if configs_dir.is_dir():
        for path in sorted(configs_dir.glob("*.json")):
            value = read_json(path)
            machines = value.get("machines", [])
            if isinstance(machines, list) and any(
                isinstance(item, str) and item.casefold() == host.casefold() for item in machines
            ):
                matches.append((path, value))
    if len(matches) > 1:
        names = ", ".join(str(path) for path, _ in matches)
        raise ConfigError(f"Машина {host} найдена в нескольких конфигурациях: {names}")
    return matches[0] if matches else (None, None)


def new_machine_config(host: str) -> dict[str, Any]:
    return {
        "id": slug(host),
        "name": host.replace("-", " "),
        "machines": [host],
        "projects": [],
    }


def ask(prompt: str, input_fn: Input) -> str:
    return input_fn(prompt).strip()


def ask_yes_no(prompt: str, input_fn: Input, default: bool = False) -> bool:
    suffix = " [Y/n] " if default else " [y/N] "
    answer = ask(prompt + suffix, input_fn).casefold()
    if not answer:
        return default
    return answer in {"y", "yes", "д", "да"}


def suggested_entry(root: Path) -> str:
    for name in ("main.py", "app.py"):
        if (root / name).is_file():
            return name
    python_files = sorted(root.glob("*.py"))
    return python_files[0].name if python_files else "main.py"


def suggested_python(root: Path) -> str:
    return ".venv/bin/python" if (root / ".venv/bin/python").is_file() else "python3"


def entry_candidates(root: Path) -> list[str]:
    python_files = sorted(item.name for item in root.glob("*.py") if item.is_file())
    preferred = [name for name in ("main.py", "app.py") if name in python_files]
    return preferred + [name for name in python_files if name not in preferred]


def literal_value(node: ast.AST, constants: dict[str, Any]) -> Any:
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Name):
        return constants.get(node.id)
    return None


def detect_network(root: Path, entry: str) -> tuple[int | None, str | None]:
    constants: dict[str, Any] = {}
    detected_port: int | None = None
    detected_host: str | None = None
    source = root / entry
    if source.is_file():
        try:
            tree = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
            for node in ast.walk(tree):
                if isinstance(node, (ast.Assign, ast.AnnAssign)):
                    targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                    value_node = node.value
                    if value_node is None:
                        continue
                    value = literal_value(value_node, constants)
                    for target in targets:
                        if isinstance(target, ast.Name) and value is not None:
                            constants[target.id] = value
                if isinstance(node, ast.Call):
                    function_name = ""
                    if isinstance(node.func, ast.Name):
                        function_name = node.func.id
                    elif isinstance(node.func, ast.Attribute):
                        function_name = node.func.attr
                    if function_name in {"ThreadingHTTPServer", "HTTPServer", "TCPServer"}:
                        if node.args and isinstance(node.args[0], ast.Tuple) and len(node.args[0].elts) >= 2:
                            detected_host = literal_value(node.args[0].elts[0], constants) or detected_host
                            port = literal_value(node.args[0].elts[1], constants)
                            if isinstance(port, int):
                                detected_port = port
                    if function_name in {"run", "serve"}:
                        for keyword in node.keywords:
                            if keyword.arg == "host":
                                detected_host = literal_value(keyword.value, constants) or detected_host
                            elif keyword.arg == "port":
                                port = literal_value(keyword.value, constants)
                                if isinstance(port, int):
                                    detected_port = port
        except (OSError, SyntaxError, UnicodeDecodeError):
            pass

    port_constant = constants.get("PORT")
    host_constant = constants.get("HOST")
    if detected_port is None and isinstance(port_constant, int):
        detected_port = port_constant
    if detected_host is None and isinstance(host_constant, str):
        detected_host = host_constant

    readme_urls: list[str] = []
    readme = root / "README.md"
    if readme.is_file():
        text = readme.read_text(encoding="utf-8")
        readme_urls = re.findall(r"https?://(?:127\.0\.0\.1|localhost|0\.0\.0\.0):\d+", text)
    for url in readme_urls:
        parsed = urlparse(url)
        if detected_port is None or parsed.port == detected_port:
            return parsed.port, url.replace("0.0.0.0", "127.0.0.1")

    if detected_port is not None:
        browser_host = detected_host if detected_host not in {None, "0.0.0.0"} else "127.0.0.1"
        return detected_port, f"http://{browser_host}:{detected_port}"
    return None, None


def enrich_project_config(config: dict[str, Any], root: Path) -> dict[str, Any]:
    enriched = {**config, "services": []}
    for service in config["services"]:
        updated = dict(service)
        entry = next((argument for argument in service["command"][1:] if argument.endswith(".py")), None)
        if entry:
            port, url = detect_network(root, entry)
            if port is not None:
                updated["port"] = port
            if url is not None:
                updated["url"] = url
        enriched["services"].append(updated)
    return enriched


def create_project_config(project: Project, input_fn: Input) -> dict[str, Any]:
    project_id = slug(project.root.name)
    project_name = project.root.name
    entries = entry_candidates(project.root) or [suggested_entry(project.root)]
    services: list[dict[str, Any]] = []
    for index, entry in enumerate(entries):
        service_id = project_id if index == 0 else f"{project_id}-{slug(Path(entry).stem)}"
        service_name = project_name if index == 0 else Path(entry).stem
        python = suggested_python(project.root)
        print(f"Сервис определён автоматически: {service_name} ({python} {entry})")
        detected_port, detected_url = detect_network(project.root, entry)
        port_text = ""
        url = ""
        if detected_port is not None:
            print(f"Порт определён автоматически: {detected_port}")
        else:
            port_text = ask("Порт (Enter — без порта): ", input_fn)
        if detected_url is not None:
            print(f"URL определён автоматически: {detected_url}")
        else:
            url = ask("URL (Enter — без URL): ", input_fn)
        service: dict[str, Any] = {
            "id": service_id,
            "name": service_name,
            "command": [python, entry],
            "autoStart": ask_yes_no("Запускать автоматически?", input_fn),
        }
        if detected_port is not None:
            service["port"] = detected_port
        elif port_text:
            try:
                service["port"] = int(port_text)
            except ValueError as error:
                raise ConfigError("Порт должен быть числом") from error
        if detected_url or url:
            service["url"] = detected_url or url
        services.append(service)
        if index == len(entries) - 1 or not ask_yes_no(
            f"Добавить найденный сервис {entries[index + 1]}?", input_fn
        ):
            break

    value = {
        "version": SCHEMA_VERSION,
        "id": project_id,
        "name": project_name,
        "enabled": True,
        "services": services,
    }
    return validate_project_config(value, project.config_path)


def preview_file(path: Path, value: dict[str, Any]) -> None:
    old = path.read_text(encoding="utf-8").splitlines(keepends=True) if path.exists() else []
    new = formatted_json(value).splitlines(keepends=True)
    diff = difflib.unified_diff(old, new, fromfile=str(path), tofile=str(path))
    print("".join(diff) or f"Без изменений: {path}")


def restart_launcher(repo: Path) -> bool:
    app = repo / "build/Launcher.app"
    executable = app / "Contents/MacOS/Launcher"
    if not executable.is_file():
        return False

    result = subprocess.run(
        ["/usr/bin/pgrep", "-f", f"^{re.escape(str(executable))}$"],
        capture_output=True,
        text=True,
    )
    pids = [int(value) for value in result.stdout.split() if value.isdigit()]
    if not pids:
        return False

    subprocess.run(
        [
            "/usr/bin/osascript",
            "-e",
            'tell application id "local.launcher.menubar" to quit',
        ],
        capture_output=True,
        text=True,
    )
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if all(not process_exists(pid) for pid in pids):
            break
        time.sleep(0.1)
    for pid in pids:
        if process_exists(pid):
            os.kill(pid, signal.SIGTERM)

    launch = subprocess.run(
        ["/bin/launchctl", "kickstart", "-k", f"gui/{os.getuid()}/local.launcher.menubar"],
        capture_output=True,
        text=True,
    )
    if launch.returncode != 0:
        subprocess.run(["/usr/bin/open", str(app)], check=True)
    print("Launcher перезапущен и применил новую конфигурацию.")
    return True


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def scan(documents: Path, repo: Path, input_fn: Input = input) -> int:
    host = machine_name()
    configs_dir = repo / "configs"
    machine_path, machine = load_machine_config(configs_dir, host)
    if machine is None:
        machine = new_machine_config(host)
        machine_path = configs_dir / f"{machine['id']}.json"
        print(f"Для машины {host} будет создана конфигурация {machine_path}.")

    existing = {
        project.get("id"): project
        for project in machine.get("projects", [])
        if isinstance(project, dict) and isinstance(project.get("id"), str)
    }
    pending_project_files: dict[Path, dict[str, Any]] = {}
    seen_ids: set[str] = set()

    def remove_existing_source(source: str, except_id: str | None = None) -> None:
        for existing_id, existing_project in list(existing.items()):
            if existing_id != except_id and existing_project.get("sourcePath") == source:
                del existing[existing_id]

    for project in discover_projects(documents):
        root_key = str(project.root.resolve())
        if project.config_path.exists():
            try:
                config = validate_project_config(read_json(project.config_path), project.config_path)
                enriched = enrich_project_config(config, project.root)
                if enriched != config:
                    print(f"\nАвтоматически уточнена конфигурация: {project.config_path}")
                    preview_file(project.config_path, enriched)
                    pending_project_files[project.config_path] = enriched
                    config = enriched
                validate_project_paths(config, project.root, project.config_path)
            except ConfigError as error:
                print(f"\nОшибка проекта {project.root}: {error}", file=sys.stderr)
                continue
        else:
            print(f"\nНайден Python-проект: {project.root}")
            if ask_yes_no("Создать launcher.json для этого проекта?", input_fn):
                config = create_project_config(project, input_fn)
                validate_project_paths(config, project.root, project.config_path)
                print("\nБудет создан проектный файл:")
                preview_file(project.config_path, config)
                pending_project_files[project.config_path] = config
            else:
                choice = ask(
                    "1 — пропустить сейчас, 2 — создать отключённый launcher.json [1]: ",
                    input_fn,
                ) or "1"
                if choice == "2":
                    disabled = {
                        "version": SCHEMA_VERSION,
                        "id": slug(project.root.name),
                        "name": project.root.name,
                        "enabled": False,
                        "services": [],
                    }
                    pending_project_files[project.config_path] = disabled
                continue

        if config["enabled"]:
            generated = resolve_project(config, project.root)
            remove_existing_source(root_key, except_id=generated["id"])
            existing[generated["id"]] = generated
            seen_ids.add(generated["id"])
        else:
            remove_existing_source(root_key)

    for project_id, project in list(existing.items()):
        source = project.get("sourcePath")
        if project_id in seen_ids or not isinstance(source, str) or Path(source).exists():
            continue
        print(f"\nПроект отсутствует на диске: {source}")
        if ask_yes_no("Удалить его из машинной конфигурации?", input_fn):
            del existing[project_id]

    updated_machine = {
        **machine,
        "machines": machine.get("machines", [host]),
        "projects": sorted(existing.values(), key=lambda item: str(item.get("name", "")).casefold()),
    }

    print("\nИтоговая машинная конфигурация:")
    preview_file(machine_path, updated_machine)
    if pending_project_files:
        print(f"Проектных файлов к записи: {len(pending_project_files)}")
    machine_text = formatted_json(updated_machine)
    machine_changed = not machine_path.exists() or machine_path.read_text(encoding="utf-8") != machine_text
    if not machine_changed and not pending_project_files:
        print("Изменений нет. Launcher не перезапускается.")
        return 0
    if not ask_yes_no("Записать показанные изменения?", input_fn):
        print("Изменения отменены.")
        return 0

    for path, value in pending_project_files.items():
        path.write_text(formatted_json(value), encoding="utf-8")
    configs_dir.mkdir(parents=True, exist_ok=True)
    machine_path.write_text(machine_text, encoding="utf-8")
    print(f"Конфигурация обновлена: {machine_path}")
    restart_launcher(repo)
    return 0


def check(documents: Path, repo: Path) -> int:
    host = machine_name()
    configs_dir = repo / "configs"
    machine_path, machine = load_machine_config(configs_dir, host)
    problems: list[str] = []
    if machine is None:
        problems.append(f"Нет конфигурации для машины {host}")
        generated_projects: dict[str, Any] = {}
    else:
        generated_projects = {
            item.get("id"): item for item in machine.get("projects", []) if isinstance(item, dict)
        }

    for project in discover_projects(documents):
        if not project.config_path.exists():
            problems.append(f"Нет launcher.json: {project.root}")
            continue
        try:
            config = validate_project_config(read_json(project.config_path), project.config_path)
            validate_project_paths(config, project.root, project.config_path)
            if config["enabled"]:
                generated = resolve_project(config, project.root)
                if generated_projects.get(generated["id"]) != generated:
                    problems.append(f"Машинная запись устарела: {project.root}")
        except ConfigError as error:
            problems.append(str(error))

    if problems:
        print("Обнаружены проблемы:")
        for problem in problems:
            print(f"- {problem}")
        return 1
    print(f"Проверка пройдена: {machine_path}")
    return 0


def show(repo: Path) -> int:
    host = machine_name()
    path, config = load_machine_config(repo / "configs", host)
    if config is None:
        print(f"Для машины {host} конфигурация не найдена.")
        return 1
    print(f"Машина: {host}")
    print(f"Файл: {path}")
    print(formatted_json(config), end="")
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Сканер конфигураций Launcher")
    result.add_argument(
        "--documents", type=Path, default=Path.home() / "Documents", help="каталог с проектами"
    )
    result.add_argument(
        "--repo", type=Path, default=Path(__file__).resolve().parent.parent, help="репозиторий Launcher"
    )
    result.add_argument("command", choices=("scan", "check", "show"))
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "scan":
            return scan(args.documents.expanduser().resolve(), args.repo.expanduser().resolve())
        if args.command == "check":
            return check(args.documents.expanduser().resolve(), args.repo.expanduser().resolve())
        return show(args.repo.expanduser().resolve())
    except (ConfigError, OSError) as error:
        print(f"Ошибка: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
