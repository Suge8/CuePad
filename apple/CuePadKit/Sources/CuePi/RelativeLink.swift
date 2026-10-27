#if os(macOS)
import Foundation

/// CuePad 建的符号链接都是相对的（Claude Code 的技能链接、各家全局规则的链接）：整个家目录搬走、换了挂载点也照样指得到。
enum RelativeLink {
    /// 在 `link` 建一个指向 `target` 的相对链接（上层目录没有就建）。
    static func make(at link: URL, to target: URL) throws {
        let parent = link.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: relative(from: parent.realPath, to: target.realPath))
    }

    /// `link` 是符号链接（失效的也算）。
    static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// `link` 是指向 `target` 的符号链接（按解析后的真实路径比）。
    static func points(_ link: URL, to target: URL) -> Bool {
        isLink(link) && link.realPath.standardizedFileURL == target.realPath.standardizedFileURL
    }

    private static func relative(from directory: URL, to target: URL) -> String {
        let from = directory.standardizedFileURL.pathComponents, to = target.standardizedFileURL.pathComponents
        let shared = zip(from, to).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: from.count - shared) + to.dropFirst(shared)).joined(separator: "/")
    }
}
#endif
