import Foundation

public enum CueStoreError: Error, Equatable {
  case notFound
  case blankTaskContent
  case blankProjectName
  /// 单个文件超过上限（`AttachmentFiles.maxBytes`）。
  case fileTooLarge(limit: Int)
  /// 卡片或任务只能归属存在且未在回收站的项目。
  case invalidProject
  /// 默认项目不能删除（`Project.defaultID`）。
  case defaultProjectUndeletable
  /// `resolveConflict` 的目标不是冲突副本。
  case notAConflictCopy
  /// 下载的附件内容与其哈希不符。
  case attachmentHashMismatch
  /// 附件记录声明的哈希格式不对（不是 SHA-256 十六进制）。
  case invalidAttachmentHash
  case blankDeliveryContent
  /// 永久删除已完成，但这些键的附件文件没能删掉（记录与文件保留）。
  case attachmentFilesNotRemoved([String])
  /// 库文件是更新版本建的，不打开。
  case unsupportedSchemaVersion(Int)
  /// 库文件是更早版本建的，这个版本不再升级旧结构，不打开。
  case schemaTooOld(Int)
  /// 只能挂到存在的任务下，不能挂到自己或自己的下级下。
  case invalidParent
  /// 挂上去后任务会超过 `Card.maxTaskDepth` 级。
  case taskTooDeep
  /// 只能绑在叶子（没有子任务的任务）上；有子任务的任务绑到它的某个子任务上。
  case notALeaf
  /// 要的是任务、给的是灵感：灵感没有状态，不能改状态、开工、绑会话，也不能当别的灵感接进去的落点。
  case notATask
  /// 预览的文件不存在、读不了或不是文件（参数是它的路径）。
  case previewUnreadable(String)
  /// 预览的文件超过 `PiPreview.maxBytes`（参数是它的路径）。
  case previewTooLarge(String, limit: Int)
  /// 预览不支持这种文件（参数是扩展名，空为没有扩展名）。
  case previewUnsupported(String)
  /// 发到手机的一份没有标题、标题不止一行、宽过 `limit` 或与同批重复（参数是文件名）。
  case previewTitle(String, limit: Int)
  /// 资料库文件只能读（多半是 Agent 的沙箱挡住了写入）。
  case readOnlyLibrary
  /// 手机上要开新会话，而一台 Mac 都还没打开过 CuePad（没写过 `macAgents`、也没有目录绑定）。
  case noMac
  // 以下除 memoryLineTooLong、questionEnded、notAChoice 外只有 Cue 经 MCP 会碰到：文案直接写给 Cue，说清该怎么办（Cue 的工具原样转给它），不进界面文字的目录；
  // 上面预览那几条同理，只有 Agent 经命令行会碰到。
  /// 叶子还没有会话（参数是叶子标题）。
  case noSession(String)
  /// 叶子已有会话，开工无事可做：话在会话里说（参数是叶子标题）。
  case alreadyStarted(String)
  /// 叶子还没绑会话，它的话正送进上一步的会话（参数是叶子标题）。
  case sending(String)
  /// 有子任务的任务还有这么多子任务没完成，不能整件完成。
  case stepsRemaining(Int)
  /// 正在为叶子开新会话，开好前不再开（参数是叶子标题）。
  case launching(String)
  /// 开会话的那台 Mac 记着这家不能用（参数是"Agent 名 原因"）。
  case agentUnavailable(String)
  /// 开会话的那台 Mac 一家能用的都没有（参数是 `MacAgents.whyNone`）。
  case noAgent(String)
  /// model 不是这家的写法（参数是 Agent 名）。
  case invalidModel(String)
  /// 会话此刻停不了这一轮（参数是会话名）。
  case cannotStop(String)
  /// 会话还在用：没做完的事绑着它，或有话正送进去（参数是会话名）。
  case sessionInUse(String)
  /// 会话在跑，Cue 这会儿说不了（参数是会话名与原因）：会打断他发起的那一轮，或停不下这一轮（`PiSessionState.speakBlocked`）。
  case cannotSpeakNow(String, String)
  /// 会话不能从 CuePad 结束（参数是会话名）。
  case cannotEnd(String)
  /// 会话没停着，没有可留给他回的停下（参数是会话名）。
  case notStopped(String)
  /// 会话换不了模型（参数是会话名）。
  case cannotChangeModel(String)
  /// 答案不在可选的里面（参数是可选的答案）。
  case invalidAnswer([String])
  /// 一条记忆超过 `CueMemoryLine.maxBytes` 字节。
  case memoryLineTooLong(Int)
  /// 摘要的区间不是记忆里对齐的 2 的幂区间。
  case invalidSummaryRange
  /// Cue 没启用（没有 `cueProfile`、停用了或没选运行在哪台 Mac）。
  case cueNotEnabled
  /// 这条提问已经结束了（答了或撤回了），或放不回（不是你开口收起的）。
  case questionEnded
  /// 回答不是这条提问的选项（参数是那句话）：不选的话在对话里直接说。
  case notAChoice(String)
  /// Cue 写的短语（提问的动作、规矩，图看什么）缺了、超长或不止一行（`CueAsking`、`CueShot.checked`）。
  case phrase(field: String, hint: String, limit: Int)
  /// 点名的图多于 `limit` 张或有重复（`CueShot.checked`）。
  case shots(limit: Int)
  /// 点名的那一份不在发到手机的里（参数是 id）。
  case shotMissing(String)
}

