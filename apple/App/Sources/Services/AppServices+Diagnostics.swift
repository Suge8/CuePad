import CueStore
import CueSync
import Foundation
#if os(macOS)
import SystemConfiguration
#endif

extension AppServices {
    func startDiagnostics() {
        let cloud = sync as? CloudSync
        diagnostics.start(
            metricKit: location.touchesRealWorld,
            outbox: cloud.flatMap { cloud in
                diagnosticDevice.map { DiagnosticOutbox(archive: diagnostics.archive, sync: cloud, device: $0.id, deviceName: $0.name, timing: timing) }
            })
        #if os(macOS)
        if let cloud {
            let inbox = DiagnosticInbox(directory: deviceLogs, sync: cloud)
            follow { await inbox.watch(every: DebugHooks.diagnosticsEvery ?? DiagnosticInbox.interval) }
        }
        #endif
    }

    /// 这台设备在诊断里的 ID 与名字：ID 同各台在同步表里认自己的（Mac 的 `hostID`、手机的 identifierForVendor），名字给 Mac 上按设备分目录。
    /// iOS 读不到用户起的设备名（要 Apple 特批的权限），系统给的是"iPhone"，用型号代号（iPhone18,1，与 MetricKit、崩溃报告里的写法一致）。
    private var diagnosticDevice: (id: String, name: String)? {
        #if os(macOS)
        (hostID, SCDynamicStoreCopyComputerName(nil, nil) as String? ?? MainThreadWatch.device)
        #else
        device.map { ($0, MainThreadWatch.device) }
        #endif
    }
}
