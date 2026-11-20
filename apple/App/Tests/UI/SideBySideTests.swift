import CueStore
import Foundation
import Testing
@testable import CuePad

/// 宽屏主区右半（第二个会话；Mac 上还有活预览）开着时的排布，与 Agent 用 `cuepad live` 交来的地址落在哪。
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

        open("b", in: .beside, workspace)
        #expect(!cueShown(workspace) && services.settings.cueOpen)
        workspace.closeColumn(.beside)
        #expect(cueShown(workspace))

        #if os(macOS)
        workspace.toggleLivePreview()
        #expect(workspace.beside == .preview && !cueShown(workspace) && services.settings.cueOpen)
        workspace.toggleLivePreview()
        #expect(cueShown(workspace))
        #endif

        services.settings.cueOpen = false
        open("b", in: .beside, workspace)
        workspace.closeColumn(.beside)
        #expect(!cueShown(workspace) && !services.settings.cueOpen)
    }
}
