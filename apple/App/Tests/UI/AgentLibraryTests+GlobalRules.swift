#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

extension AgentLibraryTests {
    /// ~/.agents 常是一个仓库，它的 AGENTS.md 只给在那里干活的 Agent 看：不当全局规则，不并进去，也不让别家链过去。
    /// 共享那份还没有时，全局规则列的是各家真读的那份。
    @Test func 共读目录里的AGENTS不算全局规则_一键整理让各家读同一份() async throws {
        let opencode = home("opencode")
        for directory in [claude, codex, opencode] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let map = agents.appending(path: "AGENTS.md"), mapText = "# Agents Directory Map\n\n- skills/：各家共读的技能\n"
        let mine = "# 我的规则\n\n先读后写\n"
        try write(mapText, map)
        try write(mine, pi.appending(path: "AGENTS.md"))
        try write("", codex.appending(path: "AGENTS.md"))
        let keeping = keep()
        defer { keeping.cancel() }

        let found = try await library("扫出全局规则") { $0.tidies.contains { $0.id == "global-instructions" } }
        #expect(found.instructions.allSatisfy { $0.path != map.path }, "全局规则里没有那份目录地图")
        #expect(found.instruction(.global)?.path == rules.path && found.instruction(.global)?.hash == nil)
        let own = try #require(found.instruction(.agent(.pi, file: "AGENTS.md")), "共享那份还没有：列出 Pi 真读的那份")
        #expect(own.path == pi.appending(path: "AGENTS.md").path && own.readers == [.pi] && own.hash == hash(mine))
        #expect(found.instructions.filter { if case .agent = $0.kind { true } else { false } }.count == 1, "空文件与没有的不列")
        #expect(found.merge(into: .global) == nil && found.automaticOrders.map(\.tidy).contains("global-instructions"), "只有 Pi 写了一份：不用合并，一键整理就做")
        #expect(found.tidies.allSatisfy { $0.sources.allSatisfy { $0.path != map.path } })

        await Workspace(services: services).tidy(found.automaticOrders, in: found)

        #expect(read(rules) == mine && read(map) == mapText)
        for file in [pi.appending(path: "AGENTS.md"), claude.appending(path: "rules/AGENTS.md"), codex.appending(path: "AGENTS.md"), opencode.appending(path: "AGENTS.md")] {
            #expect(RelativeLink.points(file, to: rules) && read(file) == mine, "\(file.path) 读到的是同一份")
        }
        let tidied = try await library("各家都读这一份") { Set($0.instruction(.global)?.readers ?? []) == [.pi, .claudeCode, .codex, .opencode] }
        #expect(tidied.tidies.isEmpty && tidied.instruction(.global)?.hash == hash(mine))
        #expect(tidied.instructions.allSatisfy { if case .agent = $0.kind { false } else { true } }, "整理后只剩共享那份")

        let folder = try await store.createProject(name: "Agents", color: "#000000")
        try await store.setDirectory(agents.path, for: folder.id)
        _ = try await library("登记成项目文件夹后才是它的项目规则") { $0.instruction(.project(folder.id))?.path == map.path && $0.instruction(.project(folder.id))?.hash == hash(mapText) }
    }

    /// Claude Code 目录里的 AGENTS.md：Grok 在哪都读，Claude Code 在 ~ 下干活时也读；链好以后它就不读了，所以要并进来，不悄悄丢。
    /// 往上一层有 CLAUDE.md 时 Claude Code 不读项目的 AGENTS.md。
    @Test func Claude目录里只有AGENTS_内容不同就提议合并_整理后都在共享那份里() async throws {
        let grok = home("grok")
        for directory in [claude, grok] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try write("# Pi 的\n", pi.appending(path: "AGENTS.md"))
        try write("# Claude 目录里的\n", claude.appending(path: "AGENTS.md"))
        let site = home("nest/site")
        try write("# Site\n", site.appending(path: "AGENTS.md"))
        try write("# 上一层的\n", home("nest").appending(path: "CLAUDE.md"))
        let project = try await store.createProject(name: "Site", color: "#000000")
        try await store.setDirectory(site.path, for: project.id)
        let keeping = keep()
        defer { keeping.cancel() }

        let found = try await library("扫出要合并的") { $0.merge(into: .global) != nil && $0.instruction(.project(project.id)) != nil }
        let merge = try #require(found.merge(into: .global))
        #expect(Set(merge.writers) == [.pi, .claudeCode] && !found.automaticOrders.map(\.tidy).contains(merge.id), "内容不同：要看过再合并")
        #expect(found.instruction(.agent(.claudeCode, file: "AGENTS.md"))?.readers == [.claudeCode, .grok])
        #expect(found.instruction(.project(project.id))?.readers.contains(.claudeCode) == false, "上一层的 CLAUDE.md 挡着")
        #expect(found.tidies.contains { $0.id == "project-claude/\(project.id.uuidString)" })

        let workspace = Workspace(services: services)
        await workspace.tidy([TidyOrder(tidy: merge.id, base: merge.base)], in: found)

        #expect(workspace.notice?.text.visible == "合并好了")
        #expect(read(rules) == "# Pi 的\n\n# Claude 目录里的\n")
        #expect(!exists(claude.appending(path: "AGENTS.md")) && !exists(claude.appending(path: "CLAUDE.md")))
        #expect(RelativeLink.points(claude.appending(path: "rules/AGENTS.md"), to: rules) && RelativeLink.points(grok.appending(path: "AGENTS.md"), to: rules))
        _ = try await library("合并完全局规则没有要整理的") { $0.merge(into: .global) == nil && !$0.tidies.contains { $0.id == "global-instructions" } }

        try await #require(workspace.notice?.action).run()

        #expect(read(claude.appending(path: "AGENTS.md")) == "# Claude 目录里的\n" && !exists(rules))
    }
}
#endif
