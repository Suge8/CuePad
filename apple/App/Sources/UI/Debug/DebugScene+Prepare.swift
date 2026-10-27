#if DEBUG
import CueStore
import SwiftUI

extension DebugScene {
    static func prepareLibrary(_ workspace: Workspace) async -> UUID? {
        var project: UUID?
        await running("摆画面的数据") { project = try await prepare(workspace) }
        return project
    }

    private static func prepare(_ workspace: Workspace) async throws -> UUID? {
        let store = workspace.services.store
        // -CuePadSampleCrash YES：存一份样例崩溃诊断，设置里出现"上次崩溃"（配 -CuePadCrashSheet YES 直接打开摘要）
        if defaults.bool(forKey: "CuePadSampleCrash") { workspace.services.diagnostics.record([sampleCrash]) }
        #if os(macOS)
        if defaults.string(forKey: "CuePadSeed") == "perf" { try await seedIfFresh(store, PerfLibrary.seed) }
        try await isolateBoundFolders(store)
        #endif
        if defaults.bool(forKey: "CuePadDemo") {
            try await seedIfFresh(store, DemoLibrary.seed)
            try await seedMacAgents(workspace.services)
            try await seedAgentLibrary(workspace.services)
            try await seedScratchFiles(store)
        }
        try await seedOneMac(store)
        await seedFiles(workspace.services)
        await presetSync(workspace.services)
        guard let name = defaults.string(forKey: "CuePadProject"),
              let project = try await store.projects().first(where: { $0.name == name })
        else { return nil }
        let many = defaults.integer(forKey: "CuePadManyTasks")
        if many > 0, try await store.taskCounts(in: project.id).open < many {
            for index in 1...many { _ = try await store.createTask(String(localized: "压力任务 \(index)：画布与节点的一段说明", table: "Demo"), in: project.id) }
        }
        if defaults.bool(forKey: "CuePadNoIdeas") {
            for card in try await store.cards(in: project.id) { _ = try await store.trashCard(card.id) }
        }
        #if os(macOS)
        workspace.show(.project(project.id))
        #endif
        return project.id
    }

    /// `-CuePadMac agents|bare`：库里写下一台 Mac「MacBook Pro」，接了 Claude Code 与 Codex，或一家都没接（bare），
    /// 看手机上启用 Cue 前那三步（`CueMacSteps`）走到哪一步。
    private static func seedOneMac(_ store: CueStore) async throws {
        guard let mac = defaults.string(forKey: "CuePadMac") else { return }
        let bare = mac == "bare"
        let agents = bare ? [] : [AgentKind.claudeCode, .codex].map { MacAgent(kind: $0, model: nil, models: []) }
        let problems = bare ? AgentKind.allCases.map { MacAgentProblem(kind: $0, reason: .notInstalled) } : []
        _ = try await store.recordMacAgents(host: "debug-mac", name: String(localized: "MacBook Pro", table: "Demo"), agents, problems: problems)
    }

    #if os(macOS)
    /// 每次启动、只要是隔离库（演示库、性能库，也包括真实数据复现的只读副本），这台 Mac 上绑在真实主目录下的文件夹都改绑到演示主目录
    /// （`DemoLibrary.demoHome`，在隔离库里），保留主目录下的相对路径：实例会真去读写绑定的文件夹（技能与规则的扫描、整理与改规则），
    /// 绑在真实主目录下就会改到真的仓库；旧版本的演示种子绑的就是真实主目录（`~/Project/cuepad`），库在了不重写。
    /// 所以副本里项目绑的文件夹也不是原来那些。`-CuePadFolder` 明说要绑的那个照旧（隔离实例里真跑 Cue 派活要它）。
    private static func isolateBoundFolders(_ store: CueStore) async throws {
        // 只在隔离库里搬：用真实库的 Debug 实例绑的就是用户自己的文件夹
        guard let library = ProcessInfo.processInfo.environment[LibraryLocation.environmentKey] else { return }
        let directories = try await store.projectDirectories()
        let real = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let home = DemoLibrary.demoHome, asked = defaults.string(forKey: "CuePadFolder")
        for (project, path) in directories where path.hasPrefix(real) && !path.hasPrefix(library + "/") && path != asked {
            try await store.setDirectory(home + path.dropFirst(real.count), for: project)
        }
    }
    #endif

    /// 库里只有默认项目（新的隔离库）时写入：库一旦有了数据就不再写，所以只在新库里起效的数据都不挂在这里（`seedScratchFiles` 每次启动都写）。
    private static func seedIfFresh(_ store: CueStore, _ seed: (CueStore) async throws -> Void) async throws {
        if try await store.projects().allSatisfy(\.isDefault) { try await seed(store) }
    }

