#if os(macOS)
import SwiftUI

/// 通话条与它的详情：开合是呈现状态，动作全部经 `Workspace.runVoice`，与手机同一份。
struct CueVoicePanel: View {
    @Environment(Workspace.self) private var workspace
    @State private var feedback = VoiceFeedback()

    var body: some View {
        CueVoiceView(presentation: workspace.voiceViewState.presentation(rejection: feedback.rejection),
                     detailsSource: Bindable(workspace).voiceDetails, action: run)
        .panel(isPresented: Binding { workspace.voiceDetails != nil } set: { if !$0 { workspace.voiceDetails = nil } },
               style: .bubble(workspace.voiceDetails ?? .unanchored, width: .fixed(360))) {
            VoiceHost { state in
                CueVoiceDetails(presentation: { state.presentation(rejection: feedback.rejection) }, action: run)
            }
        }
    }

    private func run(_ action: VoiceAction) { workspace.runVoice(action) { feedback.rejection = $0 } }
}
#endif
