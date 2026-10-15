import AppKit
import Foundation
import SystemConfiguration

struct ProjectConfig: Decodable {
    let version: Int
    let id: String
    let name: String
    let enabled: Bool?
    let services: [ServiceConfig]
}

struct RemoteLauncherConfig: Decodable {
    let remoteMachines: [RemoteMachineConfig]
}

struct RemoteMachineConfig: Decodable {
    let id: String
    let name: String
    let host: String
    let projects: [RemoteProjectConfig]
}

struct RemoteProjectConfig: Decodable {
    let id: String
    let name: String
    let port: Int
    let url: String?
}

struct ServiceConfig: Decodable {
    let id: String
    let name: String
    let port: Int?
    let url: String?
    let command: [String]
    let workingDirectory: String?
    let autoStart: Bool?
    let autoRestart: Bool?
    let healthURL: String?
}

@MainActor
struct ProjectProcess {
    let config: ProjectConfig
    let services: [ServiceProcess]
}

@MainActor
final class ServiceProcess { // Владеет процессом сервиса и явно включённым контролем
    let projectID: String
    let config: ServiceConfig
    private(set) var process: Process?
    private var logPipe: Pipe?
    private var monitor: Timer?
    private var requestedRunning = false
    private var startedAt: Date?
    private var checkingHealth = false

    init(projectID: String, config: ServiceConfig) {
        self.projectID = projectID
        self.config = config
    }

    var reference: String {
        "\(projectID)/\(config.id)"
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start() throws { // Запускает сервис и включает его контроль при autoRestart
        requestedRunning = true
        if config.autoRestart == true && monitor == nil {
            monitor = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.checkHealth()
                }
            }
        }
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
        let logPrefix = "[Launcher \(reference)]"
        log.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            if !message.isEmpty {
                NSLog("%@ %@", logPrefix, message)
            }
        }
        task.standardOutput = log
        task.standardError = log
        do {
            try task.run()
        } catch {
            log.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = task
        logPipe = log
        startedAt = Date()
    }

    func checkHealth(now: Date = Date(), session: URLSession = .shared) async { // Перезапускает только явно включённый сервис и не отменяет ручной Stop
        guard requestedRunning, config.autoRestart == true, !checkingHealth else { return }
        if !isRunning {
            do {
                NSLog("[Launcher %@] process exited; restarting", reference)
                try start()
            } catch {
                NSLog("[Launcher %@] restart failed: %@", reference, error.localizedDescription)
            }
            return
        }
        guard let startedAt, now.timeIntervalSince(startedAt) >= 60,
              let address = config.healthURL, let url = URL(string: address) else { return }
        let checkedProcess = process
        checkingHealth = true
        defer { checkingHealth = false }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        var healthy = false
        do {
            let (data, response) = try await session.data(for: request)
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            healthy = (response as? HTTPURLResponse)?.statusCode == 200
                && ["ok", "starting"].contains(body?["status"] as? String ?? "")
        } catch {
            NSLog("[Launcher %@] health request failed: %@", reference, error.localizedDescription)
        }
        guard !healthy, requestedRunning, process === checkedProcess, isRunning else { return }
        do {
            NSLog("[Launcher %@] no fresh candle health; restarting", reference)
            try restart()
        } catch {
            NSLog("[Launcher %@] restart failed: %@", reference, error.localizedDescription)
        }
    }

    func stop() { // Останавливает сервис и отменяет его автоматическое восстановление
        requestedRunning = false
        monitor?.invalidate()
        monitor = nil
        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
        logPipe?.fileHandleForReading.readabilityHandler = nil
        logPipe = nil
        if let port = config.port {
            try? killPort(port)
        }
    }

    func restart() throws {
        stop()
        try start()
    }

    func openAfterStart() {
        guard let url = config.url, let target = URL(string: url) else {
            return
        }

        let delay = config.port == nil ? 0.1 : 0.7
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSWorkspace.shared.open(target)
        }
    }
}

enum LauncherError: LocalizedError {
    case missingCommand(String)
    case projectsDirectoryNotFound(String)
    case unsupportedProjectVersion(URL, Int)
    case duplicateProjectID(String, [String])
    case duplicateServiceID(URL, String)
    case invalidConfig(URL, Error)

