import CueStore
import SwiftUI

extension View {
    /// 那台 Mac 上这几份文件同步来的正文（路径 → 正文，`LibraryFileText`）：文件页、全局规则的预览、合并稿都读它，正文变了跟着重读。
    func observingLibraryTexts(_ paths: [String], in library: AgentLibrary?, into texts: Binding<[String: String]?>) -> some View {
        modifier(LibraryTextsReading(paths: paths, host: library?.hostID, texts: texts))
    }
}

private struct LibraryTextsReading: ViewModifier {
    let paths: [String]
    let host: String?
    @Binding var texts: [String: String]?
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content.observing(services.store, id: [host ?? ""] + paths, into: $texts, onError: workspace.fail) { [host, paths] store in
            guard let host else { return [:] }
            return try store.agentLibraryTexts(host: host, paths: paths)
        }
    }
}

extension AgentLibrary {
    /// 快照里这一份此刻的正文：同步来的那条的哈希对上快照才算到了。外层 nil 是还在路上（快照先到了，或还没读），内层 nil 是还没有这个文件。
    func arrived(_ file: LibraryFile, in texts: [String: String]?) -> String?? {
        guard let entry = self.file(file) else { return nil }
        return Self.arrived(entry.textPath, hash: entry.hash, in: texts)
    }

    /// 文件页要读的几份正文：这一份，规则再加要并进来的各份（合并稿与预览照它们算）。
    func textPaths(for file: LibraryFile) -> [String] {
        (self.file(file).map { [$0.textPath] } ?? []) + (merge(for: file)?.sources.map(\.path) ?? [])
    }

    /// 这份规则另写了一份、可以合并的那件（技能没有）。
    func merge(for file: LibraryFile) -> LibraryTidy? {
        if case .instruction(let kind) = file { merge(into: kind) } else { nil }
    }

    /// 同名的技能：它是几份里的一份时的那件去重。
    func duplicate(for file: LibraryFile) -> LibraryTidy? {
        if case .skill(let path) = file { duplicate(of: path) } else { nil }
    }

    /// 文件名（文件页顶次要一行的头）。
    func fileName(_ file: LibraryFile) -> String? { self.file(file).map { URL(filePath: $0.textPath).lastPathComponent } }

    /// 文件页顶次要一行：文件名、存着没有（还没有这个文件时写还没有：写了就建出来）。
    func detail(of file: LibraryFile, draft: FileDraft?) -> Dotted {
        Dotted(fileName(file), draft?.shownState ?? (self.file(file)?.hash == nil ? String(localized: "还没有") : nil))
    }

    static func arrived(_ path: String, hash: String?, in texts: [String: String]?) -> String?? {
        guard let hash else { return .some(nil) }
        guard let text = texts?[path], LibraryEdit.base(of: text) == hash else { return nil }
        return .some(text)
    }
}
