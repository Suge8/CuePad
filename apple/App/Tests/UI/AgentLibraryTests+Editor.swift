#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

extension AgentLibraryTests {
    /// 说明的编辑页（`InstructionDraft`，Mac 的编辑页与手机的纸页同一份）：停手就存进文件；别处改了而你没在改，当场跟上；
    /// 你改着时别处也改了，你的字留着、不再自动写，等你选——换成文件里的（排着没存的那一版也不再写），或留你的盖过它。
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

        // 停手前（自动存还排着）别处改了、换成文件里的、马上离开：排着的那一版不再写
        // 不等快照：照编辑页收到快照那一下直接跟，整段在自动存的停顿之内做完
        draft.changed("排着没存的\n")
        try write("别处再改\n", file)
        draft.follow("别处再改\n")
        draft.takeFile()
        await draft.leave()
        #expect(read(file) == "别处再改\n" && draft.text == "别处再改\n" && !draft.dirty)

        try write("第三次\n", file)
        draft.changed("还是我的\n")
        await draft.leave()
        draft.follow(try await snapshot("第三次\n"))
        #expect(draft.conflicted)
        await draft.keepMine()
        #expect(read(file) == "还是我的\n" && draft.state == .saved && !draft.dirty)
    }
}
#endif
