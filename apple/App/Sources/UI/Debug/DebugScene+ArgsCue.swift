#if DEBUG

/// Cue 页与 Cue 此刻状态的参数。
/// 键 = `-CuePad` + 前缀「Cue」 + 字段名（大小写不论）；没给：Bool 为 false、数为 0、可选为 nil。
nonisolated struct CueArgs: Decodable, DebugArgGroup {
    static let prefix = "Cue"
    /// `-CuePadCueAsk <proposals|push|one|four|evidence>`（配 `-CuePadScene cue` 与演示库）：把"等你"换成提问卡的一种样子，对照设计稿截图
    let ask: String?
    /// `-CuePadCycle YES`：就绪后循环走过各个画面状态，录屏用（`DebugScene+PiDemo.swift`）
    let cycle: Bool
    /// `-CuePadCueCycleSeconds <秒>`：`-CuePadCueCycle` 各份样例之间的间隔
    let cycleSeconds: Double?
    /// `-CuePadCueDraft <文字>`（配 cue 画面）：Cue 的输入框里先有这句草稿
    let draft: String?
    /// `-CuePadCueFocus YES`（配 cue 画面）：Cue 页的输入框一出现就聚焦
    let focus: Bool
    /// `-CuePadCueNow <hearing|failed|woke|delegating|asks|done|doneExpiring|afterDone|crowded|quiet|away|four|fourAsks|fourWorking|awayBusy|busy>`：Cue 此刻钉成这份样例（`CueNowSamples`），页头、侧栏、小组件与实时活动都按它画
    let now: String?
    /// `-CuePadCuePresence <unchosen|fresh|answered|thinking|tool|woke|sending|asleep|disabled>`：unchosen 是还没选过在哪台 Mac 上运行（演示的几台 Mac 都在，手机 Cue 面板就地选）
    let presence: String?
    /// `-CuePadCueStale YES`：Cue 页摆成对话停滞的样子
    let stale: Bool
}
#endif
