#if os(macOS)
import CueStore
import SwiftUI

/// 首次使用才付的一次性成本（视图类型、玻璃材质、文本平台控件、菜单与弹出框的桥接）在启动后空闲时先付掉：
/// 把这些视图在窗口里隐形地挂两帧再卸下（不聚焦、不订阅，`pageActive` 为 false），每样一段，不挤在一个回合里。
/// 任务气泡挂一条真的任务（库里第一条没做完的顶层任务，没有就不挂）：第一次开气泡要建滚动区、菜单、输入框与整页的视图类型，挂过一次后开气泡省一半。
/// Agent 页不是付一次就够的：它的成本是现建整页与十几行会话本身，所以不挂替身，直接把真的那一页挂进内容区留着（`Workspace.premount`）。
/// 用户第一次点会话、点新会话时，付的就是"第二次"的价钱（右键菜单的第一次另议：建一个不弹出的菜单没有收益；⌘K 面板不在这里，启动后空闲时直接常驻挂上，见 `keptPanel`）。
struct Prewarm: View {
    @Environment(Workspace.self) private var workspace
    @State private var step = Step.idle
    /// 预热的对话区的贴底状态（没人读，只是滚动区要一份）。
    @State private var follow = ChatFollow()
    @State private var warmTask: TaskBubble.Request?

    /// 读到资料库后等多久开始：首屏出来、用户还没动手。⌘K 面板同一时机常驻挂上（`keptPanel`）。
    static let delay: Duration = .seconds(2)

    private enum Step: CaseIterable {
        case idle, conversation, replyBar, newSession, taskBubble, done
    }

    private static let size = CGSize(width: 900, height: 560)
    /// 任务气泡挂几帧：读库回来再建出整页（实测挂上后几毫秒就回来），留足余量。
    private static let bubbleFrames = 12

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
                ChatScroll(followKey: 0, readingWidth: 760, inset: 24, follow: $follow) {
                    PiConversation(
                        session: Self.session, items: PiChat.entries(Self.messages), messages: Self.messages, window: PiConversation.firstWindow)
                }
            case .replyBar: PiReplyBar(session: Self.session, config: nil, catalog: nil, stopping: false) {}
            case .newSession: NewSessionForm(agents: nil) { _ in }
            case .taskBubble:
                if let warmTask {
                    BubbleFrame(placement: BubblePlacement(source: .unanchored, container: CGRect(origin: .zero, size: Self.size), insets: EdgeInsets())) {
                        // 气泡的内容是读库回来才建的：这一格要订阅（外面整块 `pageActive` 为 false 时不读库）
                        TaskBubble(request: warmTask).environment(\.pageActive, true)
                    } area: {
                        EmptyView()
                    }
                }
            default: Color.clear
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .environment(\.pageActive, false)
        .task(id: workspace.isLibraryReady) {
            guard workspace.isLibraryReady else { return }
            guard (try? await Task.sleep(for: Self.delay)) != nil else { return }
            workspace.pages.premount(.agent)
            let tasks = try? await workspace.services.store.tasks(.inProgress, .todo)
            if let task = tasks?.lazy.flatMap(\.tasks).first(where: { $0.parentID == nil }) {
                warmTask = TaskBubble.Request(task: task.id, step: nil, source: .unanchored)
            }
            await NextFrame.wait()
            await NextFrame.wait()
            for next in Step.allCases.dropFirst() {
                step = next
                // 气泡的内容读库回来才建：多挂一会儿等它
                for _ in 0..<(next == .taskBubble ? Self.bubbleFrames : 2) { await NextFrame.wait() }
            }
        }
    }
}
#endif
