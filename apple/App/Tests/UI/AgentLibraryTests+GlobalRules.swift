#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CueBridge

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
        defer { await keeping.stop() }

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

    /// 整理会挡住或替换的各家真读的那几份都进比对、并进共享那份，不悄悄丢：Claude Code 目录里的 AGENTS.md（Claude Code 在 ~ 下干活时读）、
    /// Grok 认的字面 ~/.claude 里那份（测试里 Claude Code 的配置目录另在别处）、链到别处的那份（只挪链接，它指的文件不动）。
    /// Claude Code `rules/` 下自己写的照列、不碰。往上一层有 CLAUDE.md 时 Claude Code 不读项目的 AGENTS.md。
    @Test func 各家真读的都进比对_内容不同就提议合并_整理后都在共享那份里() async throws {
        let grok = home("grok"), literal = home("home/.claude")
        for directory in [claude, grok, codex] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try write("# Pi 的\n", pi.appending(path: "AGENTS.md"))
        try write("# Claude 目录里的\n", claude.appending(path: "AGENTS.md"))
        try write("# 安全\n", claude.appending(path: "rules/security.md"))
        try write("# Grok 读的\n", literal.appending(path: "CLAUDE.md"))
        let mine = home("mine.md")
        try write("# Codex 链的\n", mine)
        try RelativeLink.make(at: codex.appending(path: "AGENTS.md"), to: mine)
        let site = home("nest/site")
        try write("# Site\n", site.appending(path: "AGENTS.md"))
        try write("# 上一层的\n", home("nest").appending(path: "CLAUDE.md"))
        let project = try await store.createProject(name: "Site", color: "#000000")
        try await store.setDirectory(site.path, for: project.id)
        let keeping = keep()
        defer { await keeping.stop() }

        let found = try await library("扫出要合并的") { $0.merge(into: .global) != nil && $0.instruction(.project(project.id)) != nil }
        let merge = try #require(found.merge(into: .global))
        #expect(Set(merge.writers) == [.pi, .claudeCode, .grok, .codex] && !found.automaticOrders.map(\.tidy).contains(merge.id), "内容不同：要看过再合并")
        #expect(found.instruction(.agent(.claudeCode, file: "AGENTS.md"))?.readers == [.claudeCode])
        #expect(found.instruction(.agent(.grok, file: "~/.claude/CLAUDE.md"))?.readers == [.grok])
        #expect(found.instruction(.agent(.codex, file: "AGENTS.md"))?.hash == hash("# Codex 链的\n"), "链到别处的照列它读到的")
        #expect(found.instruction(.agent(.claudeCode, file: "rules/security.md"))?.readers == [.claudeCode])
        #expect(found.instruction(.project(project.id))?.readers.contains(.claudeCode) == false, "上一层的 CLAUDE.md 挡着")
        #expect(found.tidies.contains { $0.id == "project-claude/\(project.id.uuidString)" })

        let workspace = Workspace(services: services)
        await workspace.tidy([TidyOrder(tidy: merge.id, base: merge.base)], in: found)

        #expect(workspace.notice?.text.visible == "合并好了")
        let merged = read(rules) ?? ""
        for part in ["# Pi 的", "# Claude 目录里的", "# Grok 读的", "# Codex 链的"] { #expect(merged.contains(part), "\(part) 并进来了") }
        #expect(!merged.contains("# 安全") && read(claude.appending(path: "rules/security.md")) == "# 安全\n")
        #expect(!exists(claude.appending(path: "AGENTS.md")) && !exists(claude.appending(path: "CLAUDE.md")) && !exists(literal.appending(path: "CLAUDE.md")))
        #expect(read(mine) == "# Codex 链的\n")
        for link in [claude.appending(path: "rules/AGENTS.md"), grok.appending(path: "AGENTS.md"), codex.appending(path: "AGENTS.md")] {
            #expect(RelativeLink.points(link, to: rules), "\(link.path) 链到共享那份")
        }
        let tidied = try await library("合并完全局规则没有要整理的") { $0.merge(into: .global) == nil && !$0.tidies.contains { $0.id == "global-instructions" } }
        #expect(tidied.instruction(.agent(.claudeCode, file: "rules/security.md")) != nil, "整理后照列 Claude Code 另读的")

        try await #require(workspace.notice?.action).run(workspace)

        #expect(read(claude.appending(path: "AGENTS.md")) == "# Claude 目录里的\n" && read(literal.appending(path: "CLAUDE.md")) == "# Grok 读的\n" && !exists(rules))
        #expect(RelativeLink.points(codex.appending(path: "AGENTS.md"), to: mine))
    }
}
#endif
