#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 随手记是浮在键盘上方的输入框：收起时写了东西就留着、下次打开接着写，空的收起即丢（连同换过的种类与落点）。
@MainActor
struct CaptureDraftTests {
    private func navigation() -> Navigation {
        Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: "capture-\(UUID())")!, launchArguments: [:]))
    }

    @Test func 有内容收起后再打开还在_空的收起即丢() {
        let navigation = navigation(), project = UUID()
        navigation.startCapture()
        navigation.capture.draft.text = "周末把同步重试改掉"
        navigation.capture.project = .some(project)
        navigation.endCapture()

        #expect(!navigation.capturing)
        navigation.startCapture()
        #expect(navigation.capture.draft.text == "周末把同步重试改掉")
        #expect(navigation.capture.project == .some(project))

        navigation.capture.draft.text = "  "
        navigation.capture.kind = .task
        navigation.endCapture()
        navigation.startCapture()
        #expect(navigation.capture.draft.text.isEmpty)
        #expect(navigation.capture.kind == .idea)
        #expect(navigation.capture.project == nil)
    }

}
#endif
