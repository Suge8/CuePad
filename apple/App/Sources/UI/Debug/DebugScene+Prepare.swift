#if DEBUG
import CueStore
import SwiftUI

extension DebugScene {
    static func presetColumns(_ settings: AppSettings) {
        settings.railExpanded = args.layoutOpts.sidebar != "hidden"
        settings.cueOpen = args.cue != "shut"
    }

    static func presetBeside(_ workspace: Workspace) async {
        if let share = args.layoutOpts.besideShare {
            for kind in [WideMetrics.Kind.session, .preview] { workspace.paneShares.set([1 - share, share], for: [kind]) }
        }
        if let beside = args.layoutOpts.beside {
            workspace.openSession(SessionState.recordID(sessionID: beside), sessionID: beside, in: .aside)
        }
        if args.layoutOpts.besideCard {
            await running("并排一条灵感") {
                if let card = try await card(in: Project.defaultID, store: workspace.services.store) { workspace.drop(.card(card), at: WideNavigation.maxPanes, replacing: false) }
            }
        }
    }

    static func presetDrawers(_ workspace: Workspace) {
        if args.layoutOpts.sidebar == "drawer" { workspace.railDrawer = true }
        if args.cue == "drawer" { workspace.showCue() }
    }

    static func drivers(_ workspace: Workspace) -> [@MainActor () async -> Void] {
        let services = workspace.services
        var drivers: [@MainActor () async -> Void] = [
            { await noticeIfAsked(workspace) },
            { await composerNoticeIfAsked(services) },
            { await wakeIfAsked(workspace) },
            { await replyBlinkIfAsked(services.store) },
            { await relayIfAsked(workspace) },
            { await cueFlowIfAsked(workspace) },
            { await cueNowTourIfAsked(workspace) },
            { await boardTourIfAsked(services.store) },
            { await cycleIfAsked(services) },
            { launchArtIfAsked() },
        ]
        #if os(macOS)
        let from = workspace.mainRoute
        drivers += [
            { await saysIfAsked(services, visit: { workspace.show(.cue) }, back: { workspace.show(from) }) },
            { await awayIfAsked(services.store) },
            { await closeIfAsked(workspace) },
            { await openMenuIfAsked() },
        ]
        #else
        let from = (workspace.mainRoute, workspace.path)
        drivers += [
            { await cycleLivePhoneIfAsked(workspace) },
            {
                await saysIfAsked(services, visit: { workspace.select(.cue) }, back: {
                    workspace.select(from.0)
                    workspace.path = from.1
                })
            },
            { await awayIfAsked(services.store, leave: { workspace.show(.progress) }, back: { workspace.show(.cue) }) },
        ]
        #endif
        return drivers
    }

    /// `-CuePadSidebarCycle`、`-CuePadRightCycle`：反复开合那一栏，`fast` 在动画中途反向。
    static func cycleColumn(fast: Bool, _ toggle: @MainActor () -> Void) async {
        let gaps: [Double] = fast ? [0.1, 1.5, 0.06, 0.06, 1.5] : [1.5]
        await Task.wait(for: .seconds(3))
        for step in 0... {
            toggle()
            guard await Task.wait(for: .seconds(gaps[step % gaps.count])) else { return }
        }
    }

    static func prepareLibrary(_ workspace: Workspace) async -> UUID? {
        var project: UUID?
        await running("摆画面的数据") { project = try await prepare(workspace) }
        return project
    }

    private static func prepare(_ workspace: Workspace) async throws -> UUID? {
        let store = workspace.services.store
        if args.sampleCrash {
            let diagnostics = workspace.services.diagnostics
            try diagnostics.archive.store(sampleFreeze)
            diagnostics.record(sampleDiagnostics)
            try Data(DiagnosticSummary.text(diagnostics.reports).utf8).write(to: diagnostics.archive.directory.deletingLastPathComponent().appending(path: "summary.txt"))
        }
        #if os(macOS)
        if args.seed == "perf" { try await seedIfFresh(store, PerfLibrary.seed) }
        try await isolateBoundFolders(store)
        #endif
        if args.demo {
            try await seedIfFresh(store, DemoLibrary.seed)
            try await seedMacAgents(workspace.services)
            try await seedAgentLibrary(workspace.services)
            try await seedScratchFiles(store)
        }
        try await seedOneMac(store)
        await seedFiles(workspace.services)
        await presetSync(workspace.services)
        guard let name = args.project,
              let project = try await store.projects().first(where: { $0.name == name })
        else { return nil }
        let many = args.manyTasks
        if many > 0, try await store.taskCounts(in: project.id).open < many {
            for index in 1...many { _ = try await store.createTask(String(localized: "压力任务 \(index)：画布与节点的一段说明", table: "Demo"), in: project.id) }
        }
        if args.noIdeas {
            for card in try await store.cards(in: project.id) { _ = try await store.trashCard(card.id) }
        }
        #if os(macOS)
        workspace.show(.project(project.id))
        #endif
        return project.id
    }