    var errorDescription: String? {
        switch self {
        case .missingCommand(let name):
            return "No launch command configured for \(name)."
        case .projectsDirectoryNotFound(let path):
            return "The projects directory was not found: \(path)."
        case .unsupportedProjectVersion(let url, let version):
            return "Unsupported project configuration version \(version): \(url.path)."
        case .duplicateProjectID(let id, let paths):
            return "Duplicate project ID \(id): \(paths.joined(separator: ", "))."
        case .duplicateServiceID(let url, let id):
            return "Duplicate service ID \(id): \(url.path)."
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
    private var remoteMachines: [RemoteMachineConfig] = []
    private var catalogName = "not found"
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
            let catalog = projectsDirectoryURL()
            catalogName = abbreviatedPath(catalog.path)
            projects = try loadProjects(from: catalog).map { project in
                ProjectProcess(
                    config: project,
                    services: project.services.map {
                        ServiceProcess(projectID: project.id, config: $0)
                    }
                )
            }
            remoteMachines = try loadRemoteConfig()?.remoteMachines ?? []
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

        if !remoteMachines.isEmpty {
            if !projects.isEmpty {
                menu.addItem(.separator())
            }
            for machine in remoteMachines {
                let machineItem = NSMenuItem(title: machine.name, action: nil, keyEquivalent: "")
                let machineMenu = NSMenu(title: machine.name)
                for project in machine.projects {
                    let item = NSMenuItem(
                        title: project.name,
                        action: #selector(openRemoteProject(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = project.url ?? "http://\(machine.host):\(project.port)"
                    machineMenu.addItem(item)
                }
                menu.addItem(machineItem)
                menu.setSubmenu(machineMenu, for: machineItem)
            }
        }

        if !projects.isEmpty || !remoteMachines.isEmpty {
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
            title: "Catalog: \(catalogName) (\(machineName))",
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
            restart.representedObject = service.reference
            projectMenu.addItem(restart)

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
            service.openAfterStart()
        } catch {
            showError(error)
        }
        refreshMenu()
    }

    @objc private func quit() {
        stopAll()
        NSApp.terminate(nil)
    }

    @objc private func openRemoteProject(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let url = URL(string: value) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func service(from item: NSMenuItem) -> ServiceProcess? {
        guard let id = item.representedObject as? String else {
            return nil
        }
        return allServices.first { $0.reference == id }
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
        allServices.filter { $0.config.autoStart == true }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}

func loadProjects(from directory: URL) throws -> [ProjectConfig] {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw LauncherError.projectsDirectoryNotFound(directory.path)
    }

    let roots = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )
    .filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && fileManager.fileExists(atPath: url.appendingPathComponent("launcher.json").path)
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

    let discovered = try roots.compactMap { root -> (ProjectConfig, String)? in
        let url = root.appendingPathComponent("launcher.json")
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(ProjectConfig.self, from: data)
            guard config.version == 1 else {
                throw LauncherError.unsupportedProjectVersion(url, config.version)
            }
            let serviceGroups = Dictionary(grouping: config.services, by: \.id)
            if let duplicate = serviceGroups.first(where: { $0.value.count > 1 }) {
                throw LauncherError.duplicateServiceID(url, duplicate.key)
            }
            guard config.enabled != false else {
                return nil
            }
            return (resolveProject(config, relativeTo: root), url.path)
        } catch {
            if let launcherError = error as? LauncherError {
                throw launcherError
            }
            throw LauncherError.invalidConfig(url, error)
        }
    }

    let groups = Dictionary(grouping: discovered, by: { $0.0.id })
    if let duplicate = groups.first(where: { $0.value.count > 1 }) {
        throw LauncherError.duplicateProjectID(duplicate.key, duplicate.value.map { $0.1 })
    }
    return discovered.map { $0.0 }
}

func resolveProject(_ project: ProjectConfig, relativeTo root: URL) -> ProjectConfig {
    let services = project.services.map { service in
        var command = service.command
        if let executable = command.first,
           executable.contains("/") || executable.hasPrefix("~") {
            command[0] = resolvePath(executable, relativeTo: root)
        }
        let workingDirectory = resolvePath(service.workingDirectory ?? ".", relativeTo: root)
        return ServiceConfig(
            id: service.id,
            name: service.name,
            port: service.port,
            url: service.url,
            command: command,
            workingDirectory: workingDirectory,
            autoStart: service.autoStart,
            autoRestart: service.autoRestart,
            healthURL: service.healthURL
        )
    }
    return ProjectConfig(
        version: project.version,
        id: project.id,
        name: project.name,
        enabled: project.enabled,
        services: services
    )
}

func resolvePath(_ path: String, relativeTo root: URL) -> String {
    let expanded = expandPath(path)
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
    return root.appendingPathComponent(expanded).standardizedFileURL.path
}

func loadRemoteConfig() throws -> RemoteLauncherConfig? {
    let candidates = [
        repositoryRootURL().appendingPathComponent("remote/remotes.json"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("remote/remotes.json")
    ]
    guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
        return nil
    }
    do {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RemoteLauncherConfig.self, from: data)
    } catch {
        throw LauncherError.invalidConfig(url, error)
    }
}

func repositoryRootURL() -> URL {
    Bundle.main.bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func projectsDirectoryURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
}

func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home {
        return "~"
    }
    if path.hasPrefix(home + "/") {
        return "~/" + path.dropFirst(home.count + 1)
    }
    return path
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

func killPort(_ port: Int) throws { // Освобождает порт только от слушающего сервера, сохраняя клиентов
    let lsof = Process()
    lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    lsof.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]

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
