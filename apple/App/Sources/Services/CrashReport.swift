import Foundation

/// 一个 MetricKit 包里每种诊断都是数组，同一个包可以带好几次（崩溃加卡死、两次卡死）：每一次各是一份（`reports(file:json:)`）。
/// MetricKit 的 JSON 里时间是交来时这台设备本地时区的 "yyyy-MM-dd HH:mm:ss"、不带时区（实测，文档没写）：按本地时区读。
nonisolated struct CrashReport: Identifiable, Equatable, Sendable {
    /// 一个包里的几份按声明的顺序（崩溃、卡死、CPU、磁盘）排，存档文件名按排第一的那份；`freeze` 是本机记下的主线程卡住。
    enum Kind: String, CaseIterable, Sendable {
        case crash, hang, cpu, disk, freeze

        fileprivate var key: String {
            switch self {
            case .crash: "crashDiagnostics"
            case .hang: "hangDiagnostics"
            case .cpu: "cpuExceptionDiagnostics"
            case .disk: "diskWriteExceptionDiagnostics"
            case .freeze: FreezeNote.File.key
            }
        }

        var name: String {
            switch self {
            case .crash: String(localized: "崩溃")
            case .hang: String(localized: "卡死")
            case .cpu: String(localized: "CPU 异常")
            case .disk: String(localized: "磁盘写入异常")
            case .freeze: String(localized: "主线程卡住")
            }
        }

        var label: LocalizedStringResource {
            switch self {
            case .crash: "上次崩溃"
            case .hang: "上次卡死"
            case .cpu: "上次 CPU 异常"
            case .disk: "上次磁盘写入异常"
            case .freeze: "上次卡住"
            }
        }
    }

    /// 二进制名在 MetricKit 没给名字时按 UUID 在这台设备已载入的库里认；偏移未符号化，靠 dSYM 还原。
    struct Frame: Equatable, Sendable {
        let binary: String
        let offset: Int?
        /// CuePad 自己的代码（不是系统库）：符号化要找的就是这些。
        let own: Bool

        var text: String {
            let place = offset.map { "\(binary) +0x\(String($0, radix: 16))" } ?? binary
            return own ? "\(place)  ← CuePad" : place
        }
    }

    let id: String
    let file: String
    let kind: Kind
    let date: Date
    /// 异常类型（如 EXC_BAD_ACCESS）、信号（如 SIGSEGV）、原文的终止原因；包里没有的为 nil。
    let exception: String?
    let signal: String?
    let reason: String?
    /// 并成同一种时比的原因：异常与终止码（有终止码时只认码与看门狗事件；没有时是原文，数字抹掉：CPU 用时、地址每次都不同）。
    let cause: String
    let explanation: String?
    /// "版本（构建）· 设备 · 系统"。
    let app: Dotted?
    /// 崩溃线程（没有标记就取第一条）自顶向下的前 `topFrames` 帧；更深处 CuePad 自己的帧再补至多 `ownFrames` 个（顶上常全是系统库）。
    let frames: [Frame]
    let trail: [String]

    static let topFrames = 8
    static let ownFrames = 4

    static func reports(file: String, json data: Data) -> [CrashReport] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        if root[FreezeNote.File.key] != nil {
            return (try? JSONDecoder.diagnostics.decode(FreezeNote.File.self, from: data)).map { [CrashReport(file: file, freeze: $0.cuepadFreeze)] } ?? []
        }
        let end = root["timeStampEnd"] as? String
        let diagnostics = Kind.allCases.flatMap { kind in ((root[kind.key] as? [[String: Any]]) ?? []).map { (kind, $0) } }
        return diagnostics.enumerated().map { index, item in
            CrashReport(id: "\(file)#\(index)", file: file, kind: item.0, end: end, diagnostic: item.1)
        }
    }

    private init(id: String, file: String, kind: Kind, end: String?, diagnostic: [String: Any]) {
        let meta = diagnostic["diagnosticMetaData"] as? [String: Any] ?? [:]
        self.id = id
        self.file = file
        self.kind = kind
        date = end.flatMap { try? Self.metricKitTime.parse($0) } ?? .distantPast
        exception = (meta["exceptionType"] as? Int).map(Self.exceptionName)
        signal = (meta["signal"] as? Int).map(Self.signalName)
        let objectiveC = meta["objectiveCexceptionReason"] as? [String: Any] ?? [:]
        let exceptionReason = [objectiveC["exceptionName"] as? String, objectiveC["composedMessage"] as? String]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ": ")
        let termination = meta["terminationReason"] as? String ?? ""
        let reasons = [exceptionReason, termination].filter { !$0.isEmpty }
        reason = reasons.isEmpty ? nil : reasons.joined(separator: "\n")
        cause = [exceptionReason.replacing(/\d+/, with: "#"), Termination.key(termination)].joined(separator: "|")
        explanation = Termination.explain(termination)
        app = Self.app(
            version: (meta["appVersion"] as? String).map { "\($0)（\(meta["appBuildVersion"] as? String ?? "?")）" },
            device: meta["deviceType"] as? String, os: meta["osVersion"] as? String)
        frames = Self.frames(of: diagnostic["callStackTree"] as? [String: Any])
        trail = []
    }

    private init(file: String, freeze note: FreezeNote) {
        id = file
        self.file = file
        kind = .freeze
        date = note.start
        exception = nil
        signal = nil
        reason = note.seconds.map { String(localized: "主线程 \(Int($0.rounded())) 秒没回到事件循环，之后恢复了") }
            ?? String(localized: "主线程卡住，没等到恢复 App 就被结束了")
        cause = ""
        explanation = nil
        app = Self.app(version: note.version, device: note.device, os: note.os)
        frames = []
        trail = [String(localized: "所在页：\(note.page)")] + note.actions
    }

    var shownDate: String { date.formatted(Self.metricKitTime.timeZone(separator: .colon)) }

    private static var metricKitTime: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(dateTimeSeparator: .space, timeZone: .current).year().month().day().time(includingFractionalSeconds: false)
    }

    private static func app(version: String?, device: String?, os: String?) -> Dotted? { Dotted(version, device, os).nonEmpty }

    /// 调用栈是树：根是崩溃处，子帧依次是调用它的帧。
    private static func frames(of tree: [String: Any]?) -> [Frame] {
        let stacks = tree?["callStacks"] as? [[String: Any]] ?? []
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var top: [Frame] = [], deeper: [Frame] = []
        var node = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        while let current = node, deeper.count < ownFrames {
            let frame = LoadedImages.frame(
                name: current["binaryName"] as? String, uuid: current["binaryUUID"] as? String, offset: current["offsetIntoBinaryTextSegment"] as? Int)
            if top.count < topFrames { top.append(frame) } else if frame.own { deeper.append(frame) }
            node = (current["subFrames"] as? [[String: Any]])?.first
        }
        return top + deeper
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

/// 系统结束进程时终止原因里的终止码与看门狗事件（"code:0x8BADF00D … WatchdogEvent: process-exit"）的人话。
/// 码见 Apple 的 "Understanding the exception types in a crash report"。xc.sh diag 解析系统的崩溃报告时照抄这几句人话（device_diag.py 开头的表）：改这里就改那里。
nonisolated enum Termination {
    static func key(_ reason: String) -> String {
        guard let code = code(reason) else { return reason.replacing(/\d+/, with: "#") }
        return [code, event(reason) ?? ""].joined(separator: " ")
    }

    static func explain(_ reason: String) -> String? {
        guard let code = code(reason) else { return nil }
        let event = event(reason)
        switch code {
        case "0X8BADF00D":
            let base = String(localized: "看门狗：主线程太久没响应，被系统结束")
            return switch event {
            case "process-exit": base + String(localized: "（系统要结束 App 时 5 秒内没退出：多半主线程在那之前就卡住了，比如从后台划掉卡住的 App）")
            case "scene-update": base + String(localized: "（切前后台、场景更新时没按时答复）")
            case "scene-create": base + String(localized: "（建窗口时没按时答复）")
            case "process-launch": base + String(localized: "（启动太久）")
            case let event?: base + "（\(event)）"
            case nil: base
            }
        case "0XDEAD10CC": return String(localized: "进后台挂起时还握着共享的文件锁（如 SQLite），被系统结束")
        case "0XC00010FF": return String(localized: "设备过热，被系统结束")
        case "0XDEADFA11": return String(localized: "用户强制退出")
        case "0XBAADCA11": return String(localized: "收到 VoIP 推送后没向系统报来电，被系统结束")
        default: return nil
        }
    }

    private static func code(_ reason: String) -> String? { reason.firstMatch(of: /code:(0x[0-9A-Fa-f]+)/)?.1.uppercased() }
    private static func event(_ reason: String) -> String? { reason.firstMatch(of: /WatchdogEvent: ([\w-]+)/).map { String($0.1) } }
}
