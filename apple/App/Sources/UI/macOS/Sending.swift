#if os(macOS)
import CueDispatch
import CuePi
import CueStore
import CueText
import Foundation
import SwiftUI

extension Workspace {
    /// 项目的 Pi 会话：按工作目录归入（Store 判定），空闲的在前。
    func liveSessions(in project: UUID?) -> [CuePi.PiSession] {
        guard let project else { return [] }
        return services.pi.sessions
            .filter { sessionProjects[$0.id] == project }
            .sorted { !$0.state.isBusy && $1.state.isBusy }
    }

    /// 当前生效的目标：用户选过且仍有效的，否则本项目的 Pi 会话，否则上一个前台应用。
    func effectiveChoice(for project: UUID?) -> AppServices.Destination {
        if let sendChoice, isAvailable(sendChoice) { return sendChoice }
        return liveSessions(in: project).first.map { .pi($0.id, .send) } ?? .app(.lastFrontmost)
    }

    func label(for choice: AppServices.Destination) -> String {
        switch choice {
        case .pi(let id, let mode): (session(id).map(Self.sessionName) ?? "Pi") + (mode == .paste ? " 输入框" : "")
        case .app(.bundleID(let bundleID)): services.appName(bundleID: bundleID)
        case .app(.lastFrontmost): services.lastFrontmostApp()?.name ?? "上一个应用"
        case .clipboard: "剪贴板"
        }
    }

    func session(_ id: CuePi.PiSession.ID) -> CuePi.PiSession? {
        services.pi.sessions.first { $0.id == id }
    }

    static func sessionName(_ session: CuePi.PiSession) -> String {
        session.cwd.lastPathComponent
    }

    private func isAvailable(_ choice: AppServices.Destination) -> Bool {
        switch choice {
        case .pi(let id, _): session(id) != nil
        case .app, .clipboard: true
        }
    }

    /// 发送存储格式正文；成功后提示，Pi 忙时转为询问插话或排队。返回是否已发出。
    @discardableResult
    func send(_ stored: String, via choice: AppServices.Destination, card: UUID? = nil, task: UUID? = nil) async -> Bool {
        do {
            try await services.send(stored, to: choice, card: card, task: task)
            say(choice == .clipboard ? "已复制" : "已发给 \(label(for: choice))")
            return true
        } catch SendError.piSessionBusy {
            if case .pi(let id, _) = choice { busySend = BusySend(text: stored, session: id, card: card, task: task) }
            return false
        } catch {
            fail(error)
            return false
        }
    }

    func resolveBusySend(_ mode: DeliveryMode) {
        guard let pending = busySend else { return }
        busySend = nil
        Task {
            do {
                try await services.send(pending.text, to: .pi(pending.session, mode), card: pending.card, task: pending.task)
                say(mode == .steer ? "已插话" : "已排队")
            } catch {
                fail(error)
            }
        }
    }
}

/// 活着的 Pi 会话或项目目录绑定变化时，重算会话归属的项目。
struct SessionProjectsTracker: ViewModifier {
    let workspace: Workspace
    @State private var directories: [UUID: String]?

    private struct Key: Equatable {
        var sessions: [String]
        var directories: [UUID: String]?
    }

    func body(content: Content) -> some View {
        let key = Key(sessions: workspace.services.pi.sessions.map { "\($0.id) \($0.cwd.path)" }, directories: directories)
        content
            .observing(workspace.services.store, [.projectDirectories], into: $directories) { try $0.projectDirectories() }
            .task(id: key) { await workspace.refreshSessionProjects() }
    }
}
#endif
