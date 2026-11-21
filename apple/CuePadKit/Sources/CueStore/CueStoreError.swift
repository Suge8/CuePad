import Foundation

public enum CueStoreError: Error, Equatable {
  case notFound
  case changedSinceUndo
  case blankTaskContent
  case blankProjectName
  case fileTooLarge(limit: Int)
  case invalidProject
  case defaultProjectUndeletable
  case notAConflictCopy
  case attachmentHashMismatch
  case invalidAttachmentHash
  case deliveryAlreadyHanded
  case blankDeliveryContent
  case attachmentFilesNotRemoved([String])
  case strayFilesNotRemoved(removed: Int, failed: [String])
  case unsupportedSchemaVersion(Int)
  case schemaTooOld(Int)
  case invalidParent
  case taskTooDeep
  case notALeaf
  case notATask
  case previewUnreadable(String)
  case previewTooLarge(String, bytes: Int)
  case previewUnsupported(String)
  case previewTitle(String, PreviewTitleProblem)
  case readOnlyLibrary
  case noMac
  case sessionEnding
  case noSession(String)
  case alreadyStarted(String)
  case sending(String)
  case stepsRemaining(Int)
  case launching(String)
  case agentUnavailable(String)
  case noAgent(String)
  case invalidModel(String)
  case cannotStop(String)
  case sessionInUse(String)
  case cannotSpeakNow(String, String)
  case macOffline(String, String)
  case sessionUnconfirmed(String)
  case turnSourceUnconfirmed(String)
  case notStopped(String)
  case unknownModel(agent: String, model: String, choices: [String])
  case cannotChangeModel(String)
  case invalidAnswer([String])
  case memoryLineTooLong(Int)
  case staleMemoryRange
  case cueNotEnabled
  case questionEnded
  case notAChoice(String)
  case phrase(field: String, hint: String, limit: Int)
  case shots(limit: Int)
  case shotMissing(String)
}

