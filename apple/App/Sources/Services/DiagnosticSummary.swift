import Foundation
import MachO

/// 导出诊断（设置页"上次崩溃"那一页的"导出诊断"）复制出去的那段字：存档里的每份只留要点，同一种（`signature` 相同）的并成一条、计次数、列时间。
/// 原始 JSON 不进这段字（一份就有几十 KB，复制不完），要完整原文就分享存档里的文件（`DiagnosticArchive.url`）。
nonisolated enum DiagnosticSummary {
    /// 同一种列出的时间至多这么多个，再多的只计数。
    static let shownTimes = 5

    static func text(_ reports: [CrashReport]) -> String {
        let groups = Dictionary(grouping: reports, by: signature).values.sorted { $0[0].date > $1[0].date }
        let head = String(localized: "CuePad 诊断摘要：\(reports.count) 份，\(groups.count) 种")
        return ([head] + groups.map(block)).joined(separator: "\n\n")
    }

    /// 同一种：类型、异常、信号、终止码与看门狗事件、栈都相同（版本不算：同一个毛病跨了几个构建仍是一种）。
    private static func signature(_ report: CrashReport) -> String {
        [report.kind.rawValue, report.exception ?? "", report.signal ?? "", report.explanation ?? "", report.trail.first ?? ""]
            .joined(separator: "|") + report.frames.map(\.text).joined(separator: "|")
    }

    private static func block(_ group: [CrashReport]) -> String {
        let report = group[0]
        let title = Dotted(report.kind.name, report.exception.map { $0 + (report.signal.map { "（\($0)）" } ?? "") }).visible
        var lines = [group.count > 1 ? "\(title) × \(group.count)" : title]
        let times = group.prefix(shownTimes).map(\.shownDate).formatted(.list(type: .and)) + (group.count > shownTimes ? "…" : "")
        lines.append(String(localized: "时间：\(times)"))
        let versions = Set(group.compactMap(\.app?.visible)).sorted()
        if !versions.isEmpty { lines.append(String(localized: "版本：\(versions.formatted(.list(type: .and)))")) }
        if let explanation = report.explanation { lines.append(String(localized: "说明：\(explanation)")) }
        if let reason = report.reason { lines.append(String(localized: "原因：\(reason.replacing("\n", with: " "))")) }
        lines += report.trail.map { "  \($0)" }
        if !report.frames.isEmpty {
            lines.append(report.kind == .crash ? String(localized: "崩溃线程：") : String(localized: "主线程："))
            lines += report.frames.map { "  \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// 这台设备此刻载入的二进制，按 UUID 认（MetricKit 的帧有的不带二进制名）：系统库在同一个系统版本上 UUID 不变，
/// 所以在出事的那台设备上导出时认得出；CuePad 的二进制只认得出这一个构建的。
nonisolated enum LoadedImages {
    private struct Image { let name: String; let own: Bool }

    private static let byUUID: [String: Image] = load()

    static func frame(name: String?, uuid: String?, offset: Int?) -> CrashReport.Frame {
        let image = uuid.flatMap { byUUID[$0.uppercased()] }
        let binary = name ?? image?.name ?? uuid.map { String($0.prefix(8)) } ?? "?"
        return CrashReport.Frame(binary: binary, offset: offset, own: image?.own ?? (binary == executable))
    }

    private static let executable = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String

    private static func load() -> [String: Image] {
        let bundle = Bundle.main.bundlePath
        var images: [String: Image] = [:]
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), let path = _dyld_get_image_name(index).map(String.init(cString:)),
                  let uuid = uuid(of: header)
            else { continue }
            images[uuid] = Image(name: URL(filePath: path).lastPathComponent, own: path.hasPrefix(bundle))
        }
        return images
    }

    private static func uuid(of header: UnsafePointer<mach_header>) -> String? {
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == LC_UUID { return UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }
}
