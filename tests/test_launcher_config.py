from __future__ import annotations

import json
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from scripts import launcher_config


class LauncherConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.documents = self.root / "Documents"
        self.repo = self.root / "launcher.actu"
        self.documents.mkdir()
        (self.repo / "configs").mkdir(parents=True)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def project(self, name: str, python_file: bool = True) -> Path:
        root = self.documents / name
        root.mkdir()
        (root / "README.md").write_text(f"# {name}\n", encoding="utf-8")
        if python_file:
            (root / "main.py").write_text("print('ok')\n", encoding="utf-8")
            python = root / ".venv/bin/python"
            python.parent.mkdir(parents=True)
            python.write_text("#!/bin/sh\n", encoding="utf-8")
        return root

    def test_discovers_python_and_explicitly_configured_projects(self) -> None:
        python_project = self.project("python")
        configured_project = self.project("configured", python_file=False)
        (configured_project / "launcher.json").write_text("{}\n", encoding="utf-8")
        self.project("not-python", python_file=False)

        discovered = launcher_config.discover_projects(self.documents)

        self.assertEqual([item.root for item in discovered], [configured_project, python_project])

    def test_validation_adds_safe_autostart_default(self) -> None:
        source = self.root / "launcher.json"
        value = {
            "version": 1,
            "id": "demo",
            "name": "Demo",
            "services": [{"id": "web", "name": "Web", "command": ["python3", "main.py"]}],
        }

        validated = launcher_config.validate_project_config(value, source)

        self.assertFalse(validated["services"][0]["autoStart"])

    def test_validation_rejects_duplicate_service_ids(self) -> None:
        source = self.root / "launcher.json"
        service = {"id": "web", "name": "Web", "command": ["python3", "main.py"]}
        value = {
            "version": 1,
            "id": "demo",
            "name": "Demo",
            "services": [service, service],
        }

        with self.assertRaisesRegex(launcher_config.ConfigError, "повторяющийся id"):
            launcher_config.validate_project_config(value, source)

    def test_detects_port_and_url_from_python_and_readme(self) -> None:
        project = self.project("web")
        (project / "main.py").write_text(
            'from http.server import ThreadingHTTPServer\nHOST = "127.0.0.1"\nPORT = 8000\n'
            "ThreadingHTTPServer((HOST, PORT), object)\n",
            encoding="utf-8",
        )
        (project / "README.md").write_text(
            "Открой http://127.0.0.1:8000 после запуска.\n", encoding="utf-8"
        )

        port, url = launcher_config.detect_network(project, "main.py")

        self.assertEqual(port, 8000)
        self.assertEqual(url, "http://127.0.0.1:8000")

    def test_enrichment_corrects_previously_entered_port(self) -> None:
        project = self.project("web")
        (project / "main.py").write_text("PORT = 8000\n", encoding="utf-8")
        config = {
            "version": 1,
            "id": "web",
            "name": "web",
            "enabled": True,
            "services": [
                {
                    "id": "web",
                    "name": "web",
                    "command": ["python3", "main.py"],
                    "port": 8080,
                    "autoStart": False,
                }
            ],
        }

        enriched = launcher_config.enrich_project_config(config, project)

        self.assertEqual(enriched["services"][0]["port"], 8000)
        self.assertEqual(enriched["services"][0]["url"], "http://127.0.0.1:8000")

    def test_resolves_project_paths_for_machine_config(self) -> None:
        root = self.project("demo")
        config = {
            "id": "demo",
            "name": "Demo",
            "services": [
                {
                    "id": "web",
                    "name": "Web",
                    "command": [".venv/bin/python", "main.py"],
                    "autoStart": False,
                }
            ],
        }

        generated = launcher_config.resolve_project(config, root)

        self.assertEqual(generated["sourcePath"], str(root.resolve()))
        self.assertEqual(
            generated["services"][0]["command"][0], str((root / ".venv/bin/python").resolve())
        )
        self.assertEqual(generated["services"][0]["workingDirectory"], str(root.resolve()))

    def test_preserves_virtualenv_symlink_path(self) -> None:
        root = self.project("symlinked")
        python = root / ".venv/bin/python"
        python.unlink()
        target = self.root / "shared-python"
        target.write_text("#!/bin/sh\n", encoding="utf-8")
        python.symlink_to(target)
        config = {
            "id": "symlinked",
            "name": "symlinked",
            "services": [
                {
                    "id": "symlinked",
                    "name": "symlinked",
                    "command": [".venv/bin/python", "main.py"],
                    "autoStart": False,
                }
            ],
        }

        generated = launcher_config.resolve_project(config, root)

        self.assertEqual(generated["services"][0]["command"][0], str(root.resolve() / ".venv/bin/python"))
        self.assertNotEqual(generated["services"][0]["command"][0], str(target.resolve()))

    def test_scan_creates_project_and_machine_configs_after_confirmation(self) -> None:
        project = self.project("demo")
        answers = iter(["y", "", "", "n", "y"])

        with patch.object(launcher_config, "machine_name", return_value="Test-Mac"), patch.object(
            launcher_config, "restart_launcher", return_value=True
        ) as restart:
            with redirect_stdout(io.StringIO()):
                result = launcher_config.scan(
                    self.documents,
                    self.repo,
                    input_fn=lambda _prompt: next(answers),
                )

        self.assertEqual(result, 0)
        restart.assert_called_once_with(self.repo)
        project_config = json.loads((project / "launcher.json").read_text(encoding="utf-8"))
        machine_config = json.loads(
            (self.repo / "configs/test-mac.json").read_text(encoding="utf-8")
        )
        self.assertFalse(project_config["services"][0]["autoStart"])
        self.assertEqual(project_config["id"], "demo")
        self.assertEqual(project_config["name"], "demo")
        self.assertEqual(machine_config["machines"], ["Test-Mac"])
        self.assertEqual(machine_config["projects"][0]["id"], "demo")

    def test_scan_can_skip_project_without_persisting_the_decision(self) -> None:
        project = self.project("skipped")
        answers = iter(["n", "1", "y"])

        with patch.object(launcher_config, "machine_name", return_value="Test-Mac"):
            with redirect_stdout(io.StringIO()):
                launcher_config.scan(
                    self.documents,
                    self.repo,
                    input_fn=lambda _prompt: next(answers),
                )

        machine_config = json.loads(
            (self.repo / "configs/test-mac.json").read_text(encoding="utf-8")
        )
        self.assertNotIn("ignoredProjects", machine_config)
        self.assertEqual(machine_config["projects"], [])
        self.assertFalse((project / "launcher.json").exists())

    def test_disabled_project_removes_generated_machine_entry(self) -> None:
        project = self.project("disabled")
        (project / "launcher.json").write_text(
            launcher_config.formatted_json(
                {
                    "version": 1,
                    "id": "disabled",
                    "name": "Disabled",
                    "enabled": False,
                    "services": [],
                }
            ),
            encoding="utf-8",
        )
        machine_path = self.repo / "configs/test-mac.json"
        machine_path.write_text(
            launcher_config.formatted_json(
                {
                    "id": "test-mac",
                    "name": "Test Mac",
                    "machines": ["Test-Mac"],
                    "projects": [
                        {
                            "id": "disabled",
                            "name": "Disabled",
                            "sourcePath": str(project.resolve()),
                            "services": [],
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

        with patch.object(launcher_config, "machine_name", return_value="Test-Mac"):
            with redirect_stdout(io.StringIO()):
                launcher_config.scan(self.documents, self.repo, input_fn=lambda _prompt: "y")

        machine_config = json.loads(machine_path.read_text(encoding="utf-8"))
        self.assertEqual(machine_config["projects"], [])

    def test_unchanged_scan_does_not_restart_launcher(self) -> None:
        project = self.project("stable")
        project_config = {
            "version": 1,
            "id": "stable",
            "name": "stable",
            "enabled": True,
            "services": [
                {
                    "id": "stable",
                    "name": "stable",
                    "command": [".venv/bin/python", "main.py"],
                    "autoStart": False,
                }
            ],
        }
        (project / "launcher.json").write_text(
            launcher_config.formatted_json(project_config), encoding="utf-8"
        )
        machine = launcher_config.new_machine_config("Test-Mac")
        machine["projects"] = [launcher_config.resolve_project(project_config, project)]
        machine_path = self.repo / "configs/test-mac.json"
        machine_path.write_text(launcher_config.formatted_json(machine), encoding="utf-8")

        with patch.object(launcher_config, "machine_name", return_value="Test-Mac"), patch.object(
            launcher_config, "restart_launcher"
        ) as restart:
            with redirect_stdout(io.StringIO()):
                result = launcher_config.scan(self.documents, self.repo, input_fn=lambda _prompt: "y")

        self.assertEqual(result, 0)
        restart.assert_not_called()


if __name__ == "__main__":
    unittest.main()
