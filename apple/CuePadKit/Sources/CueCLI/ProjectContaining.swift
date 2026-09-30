import CueStore

// 临时：CueStore 即将提供同签名的 `project(containing:)`（数据 Worker 定规则），落地后删除本文件。
// 预期规则：绑定目录等于或包含给定目录的未删除项目；多个时取绑定目录最深的。
extension CueStore {
  func project(containing directory: String) throws -> Project? {
    let live = Dictionary(uniqueKeysWithValues: try projects().map { ($0.id, $0) })
    let matches = try projectDirectories().compactMap { id, bound -> (project: Project, depth: Int)? in
      let prefix = bound.hasSuffix("/") ? bound : bound + "/"
      guard let project = live[id], directory == bound || directory.hasPrefix(prefix) else { return nil }
      return (project, bound.count)
    }
    return matches.max { $0.depth < $1.depth }?.project
  }
}
