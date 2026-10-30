#if os(macOS)
import CueSync
import Foundation

/// 在 AppDelegate 与资料库初始化之前退出的只读入口；由 xc.sh 签隔离副本，现用的正式 App 不必升级或重启。
enum ActivityDiagnosticReader {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-CuePadActivityDiagnosticsRead") else { return }
        guard args.indices.contains(index + 1), ProcessInfo.processInfo.environment["CUEPAD_LIBRARY_DIR"] != nil else {
            fputs("活动取证只读入口须经 xc.sh activity-log <输出文件> 调用\n", stderr)
            exit(2)
        }
        let output = URL(filePath: args[index + 1])
        Task {
            do {
                let reports = try await ActivityDiagnosticCloud().reports()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .custom { date, encoder in
                    var value = encoder.singleValueContainer()
                    try value.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
                }
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(reports).write(to: output, options: .atomic)
                if reports.isEmpty {
                    print("无活动取证报告（只读成功）：\(output.path)")
                } else {
                    print("已只读取回 \(reports.count) 台设备的活动取证：\(output.path)")
                }
                exit(0)
            } catch {
                fputs("活动取证读取失败：\((error as NSError).domain) \((error as NSError).code)\n", stderr)
                exit(1)
            }
        }
        dispatchMain()
    }
}
#endif