    private static func seedOneMac(_ store: CueStore) async throws {
        guard let mac = args.mac else { return }
        let bare = mac == "bare"
        let agents = bare ? [] : [AgentKind.claudeCode, .codex].map { MacAgent(kind: $0, model: nil, models: []) }
        let problems = bare ? AgentKind.allCases.map { MacAgentProblem(kind: $0, reason: .notInstalled) } : []
        _ = try await store.recordMacAgents(host: "debug-mac", name: String(localized: "MacBook Pro", table: "Demo"), agents, problems: problems)
    }

    #if os(macOS)
    private static func isolateBoundFolders(_ store: CueStore) async throws {
        guard let library = ProcessInfo.processInfo.environment[LibraryLocation.environmentKey] else { return }
        let directories = try await store.projectDirectories()
        let real = UserHome.directory.path(percentEncoded: false)
        let home = DemoLibrary.demoHome, asked = args.folder
        for (project, path) in directories where path.hasPrefix(real) && !path.hasPrefix(library + "/") && path != asked {
            try await store.setDirectory(home + path.dropFirst(real.count), for: project)
        }
    }
    #endif

    private static func seedIfFresh(_ store: CueStore, _ seed: (CueStore) async throws -> Void) async throws {
        if try await store.projects().allSatisfy(\.isDefault) { try await seed(store) }
    }

    /// attachments 带上一张卡片（`-CuePadCard` 挑哪张）并放进两张演示图片与一份 PDF，lines 写进 9 行文字（看文字区长到 6 行后在里面滚）。
    /// ＋ 菜单是系统菜单、不能代为展开：截图时按一下 ＋（iPhone 17 Pro 回复框：`axe touch -x 37 -y 810 --down --up --delay 0.15`；axe 的 tap 太快，菜单不开）。
    static func presetComposer(_ draft: Binding<ComposerDraft>, source: Binding<ComposerSource?>, store: CueStore) async {
        await running("预设输入框") { try await presetComposerBody(draft, source: source, store: store) }
    }

    private static func presetComposerBody(_ draft: Binding<ComposerDraft>, source: Binding<ComposerSource?>, store: CueStore) async throws {
        switch args.composer {
        case "cards":
            // 等推入页面的转场走完再弹，转场中弹出的面板会被系统丢掉；弹出前不算就绪
            later(.seconds(1)) { source.wrappedValue = .cards }
        case "attachments":
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

    static func card(in project: UUID, store: CueStore) async throws -> UUID? {
        let cards = try await store.cards(in: project)
        let prefix = args.card ?? ""
        return cards.filter { $0.body.hasPrefix(prefix) }.max { $0.modifiedAt < $1.modifiedAt }?.id
    }

    static func scrollIfNeeded(_ proxy: ScrollViewProxy) {
        guard scene == "older" else { return }
        later(.milliseconds(300)) { proxy.scrollTo(OlderGroup.anchor, anchor: UnitPoint(x: 0.5, y: 0.35)) }
    }

    private static func lengthen(_ task: Card, in store: CueStore) async throws {
        guard try await store.children(of: task.id).filter(\.isTask).count < 12 else { return }
        let line = String(localized: "跑一下 scheduler 的测试，找出 5 人以上时谁被排到了最前\n先别改代码，告诉我原因和改法", table: "Demo")
        try await store.updateCard(task.id) { $0.rest = Array(repeating: line, count: 8).joined(separator: "\n") }
        for index in 1...12 { _ = try await store.createTask(String(localized: "检查发布事项 \(index)", table: "Demo"), under: task.id) }
    }

    static func openTask(_ workspace: Workspace, preferred: (Card) -> Bool) async {
        await running("打开任务气泡") {
            let tasks = try await workspace.services.store.tasks(.inProgress, .todo).flatMap(\.tasks)
            let named = args.task.flatMap { prefix in tasks.first { $0.title.hasPrefix(prefix) } }
            if let task = named ?? tasks.first(where: preferred) ?? tasks.first {
                if args.longTask {
                    try await lengthen(task, in: workspace.services.store)
                    later(.seconds(2)) {}
                }
                workspace.openTask(task)
            }
        }
    }
}

struct MiddleScroll: ViewModifier {
    @State private var position = ScrollPosition()
    @State private var overflow: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height - $0.containerSize.height } action: { overflow = $1 }
            .task(id: overflow) {
                guard DebugScene.args.longTask, overflow > 0, await Task.wait(for: .seconds(0.3)) else { return }
                position.scrollTo(y: overflow / 2)
            }
    }
}
#endif
