import CueStore
import Foundation

/// 侧栏的项目顺序：置顶的按手动顺序在前，其余按最近修改。⌘1–9、iOS 书架都按这个顺序。
nonisolated enum SidebarOrder {
    static func projects(_ projects: [Project], summaries: [ProjectSummary]) -> [Project] {
        let latest = Dictionary(uniqueKeysWithValues: summaries.compactMap { s in s.projectID.map { ($0, s.lastModifiedAt ?? .distantPast) } })
        let recent = projects.filter { !$0.isPinned }.sorted {
            let a = latest[$0.id] ?? $0.modifiedAt, b = latest[$1.id] ?? $1.modifiedAt
            return a != b ? a > b : $0.sortKey < $1.sortKey
        }
        return projects.filter(\.isPinned) + recent
    }
}
