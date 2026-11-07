#if os(macOS)
import SwiftUI

/// 固定阅读区里的真实请求与回复；全文可选、可滚动。再次口述只发请求，不暗示某条结果已播报。
struct CueVoiceTranscript: View {
    let presentation: CueVoicePresentation
    let action: (CueVoiceAction) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.block) {
                if let issue = presentation.issue {
                    VStack(alignment: .leading, spacing: Spacing.item) {
                        Text(issue.message).foregroundStyle(palette.failure)
                        Button { action(.recover) } label: { Text(issue.recovery) }
                            .buttonStyle(ControlButtonStyle(size: .compact))
                    }
                }
                if let request = presentation.request {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(request.delivery.title)
                            .font(Typography.meta)
                            .foregroundStyle(request.delivery == .failed ? palette.failure : palette.ink2)
                        Text(verbatim: request.text).font(Typography.body)
                    }
                }
                ForEach(presentation.replies) { reply in
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
            .font(Typography.body)
            .foregroundStyle(palette.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .safeAreaPadding(.horizontal, Spacing.page)
            .safeAreaPadding(.vertical, Spacing.item)
        }
        .scrollIndicators(.visible)
        .accessibilityLabel("通话文字")
    }
}
#endif
