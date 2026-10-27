#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

extension AgentLibraryTests {
    /// 同名的各份都列在技能里，带着同名的那件；在其中一份的文件页上"只留这份"，只移走和它撞名的，别的项目里的不动。格式不对的照列，带着哪里不对。
    @Test func 去重只留一份_格式不对的照列出来_都能撤销() async throws {
        for directory in [claude, codex] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let folder = home("work/app"), other = home("work/blog")
        let project = try await store.createProject(name: "App", color: "#000000")
        let blog = try await store.createProject(name: "Blog", color: "#000000")
        try await store.setDirectory(folder.path, for: project.id)
        try await store.setDirectory(other.path, for: blog.id)
        try skill("pr", in: agents.appending(path: "skills"))
        try skill("pr", in: folder.appending(path: ".agents/skills"))
        try skill("pr", in: other.appending(path: ".agents/skills"))
        // 两个项目各自撞名（一份在旧目录里）：各是一件
        for root in [folder, other] {
            try skill("lint", in: root.appending(path: ".agents/skills"))
            try skill("lint", in: root.appending(path: ".codex/skills"))
        }
        try skill("broken", in: agents.appending(path: "skills"), named: "Broken")
        try FileManager.default.createDirectory(at: agents.appending(path: "skills/binary"), withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00]).write(to: agents.appending(path: "skills/binary/SKILL.md"))
        let keeping = keep()
        defer { keeping.cancel() }

        let found = try await library("扫出同名的") { $0.tidies.filter { if case .duplicate = $0.kind { true } else { false } }.count == 3 }
        let lintInApp = "duplicate/lint/\(project.id.uuidString)", lintInBlog = "duplicate/lint/\(blog.id.uuidString)"
        #expect(found.tidies.map(\.id).prefix(3) == [lintInApp, lintInBlog, "duplicate/pr"] && found.automaticOrders.allSatisfy { !$0.tidy.hasPrefix("duplicate") })
        #expect(found.skills.filter { $0.name == "pr" }.count == 3 && found.skills.filter { $0.name == "lint" }.count == 4, "同名的各份都列出来，旧目录里那份也在")
        #expect(found.skill(at: agents.appending(path: "skills/broken").path)?.problem == .nameMismatch("Broken"))
        #expect(found.skill(at: agents.appending(path: "skills/binary").path)?.problem == .unreadable)
        let projectCopy = folder.appending(path: ".agents/skills/pr").path
        #expect(found.duplicate(of: projectCopy)?.id == "duplicate/pr")

        let workspace = Workspace(services: services)
        await workspace.tidy([TidyOrder(tidy: "duplicate/pr", keep: projectCopy)], in: found)

        #expect(workspace.notice?.text.visible == "只留了这份，其余进了废纸篓")
        // 留项目里的那份：移走的只是和它撞名的全局那份，另一个项目的不动
        #expect(!exists(agents.appending(path: "skills/pr")) && exists(URL(filePath: projectCopy)) && exists(other.appending(path: ".agents/skills/pr")))
        let kept = try await library("pr 不再同名") { $0.duplicate(of: projectCopy) == nil }
        #expect(kept.skills.filter { $0.name == "pr" }.map(\.path) == [projectCopy, other.appending(path: ".agents/skills/pr").path])

        try await #require(workspace.notice?.action).run()

        #expect(exists(agents.appending(path: "skills/pr/SKILL.md")))
        _ = try await library("撤销后 pr 又同名") { $0.duplicate(of: projectCopy) != nil }
    }

    /// 内容不同的全局规则：行末是另写了一份的那家，合并前先标出会并进来的段；替换基础提示的两份勾了才并进来并撤掉（Pi 的进废纸篓、Codex 的撤掉配置键）。
    @Test func 合并进来_撤掉选中的替换基础提示_能撤销() async throws {
        for directory in [claude, codex, pi] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try write("共用的\n", agents.appending(path: "AGENTS.md"))
        try write("全局规则\n", claude.appending(path: "CLAUDE.md"))
        try write("你是 Pi\n", pi.appending(path: "SYSTEM.md"))
        try write("你是 Codex\n", codex.appending(path: "prompt.md"))
        try write("", codex.appending(path: "AGENTS.md"))  // 空文件等同没有：不算 Codex 写了一份、不进合并
        let config = "model = \"gpt\"\nmodel_instructions_file = \"prompt.md\"\n\n[tools]\nweb = true\n"
        try write(config, codex.appending(path: "config.toml"))
        let keeping = keep()
        defer { keeping.cancel() }

        let found = try await library("扫出全局规则") { $0.tidies.map(\.id) == ["global-instructions"] }
        let merge = try #require(found.merge(into: .global))
        #expect(found.automaticOrders.isEmpty && merge.writers == [.claudeCode])
        #expect(merge.sources.map(\.origin) == [.shared, .agent(.claudeCode), .piSystem, .codexPrompt])
        let preview = merge.preview(retiring: [.piSystem], texts: try await texts(.instruction(.global), in: found))
        #expect(preview.map(\.text) == ["共用的", "全局规则", "你是 Pi"])
        #expect(preview.map(\.incoming) == [false, true, true], "标出会并进来的段")
        #expect(try await text(.instruction(.piSystem), in: found) == "你是 Pi\n")

        let workspace = Workspace(services: services)
        await workspace.tidy([TidyOrder(tidy: merge.id, retire: [.piSystem, .codexPrompt])], in: found)

        #expect(workspace.notice?.text.visible == "合并好了")
        #expect(read(agents.appending(path: "AGENTS.md")) == "共用的\n\n全局规则\n\n你是 Pi\n\n你是 Codex\n")
        #expect(RelativeLink.points(codex.appending(path: "AGENTS.md"), to: agents.appending(path: "AGENTS.md")), "空的那份换成链接")
        #expect(RelativeLink.points(claude.appending(path: "CLAUDE.md"), to: agents.appending(path: "AGENTS.md")))
        #expect(!exists(pi.appending(path: "SYSTEM.md")))
        #expect(read(codex.appending(path: "config.toml")) == "model = \"gpt\"\n\n[tools]\nweb = true\n")
        let merged = try await library("合并完没有该整理的") { $0.tidies.isEmpty }
        let global = try #require(merged.instruction(.global))
        #expect(merged.instruction(.piSystem) == nil && merged.unseen(global) == [])

        try await #require(workspace.notice?.action).run()

        #expect(read(claude.appending(path: "CLAUDE.md")) == "全局规则\n" && read(agents.appending(path: "AGENTS.md")) == "共用的\n")
        #expect(read(pi.appending(path: "SYSTEM.md")) == "你是 Pi\n" && read(codex.appending(path: "config.toml")) == config)
    }
}
#endif
