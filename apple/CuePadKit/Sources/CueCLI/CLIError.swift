import CueStore
import Foundation

/// 命令行的失败：`kind.rawValue` 是 `--json` 时 stderr 里的稳定错误码；用法错误退出码 2，其余 1。
struct CLIError: Error {
  enum Kind: String {
    case usage, notFound = "not_found", ambiguous, invalid, noLibrary = "no_library", store
  }

  let kind: Kind
  let message: String

  var exitCode: Int32 { kind == .usage ? 2 : 1 }

  static func usage(_ message: String) -> CLIError { CLIError(kind: .usage, message: message) }
  static func notFound(_ message: String) -> CLIError { CLIError(kind: .notFound, message: message) }
  static func invalid(_ message: String) -> CLIError { CLIError(kind: .invalid, message: message) }

  /// Store 抛出的错误翻成可操作的说明。
  init(_ error: any Error) {
    switch error {
    case let error as CLIError:
      self = error
    case CueStoreError.notFound:
      self = .notFound("对象不存在或已被永久删除（move 的 --after 须是目标项目里的卡片）")
    case CueStoreError.blankTaskContent:
      self = .invalid("任务内容不能为空")
    case CueStoreError.invalidProject:
      self = .invalid("项目不存在或在回收站里（cuepad project list 查看可用项目）")
    case CueStoreError.notAConflictCopy:
      self = .invalid("该卡片不是冲突副本（cuepad conflicts list 查看副本 id）")
    default:
      self = CLIError(kind: .store, message: "\(error)")
    }
  }

  init(kind: Kind, message: String) {
    self.kind = kind
    self.message = message
  }
}
