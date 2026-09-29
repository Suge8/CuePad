#if os(macOS)
import CuePi
import CueStore
import Foundation
import Observation
import SwiftUI

/// 一个窗口的界面状态：选中的页、打开的卡、浮层、发送目标、提示。数据本身不在这里，界面直接订阅 Store。
/// 当前项目的唯一事实源是 `AppSettings.currentProject`；这里只记"未归档"和"回收站"这两个非项目页。
@MainActor @Observable
final class Workspace {
    enum Page: Hashable {
        case project(UUID)
        case inbox
        case trash
    }

    enum Overlay: Equatable {
        case search
        case tasks
        case settings
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    /// Pi 会话正忙时待用户选择插话或排队的一次发送。
    struct BusySend {
        var text: String
        var session: CuePi.PiSession.ID
        var card: UUID?
        var task: UUID?
    }

    let services: AppServices
    var sidebar: NavigationSplitViewVisibility = .all
    var nonProjectPage: Page?
    var openCard: UUID?
    var overlay: Overlay?
    var notice: Notice?
    var busySend: BusySend?
    /// 用户在本窗口选过的发送目标；nil 或已失效时用默认目标。
    var sendChoice: SendChoice?
    /// 本机项目目录绑定（Pi 会话据此归项目）；由根视图订阅 Store 更新。
    var directories: [UUID: String]?

    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    var page: Page {
        if let nonProjectPage { return nonProjectPage }
        return services.settings.currentProject.map(Page.project) ?? .inbox
    }

    /// 当前项目（未归档为 nil）。回收站页没有项目。
    var currentProject: UUID? {
        if case .project(let id) = page { id } else { nil }
    }

    func show(_ page: Page) {
        openCard = nil
        switch page {
        case .project(let id):
            nonProjectPage = nil
            services.settings.currentProject = id
        case .inbox, .trash:
            nonProjectPage = page
        }
    }

    func toggle(_ overlay: Overlay) {
        self.overlay = self.overlay == overlay ? nil : overlay
    }

    func toggleSidebar() {
        sidebar = sidebar == .detailOnly ? .all : .detailOnly
    }

    // MARK: 提示

    private static let noticeDuration: Duration = .seconds(2.4)

    func say(_ text: String, isError: Bool = false) {
        let notice = Notice(text: text, isError: isError)
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            if self?.notice == notice { self?.notice = nil }
        }
    }

    func fail(_ error: any Error) {
        say(ErrorText.describe(error), isError: true)
    }

    /// 执行一个 Store 写操作，失败时提示。
    func perform(_ work: @escaping @Sendable (CueStore) async throws -> Void) {
        let store = services.store
        Task {
            do { try await work(store) } catch { fail(error) }
        }
    }
}
#endif
