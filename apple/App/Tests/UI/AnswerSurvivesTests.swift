import CueStore
import Foundation
import Testing
@testable import CuePad

@MainActor
@Suite(.releasesLibraries)
struct AnswerSurvivesTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    /// 答题部件（会话页、Cue 的等你卡、菜单栏）都从 `LiveSessions.answer(to:)` 找自己的作答请求：找不到，选项就停在「送达中」。
    @Test func 作答后别的请求发进同一会话_作答请求还找得到() async throws {
        let recorder = try await app.runtimeRecorder(on: "mac")
        let question = Question(promptID: "p-1", kind: .select, text: "要覆盖吗？", options: ["覆盖", "另存"])
        try await recorder.update(sessionID: "s", state: .waitingForUser, title: "homepage", question: question)
        let wait = try #require(try await CueThread.read(from: store).waiting.first)
        guard case .session(let session, _) = wait.wait else { throw Mismatch() }

        let request = try await app.services.answer(.option("另存"), to: session)
        try await store.requestDelivery("顺便把 Atom 也输出", to: session.target, on: "mac")
        #expect(try await store.deliveryRequests(toSession: "s").map(\.mode.known) == [.answer, .send])
        app.services.liveSessions.apply(try await LiveSessions.Page.read(from: store), at: .always())

        #expect(app.services.liveSessions.answer(to: session)?.id == request.id)
    }
}

private struct Mismatch: Error {}
