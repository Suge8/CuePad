#if os(iOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 手机上的技能与说明：看的是 Mac 报来的快照，整理与改说明都发往那台 Mac、等它做完。改说明攒在纸页上，点纸飞机才发，离开再回来还在；
/// Mac 上刚改过就退回，纸页留着你的字等你选。那台 Mac 由一个领 mac-a 请求的执行器扮演：照基准判断、做完写回新快照（同 Mac 的 `AgentLibraryKeeper`）。
@MainActor
struct AgentLibraryPhoneTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    /// 那台 Mac 上全局说明此刻的正文与有没有要整理的。
    actor Mac {
        var text = "# 原则\n"
        var tidied = false
        let store: CueStore

        init(store: CueStore) { self.store = store }

        func snapshot() -> AgentLibrary {
            let unlinked = LibraryTidy(id: "unlinked", kind: .unlinked([SkillEntry(name: "pr", scope: .global, path: "/Users/a/.agents/skills/pr")]))
            return AgentLibrary(
                hostID: "mac-a", home: "/Users/a",
                skills: [LibrarySkill(name: "pr", description: "写 PR", scope: .global, group: "", path: "/Users/a/.agents/skills/pr")],
                instructions: [LibraryInstruction(kind: .global, path: "/Users/a/.agents/AGENTS.md", text: text, modifiedAt: .now, readers: [.pi])],
                tidies: tidied ? [] : [unlinked], modifiedAt: .now)
        }

        func report() async throws { try await store.recordAgentLibrary(snapshot()) }

        /// 在 Mac 上直接改了文件（终端里、Mac 的编辑页）。
        func edit(_ text: String) async throws {
            self.text = text
            try await report()
        }

        func handle(_ request: DeliveryRequest) async -> DeliveryOutcome {
            if request.tidyOrders != nil { tidied = true }
            if let edit = request.instructionEdit {
                guard edit.base == LibraryInstruction.base(of: text) else { return .failed(ShownText(AgentLibraryError.changedOnMac)) }
                text = edit.text
            }
            try? await report()
            return .succeeded
        }
    }

    @Test func 全部整理发往Mac_改说明攒着点发才写_Mac上刚改过就等你选() async throws {
        let mac = Mac(store: store)
        try await mac.report()
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { await mac.handle($0) }
        try await executor.start()
        defer { Task { await executor.stop() } }
        let workspace = Workspace(services: app.services)
        let following = Task { await workspace.follow() }
        defer { following.cancel() }
        try await eventually("读到 Mac 的快照") { workspace.library?.hostID == "mac-a" }
        let library = try #require(workspace.library)

        await workspace.tidy(library.automaticOrders, in: library)

        #expect(workspace.notice?.text.visible == "整理好了 1 件" && workspace.notice?.action == nil, "手机上的整理撤销在 Mac 上")
        try await eventually("要整理的没了") { workspace.library?.tidies.isEmpty == true }

        let global = try #require(workspace.library?.instruction(.global))
        let opened = workspace.instructionDraft(global)
        opened.changed("# 原则\n\n手机改的\n")
        // 离开说明页再回来：改着的还在，一条都没发
        let draft = workspace.instructionDraft(global)
        let requests = try await store.deliveryRequests()
        #expect(draft === opened && draft.dirty && draft.text == "# 原则\n\n手机改的\n" && requests.allSatisfy { $0.instructionEdit == nil }, "没点纸飞机就不发")

        await draft.send()

        var file = await mac.text
        #expect(file == "# 原则\n\n手机改的\n" && draft.state == .saved && !draft.dirty)
        try await eventually("快照写回") { workspace.library?.instruction(.global)?.text == "# 原则\n\n手机改的\n" }
        draft.follow(workspace.library?.instruction(.global)?.text)
        #expect(draft.state == .saved)

        try await mac.edit("Mac 上改的\n")
        draft.changed("手机又改\n")
        await draft.send()
        try await eventually("快照跟上 Mac") { workspace.library?.instruction(.global)?.text == "Mac 上改的\n" }
        draft.follow(workspace.library?.instruction(.global)?.text)

        file = await mac.text
        #expect(draft.state == .conflict(file: "Mac 上改的\n") && draft.text == "手机又改\n" && file == "Mac 上改的\n")
        await draft.keepMine()
        file = await mac.text
        #expect(file == "手机又改\n" && draft.state == .saved && !draft.dirty)
    }
}
#endif
