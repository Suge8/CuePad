#if DEBUG

/// 视觉验收与测量用的启动参数（只在 Debug 构建读取，配合 `CUEPAD_LIBRARY_DIR` 使用隔离资料库），从参数域（`-CuePadScene shelf` 这类）一次解出：
/// 键 = `-CuePad` + 字段名（大小写不论）；没给：Bool 为 false、数为 0、可选为 nil。字段注释就是登记表；加参数只在这里（或分组）加一个字段。
/// 设置项可在参数域覆盖：`-theme dark`（不在这里）。
nonisolated struct DebugArgs: Decodable {
    /// `-CuePadActsAs development|stranger`（仅 Mac）：隔离库当作本机构建的开发库来定碰不碰真实世界（`DebugHooks.actsAs`）：development 照真的找这台装没装正式版
    let actsAs: String?
    /// `-CuePadAgentHome <目录>`（仅 Mac）：Agent 当作装在这个家目录里，给空目录是一家都没装，点安装真跑官方脚本装进它（`DebugHooks.agentHome`）
    let agentHome: String?
    /// `-CuePadAgentLibrary clean`：技能与规则的演示文件摆成整理好的样子（默认是该整理的样子）
    let agentLibrary: String?
    /// `-CuePadAlertStatus <on|pending|denied|undetermined|registerFailed|subscribeFailed>`：设置页通知那一行按这个状态显示
    let alertStatus: String?
    /// `-CuePadAllKinds YES|<批数>`（配 `-CuePadDemo YES -CuePadScene session -CuePadSession scratch`）：scratch 会话里发每种类型各一份的交付物、一个 3D 模型与一张"下载中"，两份一批（`seedAllKinds`）
    let allKinds: String?
    /// `-CuePadAtlas <PiWorkState>`：atlas 会话此刻的状态（`DebugScene+CueSessions.swift`）
    let atlas: String?
    /// `-CuePadAtlasTitle <名>`：atlas 会话的名字（`DebugScene+CueSessions.swift`）
    let atlasTitle: String?
    /// `-CuePadAwayAfter <秒>`：就绪后这么久离开 Cue 页（`leave`），你说一句去睡了、Cue 接着说一夜的那几句，再回来（`back`）
    let awayAfter: Double
    /// `-CuePadBusyBoard YES`（配 tasks 画面与 `-CuePadDemo YES`）：推进中里再放几件 Agent 正在多步推进的任务（`seedBusyBoard`）
    let busyBoard: Bool
    /// `-CuePadCanvasSteps YES`（配 tasks 画面）：待办里一件写了正文、有三个子任务的任务，看任务气泡的正文与子任务（`seedCanvasSteps`）
    let canvasSteps: Bool
    /// `-CuePadCard <正文开头>`：editor 画面打开哪张卡
    let card: String?
    /// `-CuePadCatalogFailure YES`：项目目录读取直接报错（重试也一样），核对读取失败画面
    let catalogFailure: String?
    /// `-CuePadCloudKit YES`：隔离库也连 iCloud（同步测量）
    let cloudKit: Bool
    /// `-CuePadComposer <cards|attachments|lines|slash>`（配 session、newsession 画面，iOS 与 Mac）：输入框出现时 cards 打开选卡片面板，slash 写进 "/re" 弹出斜杠命令面板
    let composer: String?
    /// `-CuePadComposerNotice YES`（配 session、atlas）：每隔三秒显示一条命令进度与一条配置失败，1.5 秒后撤回，循环验收两行说明进出时的贴底布局
    let composerNotice: Bool
    /// `-CuePadConnected YES`：agentsetup 先把几家 Agent 接进隔离目录
    let connected: Bool
    /// `-CuePadCrashSheet YES`（配 `-CuePadSampleCrash YES`）：直接打开诊断摘要，导出的摘要写在库目录的 summary.txt
    let crashSheet: Bool
    /// `-CuePadCue shut`：收起右边的 Cue
    let cue: String?
    /// `-CuePadDemo YES`：库为空（只有默认项目）时写入演示数据
    let demo: Bool
    /// `-CuePadDemoMac YES`：演示库里一台会回话的"demo-mac"
    let demoMac: Bool
    /// `-CuePadExtensionLibrary <隔离目录>`：扩展预览只读这里的快照，不受主 App 同时重写派生缓存影响
    let extensionLibrary: String?
    /// `-CuePadFileArrives <秒>`（配 `-CuePadFiles YES`）：过这么久那份还在 iCloud 的文件下载、落地（`seedFiles`）
    let fileArrives: Double
    /// `-CuePadFiles YES`：默认项目里写一条带附件的灵感「交接材料」，`-CuePadFileArrives <秒>` 演示那份还在 iCloud 的文件下载、落地（`seedFiles`）
    let files: Bool
    /// `-CuePadFolder <路径>`：建一个以文件夹命名、绑着它的项目（已有同名的不再建）
    let folder: String?
    /// `-CuePadHost <名>`：同一台机器上开两个隔离实例当两台 Mac（同步测量）
    let host: String?
    /// `-CuePadInspiration YES`：默认项目的混排样张，配 `-CuePadCard #` 打开
    let inspiration: Bool
    /// `-CuePadLaunch YES`（配 newsession 画面）：已经替你在圆桌发出一条会话（看送达中）
    let launch: Bool
    /// `-CuePadLibraryTab skills`：技能与规则页一打开在技能那一段
    let libraryTab: String?
    /// `-CuePadLiveActivity YES`：隔离库下也开真的实时活动（配 `-CuePadDemo YES`，演示库里有推进中与等你），验收锁屏与灵动岛
    let liveActivity: Bool
    /// `-CuePadLongChat YES`：演示对话前面多 110 轮更早的来回（比 Cue 页读得到的 `CueThread.limit` 条多：来一句新的，最早那条就掉出去，同真实库）（看 Cue 页往上翻与刻度滑条）
    let longChat: Bool
    /// `-CuePadMac agents|bare`：库里写下一台 Mac「MacBook Pro」，接了 Claude Code 与 Codex，或一家都没接（bare）
    let mac: String?
    /// `-CuePadManyTasks <条数>`：给 `-CuePadProject` 那个项目再加这么多条待办（没做完的还不到这么多时），量任务多时的项目页（`perf-ios.sh 3 -CuePadManyTasks 150 -CuePadProject CuePad`）
    let manyTasks: Int
    /// `-CuePadNoAsks YES`（配 `-CuePadDemo YES`）：演示库里等你回答的会话都改成歇着、Cue 还没结束的提问都由它撤回（同 Cue 的 withdraw）
    let noAsks: Bool
    /// `-CuePadNoIdeas YES`：`-CuePadProject` 那个项目的灵感都移到回收站，看项目页没有灵感时的空态（改的是库本身，之后的画面也没有这些灵感：配一个新的 `CUEPAD_SHOT_LIBRARY`）
    let noIdeas: Bool
    /// `-CuePadNotifications YES`：隔离库下也要通知权限、发真实的系统通知（两端，规则见 docs/verify.md「通知」）
    let notifications: Bool
    /// `-CuePadNotify YES`：走点锁屏通知的那条路进去
    let notify: Bool
    /// `-CuePadOfferSetup YES`（仅 Mac）：脚本起的实例也像正式版与从 Xcode 直接打开的那样首次打开时决定弹不弹接入面板（`Workspace.offerSetup`，只弹一次记在隔离库的偏好里），核对第一次打开与老用户升级后自动弹的那一次
    let offerSetup: Bool
    /// `-CuePadOfflineSeconds <秒>`（默认 6，配 `-CuePadSync offline`）：一开始连不上 iCloud，这么久后恢复
    let offlineSeconds: Double?
    /// `-CuePadOpenPreview <标题或文件名>`：会话页直接打开那张预览
    let openPreview: String?
    /// `-CuePadPasteFile <路径>`：粘贴测量里粘进来的那一大段换成这个文件的内容
    let pasteFile: String?
    /// `-CuePadPhoneVoice <样例>`：手机通话面板样例
    let phoneVoice: String?
    /// `-CuePadPreviewMedia <目录>`（同样配 scratch 会话）：目录里的真文件（大图、视频、多页 PDF）作为一批发进去（`seedPreviewMedia`）
    let previewMedia: String?
    /// `-CuePadProject <名称>`：打开该项目
    let project: String?
    /// `-CuePadQuotePreview <标题或文件名>`：回复那张预览（`Workspace.quote`）
    let quotePreview: String?
    /// `-CuePadRailEmpty YES`（配 rail 画面）：验空列占位
    let railEmpty: Bool
    /// `-CuePadRailForm <形态>`：rail 画面的形态
    let railForm: String?
    /// `-CuePadReconcileSeconds <秒>`（默认 8，配 `-CuePadSync newmac`）：这么久后带回 Cue 在「Mac Studio」上运行
    let reconcileSeconds: Double?
    /// `-CuePadReplies <N>`：Cue 把歇着的会话留给你回（待回复：会话条与看板的等你组，`seedReplies`）
    let replies: Int
    /// `-CuePadSampleCrash YES`：存几份样例诊断，设置里出现"上次崩溃"（`DebugScene+Crash.swift`）
    let sampleCrash: Bool
    /// `-CuePadSampleCue <秒>`（仅 Mac）：过这么久写一条 Cue 请你允许推送的消息，经 Cue 的通知出口发出（隔离库里 Cue 不值班，不会自己推）
    let sampleCue: Double
    /// `-CuePadScene <画面>`：初始画面；画面名与摆法见各画面文件登记在 `DebugScene.entries` 里的那一条
    let scene: String?
    /// `-CuePadSearch <关键词>`：search 画面与卡片选择器（`-CuePadComposer cards`）的预填关键词
    let search: String?
    /// `-CuePadSearchScope sessions`（iOS）：搜索页打开在会话那一栏
    let searchScope: String?
    /// `-CuePadSeed perf`（仅 Mac）：库为空（只有默认项目）时写入性能测量用的大资料库（`PerfLibrary`），配合 `-CuePadBench interact`
    let seed: String?
    /// `-CuePadSelect <起点:长度>`：编辑器载入后选中这一段（看选区操作）
    let select: String?
    /// `-CuePadSession <会话名>`：session 画面整页打开这个演示会话（演示会话的 sessionID 与会话名相同），send 画面与接力、叫醒等驱动也认
    let session: String?
    /// `-CuePadSettingsPane general|agents`（配 settings 画面）：设置窗口翻到那一页
    let settingsPane: String?
    /// `-CuePadSync <noAccount|decide|failed|restricted|conflicts|fullquota>`（fullquota：已同步、iCloud 空间满附件停着）：装上报这个状态的同步替身，设置里 iCloud 同步与 Mac 工具栏的同步提示按它显示（`DebugScene+Sync.swift`）
    let sync: String?
    /// `-CuePadSyncBench <host|remote>`（配 `-CuePadCloudKit YES` 与各自的 `-CuePadHost`）：同一台 Mac 上两个隔离实例经 CloudKit 开发环境同步
    let syncBench: String?
    /// `-CuePadTask <标题开头>`：task 画面打开那一条任务的气泡，没给是第一条
    let task: String?
    /// `-CuePadTaskLines written|changed`：对话末尾 Cue 再说一句关于"导入旧数据"的话（气泡下一行这件活），都看过、页停在最新处
    let taskLines: String?
    /// `-CuePadVoice mic`：Cue 能听了就开始通话，声音走麦克风与扬声器（人工验收）
    let voice: String?
    /// `-CuePadWebSnapshot <PNG 路径>`：预览网页打开时，用同一套拦截规则另载入一份、把快照存成 PNG
    let webSnapshot: String?

    /// 分组：各自在 `DebugScene+Args<名>.swift`，字段注释即那一组的登记表。
    let phoneVoiceOpts: PhoneVoiceArgs
    let voiceOpts: VoiceArgs
    let syncBenchOpts: SyncBenchArgs
    let inspirationOpts: InspirationArgs
    let quotaOpts: QuotaArgs
    let cueOpts: CueArgs
    let layoutOpts: LayoutArgs
    let driveOpts: DriveArgs
}
#endif
