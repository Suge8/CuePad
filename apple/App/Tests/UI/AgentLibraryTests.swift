#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

/// 各家的目录都在临时目录里（`TestApp.agentHomes`）。
@MainActor
struct AgentLibraryTests {
    let app = TestApp()
    var services: AppServices { app.services }
    var store: CueStore { services.store }

    func home(_ name: String) -> URL { app.directory.appending(path: name, directoryHint: .isDirectory) }
    var agents: URL { home("agents") }
    var rules: URL { home("config/agents").appending(path: "AGENTS.md") }
    var claude: URL { home("claude") }
    var codex: URL { home("codex") }
    var dsh: URL { home("dsh") }
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

    nonisolated func hash(_ text: String) -> String { LibraryEdit.base(of: text) }

    func text(_ file: LibraryFile, in library: AgentLibrary, store: CueStore? = nil) async throws -> String? {
        let texts = try await (store ?? self.store).agentLibraryTexts(host: library.hostID, paths: library.textPaths(for: file))
        return library.arrived(file, in: texts) ?? nil
    }

    func texts(_ file: LibraryFile, in library: AgentLibrary) async throws -> [String: String] {
        try await store.agentLibraryTexts(host: library.hostID, paths: library.textPaths(for: file))
    }

    func keep() -> Task<Void, Never> { Task { try? await services.library.keep() } }

    func library(_ what: String, _ condition: @escaping @Sendable (AgentLibrary) -> Bool) async throws -> AgentLibrary {
        let host = TestApp.hostID
        return try #require(try await eventually(store, { try $0.agentLibrary(host: host) }) { $0.map(condition) ?? false })
    }

    /// dsh 只读 `.agents/skills` 一层：分类里的链给它，搬到第一层的不用。
    @Test func 一键整理只做不用选的几件_撤销恢复这一次的全部改动() async throws {
        for directory in [claude, codex, dsh] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try skill("write-swift", in: agents.appending(path: "skills/development"))
        try skill("retro", in: codex.appending(path: "skills"))
        try FileManager.default.createDirectory(at: codex.appending(path: "skills/codex-primary-runtime"), withIntermediateDirectories: true)
        try skill("openai-docs", in: codex.appending(path: "skills/.system"))
        try skill("from-claude-ai", in: claude.appending(path: "skills/synced/account-a"))
        try skill("pdf", in: claude.appending(path: "skills/synced/account-b"))
        try write("# 原则\n\n先读后写\n", claude.appending(path: "CLAUDE.md"))
        try write("# 原则\n\n先读后写\n\n求证：以证据为准\n", codex.appending(path: "AGENTS.md"))
        let uploads = app.sync.uploads.stream
        let keeping = keep()
        defer { keeping.cancel() }

        let found = try await library("扫出五件") { $0.tidies.count == 5 }
        let workspace = Workspace(services: services)
        #expect(found.automaticTidies.map { workspace.fact(of: $0, in: found) } == ["1 个技能在旧目录里", "1 个技能 Claude Code 读不到", "1 个技能 DeepSeek Harness 读不到", "1 个空文件夹"])
        #expect(found.merge(into: .global)?.writers == [.claudeCode, .codex], "内容不同的全局规则不在一键整理里，在全局规则的文件页里合并")
        #expect(found.skills.map(\.name) == ["write-swift"] && found.skills[0].group == "development" && found.skills[0].unseenBy == [.claudeCode, .dsh])
        #expect(found.selfManaged == [SelfManagedSkills(agent: .claudeCode, count: 2), SelfManagedSkills(agent: .codex, count: 1)])
        #expect(found.instruction(.global)?.hash == nil)
        // 快照与各份正文同一批传，批内按记录名排
        let snapshot = AgentLibrary.recordID(host: TestApp.hostID).uuidString.lowercased()
        var uploaded = uploads.makeAsyncIterator()
        while let name = await uploaded.next(), name != snapshot {}

        await workspace.tidy(found.automaticOrders, in: found)

        #expect(workspace.notice?.text.visible == "整理好了 4 件")
        let moved = agents.appending(path: "skills/retro")
        #expect(exists(moved.appending(path: "SKILL.md")) && !exists(codex.appending(path: "skills/retro")))
        #expect(RelativeLink.points(claude.appending(path: "skills/retro"), to: moved))
        #expect(RelativeLink.points(claude.appending(path: "skills/write-swift"), to: agents.appending(path: "skills/development/write-swift")))
        #expect(RelativeLink.points(dsh.appending(path: "skills/write-swift"), to: agents.appending(path: "skills/development/write-swift")))
        #expect(!exists(dsh.appending(path: "skills/retro")), "第一层的 dsh 自己读得到")
        #expect(!exists(codex.appending(path: "skills/codex-primary-runtime")))
        #expect(!RelativeLink.isLink(claude.appending(path: "CLAUDE.md")) && !exists(rules), "规则一个字没动")
        let tidied = try await library("只剩要合并的全局规则") { $0.tidies.map(\.id) == ["global-instructions"] }
        #expect(tidied.skills.allSatisfy(\.unseenBy.isEmpty) && tidied.skills.map(\.name) == ["write-swift", "retro"])

        try await #require(workspace.notice?.action).run()

        #expect(exists(codex.appending(path: "skills/retro/SKILL.md")) && !exists(moved))
        #expect(!exists(claude.appending(path: "skills/write-swift")) && !exists(claude.appending(path: "skills/retro")) && !exists(dsh.appending(path: "skills/write-swift")))
        #expect(exists(codex.appending(path: "skills/codex-primary-runtime")))
        _ = try await library("撤销后又是五件") { $0.tidies.count == 5 }
    }

