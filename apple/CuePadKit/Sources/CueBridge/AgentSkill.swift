#if os(macOS)
import CueStore
import Foundation

/// 技能目录里一个技能的正文文件名。旧版 CuePad 还往用户目录写过自己的 `cuepad` 技能，现在只认出来迁走（`AgentIntegration.legacySkillKinds`）。
enum AgentSkill {
    static let fileName = "SKILL.md"
    static let legacyName = "cuepad"
    /// 旧版写的那份末尾的标记行：`<!-- 由 CuePad 写入（接入：pi, claudeCode），升级时整文件覆盖 -->`，用它区分同名的用户文件
    static let ownershipMarker = "<!-- 由 CuePad 写入"
    private static let kindsPrefix = "（接入："

    /// 不是 CuePad 写的为 nil；标记行里不认识的家略去。
    static func kinds(in text: String) -> Set<AgentKind>? {
        guard let marker = text.range(of: ownershipMarker) else { return nil }
        let rest = text[marker.upperBound...]
        guard rest.hasPrefix(kindsPrefix), let end = rest.firstIndex(of: "）") else { return [] }
        return Set(rest[rest.index(rest.startIndex, offsetBy: kindsPrefix.count)..<end].split(separator: ", ").compactMap { AgentKind(rawValue: String($0)) })
    }
}
#endif
