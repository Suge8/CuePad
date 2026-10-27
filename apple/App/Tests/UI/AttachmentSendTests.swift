#if os(macOS)
import CryptoKit
import CueStore
import CueSync
import CueText
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 回复框带着还没到这台 Mac 的大附件发出的那句不挡后面的话：文件在旁边现取（`AppServices.fetchFile`），发给另一个会话的话照常先送到；
/// 文件到了，那句照常送到，会话收到的是本机那份的路径。
struct AttachmentSendTests {
    let app = TestApp()

    @Test func 带着还没到的大附件的那句不挡后面的话_文件到了照常送到() async throws {
        let services: AppServices = app.services
        let atlas = try await app.host.connect("atlas", cwd: "/work/atlas")
        let web = try await app.host.connect("web", cwd: "/work/web")
        let movie = Data(repeating: 3, count: 2_000_000)
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/录屏.mov")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try movie.write(to: source)
        let key = AttachmentKey.make(hash: SHA256.hash(data: movie).map { String(format: "%02x", $0) }.joined(), format: "mov")
        let arrive = AsyncStream<Void>.makeStream()
        app.sync.fetching.withLock {
            $0 = { [files = services.store.files, arrived = arrive.stream] wanted in
                for await _ in arrived { break }  // 在路上，直到放行
                _ = try files.store(fileAt: source)
                guard let url = files.fileURL(for: wanted) else { throw FileFetchFailure.damaged }
                return url
            }
        }
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }
        let workspace = Workspace(services: services)

        for (session, draft) in [("atlas", ComposerDraft(text: "看这段录屏", files: [DraftFile(key: key, name: "录屏.mov")])), ("web", ComposerDraft(text: "先改文案"))] {
            var box = draft
            let binding = Binding(get: { box }, set: { box = $0 })
            let listener = Listener.session(SendTarget(kind: .piSession, name: session, ref: session), host: TestApp.hostID, mode: .send, card: nil)
            await workspace.speak(to: listener, from: binding) { $0.stored }.value
        }
        try await eventually("后一句先送到") { web.messages.map(\.text) == ["先改文案"] }
        #expect(atlas.messages.isEmpty)

        arrive.continuation.yield()
        try await eventually("文件到了，前一句照常送到") { !atlas.messages.isEmpty }
        let path = try #require(services.store.files.fileURL(for: key)).path(percentEncoded: false)
        #expect(atlas.messages.map(\.text) == ["看这段录屏\n\n附件：录屏.mov（\(path)）"])
    }
}
#endif
