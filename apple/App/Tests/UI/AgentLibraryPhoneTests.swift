#if os(iOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 手机上的技能与规则：看的是 Mac 报来的快照，整理与改文件都发往那台 Mac、等它做完。改动攒在文件页上，点纸飞机才发，离开再回来还在；
/// Mac 上刚改过就退回，文件页留着你的字等你选。那台 Mac 由一个领 mac-a 请求的执行器扮演：照基准判断、做完写回新快照（同 Mac 的 `AgentLibraryKeeper`）。
@MainActor
struct AgentLibraryPhoneTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    nonisolated static let skillPath = "/Users/a/.agents/skills/pr"

    /// 那台 Mac 上全局规则与 pr 这个技能此刻的样子，与有没有该整理的。
    actor Mac {
        var text = "# 原则\n"
        var skill = "---\nname: pr\ndescription: 写 PR\nlicense: MIT\n---\n\n先读模板\n"
        var tidied = false
        let store: CueStore

        init(store: CueStore) { self.store = store }

        func snapshot() -> AgentLibrary {
            let unlinked = LibraryTidy(id: "unlinked/claude", kind: .unlinked(agent: .claudeCode, skills: [SkillEntry(name: "pr", scope: .global, path: AgentLibraryPhoneTests.skillPath)]))
            return AgentLibrary(
                hostID: "mac-a", home: "/Users/a",
                skills: [LibrarySkill(name: "pr", scope: .global, group: "", path: AgentLibraryPhoneTests.skillPath, text: skill)],
                instructions: [LibraryInstruction(kind: .global, path: "/Users/a/.agents/AGENTS.md", text: text, modifiedAt: .now, readers: [.pi])],
                tidies: tidied ? [] : [unlinked], modifiedAt: .now)
        }

        func report() async throws { try await store.recordAgentLibrary(snapshot()) }

        /// 在 Mac 上直接改了文件（终端里、Mac 的文件页）。
        func edit(_ text: String) async throws {
            self.text = text
            try await report()
        }

        func editSkill(_ text: String) async throws {
            skill = text
            try await report()
        }

        func handle(_ request: DeliveryRequest) async -> DeliveryOutcome {
            if request.tidyOrders != nil { tidied = true }
            if let edit = request.libraryEdit {
                let current = edit.file == .instruction(.global) ? text : skill
                guard edit.base == LibraryEdit.base(of: current) else { return .failed(ShownText(AgentLibraryError.changedOnMac)) }
                if edit.file == .instruction(.global) { text = edit.text } else { skill = edit.text }
            }
            try? await report()
            return .succeeded
        }
    }

    func start() async throws -> (Mac, Workspace, () -> Void) {
        let mac = Mac(store: store)
        try await mac.report()
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { await mac.handle($0) }
        try await executor.start()
        let workspace = Workspace(services: app.services)
        let following = Task { await workspace.follow() }
        try await eventually("读到 Mac 的快照") { workspace.library?.hostID == "mac-a" }
        return (mac, workspace, {
            following.cancel()
            Task { await executor.stop() }
        })
    }

    @Test func 一键整理发往Mac_改规则攒着点发才写_Mac上刚改过就等你选() async throws {
        let (mac, workspace, stop) = try await start()
        defer { stop() }
        let library = try #require(workspace.library)

        await workspace.tidy(library.automaticOrders, in: library)

        #expect(workspace.notice?.text.visible == "整理好了 1 件" && workspace.notice?.action == nil, "手机上的整理没有撤销：Mac 照做、不留撤销")
        try await eventually("该整理的没了") { workspace.library?.tidies.isEmpty == true }

        let global = try #require(workspace.library?.instruction(.global))
        let opened = workspace.fileDraft(.instruction(.global), text: global.text, on: "mac-a")
        opened.changed(body: "# 原则\n\n手机改的\n")
        // 离开文件页再回来：改着的还在，一条都没发
        let draft = workspace.fileDraft(.instruction(.global), text: global.text, on: "mac-a")
        let requests = try await store.deliveryRequests()
        #expect(draft === opened && draft.dirty && draft.body == "# 原则\n\n手机改的\n" && requests.allSatisfy { $0.libraryEdit == nil }, "没点纸飞机就不发")

        await draft.send()

        var file = await mac.text
        #expect(file == "# 原则\n\n手机改的\n" && draft.state == .saved && !draft.dirty)
        try await eventually("快照写回") { workspace.library?.instruction(.global)?.text == "# 原则\n\n手机改的\n" }
        draft.follow(workspace.library?.instruction(.global)?.text)
        #expect(draft.state == .saved)

        try await mac.edit("Mac 上改的\n")
        draft.changed(body: "手机又改\n")
        await draft.send()
        try await eventually("快照跟上 Mac") { workspace.library?.instruction(.global)?.text == "Mac 上改的\n" }
        draft.follow(workspace.library?.instruction(.global)?.text)

        file = await mac.text
        #expect(draft.state == .conflict(file: "Mac 上改的\n") && draft.body == "手机又改\n" && file == "Mac 上改的\n")
        await draft.keepMine()
        file = await mac.text
        #expect(file == "手机又改\n" && draft.state == .saved && !draft.dirty)
    }

    /// 手机上改技能：说明与正文攒着，纸飞机发往 Mac 写成整份 SKILL.md（别的键留着）；Mac 上刚改过就退回，留着你的字等你选。
    @Test func 手机改技能发往Mac写回_Mac上刚改过就退回() async throws {
        let (mac, workspace, stop) = try await start()
        defer { stop() }
        let skill = try #require(workspace.library?.skill(at: Self.skillPath))
        let draft = workspace.fileDraft(.skill(skill.path), text: skill.text, on: "mac-a")
        #expect(draft.name == "pr" && draft.summary == "写 PR" && draft.body == "先读模板\n")

        draft.changed(summary: "写 PR 描述")
        draft.changed(body: "先读模板，再写\n")
        await draft.send()

        var file = await mac.skill
        #expect(file == "---\nname: pr\ndescription: 写 PR 描述\nlicense: MIT\n---\n\n先读模板，再写\n" && draft.state == .saved)
        try await eventually("快照写回") { workspace.library?.skill(at: Self.skillPath)?.description == "写 PR 描述" }

        try await mac.editSkill("---\nname: pr\ndescription: Mac 上改的\n---\n")
        draft.changed(body: "手机又改\n")
        await draft.send()

        file = await mac.skill
        #expect(draft.conflicted && draft.body == "手机又改\n" && file == "---\nname: pr\ndescription: Mac 上改的\n---\n", "Mac 上刚改过：不写，留着你的字")
        try await eventually("快照跟上 Mac") { workspace.library?.skill(at: Self.skillPath)?.description == "Mac 上改的" }
        draft.follow(workspace.library?.skill(at: Self.skillPath)?.text)
        draft.takeFile()
        #expect(draft.summary == "Mac 上改的" && draft.body == "" && !draft.dirty)
    }

    /// 技能与规则页换段只有 `Workspace.libraryPane` 一份：换到技能、点开一份技能再返回，还在技能段。
    @Test func 换到技能段_打开技能再返回还在技能段() async throws {
        let (_, workspace, stop) = try await start()
        defer { stop() }
        workspace.select(.library)
        #expect(workspace.libraryPane == .rules)

        workspace.libraryPane = .skills
        workspace.openLibrary(.skill(Self.skillPath))
        #expect(workspace.path.last == .libraryFile(.skill(Self.skillPath)))
        workspace.path.removeLast()

        #expect((workspace.path.last ?? workspace.root) == .library && workspace.libraryPane == .skills)
    }
}
#endif
