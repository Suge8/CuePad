import Foundation

/// 一份诊断的要点：类型、时间、版本与设备、异常与终止原因（看门狗那类附人话）、崩溃线程（卡死是主线程）的帧。
/// MetricKit 的 JSON 里时间是交来时这台设备本地时区的 "yyyy-MM-dd HH:mm:ss"、不带时区（实测，文档没写）：按本地时区读。
nonisolated struct CrashReport: Identifiable, Equatable, Sendable {
    /// 一个包同时带多种时按声明的顺序（崩溃、卡死、CPU、磁盘）取第一种，文件名与设置页那一行都按它；`freeze` 是本机记下的主线程卡住。
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

        fileprivate init?(root: [String: Any]) {
            guard let kind = Self.allCases.first(where: { root[$0.key] is [String: Any] || !((root[$0.key] as? [Any]) ?? []).isEmpty }) else { return nil }
            self = kind
        }

        /// 导出的摘要里的叫法
        var name: String {
            switch self {
            case .crash: String(localized: "崩溃")
            case .hang: String(localized: "卡死")
            case .cpu: String(localized: "CPU 异常")
            case .disk: String(localized: "磁盘写入异常")
            case .freeze: String(localized: "主线程卡住")
            }
        }

        /// 设置里那一行的名字
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

    /// 栈里的一帧：二进制名（MetricKit 没给名字时按 UUID 在这台设备已载入的库里认）与它里面的偏移（未符号化，靠 dSYM 还原）。
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
    let kind: Kind
    let date: Date
    /// 异常类型（如 EXC_BAD_ACCESS）、信号（如 SIGSEGV）、原文的终止原因；包里没有的为 nil。
    let exception: String?
    let signal: String?
    let reason: String?
    /// 终止原因的人话（看门狗、过热这类有名的终止码）。
    let explanation: String?
    /// "版本（构建）· 设备 · 系统"。
    let app: Dotted?
    /// 崩溃线程（没有标记就取第一条）自顶向下的前 `topFrames` 帧；更深处 CuePad 自己的帧再补至多 `ownFrames` 个（顶上常全是系统库）。
    let frames: [Frame]
    /// 主线程卡住时在哪一页、之前做了什么（本机记下的才有）。
    let trail: [String]

    static let topFrames = 8
    static let ownFrames = 4

    init?(id: String, json data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let kind = Kind(root: root) else { return nil }
        if kind == .freeze {
            guard let note = try? JSONDecoder.diagnostics.decode(FreezeNote.File.self, from: data).cuepadFreeze else { return nil }
            self.init(id: id, freeze: note)
            return
        }
        guard let diagnostic = (root[kind.key] as? [[String: Any]])?.first else { return nil }
        self.init(id: id, kind: kind, end: root["timeStampEnd"] as? String, diagnostic: diagnostic)
    }

    private init(id: String, kind: Kind, end: String?, diagnostic: [String: Any]) {
        let meta = diagnostic["diagnosticMetaData"] as? [String: Any] ?? [:]
        self.id = id
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
        explanation = Termination.explain(termination)
        app = Self.app(
            version: (meta["appVersion"] as? String).map { "\($0)（\(meta["appBuildVersion"] as? String ?? "?")）" },
            device: meta["deviceType"] as? String, os: meta["osVersion"] as? String)
        frames = Self.frames(of: diagnostic["callStackTree"] as? [String: Any])
        trail = []
    }

    private init(id: String, freeze note: FreezeNote) {
        self.id = id
        kind = .freeze
        date = note.start
        exception = nil
        signal = nil
        reason = note.seconds.map { String(localized: "主线程 \(Int($0.rounded())) 秒没回到事件循环，之后恢复了") }
            ?? String(localized: "主线程卡住，没等到恢复 App 就被结束了")
        explanation = nil
        app = Self.app(version: note.version, device: note.device, os: note.os)
        frames = []
        trail = [String(localized: "所在页：\(note.page)")] + note.actions
    }

    /// 给人看的时间：本地时区，带时差（"2026-11-06 12:02:47+08:00"）。
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
/// 码见 Apple 的 "Understanding the exception types in a crash report"。
nonisolated enum Termination {
    static func explain(_ reason: String) -> String? {
        guard let code = reason.firstMatch(of: /code:(0x[0-9A-Fa-f]+)/)?.1.uppercased() else { return nil }
        let event = reason.firstMatch(of: /WatchdogEvent: ([\w-]+)/).map { String($0.1) }
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
}
