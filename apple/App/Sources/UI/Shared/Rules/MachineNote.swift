import CueStore
import Foundation

/// FireCode 的三种信封照它自己给终端的一行投影（FireCode 的 tools/machine.ts；正文分节词两种语言都认，会话可能跨过换语言）：
struct MachineNote: Equatable {
    var who: String
    var line: String
    var failed = false
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

    private static let sections: Set = ["回复：", "错误：", "最终回复：", "顾问意见：", "Reply:", "Error:", "Final reply:", "Advisor advice:"]
    private static let errorSections: Set = ["错误：", "Error:"]
    private static let elapsed = ["耗时：", "Elapsed: "]
}