    @Test func 改规则带基准_别处改过就退回_合并项目里的CLAUDE文件() async throws {
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let folder = home("work/site")
        let project = try await store.createProject(name: "Site", color: "#000000")
        try await store.setDirectory(folder.path, for: project.id)
        try write("# Site\n", folder.appending(path: "AGENTS.md"))
        try write("# 旧的 Claude 说明\n", folder.appending(path: "CLAUDE.md"))
        try write("# 藏在 .claude 里的\n", folder.appending(path: ".claude/CLAUDE.md"))
        try write("# 我自己的\n", folder.appending(path: "CLAUDE.local.md"))
        let keeping = keep()
        defer { keeping.cancel() }
        let workspace = Workspace(services: services)
        let following = Task { await workspace.follow() }
        defer { following.cancel() }

        let found = try await library("扫出项目规则") { $0.instruction(.project(project.id))?.hash == hash("# Site\n") }
        #expect(found.merge(into: .project(project.id))?.writers == [.claudeCode] && found.automaticOrders.isEmpty)
        #expect(found.instruction(.project(project.id))?.readers == [], "有 CLAUDE.md 一类的 Claude Code 就不读 AGENTS.md")
        #expect(found.tidies.first?.sources.map(\.path) == ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md"].map { folder.appending(path: $0).path })
        let seen = try #require(found.instruction(.project(project.id)))

        let file = LibraryFile.instruction(seen.kind)
        try await workspace.saveFile(LibraryEdit(file: file, base: seen.hash ?? "", text: "# Site\n\n先跑测试\n"), in: found)
        #expect(read(folder.appending(path: "AGENTS.md")) == "# Site\n\n先跑测试\n")
        await #expect(throws: AgentLibraryError.changedOnMac) {
            try await workspace.saveFile(LibraryEdit(file: file, base: seen.hash ?? "", text: "覆盖"), in: found)
        }
        try write("# Site\n\n别处改的\n", folder.appending(path: "AGENTS.md"))
        try await eventually("编辑页读到别处改的") { workspace.library?.instruction(.project(project.id))?.hash == hash("# Site\n\n别处改的\n") }

