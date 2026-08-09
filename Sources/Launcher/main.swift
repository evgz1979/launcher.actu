import AppKit
import Foundation
import SystemConfiguration

struct LauncherConfig: Decodable {
    let id: String
    let name: String
    let machines: [String]
    let projects: [ProjectConfig]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case machines
        case projects
        case services
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.machines = try container.decode([String].self, forKey: .machines)

        if let projects = try container.decodeIfPresent([ProjectConfig].self, forKey: .projects) {
            self.projects = projects
            return
        }

        let services = try container.decodeIfPresent([ServiceConfig].self, forKey: .services) ?? []
        self.projects = [
            ProjectConfig(id: "actu", name: "actu", services: services)
        ]
    }
}

struct ProjectConfig: Decodable {
    let id: String
    let name: String
    let services: [ServiceConfig]
}

struct ServiceConfig: Decodable {
    let id: String
    let name: String
    let port: Int?
    let url: String?
    let command: [String]
    let workingDirectory: String?
    let autoStart: Bool?
}

@MainActor
struct ProjectProcess {
    let config: ProjectConfig
    let services: [ServiceProcess]
}

@MainActor
final class ServiceProcess {
    let config: ServiceConfig
    private(set) var process: Process?

    init(config: ServiceConfig) {
        self.config = config
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start() throws {
        guard !config.command.isEmpty else {
            throw LauncherError.missingCommand(config.name)
        }

        if isRunning {
            return
        }

        if let port = config.port {
            try killPort(port)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = config.command

        if let workingDirectory = config.workingDirectory, !workingDirectory.isEmpty {
            task.currentDirectoryURL = URL(fileURLWithPath: expandPath(workingDirectory))
        }

        let log = Pipe()
        task.standardOutput = log
        task.standardError = log
        try task.run()
        process = task
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
        if let port = config.port {
            try? killPort(port)
        }
    }

    func restart() throws {
        stop()
        try start()
    }

    func open() {
        if let url = config.url, let target = URL(string: url) {
            NSWorkspace.shared.open(target)
        }
    }
}

enum LauncherError: LocalizedError {
    case missingCommand(String)
    case configsDirectoryNotFound
    case ambiguousConfiguration(String, [String])
    case invalidConfig(URL, Error)

    var errorDescription: String? {
        switch self {
        case .missingCommand(let name):
            return "No launch command configured for \(name)."
        case .configsDirectoryNotFound:
            return "The repository configs directory was not found."
        case .ambiguousConfiguration(let machine, let configs):
            return "Multiple configurations match \(machine): \(configs.joined(separator: ", "))."
        case .invalidConfig(let url, let error):
            return "Could not read \(url.path): \(error.localizedDescription)"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var projects: [ProjectProcess] = []
    private var configurationName = "not found"
    private let machineName = currentMachineName()
    private let menu = NSMenu()

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Launcher"
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "Launcher")
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu

        do {
            if let config = try loadConfig(for: machineName) {
                configurationName = config.name
                projects = config.projects.map { project in
                ProjectProcess(
                    config: project,
                    services: project.services.map(ServiceProcess.init)
                )
            }
            }
        } catch {
            showError(error)
        }

        refreshMenu()
        startAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopAll()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }

    func refreshMenu() {
        menu.removeAllItems()

        for project in projects {
            let projectItem = NSMenuItem(title: project.config.name, action: nil, keyEquivalent: "")
            let projectMenu = NSMenu(title: project.config.name)
            buildProjectMenu(projectMenu, for: project)
            menu.addItem(projectItem)
            menu.setSubmenu(projectMenu, for: projectItem)
        }

        if !projects.isEmpty {
            menu.addItem(.separator())
        }

        if !allServices.isEmpty {
            let restartAll = NSMenuItem(title: "Restart all", action: #selector(restartAll), keyEquivalent: "r")
            restartAll.target = self
            menu.addItem(restartAll)

            let stopAll = NSMenuItem(title: "Stop all", action: #selector(stopAllAction), keyEquivalent: "")
            stopAll.target = self
            menu.addItem(stopAll)

            menu.addItem(.separator())
        }

        let configuration = NSMenuItem(
            title: "Configuration: \(configurationName) (\(machineName))",
            action: nil,
            keyEquivalent: ""
        )
        configuration.isEnabled = false
        menu.addItem(configuration)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Exit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func buildProjectMenu(_ projectMenu: NSMenu, for project: ProjectProcess) {
        guard !project.services.isEmpty else {
            let empty = NSMenuItem(title: "No scripts configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            projectMenu.addItem(empty)
            return
        }

        for service in project.services {
            let status = service.isRunning ? "running" : "stopped"
            let header = NSMenuItem(title: "\(service.config.name) (\(status))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            projectMenu.addItem(header)

            let restart = NSMenuItem(
                title: service.isRunning ? "Restart \(service.config.name)" : "Start \(service.config.name)",
                action: #selector(restartService(_:)),
                keyEquivalent: ""
            )
            restart.target = self
            restart.representedObject = service.config.id
            projectMenu.addItem(restart)

            if service.config.url != nil {
                let open = NSMenuItem(
                    title: "Open \(service.config.name)",
                    action: #selector(openService(_:)),
                    keyEquivalent: ""
                )
                open.target = self
                open.representedObject = service.config.id
                projectMenu.addItem(open)
            }

            projectMenu.addItem(.separator())
        }

        let restartProject = NSMenuItem(
            title: "Restart all in \(project.config.name)",
            action: #selector(restartProject(_:)),
            keyEquivalent: ""
        )
        restartProject.target = self
        restartProject.representedObject = project.config.id
        projectMenu.addItem(restartProject)

        let stopProject = NSMenuItem(
            title: "Stop all in \(project.config.name)",
            action: #selector(stopProject(_:)),
            keyEquivalent: ""
        )
        stopProject.target = self
        stopProject.representedObject = project.config.id
        projectMenu.addItem(stopProject)
    }

    private func startAll() {
        for service in autoStartServices {
            do {
                try service.start()
            } catch {
                showError(error)
            }
        }
        refreshMenu()
    }

    @objc private func restartAll() {
        for service in allServices {
            do {
                try service.restart()
            } catch {
                showError(error)
            }
        }
        refreshMenu()
    }

    @objc private func restartProject(_ sender: NSMenuItem) {
        guard let project = project(from: sender) else {
            return
        }

        for service in project.services {
            do {
                try service.restart()
            } catch {
                showError(error)
            }
        }
        refreshMenu()
    }

    @objc private func stopAllAction() {
        stopAll()
        refreshMenu()
    }

    @objc private func stopProject(_ sender: NSMenuItem) {
        guard let project = project(from: sender) else {
            return
        }

        project.services.forEach { $0.stop() }
        refreshMenu()
    }

    private func stopAll() {
        allServices.forEach { $0.stop() }
    }

    @objc private func restartService(_ sender: NSMenuItem) {
        guard let service = service(from: sender) else {
            return
        }

        do {
            try service.restart()
        } catch {
            showError(error)
        }
        refreshMenu()
    }

    @objc private func openService(_ sender: NSMenuItem) {
        service(from: sender)?.open()
    }

    @objc private func quit() {
        stopAll()
        NSApp.terminate(nil)
    }

    private func service(from item: NSMenuItem) -> ServiceProcess? {
        guard let id = item.representedObject as? String else {
            return nil
        }
        return allServices.first { $0.config.id == id }
    }

    private func project(from item: NSMenuItem) -> ProjectProcess? {
        guard let id = item.representedObject as? String else {
            return nil
        }
        return projects.first { $0.config.id == id }
    }

    private var allServices: [ServiceProcess] {
        projects.flatMap(\.services)
    }

    private var autoStartServices: [ServiceProcess] {
        allServices.filter { $0.config.autoStart != false }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}

func loadConfig(for machineName: String) throws -> LauncherConfig? {
    let repositoryRoot = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        repositoryRoot.appendingPathComponent("configs", isDirectory: true),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("configs", isDirectory: true)
    ]
    let fileManager = FileManager.default

    guard let directory = candidates.first(where: {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }) else {
        throw LauncherError.configsDirectoryNotFound
    }

    let urls = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension.lowercased() == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

    let configs = try urls.map { url in
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(LauncherConfig.self, from: data)
        } catch {
            throw LauncherError.invalidConfig(url, error)
        }
    }
    let matches = configs.filter { config in
        config.machines.contains { $0.caseInsensitiveCompare(machineName) == .orderedSame }
    }

    guard matches.count < 2 else {
        throw LauncherError.ambiguousConfiguration(machineName, matches.map(\.name))
    }
    return matches.first
}

func currentMachineName() -> String {
    if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
        return name
    }
    return ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
}

func expandPath(_ path: String) -> String {
    if path == "~" {
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    if path.hasPrefix("~/") {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(path.dropFirst(2)))
            .path
    }

    return path
}

func killPort(_ port: Int) throws {
    let lsof = Process()
    lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    lsof.arguments = ["-ti", ":\(port)"]

    let output = Pipe()
    lsof.standardOutput = output
    lsof.standardError = Pipe()

    try lsof.run()
    lsof.waitUntilExit()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    let pids = text
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .filter { !$0.isEmpty }

    for pid in pids {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/bin/kill")
        kill.arguments = ["-9", pid]
        try? kill.run()
        kill.waitUntilExit()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
