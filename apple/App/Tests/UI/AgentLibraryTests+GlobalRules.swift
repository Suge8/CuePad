#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

extension AgentLibraryTests {
    /// ~/.agents 常是一个仓库，它的 AGENTS.md 只给在那里干活的 Agent 看：不当全局规则，不并进去，也不让别家链过去。
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
        #expect(found.instruction(.global)?.path == rules.path && found.instructions.allSatisfy { $0.path != map.path }, "全局规则里没有那份目录地图")
        #expect(found.merge(into: .global) == nil && found.automaticOrders.map(\.tidy).contains("global-instructions"), "只有 Pi 写了一份：不用合并，一键整理就做")
        #expect(found.tidies.allSatisfy { $0.sources.allSatisfy { $0.path != map.path } })

        await Workspace(services: services).tidy(found.automaticOrders, in: found)

        #expect(read(rules) == mine && read(map) == mapText)
        for file in [pi.appending(path: "AGENTS.md"), claude.appending(path: "CLAUDE.md"), codex.appending(path: "AGENTS.md"), opencode.appending(path: "AGENTS.md")] {
            #expect(RelativeLink.points(file, to: rules) && read(file) == mine, "\(file.path) 读到的是同一份")
        }
        let tidied = try await library("各家都读这一份") { Set($0.instruction(.global)?.readers ?? []) == [.pi, .claudeCode, .codex, .opencode] }
        #expect(tidied.tidies.isEmpty && tidied.instruction(.global)?.hash == hash(mine))

        let folder = try await store.createProject(name: "Agents", color: "#000000")
        try await store.setDirectory(agents.path, for: folder.id)
        _ = try await library("登记成项目文件夹后才是它的项目规则") { $0.instruction(.project(folder.id))?.path == map.path && $0.instruction(.project(folder.id))?.hash == hash(mapText) }
    }
}
#endif
