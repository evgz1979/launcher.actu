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

    def test_scan_creates_project_and_machine_configs_after_confirmation(self) -> None:
        project = self.project("demo")
        answers = iter(["y", "", "", "", "", "", "", "", "", "n", "n", "y"])

        with patch.object(launcher_config, "machine_name", return_value="Test-Mac"):
            with redirect_stdout(io.StringIO()):
                result = launcher_config.scan(
                    self.documents,
                    self.repo,
                    input_fn=lambda _prompt: next(answers),
                )

        self.assertEqual(result, 0)
        project_config = json.loads((project / "launcher.json").read_text(encoding="utf-8"))
        machine_config = json.loads(
            (self.repo / "configs/test-mac.json").read_text(encoding="utf-8")
        )
        self.assertFalse(project_config["services"][0]["autoStart"])
        self.assertEqual(machine_config["machines"], ["Test-Mac"])
        self.assertEqual(machine_config["projects"][0]["id"], "demo")

    def test_scan_can_ignore_project_on_current_machine(self) -> None:
        project = self.project("ignored")
        answers = iter(["n", "2", "y"])

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
        self.assertEqual(machine_config["ignoredProjects"], [str(project.resolve())])
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
                    "ignoredProjects": [],
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


if __name__ == "__main__":
    unittest.main()
