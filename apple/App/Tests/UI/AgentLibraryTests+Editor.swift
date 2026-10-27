#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

extension AgentLibraryTests {
    /// 规则的文件页（`FileDraft`，Mac 与手机的文件页同一份）：停手就存进文件；别处改了而你没在改，当场跟上；
    /// 你改着时别处也改了，你的字留着、不再自动写，等你选——换成文件里的（排着没存的那一版也不再写），或留你的盖过它。
    @Test func 规则的文件页自动存_跟上别处的改动_两边都改时由你选() async throws {
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
        let draft = FileDraft(.instruction(.global), text: workspace.library?.instruction(.global)?.text, workspace: workspace)

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

        // 停手前（自动存还排着）别处改了、换成文件里的、马上离开：排着的那一版不再写
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

    /// 技能的文件页：name、description 两个输入框与正文分开改，写回 SKILL.md 时别的 frontmatter 键原样留着；
    /// name 改得和文件夹名不一样，重扫后这个技能带上哪里不对（标在 name 那个框下）。
    @Test func 技能的文件页改name与description与正文_写回文件_其余键留着() async throws {
        let directory = agents.appending(path: "skills/pr")
        let file = directory.appending(path: "SKILL.md")
        try write("---\nname: pr\ndescription: >\n  写 PR\n  描述\nlicense: MIT\n---\n\n旧的正文\n", file)
        let keeping = keep()
        defer { keeping.cancel() }
        let workspace = Workspace(services: services)
        let following = Task { await workspace.follow() }
        defer { following.cancel() }
        try await eventually("快照读到这个技能") { workspace.library?.skill(at: directory.path) != nil }
        let skill = try #require(workspace.library?.skill(at: directory.path))
        #expect(skill.description == "写 PR 描述")
        let draft = FileDraft(.skill(skill.path), text: skill.text, workspace: workspace)
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

    /// 技能与规则页换段只有 `Workspace.libraryPane` 一份（工具栏的分段读写它）：换到技能、打开一份技能再收起、去别页再回来，都还在技能段。
    @Test func 换到技能段_打开技能再收起_换页回来还在技能段() async throws {
        try skill("pr", in: agents.appending(path: "skills"))
        let keeping = keep()
        defer { keeping.cancel() }
        let workspace = Workspace(services: services)
        let following = Task { await workspace.follow() }
        defer { following.cancel() }
        let path = agents.appending(path: "skills/pr").path
        try await eventually("快照读到这个技能") { workspace.library?.skill(at: path) != nil }
        workspace.show(.library)
        #expect(workspace.libraryPane == .rules)

        workspace.libraryPane = .skills
        workspace.openLibrary(.skill(path))
        workspace.overlay = nil
        #expect(workspace.root == .library && workspace.libraryPane == .skills)

        workspace.show(.progress)
        workspace.show(.library)
        #expect(workspace.libraryPane == .skills)
    }
}
#endif