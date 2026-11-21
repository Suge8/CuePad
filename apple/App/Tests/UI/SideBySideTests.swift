import CueStore
import Foundation
import Testing
@testable import CuePad

/// 宽屏主区并排（最左的会话旁边再开别的会话、灵感；Mac 上还有活预览）时的排布。
@Suite(.releasesLibraries)
struct SideBySideTests {
    let rig = TestApp()
    var services: AppServices { rig.services }

    private func wide() -> Workspace {
        let workspace = Workspace(services: services)
        workspace.setLayout(.wide)
        return workspace
    }

    private func open(_ sessionID: String, in column: Workspace.Column = .main, _ workspace: Workspace) {
        workspace.openSession(SessionState.recordID(sessionID: sessionID), sessionID: sessionID, in: column)
    }

    /// 放得下会话条、一个会话与 Cue 的窗口。
    private func cueShown(_ workspace: Workspace) -> Bool { workspace.cueShown(WideMetrics(width: 1600, workspace: workspace)) }

    @Test func 右半开着时Cue收成钮_收起右半回到原来的选择_选择本身没被改() {
        services.settings.cueOpen = true
        let workspace = wide()
        open("a", workspace)
        #expect(cueShown(workspace))

        open("b", in: .aside, workspace)
        #expect(!cueShown(workspace) && services.settings.cueOpen)
        workspace.closeColumn(.beside(0))
        #expect(cueShown(workspace))

        #if os(macOS)
        workspace.toggleLivePreview()
        #expect(workspace.beside.contains(.preview) && !cueShown(workspace) && services.settings.cueOpen)
        workspace.toggleLivePreview()
        #expect(cueShown(workspace))
        #endif

        services.settings.cueOpen = false
        open("b", in: .aside, workspace)
        workspace.closeColumn(.beside(0))
        #expect(!cueShown(workspace) && !services.settings.cueOpen)
    }

    @Test func 灵感并排在会话旁边_放得下三块_灵感不占最左_删了那一块自己收起() async throws {
        let workspace = wide()
        workspace.fit(WideMetrics(width: 1600, workspace: workspace).fits)
        let idea = try await services.store.createCard(body: "边聊边看的那条")
        open("a", workspace)

        workspace.drop(.card(idea.id), at: 1, replacing: false)
        open("b", in: .aside, workspace)
        #expect(workspace.navigation.trail == "wide session | card | session")
        workspace.drop(.card(idea.id), at: 0, replacing: true)
        #expect(workspace.navigation.trail == "wide session | card | session", "灵感换不到最左")

        open("c", in: .aside, workspace)
        #expect(workspace.navigation.trail == "wide session | card | session" && workspace.session(in: .beside(1))?.sessionID == "c", "放满了，开在旁边换掉最右那块")

        try await workspace.trash(idea.id)
        #expect(workspace.navigation.trail == "wide session | session")
    }

    @Test func 看着一条灵感时拖来会话_会话占左边_灵感挪到右边() async throws {
        let workspace = wide()
        let idea = try await services.store.createCard(body: "边聊边看的那条")
        workspace.select(.shelf)
        workspace.showEditor(idea.id)

        workspace.drop(.session(SessionRoute(id: SessionState.recordID(sessionID: "a"), sessionID: "a")), at: 0, replacing: false)
        #expect(workspace.navigation.trail == "wide session | card" && workspace.overlay == nil)
    }
}
