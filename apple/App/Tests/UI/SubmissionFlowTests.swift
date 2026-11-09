import CueStore
import CueText
import Foundation
import SwiftUI
import Testing
@testable import CuePad

struct SubmissionFlowTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test(arguments: [PiQuestionKind.text, .select])
    func 文字作答只交答案_卡片附件批注留在回复框(kind: PiQuestionKind) async throws {
        let recorder = try await app.runtimeRecorder(on: "mac-a")
        try await recorder.update(sessionID: "atlas", state: .waitingForUser, title: "atlas",
                                  question: PiQuestion(promptID: "question", kind: kind, text: "喝什么？", options: ["茶"], allowsOther: true))
        let session = try #require(try await store.allPiSessionStates().first)
        let card = try await store.createCard(body: "稍后再发的卡片")
        let file = DraftFile(key: try store.files.store(pngData()), name: "")
        let outbox = Outbox(content: card.body, card: card.id)
        let note = ReplyNote(entry: UUID(), run: 0, location: 0, quote: "旧回答", note: "稍后修改")
        let box = app.services.settings.replyDraftBinding(for: session.id)
        box.wrappedValue = ComposerDraft(text: "  咖啡\n", files: [file], attachments: [outbox], notes: [note])
        let workspace = Workspace(services: app.services)

        let sending = workspace.answer(session, from: box)
        #expect(box.wrappedValue.text.isEmpty)
        await sending.value

        let request = try #require(try await store.deliveryRequests().first)
        #expect(request.answer == PiAnswer(promptID: "question", value: .text("咖啡")))
        #expect(box.wrappedValue.files == [file])
        #expect(box.wrappedValue.attachments.map(\.card) == [card.id])
        #expect(box.wrappedValue.attachments.map(\.content) == ["稍后再发的卡片"])
        #expect(box.wrappedValue.notes == [note])
    }

    @Test func 停止被拒绝_回复框操作显示执行端原因() async throws {
        let recorder = try await app.runtimeRecorder(on: "mac-a")
        try await recorder.update(sessionID: "atlas", state: .thinking, title: "atlas")
        let session = try #require(try await store.allPiSessionStates().first)
        let workspace = Workspace(services: app.services)
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { _, _ in
            .failed(.verbatim("Agent 拒绝停止"))
        }
        try await executor.start()
        await workspace.stop(session)
        await executor.stop()
        #expect(workspace.notice?.isError == true)
        #expect(workspace.notice?.text.visible.contains("Agent 拒绝停止") == true)
    }
    @Test func 新会话等附件_离线安全替换_查不到结果须确认才另开() async throws {
        let workspace = Workspace(services: app.services)
        let project = try #require(try await store.project(Project.defaultID))
        let place = try #require(ProjectFolders.launchPlaces(projects: [project], bindings: [], host: nil, workMac: "mac-a").first)
        let choice = AgentModelChoice(agents: [], agent: .pi, model: nil, thinking: nil)
        let start = SessionStart(project: project.id)
        let launching = workspace.sessionLaunching(start.launchKey)
        func submit(_ draft: ComposerDraft) -> Task<Void, Never>? {
            workspace.submitSession(start, in: place, draft: draft, choice: choice, opened: { _ in })
        }
        let url = app.directory.appending(path: "截图.png")
        try pngData().write(to: url)
        var draft = ComposerDraft(text: "看图复现")
        let box = Binding(get: { draft }, set: { draft = $0 })
        workspace.importFiles([.file(url)], into: box)
        #expect(!draft.importing.isEmpty)
        let sending = try #require(submit(draft))
        #expect(launching.sending)
        #expect(submit(draft) == nil)
        await sending.value
        let first = try #require(launching.launch)
        let request = try #require(try await store.deliveryRequest(first.request))
        let keys = CueFormat.attachmentKeys(in: request.launch?.prompt ?? "")
        let key = try #require(keys.first)
        #expect(store.files.fileURL(for: key) != nil)
        #expect(request.launch?.prompt?.hasPrefix("看图复现") == true)

        try await eventually("读到这一次的进度") { launching.progress?.launch == first.request }
        await submit(ComposerDraft(text: "改过的开场"))?.value
        let replacement = try #require(launching.launch)
        #expect(replacement.request != first.request)
        #expect(try await store.deliveryRequests().map(\.id) == [replacement.request])
        #expect(try await store.deliveryRequest(replacement.request)?.launch?.prompt == "改过的开场")

        try await store.deleteDelivery(replacement.request)
        try await eventually("查不到这一次") { launching.progress?.launch == replacement.request && launching.phase(at: app.services.speech) == .missing }
        #expect(submit(ComposerDraft(text: "再开")) == nil)
        #expect(launching.confirmingAgain)
        #expect(try await store.deliveryRequests().isEmpty)
        await launching.launchAgain()?.value
        #expect(try await store.deliveryRequests().map { $0.launch?.prompt } == ["再开"])
    }

}
