#if os(iOS)
import SwiftUI

struct NoticeBanner: View {
    @Environment(Workspace.self) private var workspace

    private static let sideClearance = FloatingHeaderLayout.margin + FloatingHeaderLayout.slot
    private static let maxWidth: CGFloat = 440

    static func giveWay(_ covered: Bool) -> Animation {
        covered ? Motion.fade : Motion.fade.delay(Motion.Fade.settle)
    }

    var body: some View {
        let field = workspace.layout == .narrow && (workspace.top == .shelf || workspace.top == .progress)
        NoticeSlot(place: .head(fills: true))
            .frame(maxWidth: field ? .infinity : Self.maxWidth)
            .frame(maxWidth: .infinity)
            .padding(.leading, field ? FloatingHeaderLayout.margin : Self.sideClearance)
            .padding(.trailing, Self.sideClearance)
            .animation(Motion.fade, value: field)
            .containerCornerOffset(.horizontal, sizeToFit: true)
            .sensoryFeedback(trigger: workspace.notice) { _, notice in
                guard let notice else { return nil }
                return notice.isError ? .error : .success
            }
            .onChange(of: workspace.services.sessionAlert) { _, alert in
                guard !DebugHooks.preset.quietAlerts, let alert, workspace.showsAlert(about: alert.session) else { return }
                workspace.say(alert.text, status: alert.status, link: .session(alert.session), sound: Sound(alert.kind.tone))
            }
            .background { PhoneVoiceEndings() }
            .onChange(of: workspace.notice.map(workspace.keeps)) { _, keeps in if keeps == false { workspace.notice = nil } }
    }
}
#endif
