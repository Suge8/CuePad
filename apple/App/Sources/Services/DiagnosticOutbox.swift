import CueStore
import CueSync
import Foundation
import os

/// 让云上这台设备的诊断（`DeviceDiagnostic`）与本机存档（`DiagnosticArchive`）一致：存档里新有的传上去，存档整理掉的云上也删。
/// 传过哪些（连同传时的修改时刻：卡住记录恢复后原地改写，要再传）记在存档目录的 `sent.json`，按资料所属账号记：换了账号就当一份都没传过（旧账号那边的不去删）。
/// 一次只对一遍；对的途中又有变化（`reconcile` 再被调），这一遍完了接着再对一遍。没对成的（断网、被限流）自己隔一阵再对，
/// 从 `firstRetry` 起每次加倍、至多 `lastRetry`，对成为止：恢复连接后不必等存档再变。不看同步的状态：诊断没传成时同步可能一直是好的。
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

    /// 返回时这一遍（及其间要求的再一遍）对完；没对成的抛出这一遍的错误，并排上自己重试。账号还没认好时等它认好（`CloudSync.diagnosticsAccount`）。
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
            var delay = Self.firstRetry
            while (try? await timing.sleep(delay)) != nil {
                do {
                    try await pass()
                    break
                } catch {
                    Self.log.notice("诊断仍没送进 iCloud，\(delay * 2 > Self.lastRetry ? Self.lastRetry : delay * 2) 后再送：\(String(describing: error), privacy: .public)")
                    delay = min(delay * 2, Self.lastRetry)
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
            repeat {
                again = false
                try await once(account: try await sync.diagnosticsAccount())
            } while again
        }
        running = task
        defer { running = nil }
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
        // 太大不传的也记作对过：不然每对一遍都再读一次、再记一条
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
