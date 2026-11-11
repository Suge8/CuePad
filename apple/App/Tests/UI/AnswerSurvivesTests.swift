import CueStore
import Foundation
import Testing
@testable import CuePad

/// 作答之后同一会话又有别的请求发进来：答题部件仍找得到自己的作答请求，选项才能跟着它的结果走，不停在「送达中」。
/// 两条路径取会话的来源不同（拍板卡读 `CueThread`，菜单栏读 `LiveSessions`），找作答请求的是同一处。
@MainActor
@Suite(.releasesLibraries)
struct AnswerSurvivesTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func answered(from pick: (CueStore) async throws -> PiSessionState) async throws -> (DeliveryRequest, PiSessionState) {
        let recorder = try await app.runtimeRecorder(on: "mac")
        let question = PiQuestion(promptID: "p-1", kind: .select, text: "要覆盖吗？", options: ["覆盖", "另存"])
        try await recorder.update(sessionID: "s", state: .waitingForUser, title: "homepage", question: question)
        let session = try await pick(store)
        let request = try await app.services.answer(.option("另存"), to: session)
        try await store.requestDelivery("顺便把 Atom 也输出", to: session.target, on: "mac")
        #expect(try await store.deliveryRequests(toSession: "s").map(\.mode.known) == [.answer, .send])
        app.services.liveSessions.apply(try await LiveSessions.Page.read(from: store), at: .always())
        return (request, session)
    }

    private func resolves(_ request: DeliveryRequest, _ session: PiSessionState) async throws {
        #expect(app.services.liveSessions.answer(to: session)?.id == request.id)
    }

    @Test func Cue的等你卡_作答后别的请求插进来_作答请求还在() async throws {
        let (request, session) = try await answered { store in
            let wait = try #require(try await CueThread.read(from: store).waiting.first)
            guard case .session(let session, _) = wait.wait else { throw Mismatch() }
            return session
        }
        try await resolves(request, session)
    }

    @Test func 菜单栏_作答后别的请求插进来_作答请求还在() async throws {
        let (request, session) = try await answered { store in
            try #require(try await store.allPiSessionStates().first)
        }
        try await resolves(request, session)
    }
}

private struct Mismatch: Error {}
