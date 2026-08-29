import Foundation
import Testing
@testable import Launcher

@Test func loadsOnlyImmediateConfiguredProjectsAndResolvesPaths() throws {
    let catalog = try temporaryCatalog()
    defer { try? FileManager.default.removeItem(at: catalog) }

    let actu = catalog.appendingPathComponent("actu", isDirectory: true)
    try FileManager.default.createDirectory(at: actu, withIntermediateDirectories: true)
    try projectJSON(
        id: "actu",
        serviceID: "datafeeder",
        executable: ".venv/bin/python"
    ).write(to: actu.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)

    let unconfigured = catalog.appendingPathComponent("unconfigured", isDirectory: true)
    try FileManager.default.createDirectory(at: unconfigured, withIntermediateDirectories: true)
    try "print('not a configured project')\n".write(
        to: unconfigured.appendingPathComponent("main.py"),
        atomically: true,
        encoding: .utf8
    )

    let nested = unconfigured.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try projectJSON(id: "nested", serviceID: "nested", executable: "python3")
        .write(to: nested.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)

    let projects = try loadProjects(from: catalog)

    #expect(projects.map(\.id) == ["actu"])
    #expect(projects[0].services[0].command[0].hasSuffix("/actu/.venv/bin/python"))
    #expect(projects[0].services[0].workingDirectory?.hasSuffix("/actu") == true)
}

@Test func skipsDisabledProject() throws {
    let catalog = try temporaryCatalog()
    defer { try? FileManager.default.removeItem(at: catalog) }

    let disabled = catalog.appendingPathComponent("disabled", isDirectory: true)
    try FileManager.default.createDirectory(at: disabled, withIntermediateDirectories: true)
    let json = projectJSON(id: "disabled", serviceID: "service", executable: "python3")
        .replacingOccurrences(of: "\"enabled\": true", with: "\"enabled\": false")
    try json.write(
        to: disabled.appendingPathComponent("launcher.json"),
        atomically: true,
        encoding: .utf8
    )

    #expect(try loadProjects(from: catalog).isEmpty)
}

@Test func rejectsDuplicateProjectIDs() throws {
    let catalog = try temporaryCatalog()
    defer { try? FileManager.default.removeItem(at: catalog) }

    for name in ["first", "second"] {
        let root = catalog.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try projectJSON(id: "duplicate", serviceID: name, executable: "python3")
            .write(to: root.appendingPathComponent("launcher.json"), atomically: true, encoding: .utf8)
    }

    do {
        _ = try loadProjects(from: catalog)
        Issue.record("Duplicate project ID was accepted")
    } catch LauncherError.duplicateProjectID(let id, _) {
        #expect(id == "duplicate")
    }
}

@Test func rejectsDuplicateServiceIDs() throws {
    let catalog = try temporaryCatalog()
    defer { try? FileManager.default.removeItem(at: catalog) }

    let root = catalog.appendingPathComponent("duplicate-services", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let json = """
    {
      "version": 1,
      "id": "project",
      "name": "project",
      "enabled": true,
      "services": [
        {
          "id": "duplicate",
          "name": "first",
          "command": ["python3", "first.py"],
          "autoStart": true
        },
        {
          "id": "duplicate",
          "name": "second",
          "command": ["python3", "second.py"],
          "autoStart": false
        }
      ]
    }
    """
    try json.write(
        to: root.appendingPathComponent("launcher.json"),
        atomically: true,
        encoding: .utf8
    )

    #expect(throws: LauncherError.self) {
        _ = try loadProjects(from: catalog)
    }
}

private func temporaryCatalog() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func projectJSON(id: String, serviceID: String, executable: String) -> String {
    """
    {
      "version": 1,
      "id": "\(id)",
      "name": "\(id)",
      "enabled": true,
      "services": [
        {
          "id": "\(serviceID)",
          "name": "\(serviceID)",
          "command": ["\(executable)", "main.py"],
          "autoStart": true
        }
      ]
    }
    """
}
