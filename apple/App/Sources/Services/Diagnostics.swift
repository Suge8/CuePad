import CueStore
import MetricKit
import Observation
import os

/// MetricKit 的诊断一般在下次启动或隔天才交来。存本机（`DiagnosticArchive`），连着 iCloud 时经你自己的私有库送到你的 Mac（`DiagnosticOutbox`），
/// Mac 落成文件给 agent 读（`DiagnosticInbox`，docs/diagnose.md）；不经别人。手机与 Mac 都不在手边、要发给别人时用设置页"导出诊断"。
@Observable
final class Diagnostics {
    private(set) var reports: [CrashReport]
    /// 连着 iCloud（或测试、验收的替身云）时才能把最近日志发到 Mac。
    private(set) var canSend = false
    @ObservationIgnored let archive: DiagnosticArchive
    @ObservationIgnored private var subscriber: Subscriber?
    @ObservationIgnored private var outbox: DiagnosticOutbox?
    private static let log = Logger(subsystem: AppIdentity.id, category: "diagnostics")

    var latest: CrashReport? { reports.first }

    init(directory: URL) {
        archive = DiagnosticArchive(directory: directory)
        archive.tidy()
        reports = archive.reports()
    }

    /// 幂等。`metricKit` 只在用户的设备上（`touchesRealWorld`）才订阅，并取一次系统已经攒着的（订阅之前到的）。
    /// `outbox` 在连着 iCloud 时给：存档一变就对一遍云上的，这里先对一遍（之前没送成的，账号认好才发）。
    func start(metricKit: Bool, outbox: DiagnosticOutbox?) {
        MainThreadWatch.shared.start(archive: archive, version: AppServices.version) { [weak self] note in self?.recorded(note) }
        if self.outbox == nil, let outbox {
            self.outbox = outbox
            canSend = true
            push()
        }
        guard metricKit, subscriber == nil else { return }
        let subscriber = Subscriber { [weak self] payloads in Task { @MainActor in self?.record(payloads) } }
        MXMetricManager.shared.add(subscriber)
        self.subscriber = subscriber
        record(MXMetricManager.shared.pastDiagnosticPayloads.map { $0.jsonRepresentation() })
    }

    func record(_ payloads: [Data]) {
        for payload in payloads {
            do { try archive.store(payload) } catch { AppServices.log.error("诊断存档失败：\(String(describing: error))") }
        }
        reload()
    }

    /// 设置里"把最近日志发到 Mac"：存一份最近 `RecentLogs.window` 的日志，送进 iCloud。返回时已被 iCloud 收下；
    /// 没送成（没登录、断网、被限流）或等了 `sendLimit` 还没收下，抛 `Queued`：日志已存下，送件那边自己接着送（`DiagnosticOutbox`）。
    func sendRecentLogs() async throws {
        guard let outbox else { throw CancellationError() }
        let end = Date.now
        let text = try await Self.capture(from: end.addingTimeInterval(-RecentLogs.window), to: end, title: "最近日志 | CuePad \(AppServices.version)")
        try archive.store(log: text, at: end, kind: "log")
        reload(pushing: false)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await outbox.reconcile() }
                group.addTask {
                    try await Task.sleep(for: Self.sendLimit)
                    throw CancellationError()
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            throw Queued()
        }
    }

    static let sendLimit = Duration.seconds(30)
    struct Queued: Error {}

    /// 卡住恢复了就附上它前后那段日志（同一个时刻开头，存档里紧挨着那条卡住记录）：卡住期间与之前一分钟。
    /// 没恢复的（被结束）附不上：`OSLogStore` 只读得到本进程这次运行的。
    private func recorded(_ note: FreezeNote) {
        reload()
        guard let seconds = note.seconds else { return }
        Task {
            do {
                let text = try await Self.capture(
                    from: note.start.addingTimeInterval(-Self.beforeFreeze), to: note.start.addingTimeInterval(seconds + 1), title: "卡住前后的日志 | CuePad \(AppServices.version)")
                try archive.store(log: text, at: note.start, kind: "freeze-log")
                reload()
            } catch {
                Self.log.error("卡住前后的日志没存下：\(String(describing: error), privacy: .public)")
            }
        }
    }

    static let beforeFreeze: TimeInterval = 60

    @concurrent private static func capture(from start: Date, to end: Date, title: String) async throws -> String {
        try RecentLogs.text(from: start, to: end, title: title)
    }

    private func reload(pushing: Bool = true) {
        archive.tidy()
        reports = archive.reports()
        if pushing { push() }
    }

    private func push() {
        guard let outbox else { return }
        Task {
            do { try await outbox.reconcile() } catch {
                Self.log.notice("诊断这次没送进 iCloud，过一阵自己再送：\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// MetricKit 在自己的队列上回调；包不是 Sendable，在回调里就转成 JSON（时间按这一刻的本地时区写，`CrashReport` 按本地时区读）。
    private final class Subscriber: NSObject, MXMetricManagerSubscriber, Sendable {
        let handler: @Sendable ([Data]) -> Void

        nonisolated init(handler: @escaping @Sendable ([Data]) -> Void) { self.handler = handler }

        nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) { handler(payloads.map { $0.jsonRepresentation() }) }
    }
}
