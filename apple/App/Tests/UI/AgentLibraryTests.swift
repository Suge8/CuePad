#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

/// 技能与说明：Mac 照各家的文件写下快照（每台一条、内容变了才写、写了就传），文件就是事实；
/// 整理不弹确认，做完一条可撤销的提示，撤销恢复这一次的全部改动；改说明带基准，文件在别处改过就退回；手机发来的整理与改说明由 Mac 照做。
/// 各家的目录都在临时目录里（`TestApp.agentHomes`），移走的进库里的废纸篓。
@MainActor
struct AgentLibraryTests {
    let app = TestApp()
    var services: AppServices { app.services }
    var store: CueStore { services.store }

    func home(_ name: String) -> URL { app.directory.appending(path: name, directoryHint: .isDirectory) }
    var agents: URL { home("agents") }
    var claude: URL { home("claude") }
    var codex: URL { home("codex") }
    var pi: URL { app.piPaths.agentDirectory }

    func write(_ text: String, _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func skill(_ name: String, in directory: URL, named: String? = nil) throws {
        try write("---\nname: \(named ?? name)\ndescription: \(name) 的说明\n---\n正文\n", directory.appending(path: "\(name)/SKILL.md"))
    }

    func read(_ file: URL) -> String? { try? String(contentsOf: file, encoding: .utf8) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) || RelativeLink.isLink(url) }

    /// 像启动时那样跟着文件写快照；等到库里这台的快照满足条件。
    func keep() -> Task<Void, Never> { Task { try? await services.library.keep() } }

    func library(_ what: String, _ condition: @escaping @Sendable (AgentLibrary) -> Bool) async throws -> AgentLibrary {
        let host = TestApp.hostID
        return try #require(try await eventually(store, { try $0.agentLibrary(preferring: host) }) { $0.map(condition) ?? false })
    }

    @Test func 扫出技能与说明_全部整理一下做完_撤销恢复这一次的全部改动() async throws {
        for directory in [claude, codex] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try skill("write-swift", in: agents.appending(path: "skills/development"))
        try skill("retro", in: codex.appending(path: "skills"))
        try FileManager.default.createDirectory(at: codex.appending(path: "skills/codex-primary-runtime"), withIntermediateDirectories: true)
        try skill("openai-docs", in: codex.appending(path: "skills/.system"))
        try skill("from-claude-ai", in: claude.appending(path: "skills/synced"))
        try write("# 原则\n\n先读后写\n", claude.appending(path: "CLAUDE.md"))
        try write("# 原则\n\n先读后写\n\n求证：以证据为准\n", codex.appending(path: "AGENTS.md"))
        let uploads = app.sync.uploads.stream
        let keeping = keep()
        defer { keeping.cancel() }

        let found = try await library("扫出四件要整理") { $0.tidies.count == 4 }
        #expect(found.tidies.map(\.title) == ["「retro」在旧目录里", "Claude Code 看不见 1 个技能", "技能目录里有个空目录", "2 家的全局规则各写一份"])
        #expect(found.tidies.map(\.action) == [.move, .link, .trash, .compare])
        #expect(found.skills.map(\.name) == ["write-swift"] && found.skills[0].group == "development" && found.skills[0].unseenBy == [.claudeCode])
        #expect(found.selfManaged == [SelfManagedSkills(agent: .claudeCode, count: 1), SelfManagedSkills(agent: .codex, count: 1)])
        #expect(found.instruction(.global)?.text == nil)
        var uploaded = uploads.makeAsyncIterator()
        #expect(await uploaded.next() == AgentLibrary.recordID(host: TestApp.hostID).uuidString.lowercased())

        let workspace = Workspace(services: services)
        await workspace.tidy(found.automaticOrders, in: found)

        #expect(workspace.notice?.text.visible == "整理好了 4 件")
        let moved = agents.appending(path: "skills/retro")
        #expect(exists(moved.appending(path: "SKILL.md")) && !exists(codex.appending(path: "skills/retro")))
        #expect(RelativeLink.points(claude.appending(path: "skills/retro"), to: moved))
        #expect(RelativeLink.points(claude.appending(path: "skills/write-swift"), to: agents.appending(path: "skills/development/write-swift")))
        #expect(!exists(codex.appending(path: "skills/codex-primary-runtime")))
        #expect(read(agents.appending(path: "AGENTS.md")) == "# 原则\n\n先读后写\n\n求证：以证据为准\n")
        for file in [claude.appending(path: "CLAUDE.md"), codex.appending(path: "AGENTS.md")] {
            #expect(RelativeLink.points(file, to: agents.appending(path: "AGENTS.md")))
        }
        let tidied = try await library("整理完没有要整理的") { $0.tidies.isEmpty }
        #expect(tidied.instruction(.global)?.readers == [.claudeCode, .codex])
        #expect(tidied.skills.allSatisfy(\.unseenBy.isEmpty) && tidied.skills.map(\.name) == ["write-swift", "retro"])

        try await #require(workspace.notice?.action).run()

        #expect(exists(codex.appending(path: "skills/retro/SKILL.md")) && !exists(moved))
        #expect(!exists(claude.appending(path: "skills/write-swift")) && !exists(claude.appending(path: "skills/retro")))
        #expect(exists(codex.appending(path: "skills/codex-primary-runtime")))
        #expect(!RelativeLink.isLink(claude.appending(path: "CLAUDE.md")) && read(claude.appending(path: "CLAUDE.md")) == "# 原则\n\n先读后写\n")
        #expect(!exists(agents.appending(path: "AGENTS.md")))
        _ = try await library("撤销后又是四件") { $0.tidies.count == 4 }
    }