    /// `-CuePadComposer <cards|attachments|lines|slash>`（配 session、newsession 画面，iOS 与 Mac）：输入框出现时 cards 打开选卡片面板，slash 写进 "/re" 弹出斜杠命令面板，
    /// attachments 带上一张卡片（`-CuePadCard` 挑哪张）并放进两张演示图片与一份 PDF，lines 写进 9 行文字（看文字区长到 6 行后在里面滚）。
    /// ＋ 菜单是系统菜单、不能代为展开：截图时按一下 ＋（iPhone 17 Pro 回复框：`axe touch -x 37 -y 810 --down --up --delay 0.15`；axe 的 tap 太快，菜单不开）。
    static func presetComposer(_ draft: Binding<ComposerDraft>, source: Binding<ComposerSource?>, store: CueStore) async {
        await running("预设输入框") { try await presetComposerBody(draft, source: source, store: store) }
    }

    private static func presetComposerBody(_ draft: Binding<ComposerDraft>, source: Binding<ComposerSource?>, store: CueStore) async throws {
        switch defaults.string(forKey: "CuePadComposer") {
        case "cards":
            // 等推入页面的转场走完再弹，转场中弹出的面板会被系统丢掉；弹出前不算就绪
            later(.seconds(1)) { source.wrappedValue = .cards }
        case "attachments":
            // 先挑默认项目里的，没有再挑第一个项目里的
            var id = try await card(in: Project.defaultID, store: store)
            if id == nil, let project = try await store.projects().first { id = try await card(in: project.id, store: store) }
            if let id, let card = try await store.card(id) {
                draft.wrappedValue.attach(card)
            }
            let swatches = try [(0.85, 0.47, 0.29), (0.25, 0.56, 0.72)].map { try store.files.store(swatch(red: $0.0, green: $0.1, blue: $0.2)) }
            draft.wrappedValue.files = swatches.map { DraftFile(key: $0, name: "") } + [try demoPDF(store)]
        case "lines":
            draft.wrappedValue.text = (1...9).map { String(localized: "第 \($0) 行", table: "Demo") }.joined(separator: "\n")
        case "slash":
            draft.wrappedValue.text = "/re"
        default:
            break
        }
    }

    /// 演示用的一份 PDF（一页 A4、几行字）存进附件目录：附件条、正文里的文件牌、你的话里的文件拍照用。
    static func demoPDF(_ store: CueStore) throws -> DraftFile {
        let name = String(localized: "季度复盘.pdf", table: "Demo")
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &page, nil) else { throw Unmet("演示 PDF 建不出来：\(url.path)") }
        context.beginPDFPage(nil)
        context.setFillColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1)
        context.fill(page)
        context.setFillColor(red: 0.2, green: 0.24, blue: 0.32, alpha: 1)
        for (row, width) in [420.0, 360, 400, 300, 380, 240].enumerated() {
            context.fill(CGRect(x: 72, y: 720 - Double(row) * 44, width: width, height: row == 0 ? 26 : 12))
        }
        context.endPDFPage()
        context.closePDF()
        return DraftFile(key: try store.files.store(fileAt: url), name: name)
    }

    static func swatch(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
        let size = CGSize(width: 240, height: 180)
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        return DemoLibrary.encode(context.makeImage()!)
    }

    /// `-CuePadCard` 指定（或最近修改）的一张散放的灵感。
    static func card(in project: UUID, store: CueStore) async throws -> UUID? {
        let cards = try await store.cards(in: project)
        let prefix = defaults.string(forKey: "CuePadCard") ?? ""
        return cards.filter { $0.body.hasPrefix(prefix) }.max { $0.modifiedAt < $1.modifiedAt }?.id
    }

    static func scrollIfNeeded(_ proxy: ScrollViewProxy) {
        guard scene == "older" else { return }
        later(.milliseconds(300)) { proxy.scrollTo(ScrollAnchor.older, anchor: UnitPoint(x: 0.5, y: 0.35)) }
    }

    /// task 画面：打开 `-CuePadTask <标题开头>` 那一条任务的气泡，没给是 `preferred` 挑中的，再没有是第一条（推进中、待办）。
    static func openTask(_ workspace: Workspace, preferred: (Card) -> Bool) async {
        await running("打开任务气泡") {
            let tasks = try await workspace.services.store.tasks(.inProgress, .todo).flatMap(\.tasks)
            let named = defaults.string(forKey: "CuePadTask").flatMap { prefix in tasks.first { $0.title.hasPrefix(prefix) } }
            if let task = named ?? tasks.first(where: preferred) ?? tasks.first { workspace.openTask(task) }
        }
    }
}
#endif
