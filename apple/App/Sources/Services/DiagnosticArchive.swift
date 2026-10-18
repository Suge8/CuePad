import Foundation

/// MetricKit 交来的诊断（崩溃、卡死、CPU 与磁盘写入异常）的存档：原始 JSON 按时间命名存进一个文件夹（资料库目录下的 `Diagnostics`），
/// 只留最近 `keep` 份。不联网、不上传；崩溃栈要靠用户在设置页"导出诊断"发来。
nonisolated struct DiagnosticArchive: Sendable {
    let directory: URL
    static let keep = 10

    /// 存一份 `MXDiagnosticPayload.jsonRepresentation()`；没有任何诊断内容的包不存。文件名取包的结束时间，
    /// 同一份重复送达（`didReceive` 与 `pastDiagnosticPayloads`）只存一份。
    func store(_ json: Data, receivedAt: Date = .now) throws {
        guard let root = CrashReport.root(of: json), let kind = CrashReport.Kind(root: root) else { return }
        let date = (root["timeStampEnd"] as? String).flatMap(Self.parse) ?? receivedAt
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try json.write(to: directory.appending(path: "\(Self.stamp(date))-\(kind.rawValue).json"), options: .atomic)
        for name in names().dropFirst(Self.keep) { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
    }

    /// 存档里的诊断，新的在前；读不出来的文件跳过。
    func reports() -> [CrashReport] {
        names().compactMap { name in
            (try? Data(contentsOf: directory.appending(path: name))).flatMap { CrashReport(id: name, json: $0) }
        }
    }

    private func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.sorted(by: >)
    }

    /// MetricKit 的时间是 UTC 的 "yyyy-MM-dd HH:mm:ss"；存档文件名与摘要里的时间都从这里来。
    fileprivate static func parse(_ text: String) -> Date? {
        try? Date(text.replacing(" ", with: "T") + "Z", strategy: .iso8601)
    }

    /// 文件名里的时间：UTC，冒号换成短横（按名字排序即按时间排序）。
    private static func stamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(timeZone: .gmt).format(date).replacing(":", with: "-")
    }
}

/// 一份诊断的摘要（崩溃类型、崩溃线程顶部的帧）与可导出的文本。
nonisolated struct CrashReport: Identifiable, Equatable, Sendable {
    /// 一个包同时带多种时按声明的顺序（崩溃、卡死、CPU、磁盘）取第一种，文件名与设置页那一行都按它。
    enum Kind: String, CaseIterable, Sendable {
        case crash, hang, cpu, disk

        /// 包里的诊断数组键。
        fileprivate var key: String {
            switch self {
            case .crash: "crashDiagnostics"
            case .hang: "hangDiagnostics"
            case .cpu: "cpuExceptionDiagnostics"
            case .disk: "diskWriteExceptionDiagnostics"
            }
        }

        fileprivate init?(root: [String: Any]) {
            guard let kind = Self.allCases.first(where: { !((root[$0.key] as? [Any]) ?? []).isEmpty }) else { return nil }
            self = kind
        }

        var name: String {
            switch self {
            case .crash: "崩溃"
            case .hang: "卡死"
            case .cpu: "CPU 异常"
            case .disk: "磁盘写入异常"
            }
        }

        var label: String { "上次" + name }
    }

    /// 文件名。
    let id: String
    let kind: Kind
    let date: Date
    /// 异常类型（如 EXC_BAD_ACCESS）、信号（如 SIGSEGV）、终止原因；包里没有的为 nil。
    let exception: String?
    let signal: String?
    let reason: String?
    /// "版本（构建）· 设备 · 系统"。
    let app: Dotted?
    /// 崩溃线程（没有标记就取第一条）的帧，最深的在前，至多 `topFrames` 个：二进制名与它里面的偏移（未符号化，靠 dSYM 还原）。
    let frames: [String]
    /// 原始 JSON（导出给开发者符号化）。
    let json: String

    private static let topFrames = 6

    init?(id: String, json data: Data) {
        guard let root = Self.root(of: data), let kind = Kind(root: root),
              let diagnostic = (root[kind.key] as? [[String: Any]])?.first
        else { return nil }
        let meta = diagnostic["diagnosticMetaData"] as? [String: Any] ?? [:]
        self.id = id
        self.kind = kind
        date = (root["timeStampEnd"] as? String).flatMap(DiagnosticArchive.parse) ?? .distantPast
        exception = (meta["exceptionType"] as? Int).map(Self.exceptionName)
        signal = (meta["signal"] as? Int).map(Self.signalName)
        reason = meta["terminationReason"] as? String
        app = Self.app(meta)
        frames = Self.frames(of: diagnostic["callStackTree"] as? [String: Any])
        json = String(decoding: data, as: UTF8.self)
    }

    /// 导出文本：摘要加原始 JSON。
    var diagnostics: String {
        var lines = ["CuePad \(kind.name)诊断", "时间：\(date.formatted(.iso8601))"]
        if let exception { lines.append("异常：\(exception)\(signal.map { "（\($0)）" } ?? "")") }
        if let reason { lines.append("原因：\(reason)") }
        if let app { lines.append("CuePad：\(app.visible)") }
        if !frames.isEmpty { lines.append("崩溃线程顶部：\n" + frames.map { "  \($0)" }.joined(separator: "\n")) }
        return lines.joined(separator: "\n") + "\n\n原始 JSON：\n\(json)"
    }

    fileprivate static func root(of json: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    private static func app(_ meta: [String: Any]) -> Dotted? {
        Dotted(
            (meta["appVersion"] as? String).map { version in "\(version)（\(meta["appBuildVersion"] as? String ?? "?")）" },
            meta["deviceType"] as? String, meta["osVersion"] as? String
        ).nonEmpty
    }

    /// 调用栈是树：根是最外层，沿第一个子帧走到最深处就是崩溃处。
    private static func frames(of tree: [String: Any]?) -> [String] {
        let stacks = tree?["callStacks"] as? [[String: Any]] ?? []
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var path: [String] = []
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        while let current = frame {
            let offset = (current["offsetIntoBinaryTextSegment"] as? Int).map { "+0x" + String($0, radix: 16) } ?? ""
            path.append("\(current["binaryName"] as? String ?? "?") \(offset)".trimmingCharacters(in: .whitespaces))
            frame = (current["subFrames"] as? [[String: Any]])?.first
        }
        return Array(path.reversed().prefix(topFrames))
    }

    private static func exceptionName(_ type: Int) -> String {
        [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION", 5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT",
         7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL", 9: "EXC_RPC_ALERT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD"][type] ?? "EXC_\(type)"
    }

    private static func signalName(_ signal: Int) -> String {
        [1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS",
         11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM"][signal] ?? "SIG\(signal)"
    }
}