    /// 同名的要你挑留哪份、格式不对的要你自己改，"全部整理"不碰；替换基础提示的两份是比对来源，合成时选了才撤（Pi 的进废纸篓、Codex 的撤掉配置键）。
    @Test func 同名留一份_合成时撤掉选中的替换基础提示_都能撤销() async throws {
        for directory in [claude, codex, pi] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let folder = home("work/app"), other = home("work/blog")
        let project = try await store.createProject(name: "App", color: "#000000")
        let blog = try await store.createProject(name: "Blog", color: "#000000")
        try await store.setDirectory(folder.path, for: project.id)
        try await store.setDirectory(other.path, for: blog.id)
        try skill("pr", in: agents.appending(path: "skills"))
        try skill("pr", in: folder.appending(path: ".agents/skills"))
        try skill("pr", in: other.appending(path: ".agents/skills"))
        // 两个项目各自撞名：各是一件，各自留一份，不动别的项目
        for root in [folder, other] {
            try skill("lint", in: root.appending(path: ".agents/skills"))
            try skill("lint", in: root.appending(path: ".codex/skills"))
        }
        try skill("broken", in: agents.appending(path: "skills"), named: "Broken")
        try FileManager.default.createDirectory(at: agents.appending(path: "skills/binary"), withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00]).write(to: agents.appending(path: "skills/binary/SKILL.md"))
        try write("全局规则\n", claude.appending(path: "CLAUDE.md"))
        try write("你是 Pi\n", pi.appending(path: "SYSTEM.md"))
        try write("你是 Codex\n", codex.appending(path: "prompt.md"))
        let config = "model = \"gpt\"\nmodel_instructions_file = \"prompt.md\"\n\n[tools]\nweb = true\n"
        try write(config, codex.appending(path: "config.toml"))
        let keeping = keep()
        defer { keeping.cancel() }

