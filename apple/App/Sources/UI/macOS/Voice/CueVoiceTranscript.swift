#if os(macOS)
import SwiftUI

/// 固定阅读区里的全部真实请求与回复；再次口述只发请求，不暗示某条结果已播报。
/// 沿用对话的分段按需布局与贴底规则：只在底部跟随，上翻保位，回来继续；不复制业务历史。
struct CueVoiceTranscript: View {
    let presentation: CueVoicePresentation
    let action: (CueVoiceAction) -> Void
    @Environment(\.palette) private var palette
    @State private var follow = ChatFollow()

    // 通话阅读区只有几行高，每批四条已足够铺满；更早的按滚动位置继续排开。
    private static let pageSize = 4

    private struct FollowKey: Equatable {
        let count: Int
        let lastID: UUID?
        let text: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            if let issue = presentation.issue {
                VStack(alignment: .leading, spacing: Spacing.item) {
                    Text(issue.message).foregroundStyle(palette.failure)
                    Button { action(.recover) } label: { Text(issue.recovery) }
                        .buttonStyle(ControlButtonStyle(size: .compact))
                }
                .font(Typography.body)
                .textSelection(.enabled)
                .padding(.horizontal, Spacing.page)
            }
            conversation
        }
    }

    private var conversation: some View {
        ChatColumn(
            followKey: FollowKey(count: presentation.replies.count, lastID: presentation.replies.last?.id, text: presentation.replies.last?.text),
            readingWidth: Spacing.reading, inset: Spacing.page, follow: $follow, marks: [],
            ids: presentation.replies.map(\.id), paging: .fixed(first: Self.pageSize, step: Self.pageSize), holding: false
        ) { window in
            ChatStack(spacing: Spacing.block) {
                if let request = presentation.request {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(request.delivery.title)
                            .font(Typography.meta)
                            .foregroundStyle(request.delivery == .failed ? palette.failure : palette.ink2)
                        Text(verbatim: request.text).font(Typography.body)
                    }
                }
                ChatSegments(items: presentation.replies, window: window, size: Self.pageSize) { replies in
                    ChatRows(ids: replies.map(\.id), spacing: Spacing.block) {
                        ForEach(replies) { reply in
                            replyRow(reply)
                        }
                    }
                }
            }
            .font(Typography.body)
            .foregroundStyle(palette.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 操作行在阅读区外，不继承宿主回复框给对话预留的空间。
        .environment(\.chatBottomInset, 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("通话文字")
    }

    private func replyRow(_ reply: CueVoicePresentation.Reply) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.item) {
                Text(verbatim: presentation.name).font(Typography.label)
                Spacer(minLength: 0)
                Button { action(.requestRepeat(reply.id)) } label: {
                    Text("再说一遍")
                }
                .buttonStyle(ControlButtonStyle(kind: .quiet, size: .compact))
                .disabled(!reply.canRequestRepeat)
            }
            Text(verbatim: reply.text)
                .font(Typography.reading)
                .lineSpacing(Typography.readingLineSpacing)
        }
    }
}
#endif
