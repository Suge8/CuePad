#if os(macOS)
import SwiftUI

/// 真实问题优先于最新请求摘要；问题与恢复对象由宿主投影，不把最新请求当作失败对象。
/// 无问题时显示最新请求，详情始终保留两者；紧凑档合入需注意执行与全部记录入口，摘要不参与滚动和底部跟随。
struct CueVoiceStatus: View {
    let presentation: CueVoicePresentation
    let compact: Bool
    let action: (CueVoiceAction) -> Void
    @State private var details = false
    @Environment(\.palette) private var palette
    static let height: CGFloat = 48

    var body: some View {
        HStack(spacing: Spacing.item) {
            Button { details = true } label: {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    if let issue = presentation.issue {
                        Text(issue.message).font(Typography.body).foregroundStyle(palette.failure)
                            .lineLimit(compact ? 1 : 2)
                    } else if let request = presentation.request {
                        Text("当前请求：\(request.status)").font(Typography.bodyStrong)
                            .foregroundStyle(request.delivery.failure != nil ? palette.failure : palette.ink)
                        if !compact { Text(verbatim: request.text).font(Typography.meta).foregroundStyle(palette.ink2) }
                    }
                    if compact, let item = CueVoiceExecutionSummary.primary(presentation.executions) {
                        if item.needsAttention {
                            HStack(spacing: Spacing.tight) {
                                Text("需注意").fixedSize()
                                Text(verbatim: item.title)
                            }
                            .font(Typography.meta).foregroundStyle(palette.failure)
                        } else {
                            Text(Dotted(item.title, item.status))
                                .font(Typography.meta).foregroundStyle(palette.ink2)
                        }
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: ControlSize.compact.height, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(PressStyle(.button))
            .help("查看请求详情")
            .bubble(isPresented: $details, width: .fixed(320)) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.block) {
                        if let request = presentation.request {
                            Text("当前请求").font(Typography.bodyStrong)
                            Text(verbatim: request.status).foregroundStyle(palette.ink2)
                            Text(verbatim: request.text)
                        }
                        if let issue = presentation.issue {
                            Text(issue.message).foregroundStyle(palette.failure)
                        }
                        if compact { CueVoiceExecutionRecords(executions: presentation.executions) }
                    }
                    .font(Typography.body)
                    .textSelection(.enabled)
                    .padding(Spacing.page)
                }
                .frame(height: 320)
            }
            if let issue = presentation.issue, presentation.activity.isLive {
                Button { action(.recover) } label: { Label(issue.recovery, icon: .retry) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
                    .help(Text(issue.recovery))
            }
        }
        .padding(.horizontal, Spacing.page)
        .frame(height: Self.height, alignment: .top)
        .keepsPlace(shown: presentation.request != nil || presentation.issue != nil || (compact && !presentation.executions.isEmpty))
    }
}

/// 全部执行与停止记录在有界详情中逐项呈现，不按状态文案猜测成功或失败。
struct CueVoiceExecutions: View {
    let executions: [CueVoicePresentation.Execution]
    @Binding var showing: Bool

    var body: some View {
        Button { showing = true } label: { Text("执行详情 \(executions.count)") }
            .buttonStyle(ControlButtonStyle(kind: .quiet, size: .compact))
            .keepsPlace(shown: !executions.isEmpty)
            .bubble(isPresented: $showing, width: .fixed(320)) {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.block) {
                            CueVoiceExecutionRecords(executions: executions)
                        }
                        .textSelection(.enabled)
                        .padding(Spacing.page)
                    }
                    .accessibilityLabel("执行与停止记录")
                    .onAppear {
                        if let item = executions.first(where: \.needsAttention) { reader.scrollTo(item.id, anchor: .top) }
                    }
                }
                .frame(height: 320)
            }
    }
}
/// 只挑投影明确标记的需注意项；旧失败不会被正常记录覆盖，不推断已经停止。
struct CueVoiceExecutionSummary: View {
    let executions: [CueVoicePresentation.Execution]
    let showDetails: () -> Void
    @Environment(\.palette) private var palette
    static let height: CGFloat = 36

    static func primary(_ executions: [CueVoicePresentation.Execution]) -> CueVoicePresentation.Execution? {
        executions.first(where: \.needsAttention) ?? executions.first
    }

    private var item: CueVoicePresentation.Execution? { Self.primary(executions) }

    var body: some View {
        Button(action: showDetails) {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                if let item {
                    HStack(spacing: Spacing.tight) {
                        if item.needsAttention { Text("需注意").foregroundStyle(palette.failure) }
                        Text(verbatim: item.title).foregroundStyle(palette.ink2)
                    }
                    Text(verbatim: item.status).foregroundStyle(item.needsAttention ? palette.failure : palette.ink2)
                }
            }
            .font(Typography.meta)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.button))
        .padding(.horizontal, Spacing.page)
        .frame(height: Self.height)
        .keepsPlace(shown: item != nil)
        .help("查看全部执行与停止记录")
    }
}
private struct CueVoiceExecutionRecords: View {
    let executions: [CueVoicePresentation.Execution]
    @Environment(\.palette) private var palette

    var body: some View {
        ForEach(executions) { execution in
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(verbatim: execution.title).font(Typography.bodyStrong)
                Text(verbatim: execution.status).font(Typography.body)
                    .foregroundStyle(execution.needsAttention ? palette.failure : palette.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(execution.id)
        }
    }
}
#endif
