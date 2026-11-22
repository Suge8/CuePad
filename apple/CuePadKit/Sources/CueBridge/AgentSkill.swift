#if os(macOS)
import CueStore
import Foundation

enum AgentSkill {
    static let fileName = "SKILL.md"
    static let legacyName = "cuepad"
    static let ownershipMarker = "<!-- 由 CuePad 写入"
    private static let kindsPrefix = "（接入："

    static func kinds(in text: String) -> Set<AgentKind>? {
        guard let marker = text.range(of: ownershipMarker) else { return nil }
        let rest = text[marker.upperBound...]
        guard rest.hasPrefix(kindsPrefix), let end = rest.firstIndex(of: "）") else { return [] }
        return Set(rest[rest.index(rest.startIndex, offsetBy: kindsPrefix.count)..<end].split(separator: ", ").compactMap { AgentKind(rawValue: String($0)) })
    }
}
#endif
