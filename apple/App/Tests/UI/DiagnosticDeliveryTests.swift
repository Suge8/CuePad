import CloudKit
@testable import CueStore
@testable import CueSync
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 手机的诊断与"把最近日志发到 Mac"经同一朵云替身到 Mac：Mac 那头是 App 用的 `DiagnosticInbox`，落盘目录换成测试自己的。
@MainActor
struct DiagnosticDeliveryTests {
    /// 一份只有一次崩溃的 MetricKit 包，时间按 `day` 排。
    private func crash(day: Int) -> Data {
        Data(#"{"timeStampEnd": "2026-01-\#(String(format: "%02d", day)) 12:00:00", "crashDiagnostics": [{"diagnosticMetaData": {"exceptionType": 1, "signal": 11}}]}"#.utf8)
    }

    @Test func 手机的诊断与最近日志到Mac_只留最近十份_删掉的Mac上也删() async throws {
        let cloud = SimulatedCloud([CKRecord.peerFloor(CueStore.peerFloor)])
        let phone = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let mac = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let services = phone.services!
        for side in [phone, mac] { side.services.startSync() }
        services.startDiagnostics()
        defer { for side in [phone, mac] { side.services.cancelBackgroundWork() } }
        let inbox = DiagnosticInbox(directory: mac.directory.appending(path: "DeviceLogs"), sync: try #require(mac.services.sync as? CloudSync))
        let arrived = {
            let folders = try FileManager.default.contentsOfDirectory(at: inbox.directory, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
            return Set(try folders.flatMap { try FileManager.default.contentsOfDirectory(atPath: $0.path) })
        }

        services.diagnostics.record((1...12).map(crash))
        try await services.diagnostics.sendRecentLogs()

        let kept = services.diagnostics.archive.names()
        #expect(kept.count == DiagnosticArchive.keep)
        #expect(kept.first?.hasSuffix("-log.log") == true)
        #expect(!kept.contains { $0.hasPrefix("2026-01-03") })
        try await inbox.check()
        #expect(try arrived() == Set(kept))
        let log = try String(contentsOf: services.diagnostics.archive.url(try #require(kept.first)), encoding: .utf8)
        #expect(log.hasPrefix("# 最近日志 | CuePad "))

        services.diagnostics.record([crash(day: 20)])
        try await eventually("第 4 天那份在 Mac 上被删、第 20 天的到了") {
            try await inbox.check()
            let files = try arrived()
            return files.contains { $0.hasPrefix("2026-01-20") } && !files.contains { $0.hasPrefix("2026-01-04") }
        }
        #expect(try arrived() == Set(services.diagnostics.archive.names()))

        // 主线程卡住先记一份、恢复后原地改写带上时长：Mac 上的跟着换成恢复后的
        var note = FreezeNote(start: .now, seconds: nil, page: "cue", actions: [], version: "1", device: "iPhone18,1", os: "iOS 27")
        try services.diagnostics.archive.store(note)
        services.diagnostics.record([])
        let freeze = try #require(services.diagnostics.archive.names().first { $0.hasSuffix("-freeze.json") })
        let onMac = {
            try await inbox.check()
            let folder = try #require(FileManager.default.contentsOfDirectory(at: inbox.directory, includingPropertiesForKeys: nil).first { !$0.lastPathComponent.hasPrefix(".") })
            return try? JSONDecoder.diagnostics.decode(FreezeNote.File.self, from: Data(contentsOf: folder.appending(path: freeze))).cuepadFreeze
        }
        try await eventually("卡住记录到了 Mac") { try await onMac() != nil }
        note.seconds = 3
        try services.diagnostics.archive.store(note)
        services.diagnostics.record([])
        try await eventually("Mac 上的卡住记录换成恢复后的") { try await onMac()?.seconds == 3 }
    }
}
