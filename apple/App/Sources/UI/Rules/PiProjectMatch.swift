import Foundation

/// Pi 会话按工作目录归入项目：项目绑定的目录是会话目录本身或其祖先（按路径分段比较，
/// `/a/proj` 不会误配 `/a/project`）；多个项目命中时取最深的目录。
nonisolated enum PiProjectMatch {
    static func project(forDirectory directory: String, in directories: [UUID: String]) -> UUID? {
        let target = segments(directory)
        return directories
            .map { (id: $0.key, segments: segments($0.value)) }
            .filter { !$0.segments.isEmpty && target.starts(with: $0.segments) }
            .max { $0.segments.count < $1.segments.count }?
            .id
    }

    private static func segments(_ path: String) -> [Substring] {
        path.split(separator: "/")
    }
}