        let found = try await library("扫出同名、格式不对与全局规则") { $0.tidies.count == 6 }
        let lintInApp = "duplicate/lint/\(project.id.uuidString)", lintInBlog = "duplicate/lint/\(blog.id.uuidString)"
        #expect(found.tidies.map(\.id).prefix(3) == [lintInApp, lintInBlog, "duplicate/pr"])
        #expect(found.tidies.map(\.title) == [
            "2 个技能都叫 lint", "2 个技能都叫 lint", "3 个技能都叫 pr", "「binary」的格式不对", "「broken」的格式不对", "3 家的全局规则各写一份",
        ])
        #expect(found.automaticOrders.map(\.tidy) == ["global-instructions"])
        let global = try #require(found.tidies.last)
        #expect(global.sources.map(\.origin) == [.agent(.claudeCode), .piSystem, .codexPrompt])
        #expect(found.instruction(.piSystem)?.text == "你是 Pi\n")

        let workspace = Workspace(services: services)
        let projectCopy = folder.appending(path: ".agents/skills/pr").path
        await workspace.tidy([
            TidyOrder(tidy: "duplicate/pr", keep: projectCopy), TidyOrder(tidy: lintInApp, keep: folder.appending(path: ".agents/skills/lint").path),
            TidyOrder(tidy: global.id, retire: [.piSystem, .codexPrompt]),
        ], in: found)

        #expect(workspace.notice?.text.visible == "整理好了 3 件")
        #expect(!exists(folder.appending(path: ".codex/skills/lint")) && exists(other.appending(path: ".codex/skills/lint")))
        // 留项目里的那份：移走的只是和它撞名的全局那份，另一个项目的不动
        #expect(!exists(agents.appending(path: "skills/pr")) && exists(URL(filePath: projectCopy)) && exists(other.appending(path: ".agents/skills/pr")))
        #expect(read(agents.appending(path: "AGENTS.md")) == "全局规则\n\n你是 Pi\n\n你是 Codex\n")
        #expect(!exists(pi.appending(path: "SYSTEM.md")))
        #expect(read(codex.appending(path: "config.toml")) == "model = \"gpt\"\n\n[tools]\nweb = true\n")
        #expect(RelativeLink.points(pi.appending(path: "AGENTS.md"), to: agents.appending(path: "AGENTS.md")))
        let malformed = ["binary", "broken"].map { "malformed/\(agents.appending(path: "skills/\($0)").path)" }
        // 留下的是项目里那几份：Claude Code 看不见它们，接着要链上；另一个项目的同名还在
        let tidied = try await library("只剩链接、另一个项目的同名与格式不对的") { $0.tidies.map(\.id) == ["unlinked", lintInBlog] + malformed }
        #expect(tidied.instruction(.piSystem) == nil)

        try await #require(workspace.notice?.action).run()

        #expect(exists(agents.appending(path: "skills/pr/SKILL.md")))
        #expect(read(pi.appending(path: "SYSTEM.md")) == "你是 Pi\n" && read(codex.appending(path: "config.toml")) == config)
        #expect(!exists(agents.appending(path: "AGENTS.md")) && !exists(pi.appending(path: "AGENTS.md")))
    }

    /// 编辑页自动存：带着改之前看到的内容（基准）写进文件；文件在别处改过就不写、退回"Mac 上刚改过"，编辑页跟上文件此刻的样子。
    /// 手机发来的改说明与整理（投送请求）由 Mac 照做，结果写回请求。
    @Test func 改说明带基准_别处改过就退回_手机发来的改说明与整理由Mac照做() async throws {
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let folder = home("work/site")
        let project = try await store.createProject(name: "Site", color: "#000000")
        try await store.setDirectory(folder.path, for: project.id)
        try write("# Site\n", folder.appending(path: "AGENTS.md"))
        try write("# 旧的 Claude 说明\n", folder.appending(path: "CLAUDE.md"))
        let keeping = keep()
        defer { keeping.cancel() }
        let workspace = Workspace(services: services)
        let following = Task { await workspace.follow() }
        defer { following.cancel() }

        let found = try await library("扫出项目说明") { $0.instruction(.project(project.id))?.text == "# Site\n" }
        #expect(found.tidies.map(\.title) == ["项目里另有一份不同的 CLAUDE.md"])
        #expect(found.instruction(.project(project.id))?.readers == [], "Claude Code 只读同层的 CLAUDE.md")
        let seen = try #require(found.instruction(.project(project.id)))

        try await workspace.saveInstruction(InstructionEdit(instruction: seen.kind, base: seen.base, text: "# Site\n\n先跑测试\n"), in: found)
        #expect(read(folder.appending(path: "AGENTS.md")) == "# Site\n\n先跑测试\n")
        await #expect(throws: AgentLibraryError.changedOnMac) {
            try await workspace.saveInstruction(InstructionEdit(instruction: seen.kind, base: seen.base, text: "覆盖"), in: found)
        }
        try write("# Site\n\n别处改的\n", folder.appending(path: "AGENTS.md"))
        try await eventually("编辑页读到别处改的") { workspace.library?.instruction(.project(project.id))?.text == "# Site\n\n别处改的\n" }

        try await services.executor.start()
        let current = try #require(workspace.library?.instruction(.project(project.id)))
        let stale = try await store.requestInstructionEdit(InstructionEdit(instruction: current.kind, base: seen.base, text: "手机改的"), title: "Site", on: TestApp.hostID)
        let refused = try await store.outcome(of: stale)
        #expect(refused.failureReason == ShownText(AgentLibraryError.changedOnMac) && refused.failure == "Mac 上刚改过")
        let edit = try await store.requestInstructionEdit(InstructionEdit(instruction: current.kind, base: current.base, text: "手机改的\n"), title: "Site", on: TestApp.hostID)
        #expect(try await store.outcome(of: edit).status == .known(.succeeded))
        #expect(read(folder.appending(path: "AGENTS.md")) == "手机改的\n")

        let tidy = try await store.requestTidy([TidyOrder(tidy: "project-claude/\(project.id.uuidString)")], on: TestApp.hostID)
        #expect(try await store.outcome(of: tidy).status == .known(.succeeded))
        #expect(read(folder.appending(path: "AGENTS.md")) == "手机改的\n\n# 旧的 Claude 说明\n" && !exists(folder.appending(path: "CLAUDE.md")))
        _ = try await library("合成后 Claude Code 读 AGENTS.md") { $0.tidies.isEmpty && $0.instruction(.project(project.id))?.readers == [.claudeCode] }
        services.cancelBackgroundWork()
    }

    /// 说明的编辑页（`InstructionDraft`，Mac 的编辑页与手机的纸页同一份）：停手就存进文件；别处改了而你没在改，当场跟上；
    /// 你改着时别处也改了，你的字留着、不再自动写，等你选——换成文件里的，或留你的盖过它。
    @Test func 编辑页自动存_跟上别处的改动_两边都改时由你选() async throws {
        let file = agents.appending(path: "AGENTS.md")
        try write("# 原则\n", file)
        let keeping = keep()
        defer { keeping.cancel() }
        let workspace = Workspace(services: services)
        let following = Task { await workspace.follow() }
        defer { following.cancel() }
        func snapshot(_ text: String) async throws -> String? {
            try await eventually("快照读到 \(text)") { workspace.library?.instruction(.global)?.text == text }
            return workspace.library?.instruction(.global)?.text
        }
        _ = try await snapshot("# 原则\n")
        let draft = InstructionDraft(try #require(workspace.library?.instruction(.global)), workspace: workspace)

        draft.changed("# 原则\n\n先读\n")
        await draft.leave()
        #expect(read(file) == "# 原则\n\n先读\n" && draft.state == .saved && !draft.dirty)

        try write("# 原则\n\n终端里改的\n", file)
        draft.follow(try await snapshot("# 原则\n\n终端里改的\n"))
        #expect(draft.text == "# 原则\n\n终端里改的\n" && draft.state == .followed && !draft.dirty)

        try write("别处又改\n", file)
        draft.changed("我改的\n")
        await draft.leave()
        draft.follow(try await snapshot("别处又改\n"))
        #expect(draft.state == .conflict(file: "别处又改\n") && draft.text == "我改的\n" && read(file) == "别处又改\n")
        draft.takeFile()
        #expect(draft.text == "别处又改\n" && !draft.dirty)

        try write("第三次\n", file)
        draft.changed("还是我的\n")
        await draft.leave()
        draft.follow(try await snapshot("第三次\n"))
        #expect(draft.conflicted)
        await draft.keepMine()
        #expect(read(file) == "还是我的\n" && draft.state == .saved && !draft.dirty)
    }

    /// 整理之后又改过（编辑页改了合成的说明）：撤销整个不做、说明原因，后来的改动留着。留着的 Pi 系统提示、各家自管的技能照样跟着文件变。
    @Test func 整理之后又改过_撤销整个不做_留着的系统提示照样跟着文件() async throws {
        for directory in [claude, codex, pi] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: codex.appending(path: "skills/.system"), withIntermediateDirectories: true)
        try write("规则一\n", claude.appending(path: "CLAUDE.md"))
        try write("规则二\n", codex.appending(path: "AGENTS.md"))
        try write("你是 Pi\n", pi.appending(path: "SYSTEM.md"))
        let keeping = keep()
        defer { keeping.cancel() }
        let found = try await library("扫出全局规则") { !$0.tidies.isEmpty }
        let workspace = Workspace(services: services)
        await workspace.tidy(found.automaticOrders, in: found)
        let undo = try #require(workspace.notice?.action)
        let merged = try await library("合成好了") { $0.instruction(.global)?.text == "规则一\n\n规则二\n" }
        let global = try #require(merged.instruction(.global))
        try await workspace.saveInstruction(InstructionEdit(instruction: .global, base: global.base, text: "规则一\n\n规则二\n\n后来加的\n"), in: merged)

        await #expect(throws: AgentLibraryError.changedSinceTidy) { try await undo.run() }

        #expect(read(agents.appending(path: "AGENTS.md")) == "规则一\n\n规则二\n\n后来加的\n")
        #expect(RelativeLink.points(claude.appending(path: "CLAUDE.md"), to: agents.appending(path: "AGENTS.md")))
        _ = try await library("读到后来加的") { $0.instruction(.global)?.text?.hasSuffix("后来加的\n") == true }
        await quietPeriod(.milliseconds(300))  // 前面那些改动的跟随都过去了：下面这次只能由盯着 SYSTEM.md 读到
        try Data("你是 Pi，改过\n".utf8).write(to: pi.appending(path: "SYSTEM.md"))  // 原地写，不换文件，所在目录不变
        _ = try await library("系统提示跟上") { $0.instruction(.piSystem)?.text == "你是 Pi，改过\n" }
        try skill("from-claude-ai", in: claude.appending(path: "skills/synced"))
        _ = try await library("自管的计数跟上") { $0.selfManaged == [SelfManagedSkills(agent: .claudeCode, count: 1)] }
        try skill("openai-docs", in: codex.appending(path: "skills/.system"))
        _ = try await library("Codex 自带的多了一个") { $0.selfManaged.contains(SelfManagedSkills(agent: .codex, count: 1)) }
        try FileManager.default.removeItem(at: codex.appending(path: "skills/.system/openai-docs"))
        _ = try await library("Codex 自带的又没了") { $0.selfManaged == [SelfManagedSkills(agent: .claudeCode, count: 1)] }
    }
}
#endif
