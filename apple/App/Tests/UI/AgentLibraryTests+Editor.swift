#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

extension AgentLibraryTests {
    @Test func 规则的文件页自动存_跟上别处的改动_两边都改时由你选() async throws {
        let file = rules
        let keeping = keep()
        defer { await keeping.stop() }
        let workspace = Workspace(services: services)
        let following = Task { await workspace.follow() }
        defer { await following.stop() }
        func snapshot(_ text: String) async throws -> String? {
            try await eventually("快照读到 \(text)") { workspace.library?.instruction(.global)?.hash == hash(text) }
            return try await self.text(.instruction(.global), in: try #require(workspace.library))
        }
        try await eventually("快照里有还没文件的全局规则") { workspace.library?.instruction(.global) != nil }
        let draft = FileDraft(.instruction(.global), text: nil, workspace: workspace)

        draft.changed(body: "# 原则\n")
        await draft.leave()
        #expect(read(file) == "# 原则\n" && draft.state == .saved && !draft.dirty)

        draft.changed(body: "# 原则\n\n先读\n")
        await draft.leave()
        #expect(read(file) == "# 原则\n\n先读\n" && draft.state == .saved && !draft.dirty)

        try write("# 原则\n\n终端里改的\n", file)
        draft.follow(try await snapshot("# 原则\n\n终端里改的\n"))
        #expect(draft.body == "# 原则\n\n终端里改的\n" && draft.state == .followed && !draft.dirty)

        try write("别处又改\n", file)
        draft.changed(body: "我改的\n")
        await draft.leave()
        draft.follow(try await snapshot("别处又改\n"))
        #expect(draft.state == .conflict(file: "别处又改\n") && draft.body == "我改的\n" && read(file) == "别处又改\n")
        draft.takeFile()
        #expect(draft.body == "别处又改\n" && !draft.dirty)

        // 不等快照：照编辑页收到快照那一下直接跟，整段在自动存的停顿之内做完
        draft.changed(body: "排着没存的\n")
        try write("别处再改\n", file)
        draft.follow("别处再改\n")
        draft.takeFile()
        await draft.leave()
        #expect(read(file) == "别处再改\n" && draft.body == "别处再改\n" && !draft.dirty)

        try write("第三次\n", file)
        draft.changed(body: "还是我的\n")
        await draft.leave()
        draft.follow(try await snapshot("第三次\n"))
        #expect(draft.conflicted)
        await draft.keepMine()
        #expect(read(file) == "还是我的\n" && draft.state == .saved && !draft.dirty)
    }

    @Test func 技能的文件页改name与description与正文_写回文件_其余键留着() async throws {
        let directory = agents.appending(path: "skills/pr")
        let file = directory.appending(path: "SKILL.md")
        try write("---\nname: pr\ndescription: >\n  写 PR\n  描述\nlicense: MIT\n---\n\n旧的正文\n", file)
        let keeping = keep()
        defer { await keeping.stop() }
        let workspace = Workspace(services: services)
        let following = Task { await workspace.follow() }
        defer { await following.stop() }
        try await eventually("快照读到这个技能") { workspace.library?.skill(at: directory.path) != nil }
        let skill = try #require(workspace.library?.skill(at: directory.path))
        #expect(skill.description == "写 PR 描述")
        let draft = FileDraft(.skill(skill.path), text: try await text(.skill(skill.path), in: try #require(workspace.library)), workspace: workspace)
        #expect(draft.name == "pr" && draft.summary == "写 PR 描述" && draft.body == "旧的正文\n", "正文从第一行字起，frontmatter 后的空行写回时放回")

        draft.changed(summary: "用法: 先读模板")
        draft.changed(body: "新的正文\n")
        await draft.leave()

        #expect(read(file) == "---\nname: pr\ndescription: \"用法: 先读模板\"\nlicense: MIT\n---\n\n新的正文\n")
        #expect(draft.state == .saved && !draft.dirty)
        try await eventually("快照读到新的说明") { workspace.library?.skill(at: directory.path)?.description == "用法: 先读模板" }

        draft.changed(name: "pr-new")
        await draft.leave()

        #expect(read(file) == "---\nname: pr-new\ndescription: \"用法: 先读模板\"\nlicense: MIT\n---\n\n新的正文\n")
        try await eventually("重扫标出 name 不对") { workspace.library?.skill(at: directory.path)?.problem == .nameMismatch("pr-new") }
        #expect(workspace.library?.skill(at: directory.path)?.problem?.field == .name)
    }

    @Test func 写入途中别处改了_冲突提示保持() async throws {
        let file = rules
        try write("# a\n", file)
        let keeping = keep()
        defer { await keeping.stop() }
        let workspace = Workspace(services: services)
        let following = Task { await workspace.follow() }
        defer { await following.stop() }
        try await eventually("快照有全局规则") { workspace.library?.instruction(.global)?.hash == hash("# a\n") }
        let draft = FileDraft(.instruction(.global), text: "# a\n", workspace: workspace)

        draft.changed(body: "mine\n")
        let writing = Task { await draft.send() }
        try await yieldUntil("写入进入保存中") { draft.state == .saving }
        #expect(draft.state == .saving, "写入在途中")
        try write("ext\n", file)
        draft.follow("ext\n")
        await writing.value

        #expect(draft.state == .conflict(file: "ext\n") && draft.dirty, "旧写入完成后冲突还在：\(draft.state)")
    }

    private func ready(_ text: String) async throws -> (FileDraft, Task<Void, Never>, Task<Void, Never>) {
        try write(text, rules)
        let keeping = keep()
        let workspace = Workspace(services: services)
        let following = Task { await workspace.follow() }
        try await eventually("快照") { workspace.library?.instruction(.global)?.hash == hash(text) }
        return (FileDraft(.instruction(.global), text: text, workspace: workspace), keeping, following)
    }

    @Test func 自己写入的回声先到_期间又打了字_不报冲突() async throws {
        let (draft, keeping, following) = try await ready("# a\n")
        defer { await keeping.stop(); await following.stop() }
        draft.changed(body: "v1\n")
        let writing = Task { await draft.send() }
        try await yieldUntil("写入进入保存中") { draft.state == .saving }
        draft.changed(body: "v2\n")
        draft.follow("v1\n")
        await writing.value
        #expect(!draft.conflicted, "把自己的写入误报成冲突：\(draft.state)")
        await draft.leave()
        #expect(read(rules) == "v2\n" && draft.state == .saved)
    }

    @Test func 冲突后文件改回基准或变得和我的一样_冲突自动解除() async throws {
        let (draft, keeping, following) = try await ready("# a\n")
        defer { await keeping.stop(); await following.stop() }
        draft.changed(body: "mine\n")
        draft.follow("ext\n")
        #expect(draft.conflicted)
        draft.follow("# a\n")
        #expect(!draft.conflicted && draft.dirty, "回到基准：没有别处的改动了，我的字照常存")
        await draft.leave()
        #expect(draft.state == .saved && read(rules) == "mine\n")

        draft.changed(body: "mine2\n")
        draft.follow("ext2\n")
        #expect(draft.conflicted)
        draft.follow("mine2\n")
        #expect(draft.state == .saved && !draft.dirty, "变得和我的一样：已保存")
    }
}
#endif
