#if DEBUG

nonisolated struct LayoutArgs: Decodable, DebugArgGroup {
    static let prefix = ""
    /// `-CuePadBeside <会话>`（仅 Mac）：主区右半并排开这个演示会话（左半是 `-CuePadSession`）
    let beside: String?
    /// `-CuePadCompact <宽>`（iPad）：按这么宽的窄窗口画（分屏、台前调度；紧凑尺寸类）；不给时 iPad 的调试实例起来先铺满屏
    let compact: Double?
    /// `-CuePadCuePanel YES`（iOS，配 cue 画面）：页头一出现就展开成面板
    let cuePanel: Bool
    /// `-CuePadDrawerCross rail|cue`（仅 Mac）：拉出那个抽屉后反复跨过临界宽来回拖（`DebugScene+Wide.swift`）
    let drawerCross: String?
    /// `-CuePadGeometryLoop YES`（仅 Mac）：挂一个刻意的几何回写环，给布局压力场景的检测器自检
    let geometryLoop: Bool
    /// `-CuePadHeaderCycle YES`（配录屏）就绪后来回走：滑去看历史（让开）→ 点顶上唤出 → 再滑（让开）→ 回到最新（回来），每步 1.5 秒
    let headerCycle: Bool
    /// `-CuePadHeaderHidden YES`、`-CuePadHeaderCycle YES`（iOS，配 session）：会话页顶那一排让开、来回让开与回来（`debugDrivesHeader`）
    let headerHidden: Bool
    /// `-CuePadHelpOpen YES`：页顶与导航栏里的问号一出现就点开说明（`debugOpensHelp`）
    let helpOpen: Bool
    /// `-CuePadHighContrast YES`：整个窗口按增强对比度画
    let highContrast: Bool
    /// `-CuePadLargestType YES`：整个窗口按最大的辅助字号画
    let largestType: Bool
    /// `-CuePadMergePreview YES`（配 instruction 画面）：已点过一下"合并进来"、标出会并进来的段
    let mergePreview: Bool
    /// `-CuePadLandscape YES`（iOS、iPad）：由 `xc.sh` 在起实例前把模拟器横过来（`app_sim.py`），App 自己不读；登记在这里是为了不被当成拼错的参数
    let landscape: Bool
    /// `-CuePadModelMenu YES`（Mac）：模型菜单一出现就打开；菜单是独立窗口，截图另拍它
    let modelMenu: Bool
    /// `-CuePadNarrowCycle YES`（配录屏）：就绪后走一圈开侧栏的进展、换到项目、换回进展、再换到项目（中途反向：上一下换段的滑动还没停就点回去）、回 Cue
    let narrowCycle: Bool
    /// `-CuePadNarrowPane projects|progress`（iOS 窄屏）：起在满屏侧栏的哪一栏
    let narrowPane: String?
    /// `-CuePadNarrowWaiting <N>`（iOS 窄屏）：再加入 N 个拍板，检查固定块内部滚动
    let narrowWaiting: Int
    /// `-CuePadOffscreen YES`（仅 Mac）：主窗口放在所有屏幕之外（第一次显示前就放好、不被系统夹回，也不记位置），复现窗口不可见时的布局、测量时不露在桌面上
    let offscreen: Bool
    /// `-CuePadPanelCycle YES`（配 cue 画面录屏）：画面就绪后每 1.5 秒点一下 Cue 页头，开合面板几遍，看动效
    let panelCycle: Bool
    /// `-CuePadQuiet YES`（iOS）：不弹演示会话的前台横幅
    let quiet: Bool
    /// `-CuePadQuotaCycle YES`（iOS，配 progress 录屏）：反复点额度钮开浮窗、走点外面那条路关（`cycleQuota`）
    let quotaCycle: Bool
    /// `-CuePadQuotaOpen YES`：额度明细一出现就长开（手机进展页顶栏、Mac 侧栏）
    let quotaOpen: Bool
    /// `-CuePadReader YES`：提示条当作读屏开着（`NoticeCapsule`），录读屏下不自动收
    let reader: Bool
    /// `-CuePadReduceMotion YES`：整个窗口按"减弱动态效果"画（`PaletteProvider` 改窗口的环境）
    let reduceMotion: Bool
    /// `-CuePadRightCycle YES|fast`：同样开合右栏（Cue）
    let rightCycle: String?
    /// `-CuePadScheduleOpen YES`：新定时的几点展开（配 cueschedules、task 画面）
    let scheduleOpen: Bool
    /// `-CuePadSheetEnd YES`：预览页一打开停在底，一屏放不下时与停在顶的那张拼成整份
    let sheetEnd: Bool
    /// `-CuePadShowsDone YES`：已完成列的"更早做完的"一开始就展开
    let showsDone: Bool
    /// `-CuePadSidebar hidden`：宽屏会话条藏起（不给是正式版的默认：开着），`drawer`：窗口放不下会话条时拉出它的左缘抽屉（`-CuePadCue drawer` 同理拉出 Cue 的右缘抽屉）
    let sidebar: String?
    /// `-CuePadSidebarCycle YES`（Mac、iPad 宽屏）：就绪后反复开合会话条（录开合的动效），`fast` 在动画中途反向
    let sidebarCycle: String?
    /// `-CuePadSoftKeyboard YES`（iOS）：模拟器里聚焦也弹出系统键盘
    let softKeyboard: Bool
    /// `-CuePadTasksOpen YES`：项目页任务纸的"还有 N 条"与"已完成 M"一开始就展开
    let tasksOpen: Bool
    /// `-CuePadToolsOpen YES`：每一轮的经过、子代理名册与 Cue 页折起的醒来记录与经过一开始就全部展开（`RoundProcess`、`PiSubagentList`、`CueNoteLog`、`CueTrace`）
    let toolsOpen: Bool
    /// `-CuePadTurnCycle YES`（配录屏）：就绪后把这一处的切页来回翻几遍（"更多"里的移到项目、任务气泡的子任务、搜索的范围）
    let turnCycle: Bool
    /// `-CuePadWideHold <毫秒>` 改停多久（如 1500：收窄、展开各滑完一整段）
    let wideHold: Int?
    /// `-CuePadWideReverse <组合>`（仅 Mac）：摆好一种主区组合、就绪后反复在会话条自动藏起的临界宽度上反向（录宽屏跨阈值的滑动，`DebugScene+Wide.swift`）
    let wideReverse: String?
    /// `-CuePadWindowSize 1280x800`：主窗口尺寸（Mac 内容铺满标题栏，即整窗尺寸）
    let windowSize: String?
}
#endif
