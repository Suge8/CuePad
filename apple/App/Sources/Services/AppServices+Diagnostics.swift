import CueStore
import CueSync
import Foundation
#if os(macOS)
import SystemConfiguration
#else
import UIKit
#endif

/// 诊断怎么从各台设备到 Mac：存档一变就经 iCloud 送出（`DiagnosticOutbox`），Mac 隔一阵收一次、落成文件（`DiagnosticInbox`）。
/// 只在真同步（`CloudSync`，含同步测量与测试的替身云）时送；没同步的隔离实例只存本机。
extension AppServices {
    func startDiagnostics() {
        let cloud = sync as? CloudSync
        diagnostics.start(
            metricKit: location.touchesRealWorld,
            outbox: cloud.flatMap { cloud in
                diagnosticDevice.map { DiagnosticOutbox(archive: diagnostics.archive, sync: cloud, device: $0.id, deviceName: $0.name) }
            })
        #if os(macOS)
        if let cloud {
            let inbox = DiagnosticInbox(directory: location.deviceLogs, sync: cloud)
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
        UIDevice.current.identifierForVendor.map { ($0.uuidString, MainThreadWatch.device) }
        #endif
    }
}
