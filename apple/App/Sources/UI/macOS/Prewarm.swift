#if os(macOS)
import CueStore
import SwiftUI

struct Prewarm: View {
    @Environment(Workspace.self) private var workspace
    @State private var step = Step.idle
    @State private var follow = ChatFollow()
    @State private var warmTask: TaskBubble.Request?

    static let delay: Duration = .seconds(2)

    private enum Step: CaseIterable {
        case idle, conversation, replyBar, newSession, taskBubble, done
    }

    private static let size = CGSize(width: 900, height: 560)
    private static let bubbleFrames = 12

    private static let session = SessionState(
        id: UUID(), sessionID: "prewarm", hostID: "", title: "", projectID: nil, state: .known(.ended), detail: nil, folder: nil,
        lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .distantPast, busySince: nil, createdAt: .distantPast,
        modifiedAt: .distantPast)

    private static let messages = [
        ChatMessage(sessionID: "prewarm", entryID: "1", seq: 1, role: .user, text: "把这个函数改成异步的", at: .distantPast),
        ChatMessage(
            sessionID: "prewarm", entryID: "2", seq: 2, role: .pi,
            text: "改好了：\n\n- 调用方都加了 `await`\n- 错误经 `throws` 抛出\n\n```swift\nfunc load() async throws {}\n```\n\n| 文件 | 改动 |\n| --- | --- |\n| a.swift | +3 −1 |", at: .distantPast),
    ]

    var body: some View {
        ZStack {
            switch step {
            case .conversation:
                ChatScroll(followKey: 0, readingWidth: Spacing.reading, inset: Spacing.page, follow: $follow) {
                    Conversation(
                        session: Self.session, items: Chat.entries(Self.messages), messages: Self.messages, window: ChatWindow(column: UUID(), count: Conversation.firstWindow, earlier: 0) {})
                }
            case .replyBar: ReplyBar(session: Self.session, config: nil, catalog: nil, stopping: false) {}
            case .newSession: NewSessionInput(start: SessionStart())
            case .taskBubble:
                if let warmTask {
                    BubbleFrame(placement: BubblePlacement(source: .unanchored, container: CGRect(origin: .zero, size: Self.size), insets: EdgeInsets())) {
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
            workspace.pages.premount(.progress)
            let tasks = try? await workspace.services.store.tasks(.inProgress, .todo)
            if let task = tasks?.lazy.flatMap(\.tasks).first(where: { $0.parentID == nil }) {
                warmTask = TaskBubble.Request(task: task.id, step: nil, source: .unanchored)
            }
            await NextFrame.wait()
            await NextFrame.wait()
            for next in Step.allCases.dropFirst() {
                step = next
                for _ in 0..<(next == .taskBubble ? Self.bubbleFrames : 2) { await NextFrame.wait() }
            }
        }
    }
}
#endif
