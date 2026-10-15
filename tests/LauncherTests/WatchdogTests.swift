import Foundation
import Testing
@testable import Launcher

final class WatchdogHealthProtocol: URLProtocol, @unchecked Sendable { // Отдаёт контролируемую свежесть без открытия тестовых портов
    override class func canInit(with request: URLRequest) -> Bool { true } // Принимает запрос тестовой сессии
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request } // Сохраняет исходный адрес
    override func startLoading() { // Возвращает ok или stale по пути тестового URL
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"status\":\"\(request.url!.lastPathComponent)\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {} // Не создаёт фоновой работы
}

@MainActor
func watchdogService(autoRestart: Bool, health: String? = nil, command: [String] = ["/bin/sleep", "120"]) -> ServiceProcess { // Создаёт отдельный проверочный процесс без порта
    ServiceProcess(projectID: "test", config: ServiceConfig(id: "watchdog", name: "watchdog", port: nil, url: nil, command: command, workingDirectory: nil, autoStart: true, autoRestart: autoRestart, healthURL: health))
}

@Test @MainActor func watchdogRestartsExitedProcessAndHonorsStop() async throws { // Аварийный выход запускается снова, ручной Stop сохраняется
    let service = watchdogService(autoRestart: true, command: ["/bin/sh", "-c", "exit 1"])
    defer { service.stop() }
    try service.start()
    let first = service.process!
    for _ in 0..<100 {
        if !first.isRunning { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(!first.isRunning)
    await service.checkHealth()
    #expect(service.process !== first)
    service.stop()
    await service.checkHealth()
    #expect(service.process == nil)
}

@Test @MainActor func watchdogDoesNotRestartServicesWithoutOptIn() async throws { // Остальные сервисы не получают новую политику запуска
    let service = watchdogService(autoRestart: false, command: ["/bin/sh", "-c", "exit 1"])
    defer { service.stop() }
    try service.start()
    let first = service.process!
    for _ in 0..<100 {
        if !first.isRunning { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    await service.checkHealth()
    #expect(service.process === first)
}

@Test @MainActor func watchdogGivesStartupGraceAndRestartsStaleHealth() async throws { // Живой процесс получает время подключения и перезапускается при stale
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WatchdogHealthProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    for state in ["ok", "stale"] {
        let service = watchdogService(autoRestart: true, health: "https://watchdog.invalid/\(state)")
        try service.start()
        let first = service.process!
        await service.checkHealth(session: session)
        #expect(service.process === first)
        await service.checkHealth(now: Date().addingTimeInterval(61), session: session)
        #expect((service.process === first) == (state == "ok"))
        service.stop()
    }
}
