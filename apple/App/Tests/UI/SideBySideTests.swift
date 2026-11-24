import CueStore
import Foundation
import Testing
@testable import CuePad

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

    private func fit(_ workspace: Workspace, width: CGFloat = 1600) { workspace.fit(WideMetrics(width: width, workspace: workspace).fits) }

    @Test func 并排时拉出Cue抽屉看一眼_收起并排后Cue栏还是原来的开合() {
        for chosen in [true, false] {
            services.settings.cueOpen = chosen
            let workspace = wide()
            open("a", workspace)
            open("b", in: .aside, workspace)
            fit(workspace)
            workspace.toggleCue()
            #expect(workspace.cueDrawer && services.settings.cueOpen == chosen)
            workspace.toggleCue()
            workspace.closeColumn(.beside(0))
            fit(workspace)
            #expect(!workspace.cueDrawer && services.settings.cueOpen == chosen)
        }
    }

    @Test func 窄窗拉出的Cue抽屉_窗口放宽后成了右栏() {
        services.settings.cueOpen = false
        let workspace = wide()
        fit(workspace, width: 700)
        workspace.toggleCue()
        #expect(workspace.cueDrawer && !services.settings.cueOpen)
        fit(workspace)
        #expect(!workspace.cueDrawer && services.settings.cueOpen)
    }

    private func session(_ sessionID: String) -> WideNavigation.Pane {
        .session(SessionRoute(id: SessionState.recordID(sessionID: sessionID), sessionID: sessionID))
    }

    @Test func 灵感并排在会话旁边_放得下三块_能换到最左_删了那一块自己收起() async throws {
        let workspace = wide()
        workspace.fit(WideMetrics(width: 1600, workspace: workspace).fits)
        let idea = try await services.store.createCard(body: "边聊边看的那条")
        open("a", workspace)

        workspace.drop(.card(idea.id), at: 1, replacing: false)
        open("b", in: .aside, workspace)
        #expect(workspace.panes == [session("a"), .card(idea.id), session("b")])
        workspace.drop(.card(idea.id), at: 0, replacing: true)
        #expect(workspace.panes == [.card(idea.id), session("a"), session("b")], "灵感与最左的会话对调")
        #expect(workspace.moveColumn(.main, by: 1) && workspace.panes == [session("a"), .card(idea.id), session("b")], "键盘挪回去")

        open("c", in: .aside, workspace)
        #expect(workspace.panes == [session("a"), .card(idea.id), session("c")], "放满了，开在旁边换掉最右那块")

        try await workspace.trash(idea.id)
        #expect(workspace.panes == [session("a"), session("c")])
    }

    @Test func 从项目页拖出灵感_项目页与灵感并排_再拖一条是三块_换页时灵感留着_进展独占() async throws {
        let workspace = wide()
        workspace.fit(WideMetrics(width: 1600, workspace: workspace).fits)
        let first = try await services.store.createCard(body: "第一条"), second = try await services.store.createCard(body: "第二条")
        #expect(!workspace.drop(.card(first.id), at: 1, replacing: false), "进展旁边不并排")

        workspace.select(.project(Project.defaultID))
        #expect(workspace.drop(.card(first.id), at: 1, replacing: false) && workspace.panes == [.page(.project(Project.defaultID)), .card(first.id)])
        #expect(workspace.drop(.card(second.id), at: 2, replacing: false) && workspace.panes == [.page(.project(Project.defaultID)), .card(first.id), .card(second.id)])

        workspace.select(.shelf)
        #expect(workspace.panes == [.page(.shelf), .card(first.id), .card(second.id)], "页原地换，旁边的留着")
        workspace.closeColumn(.main)
        #expect(workspace.panes == [.card(first.id), .card(second.id)], "灵感自己也成一排")
        workspace.select(.progress)
        #expect(workspace.panes == [.page(.progress)])
        #expect(workspace.drop(session("a"), at: 0, replacing: true) && workspace.panes == [session("a")], "拖到进展上换掉它")
    }

    @Test func 点开的灵感拖到旁边_成了并排的一块_底下那一页还在() async throws {
        let workspace = wide()
        workspace.fit(WideMetrics(width: 1600, workspace: workspace).fits)
        let idea = try await services.store.createCard(body: "边聊边看的那条")
        workspace.select(.shelf)
        workspace.showEditor(idea.id)
        #expect(workspace.openCard == idea.id && workspace.panes == [.page(.shelf)])

        #expect(workspace.drop(session("a"), at: 0, replacing: false))
        #expect(workspace.panes == [session("a"), .page(.shelf)] && workspace.openCard == idea.id, "别的块并排进来，灵感还盖在那一页上")
        #expect(workspace.drop(.card(idea.id), at: 2, replacing: false))
        #expect(workspace.panes == [session("a"), .page(.shelf), .card(idea.id)] && workspace.overlay == nil)

        workspace.closeColumn(.beside(1))
        #expect(workspace.panes == [session("a"), .page(.shelf)])
    }

    @Test func 盖着灵感的那一块被换掉_灵感跟着收() async throws {
        let workspace = wide()
        workspace.fit(WideMetrics(width: 1600, workspace: workspace).fits)
        let idea = try await services.store.createCard(body: "边聊边看的那条")
        open("a", workspace)
        workspace.showEditor(idea.id)
        open("b", in: .aside, workspace)
        #expect(workspace.openCard == idea.id, "旁边开别的不碰它")

        #expect(workspace.drop(session("c"), at: 0, replacing: true))
        #expect(workspace.panes == [session("c"), session("b")] && workspace.overlay == nil)
    }

    @Test func 窗口变窄藏起最右那块_开在旁边换掉看得见的那块() {
        let workspace = wide()
        workspace.fit(WideMetrics(width: 1600, workspace: workspace).fits)
        open("a", workspace)
        open("b", in: .aside, workspace)
        open("c", in: .aside, workspace)
        workspace.fit(WideMetrics(width: 1000, workspace: workspace).fits)

        open("d", in: .aside, workspace)
        #expect(workspace.session(in: .beside(0))?.sessionID == "d" && workspace.session(in: .beside(1))?.sessionID == "c")
    }

    @Test func 宽窄来回_并排的会话与灵感都还在() async throws {
        let workspace = wide()
        workspace.fit(WideMetrics(width: 1600, workspace: workspace).fits)
        let idea = try await services.store.createCard(body: "边聊边看的那条")
        open("a", workspace)
        open("b", in: .aside, workspace)
        workspace.drop(.card(idea.id), at: 2, replacing: false)

        workspace.setLayout(.narrow)
        #expect(workspace.path == [.session("a"), .session("b")] && !workspace.sidebarOpen && workspace.ideaDock?.card == idea.id)
        workspace.setLayout(.wide)
        #expect(workspace.panes == [session("a"), session("b"), .card(idea.id)])
    }

    @Test func 挑会话的提示被别的提示顶掉_就不挑了() async throws {
        let workspace = Workspace(services: services)
        workspace.setLayout(.narrow)
        let idea = try await services.store.createCard(body: "边聊边看的那条")
        workspace.pickDock(idea.id)
        #expect(workspace.pickingDock)

        workspace.say("已复制")
        #expect(workspace.ideaDock == nil)
    }
}
