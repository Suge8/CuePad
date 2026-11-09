import MetricKit
import Observation
import os

/// MetricKit 的诊断一般在下次启动或隔天才交来。只存本机、不联网；手机不在开发用的 Mac 旁边时，拿崩溃栈靠用户在设置页"导出诊断"（连着时用 xc.sh diag）。
@Observable
final class Diagnostics {
    private(set) var reports: [CrashReport]
    @ObservationIgnored let archive: DiagnosticArchive
    @ObservationIgnored private var subscriber: Subscriber?

    var latest: CrashReport? { reports.first }

    init(directory: URL) {
        archive = DiagnosticArchive(directory: directory)
        archive.tidy()
        reports = archive.reports()
    }

    /// 幂等。`metricKit` 只在用户的设备上（`touchesRealWorld`）才订阅，并取一次系统已经攒着的（订阅之前到的）。
    func start(metricKit: Bool) {
        MainThreadWatch.shared.start(archive: archive, version: AppServices.version) { [weak self] in self?.reload() }
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

    private func reload() {
        archive.tidy()
        reports = archive.reports()
    }

    /// MetricKit 在自己的队列上回调；包不是 Sendable，在回调里就转成 JSON（时间按这一刻的本地时区写，`CrashReport` 按本地时区读）。
    private final class Subscriber: NSObject, MXMetricManagerSubscriber, Sendable {
        let handler: @Sendable ([Data]) -> Void

        nonisolated init(handler: @escaping @Sendable ([Data]) -> Void) { self.handler = handler }

        nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) { handler(payloads.map { $0.jsonRepresentation() }) }
    }
}