extension CueStoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notFound: String(localized: "找不到这条记录，可能已被删除")
    case .blankTaskContent: String(localized: "任务内容不能为空")
    case .blankProjectName: String(localized: "项目名不能为空")
    case .fileTooLarge(let limit): String(localized: "文件超过 \(limit / 1_000_000) MB，存不进来")
    case .invalidProject: String(localized: "目标项目已不存在或在回收站")
    case .defaultProjectUndeletable: String(localized: "默认项目不能删除")
    case .notAConflictCopy: String(localized: "这条不是冲突副本")
    case .attachmentHashMismatch: String(localized: "附件内容与其哈希不符")
    case .invalidAttachmentHash: String(localized: "附件的哈希格式不对")
    case .blankDeliveryContent: String(localized: "发送内容不能为空")
    case .attachmentFilesNotRemoved(let keys): String(localized: "已永久删除，但有 \(keys.count) 个附件文件没能删掉")
    case .unsupportedSchemaVersion(let version): String(localized: "资料库由更新版本的 CuePad 建立（结构版本 \(version)），这个版本打不开")
    case .schemaTooOld(let version): String(localized: "资料库由更早版本的 CuePad 建立（结构版本 \(version)），这个版本不再升级它")
    case .invalidParent: String(localized: "只能挂到任务下，不能挂到自己或自己的下级下")
    case .taskTooDeep: String(localized: "任务最多 \(Card.maxTaskDepth) 级（任务 → 子任务）")
    case .notALeaf: String(localized: "有子任务的任务不直接绑会话，绑到它的某个子任务上")
    case .notATask: String(localized: "这是灵感，没有状态：要做的事另建任务，或把这条灵感接进一条任务")
    case .previewUnreadable(let path): "读不了这个文件（不存在、不是文件或没有权限）：\(path)"
    case .previewTooLarge(let path, let limit): "文件太大，单个不超过 \(limit / 1_000_000) MB：\(path)"
    case .previewUnsupported(let ext): "不支持预览\(ext.isEmpty ? "没有扩展名的文件" : " .\(ext) 文件")，可发：\(PiPreviewKind.supportedList)"
    case .previewTitle(let name, let limit):
      "\(name) 的标题要一句说清这份是什么、看哪里，同一次发的各不相同（一行、宽不过 \(limit)，约 \(limit / 2) 个汉字，用和用户对话的语言），如“深色：会话列表的分组标题”"
    case .readOnlyLibrary: String(localized: "资料库是只读的，写不进去")
    case .noSession(let title): "「\(title)」还没有会话：先 start 开工，它的正文会作为第一句"
    case .alreadyStarted(let title): "「\(title)」已有会话：用 say 对它说话"
    case .stepsRemaining(let count): "还有 \(count) 个子任务没完成：先把它们做完并 done（不用做的，evidence 写明为什么不用做）"
    case .sending(let title): "「\(title)」的话正送进上一步的会话：送到后这一步就绑上它，再用 say 说话（peek 看状态）"
    case .launching(let title): "正在为「\(title)」开会话：等它开好（peek 看状态），再用 say 说话"
    case .noMac: String(localized: "还没有 Mac 打开过 CuePad，开不了会话：先在 Mac 上打开它")
    case .agentUnavailable(let reason): "开不了会话：\(reason)。start 的 agent 换成系统提示里列着的那几家"
    case .noAgent(let why): "开会话的那台 Mac 上没有能用的 Agent（\(why)）：用 tell 告诉用户"
    case .invalidModel(let agent): "\(agent) 的 model 写成 provider/id：提供方与模型 id 用 / 隔开（Claude Code、Codex 只写 id）"
    case .cannotChangeModel(let title): "会话「\(title)」换不了模型（这一家在终端里开的会话不能从 CuePad 换）：用 start 带 fresh:true 和 model 开新会话"
    case .cannotStop(let title): "会话「\(title)」现在停不了：没在跑一轮、在等回答，或它在终端里开、不能从 CuePad 停止"
    case .cannotSpeakNow(let title, let why): "会话「\(title)」\(why)：没说出去。等它歇下（会叫醒你）再说"
    case .sessionInUse(let title): "会话「\(title)」还在用（没做完的事绑着它，或有话正送进去），没结束：那件事做完时 done 那件事"
    case .cannotEnd(let title): "会话「\(title)」不能从 CuePad 结束（终端里开的这类）：要收掉就 tell 他在终端里退出"
    case .notStopped(let title): "会话「\(title)」没停着（在跑、被打断或已结束）：留给他回只用在它歇着、在等回答或出错时"
    case .invalidAnswer(let options): "会话在等提问的回答，答案要是其中之一（原文或从 1 起的序号）：\(options.joined(separator: " / "))"
    case .memoryLineTooLong(let limit): String(localized: "一条记忆最多 \(limit) 字节（UTF-8）")
    case .invalidSummaryRange: "摘要的区间要是记忆里对齐的 2 的幂区间，至少两行、行都在"
    case .cueNotEnabled: "Cue 没有启用，不能派活：等用户在 CuePad 里重新启用"
    case .questionEnded: String(localized: "这条提问已经结束了")
    case .notAChoice(let answer): String(localized: "「\(answer)」不是这条提问的选项")
    case .phrase(let field, let hint, let limit): "\(field)：\(hint)，一行、不超过 \(limit) 字"
    case .shots(let limit): "show 至多 \(limit) 张、不重复：只挑回答问题必须看的、证明结论的最终成果"
    case .shotMissing(let id): "发到手机的里没有 \(id)：照 task peek 里列的 id 写"
    }
  }
}