        await workspace.tidy([TidyOrder(tidy: "project-claude/\(project.id.uuidString)")], in: found)

        #expect(workspace.notice?.text.visible == "合并好了")
        #expect(read(folder.appending(path: "AGENTS.md")) == "# Site\n\n别处改的\n\n# 旧的 Claude 说明\n\n# 藏在 .claude 里的\n")
        #expect(RelativeLink.points(folder.appending(path: "CLAUDE.md"), to: folder.appending(path: "AGENTS.md")), "同全局：CLAUDE.md 换成链到 AGENTS.md 的链接")
        #expect(!exists(folder.appending(path: ".claude/CLAUDE.md")) && read(folder.appending(path: "CLAUDE.local.md")) == "# 我自己的\n")
        _ = try await library("合并后 Claude Code 经链接读 AGENTS.md") { $0.tidies.isEmpty && $0.instruction(.project(project.id))?.readers == [.claudeCode] }
    }

    @Test func 合并之后又改过_撤销整个不做_留着的系统提示照样跟着文件() async throws {
        for directory in [claude, codex, pi] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: codex.appending(path: "skills/.system"), withIntermediateDirectories: true)
        try write("规则一\n", claude.appending(path: "CLAUDE.md"))
        try write("规则二\n", codex.appending(path: "AGENTS.md"))
        try write("你是 Pi\n", pi.appending(path: "SYSTEM.md"))
        let keeping = keep()
        defer { keeping.cancel() }
        let found = try await library("扫出全局规则") { !$0.tidies.isEmpty }
        let workspace = Workspace(services: services)
        await workspace.tidy([TidyOrder(tidy: "global-instructions")], in: found)
        let undo = try #require(workspace.notice?.action)
        let merged = try await library("合并好了") { $0.instruction(.global)?.hash == hash("规则一\n\n规则二\n") }
        let global = try #require(merged.instruction(.global))
        try await workspace.saveFile(
            LibraryEdit(file: .instruction(.global), base: global.hash ?? "", text: "规则一\n\n规则二\n\n后来加的\n"), in: merged)

        await #expect(throws: AgentLibraryError.changedSinceTidy) { try await undo.run() }

        #expect(read(rules) == "规则一\n\n规则二\n\n后来加的\n")
        #expect(RelativeLink.points(claude.appending(path: "rules/AGENTS.md"), to: rules))
        _ = try await library("读到后来加的") { $0.instruction(.global)?.hash == hash("规则一\n\n规则二\n\n后来加的\n") }
        await quietPeriod(.milliseconds(300))  // 前面那些改动的跟随都过去了：下面这次只能由盯着 SYSTEM.md 读到
        try Data("你是 Pi，改过\n".utf8).write(to: pi.appending(path: "SYSTEM.md"))  // 原地写，不换文件，所在目录不变
        _ = try await library("系统提示跟上") { $0.instruction(.piSystem)?.hash == hash("你是 Pi，改过\n") }
        try skill("from-claude-ai", in: claude.appending(path: "skills/synced/account-a"))
        _ = try await library("自管的计数跟上") { $0.selfManaged == [SelfManagedSkills(agent: .claudeCode, count: 1)] }
        try skill("docx", in: claude.appending(path: "skills/synced/account-a"))  // 账号那一层也盯着
        _ = try await library("同一个账号里又多一个") { $0.selfManaged == [SelfManagedSkills(agent: .claudeCode, count: 2)] }
        try skill("openai-docs", in: codex.appending(path: "skills/.system"))
        _ = try await library("Codex 自带的多了一个") { $0.selfManaged.contains(SelfManagedSkills(agent: .codex, count: 1)) }
        try FileManager.default.removeItem(at: codex.appending(path: "skills/.system/openai-docs"))
        _ = try await library("Codex 自带的又没了") { $0.selfManaged == [SelfManagedSkills(agent: .claudeCode, count: 2)] }
    }
}
#endif
