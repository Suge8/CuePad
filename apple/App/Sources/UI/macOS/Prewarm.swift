#if os(macOS)
import CueStore
import SwiftUI

/// 首次使用才付的一次性成本（视图类型、玻璃材质、文本平台控件、菜单与弹出框的桥接）在启动后空闲时先付掉：
/// 把这些视图在窗口里隐形地挂两帧再卸下（不聚焦、不订阅，`pageActive` 为 false），每样一段，不挤在一个回合里。
/// Agent 页不是付一次就够的：它的成本是现建整页与十几行会话本身，所以不挂替身，直接把真的那一页挂进内容区留着（`Workspace.premount`）。
/// 用户第一次点会话、点新会话时，付的就是"第二次"的价钱（右键菜单的第一次另议：建一个不弹出的菜单没有收益；⌘K 面板不在这里，启动后空闲时直接常驻挂上，见 `keptPanel`）。
struct Prewarm: View {
    @Environment(Workspace.self) private var workspace
    @State private var step = Step.idle

    private enum Step: CaseIterable {
        case idle, conversation, replyBar, newSession, done
    }

    /// 回复框要一个会话：已结束的、不属于任何项目的占位，不写进任何地方。
    private static let session = PiSessionState(
        id: UUID(), sessionID: "prewarm", hostID: "", title: "", projectID: nil, state: .known(.ended), detail: nil, folder: nil,
        lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .distantPast, busySince: nil, createdAt: .distantPast,
        modifiedAt: .distantPast)

    private static let messages = [
        PiChatMessage(sessionID: "prewarm", entryID: "1", seq: 1, role: .user, text: "把这个函数改成异步的", at: .distantPast),
        PiChatMessage(
            sessionID: "prewarm", entryID: "2", seq: 2, role: .pi,
            text: "改好了：\n\n- 调用方都加了 `await`\n- 错误经 `throws` 抛出\n\n```swift\nfunc load() async throws {}\n```\n\n| 文件 | 改动 |\n| --- | --- |\n| a.swift | +3 −1 |", at: .distantPast),
    ]

    var body: some View {
        ZStack {
            switch step {
            case .conversation:
                ChatScroll(followKey: 0, readingWidth: 760, inset: 24) {
                    PiConversation(
                        session: Self.session, items: PiChat.entries(Self.messages), messages: Self.messages, window: PiConversation.firstWindow)
                }
            case .replyBar: PiReplyBar(session: Self.session, config: nil, stopping: false) {}
            case .newSession: NewSessionForm { _ in }
            default: Color.clear
            }
        }
        .frame(width: 900, height: 560)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .environment(\.pageActive, false)
        .task(id: workspace.isLibraryReady) {
            guard workspace.isLibraryReady else { return }
            // 首屏出来、用户还没动手：等一会儿再开始
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            workspace.pages.premount(.agent)
            await NextFrame.wait()
            await NextFrame.wait()
            for next in Step.allCases.dropFirst() {
                step = next
                await NextFrame.wait()
                await NextFrame.wait()
            }
        }
    }
}
#endif
