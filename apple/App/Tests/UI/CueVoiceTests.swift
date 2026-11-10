#if os(macOS)
import CueStore
import CueTestSupport
import Testing
@testable import CuePad

@MainActor
struct CueVoiceTests {
    @Test func 每一通用开始时库里的音色_通话中改了下一通才换_认不出的按默认() async throws {
        let app = TestApp(), store = app.services.store, host = TestApp.hostID
        defer { app.services.cancelBackgroundWork() }
        try await store.updateCueProfile { $0.enabledAt = .now; $0.hostID = host; $0.voice = .known(.hanul) }
        let fixture = VoiceFlowFixture(app.services)
        try await fixture.connect()
        try await app.services.updateCue { $0.voice = .known(.himari) }
        #expect(fixture.voices == [.hanul])
        #expect(!app.services.voice.canPreview)
        try await fixture.hangUp()
        #expect(app.services.voice.canPreview)
        try await fixture.connect()
        try await fixture.hangUp()
        try await store.updateCueProfile { $0.voice = .unknown("rindō") }
        try await fixture.connect()
        try await fixture.hangUp()
        #expect(fixture.voices == [.hanul, .himari, .cove])
        #expect(try await store.cueProfile()?.voice == .unknown("rindō"))
    }
}
#endif
