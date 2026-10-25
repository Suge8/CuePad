import CueStore
import Foundation

/// 机器消息的一块信封在会话页卡片上的样子（`MachineCards`）：谁发来的、一行交回了什么、点开看的全文。
/// FireCode 的三种信封照它自己给终端的一行投影（FireCode 的 tools/machine.ts；正文分节词两种语言都认，会话可能跨过换语言）：
/// 子代理事件写子代理名与结果首句（失败取"错误"那一节、标胭脂；没有分节的通知、被中断写标题），审查写结论那行标题，观察员写它说的首句。
/// 别的信封写信封名与正文首句；不是信封的（别的扩展投进来的纯文字）写"扩展"。
struct MachineNote: Equatable {
    var who: String
    var line: String
    var failed = false
    /// 点开看的全文（Markdown）；与那一行一样时没有，卡片点不开
    var detail: String
    var fromFireCode: Bool

    init(_ envelope: PiEnvelope) {
        let body = envelope.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = body.components(separatedBy: "\n")
        let heading = lines.first ?? ""
        let rest = Array(lines.dropFirst())
        let afterHeading = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        fromFireCode = envelope.name.hasPrefix("firecode_")
        switch envelope.name {
        case "firecode_master_event":
            let errorAt = rest.firstIndex { Self.errorSections.contains($0.trimmingCharacters(in: .whitespaces)) }
            let marker = errorAt ?? rest.firstIndex { Self.sections.contains($0.trimmingCharacters(in: .whitespaces)) }
            failed = errorAt != nil
            let content = marker.map { rest[($0 + 1)...].filter { line in !Self.elapsed.contains { line.hasPrefix($0) } }.joined(separator: "\n") }
            who = marker == nil ? String(localized: "子代理") : String(localized: "子代理 \(String(heading.prefix { $0 != " " }))")
            line = PiProgress.firstSentence(content) ?? heading
            detail = afterHeading
        case "firecode_review":
            who = String(localized: "审查")
            line = heading
            detail = afterHeading
        case "firecode_watcher":
            who = String(localized: "观察员")
            line = PiProgress.firstSentence(afterHeading) ?? heading
            detail = afterHeading
        default:
            who = envelope.name.isEmpty ? String(localized: "扩展") : envelope.name
            line = PiProgress.firstSentence(body) ?? ""
            detail = body
        }
        if detail == line { detail = "" }
    }

    /// FireCode 子代理事件正文的分节标记（独占一行）：回复、错误、最终回复、顾问意见
    private static let sections: Set = ["回复：", "错误：", "最终回复：", "顾问意见：", "Reply:", "Error:", "Final reply:", "Advisor advice:"]
    private static let errorSections: Set = ["错误：", "Error:"]
    /// 用时那一行（"耗时：本次运行 20 秒 · 当前任务 22 秒"）：不是结果
    private static let elapsed = ["耗时：", "Elapsed: "]
}
