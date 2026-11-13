#if os(iOS)
@testable import CueStore
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct IOSLaunchHistoryTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func receipt(_ launch: SessionLaunch, status: DeliveryStatus) async throws {
        var row = try #require(try await store.syncRow(recordName: launch.request.uuidString.lowercased()))
        row.fields["status"] = .text(status.rawValue)
        row.fields["handledBy"] = .text("mac")
        row.fields["modifiedAt"] = .int(row.modifiedAt + 1000)
        #expect(try await store.applyRemote([.save(row, systemFields: Data(), serverAt: Date())]).isEmpty)
    }

    @Test(arguments: [false, true])
    func 确认再开失败后_关闭重开仍须确认旧未知请求(retryWithoutClosing: Bool) async throws {
        defer { app.services.cancelBackgroundWork() }
        let task = try await store.createTask("修乱序", in: Project.defaultID)
        let workspace = Workspace(services: app.services)
        func launch(_ intent: SessionLaunchIntent) async throws -> SessionLaunch {
            try await app.services.launchSession(in: task.projectID, prompt: task.body, title: task.heading,
                                              on: "mac", card: task.id, agent: .pi, intent: intent)
        }
        let first = try await launch(.new)
        try await receipt(first, status: .unconfirmed)
        let second = try await launch(.repeatingConfirmed)
        try await receipt(second, status: .failed)

        let inPlace = try store.snapshot { try second.progress(from: $0) }.value
        #expect(inPlace.request?.status == .known(.failed))
        #expect(inPlace.submission(at: app.services.speech) == .confirm)
        await #expect(throws: CueStoreError.deliveryAlreadyHanded) { try await launch(retryWithoutClosing ? .replacing(second.request) : .new) }
        #expect(Set(try await store.deliveryRequests().map(\.id)) == [first.request, second.request])
        workspace.handOff(task)
        let restored = try #require(workspace.sessionLaunching(.card(task.id)).launch)
        #expect(restored.request == first.request)
        let progress = try store.snapshot { try restored.progress(from: $0) }.value
        #expect(progress.submission(at: app.services.speech) == .confirm)
        await #expect(throws: CueStoreError.deliveryAlreadyHanded) { try await launch(.new) }
        #expect(Set(try await store.deliveryRequests().map(\.id)) == [first.request, second.request])
        let third = try await launch(.repeatingConfirmed)
        #expect(Set(try await store.deliveryRequests().map(\.id)) == [first.request, second.request, third.request])
        #expect(try await store.deliveryRequest(first.request)?.status == .known(.unconfirmed))
    }
}
#endif