extension CueStoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notFound: String(localized: "找不到这条记录，可能已被删除")
    case .changedSinceUndo: String(localized: "已改过，无法撤销")
    case .blankTaskContent: String(localized: "任务内容不能为空")
    case .blankProjectName: String(localized: "项目名不能为空")
    case .fileTooLarge(let limit): String(localized: "文件超过 \(limit / 1_000_000) MB，存不进来")
    case .invalidProject: String(localized: "目标项目已不存在或在回收站")
    case .defaultProjectUndeletable: String(localized: "默认项目不能删除")
    case .notAConflictCopy: String(localized: "这条不是冲突副本")
    case .attachmentHashMismatch: String(localized: "附件内容与其哈希不符")
    case .invalidAttachmentHash: String(localized: "附件的哈希格式不对")
    case .deliveryAlreadyHanded: String(localized: "这句可能已经交出，不能安全撤回")
    case .blankDeliveryContent: String(localized: "发送内容不能为空")
    case .attachmentFilesNotRemoved(let keys): String(localized: "已永久删除，但有 \(keys.count) 个附件文件没能删掉")
    case .strayFilesNotRemoved(let removed, let failed): "启动清理删掉了 \(removed) 个附件文件，\(failed.count) 处没能删：\(failed.joined(separator: "；"))"
    case .unsupportedSchemaVersion(let version): String(localized: "资料库由更新版本的 CuePad 建立（结构版本 \(version)），这个版本打不开")
    case .schemaTooOld(let version): String(localized: "资料库由更早版本的 CuePad 建立（结构版本 \(version)），这个版本不再升级它")
    case .invalidParent: String(localized: "只能挂到任务下，不能挂到自己或自己的下级下")
    case .taskTooDeep: String(localized: "任务最多 \(Card.maxTaskDepth) 级（任务 → 子任务）")
    case .notALeaf: String(localized: "有子任务的任务不直接绑会话，绑到它的某个子任务上")
    case .notATask: String(localized: "这是灵感，没有状态：要做的事另建任务，或把这条灵感接进一条任务")
    case .previewUnreadable(let path): "读不了这个文件（不存在、不是文件或没有权限）：\(path)"
    case .previewTooLarge(let path, let bytes):
      "文件 \((Double(bytes) / 1_000_000).formatted(.number.precision(.fractionLength(1)))) MB，超过单个上限 \(PreviewItem.maxBytes / 1_000_000) MB：\(path)。压缩或裁短后再发"
    case .previewUnsupported(let ext): "不支持预览\(ext.isEmpty ? "没有扩展名的文件" : " .\(ext) 文件")，可发：\(PreviewKind.supportedList)"
    case .previewTitle(let name, let problem): "\(name) 的标题\(problem.phrase)。标题要\(PreviewItem.titleRule)，如“改后：会话列表的分组标题”"
    case .readOnlyLibrary: String(localized: "资料库是只读的，写不进去")
    case .noSession(let title): "「\(title)」还没有会话"
    case .alreadyStarted(let title): "「\(title)」已有会话"
    case .stepsRemaining(let count): "还有 \(count) 个子任务没完成"
    case .sending(let title): "「\(title)」上一句的送达尚未确认：先查看会话，可能已经执行，避免重复操作"
    case .launching(let title): "「\(title)」的会话启动结果尚未确认：先查看已有会话，避免重复创建"
    case .noMac: String(localized: "还没有 Mac 打开过 CuePad，开不了会话：先在 Mac 上打开它")
    case .agentUnavailable(let reason): "开不了会话：\(reason)"
    case .noAgent(let why): "开会话的那台 Mac 上没有能用的 Agent（\(why)）"
    case .invalidModel(let agent): "\(agent) 的 model 写成 provider/id：提供方与模型 id 用 / 隔开（Claude Code、Codex 只写 id）"
    case .unknownModel(let agent, let model, _): "\(agent) 没有 \(model)"
    case .cannotChangeModel(let title): "会话「\(title)」换不了模型（它的记录还没到）"
    case .cannotStop(let title): "会话「\(title)」现在停不了：没在跑一轮，或在等回答"
    case .cannotSpeakNow(let title, let why): "会话「\(title)」\(why)：没说出去"
    case .macOffline(let title, let mac):
      "会话「\(title)」所在的「\(mac)」此刻不在线（睡着、关机或 CuePad 没开）：这次没有发出，那台开机前对它做什么都送不到"
    case .sessionUnconfirmed(let title):
      "会话「\(title)」此刻在做什么还没确认（它所在的 Mac 这次开机后还没报过它，或报的状态这个版本不认识）：这次没有发出"
    case .turnSourceUnconfirmed(let title): "会话「\(title)」正在跑的这一轮查不到是谁开的：现在说会打断它，没说出去"
    case .sessionEnding: String(localized: "会话正在休眠，确认结果后才能关联或发送")
    case .sessionInUse(let title): "会话「\(title)」还在用（没做完的事绑着它，或有话正送进去），没结束"
    case .notStopped(let title): "会话「\(title)」没停着（在跑或已结束）"
    case .invalidAnswer(let options): "会话在等提问的回答，答案要是其中之一（原文或从 1 起的序号）：\(options.joined(separator: " / "))"
    case .memoryLineTooLong(let limit): String(localized: "一条记忆最多 \(limit) 字节（UTF-8）")
    case .staleMemoryRange: "记忆区间的输入已变化，请读取新视图后重新整理或展开"
    case .cueNotEnabled: "Cue 没有启用"
    case .questionEnded: String(localized: "这条提问已经结束了")
    case .notAChoice(let answer): String(localized: "「\(answer)」不是这条提问的选项")
    case .phrase(let field, let hint, let limit): "\(field)：\(hint)，一行、不超过 \(limit) 字"
    case .shots(let limit): "点名的图至多 \(limit) 张、不能重复"
    case .shotMissing(let id): "发到手机的里没有 \(id)"
    }
  }
}
