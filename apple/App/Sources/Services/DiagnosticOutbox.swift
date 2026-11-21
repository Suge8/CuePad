import CueStore
import CueSync
import Foundation
import os

actor DiagnosticOutbox {
    struct Sent: Codable, Equatable {
        var account: String
        var files: [String: Date]
    }

    private let archive: DiagnosticArchive
    private let sync: CloudSync
    private let device: String
    private let deviceName: String
    private let timing: Timing
    private var running: Task<Void, any Error>?
    private var again = false
    private var retry: Task<Void, Never>?
    static let firstRetry = Duration.seconds(30)
    static let lastRetry = Duration.seconds(600)
    private static let log = Logger(subsystem: AppIdentity.id, category: "diagnostics")

    init(archive: DiagnosticArchive, sync: CloudSync, device: String, deviceName: String, timing: Timing) {
        self.archive = archive
        self.sync = sync
        self.device = device
        self.deviceName = deviceName
        self.timing = timing
    }

    private var sentFile: URL { archive.directory.appending(path: "sent.json") }

    func reconcile() async throws {
        do { try await pass() } catch {
            retryLater()
            throw error
        }
    }

    /// 等这一遍对完，至多 `limit`（按注入的钟）：对成返回 true，没对成或到点还没对完返回 false。到点不取消送件：
    /// 送件是共用的那一遍（自动送也在等它），账号认好、连上后它自己送完；在任务组里比快会等被取消的一方真结束，等账号时永远等不完。
    func reconcile(within limit: Duration) async -> Bool {
        let (outcomes, first) = AsyncStream.makeStream(of: Bool.self)
        Task {
            do {
                try await reconcile()
                first.yield(true)
            } catch {
                first.yield(false)
            }
        }
        let timer = Task { [timing] in
            guard (try? await timing.sleep(limit)) != nil else { return }
            first.yield(false)
        }
        defer { timer.cancel() }
        for await sent in outcomes { return sent }
        return false
    }

    private func retryLater() {
        guard retry == nil else { return }
        retry = Task {
            var backoff = Backoff(first: Self.firstRetry, cap: Self.lastRetry)
            while (try? await timing.sleep(backoff.next())) != nil {
                do {
                    try await pass()
                    break
                } catch {
                    Self.log.notice("诊断仍没送进 iCloud，退避后再送：\(String(describing: error), privacy: .public)")
                }
            }
            retry = nil
        }
    }

    private func pass() async throws {
        if let running {
            again = true
            try await running.value
            return
        }
        let task = Task<Void, any Error> {
            defer { running = nil }
            repeat {
                again = false
                try await once(account: try await sync.diagnosticsAccount())
            } while again
        }
        running = task
        try await task.value
    }

    private func once(account: String) async throws {
        let previous = (try? JSONDecoder().decode(Sent.self, from: Data(contentsOf: sentFile))).flatMap { $0.account == account ? $0 : nil }
        let sent = previous?.files ?? [:]
        let here = archive.modified()
        let new = here.keys.filter { sent[$0] != here[$0] }
        let saving = new.compactMap(diagnostic)
        let deleting = sent.keys.filter { here[$0] == nil }.map { DeviceDiagnostic.Key(device: device, file: $0) }
        guard !new.isEmpty || !deleting.isEmpty else { return }
        if !saving.isEmpty || !deleting.isEmpty { try await sync.sendDiagnostics(saving: saving, deleting: deleting) }
        try JSONEncoder().encode(Sent(account: account, files: here)).write(to: sentFile, options: .atomic)
        Self.log.notice("诊断送进 iCloud：传 \(saving.count) 份、删 \(deleting.count) 份")
    }

    private func diagnostic(_ name: String) -> DeviceDiagnostic? {
        guard let content = try? Data(contentsOf: archive.url(name)) else { return nil }
        guard content.count <= DeviceDiagnostic.maxBytes else {
            Self.log.error("诊断 \(name, privacy: .public) 有 \(content.count) 字节，超过一条记录的上限，不传")
            return nil
        }
        return DeviceDiagnostic(device: device, deviceName: deviceName, file: name, content: content)
    }
}
