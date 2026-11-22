import SwiftUI

struct CueVoiceDetails: View {
    let presentation: () -> CueVoicePresentation?
    let action: (VoiceAction) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        if let presentation = presentation() { details(presentation) }
    }

    private func details(_ presentation: CueVoicePresentation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            HStack(spacing: Spacing.item) {
                Text("通话详情").font(Typography.title)
                Spacer(minLength: Spacing.item)
                Button { action(.hangUp) } label: { Text("结束通话") }
                    .buttonStyle(ControlButtonStyle(size: .compact))
                    .disabled(!presentation.active || presentation.activity == .closing)
                    .opacity(presentation.active ? 1 : 0)
                    .readerHidden(!presentation.active)
            }
            if presentation.active {
                Text(presentation.title).font(Typography.body).foregroundStyle(palette.ink2)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.block) {
                    ForEach(presentation.issues) { issue in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(issue.summary).font(Typography.bodyStrong)
                            Text(issue.message).font(Typography.body)
                            if let recovery = issue.recovery {
                                Button { action(recovery) } label: { Text(recovery.title) }
                                    .buttonStyle(ControlButtonStyle(size: .compact))
                            }
                        }
                        .foregroundStyle(palette.failure)
                    }
                    if !presentation.readings.isEmpty {
                        Text("朗读记录").font(Typography.bodyStrong)
                        ForEach(presentation.readings) { reading in
                            VStack(alignment: .leading, spacing: Spacing.tight) {
                                Text(verbatim: reading.excerpt).font(Typography.body).lineLimit(1)
                                Text(verbatim: reading.status).font(Typography.meta).foregroundStyle(palette.ink2)
                                if let recovery = reading.recovery {
                                    Button { action(recovery) } label: { Text(recovery.title) }
                                        .buttonStyle(ControlButtonStyle(size: .compact))
                                }
                            }
                        }
                    }
                    if let earlier = presentation.earlier {
                        Text(earlier).font(Typography.meta).foregroundStyle(palette.ink2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 320)
        }
        .padding(Spacing.panel)
    }
}
