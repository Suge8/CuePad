import CueStore
import Foundation
import Testing
@testable import CuePad

/// fixture 由 main 83d308687 的真实 CueNow / CueActivityState 与 JSONEncoder 生成，非当前编码器反推。
struct RuntimeSnapshotUpgradeTests {
    @Test func 更新后读旧缓存和已有活动_保留任务与最后进度_无证明不假忙也不结束已有活动() async throws {
        let app = TestApp(), workspace = Workspace(services: app.services)
        let task = try await workspace.createTask("升级前任务", in: Project.defaultID)
        let directory = app.services.location.snapshotsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.fixture("runtime-main-cache", task: task.id).write(to: directory.appending(path: CueNow.fileName), options: .atomic)
        let cached = try #require(Snapshots.read(CueNow.self, from: directory))
        let activity = try JSONDecoder().decode(CueActivityState.self, from: Self.fixture("runtime-main-activity", task: task.id))
        let originalAt = Date(timeIntervalSince1970: 1_790_000_000)
        for now in [cached, activity.now] {
            #expect(now.at == originalAt && now.advancing == 1)
            #expect(now.items.first?.id == "task/\(task.id.uuidString)" && now.items.first?.name == "升级前任务")
            #expect(now.items.first?.since == originalAt - 30 && now.items.first?.kind == .unconfirmed)
            #expect(now.tally.moving == 0 && now.subagents == 0 && now.unconfirmed)
            #expect(now.isLive && !now.hasConfirmedActivity)
            let expired = now.shown(at: originalAt + 901)
            #expect(expired.isLive && !expired.hasConfirmedActivity && expired.items.first?.name == "升级前任务")
        }
        #expect(try await app.services.store.card(task.id)?.status == .todo)
        try Snapshots.write(cached, to: directory)
        let rewritten = try #require(Snapshots.read(CueNow.self, from: directory))
        #expect(rewritten == cached)
        let bytes = try Data(contentsOf: directory.appending(path: CueNow.fileName))
        let fields = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(fields["name"] as? String == "Cue" && fields["n"] == nil)
    }

    private static func fixture(_ name: String, task: UUID) throws -> Data {
        let url = try #require(Bundle(for: RuntimeSnapshotFixtures.self).url(forResource: name, withExtension: "json"))
        let original = try String(contentsOf: url, encoding: .utf8)
        return Data(original.replacingOccurrences(of: "11111111-1111-1111-1111-111111111111", with: task.uuidString).utf8)
    }
}

private final class RuntimeSnapshotFixtures: NSObject {}
