import MetricKit
import Observation
import os

/// 崩溃诊断：订阅 MetricKit，系统把崩溃、卡死、CPU 与磁盘写入异常的诊断（一般在下次启动或隔天）交来时存进 `DiagnosticArchive`，
/// 设置页据 `latest` 写"上次崩溃"。只存本机、不联网；真机上拿崩溃栈靠用户在设置页"导出诊断"。
@Observable
final class Diagnostics {
    private(set) var latest: CrashReport?
    @ObservationIgnored private let archive: DiagnosticArchive
    @ObservationIgnored private var subscriber: Subscriber?

    init(directory: URL) {
        archive = DiagnosticArchive(directory: directory)
        latest = archive.reports().first
    }

    /// 幂等。开始订阅，并取一次系统已经攒着的（订阅之前到的）。
    func start() {
        guard subscriber == nil else { return }
        let subscriber = Subscriber { [weak self] payloads in Task { @MainActor in self?.record(payloads) } }
        MXMetricManager.shared.add(subscriber)
        self.subscriber = subscriber
        record(MXMetricManager.shared.pastDiagnosticPayloads.map { $0.jsonRepresentation() })
    }

    /// 存下一批包的原始 JSON。存不下来时记日志，别的包照常存。
    func record(_ payloads: [Data]) {
        for payload in payloads {
            do { try archive.store(payload) } catch { AppServices.log.error("诊断存档失败：\(String(describing: error), privacy: .public)") }
        }
        latest = archive.reports().first
    }

    /// MetricKit 在自己的队列上回调；包不是 Sendable，在回调里就转成 JSON。
    private final class Subscriber: NSObject, MXMetricManagerSubscriber, Sendable {
        let handler: @Sendable ([Data]) -> Void

        nonisolated init(handler: @escaping @Sendable ([Data]) -> Void) { self.handler = handler }

        nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) { handler(payloads.map { $0.jsonRepresentation() }) }
    }
}
