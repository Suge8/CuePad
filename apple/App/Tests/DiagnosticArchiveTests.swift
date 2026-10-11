import Foundation
import Testing
@testable import CuePad

/// MetricKit 交来的崩溃/卡死诊断：原始 JSON 按时间存进资料库目录下的诊断文件夹（只留最近 `DiagnosticArchive.keep` 份），
/// 设置页据最新一份写"上次崩溃 · 时间"并给摘要。不联网、不上传。
struct DiagnosticArchiveTests {
    private func archive() -> DiagnosticArchive {
        DiagnosticArchive(directory: TestLibraries.makeDirectory().appending(path: "Diagnostics", directoryHint: .isDirectory))
    }

    /// MetricKit 的 JSON 形状（`MXDiagnosticPayload.jsonRepresentation()`）：第一条调用栈不是崩溃线程，第二条才是；
    /// 栈是树，根是最外层（dyld），最深的叶子是崩溃处。
    static func payload(end: String = "2026-10-09 03:40:12", kind: String = "crashDiagnostics", exceptionType: Int = 1, signal: Int = 11) -> Data {
        Data("""
        {
          "timeStampBegin": "2026-10-09 00:00:00", "timeStampEnd": "\(end)",
          "\(kind)": [{
            "version": "1.0.0",
            "diagnosticMetaData": {
              "appVersion": "0.1.0", "appBuildVersion": "2610082154", "deviceType": "iPhone18,3", "osVersion": "iPhone OS 27.0 (24A430)",
              "exceptionType": \(exceptionType), "exceptionCode": 1, "signal": \(signal),
              "terminationReason": "Namespace SIGNAL, Code 11 Segmentation fault: 11"
            },
            "callStackTree": { "callStackPerThread": true, "callStacks": [
              { "threadAttributed": false, "callStackRootFrames": [
                { "binaryName": "libsystem_kernel.dylib", "offsetIntoBinaryTextSegment": 100, "address": 1, "sampleCount": 1, "subFrames": [] } ] },
              { "threadAttributed": true, "callStackRootFrames": [
                { "binaryName": "dyld", "offsetIntoBinaryTextSegment": 100, "address": 2, "sampleCount": 1, "subFrames": [
                  { "binaryName": "CuePad", "offsetIntoBinaryTextSegment": 2000, "address": 3, "sampleCount": 1, "subFrames": [
                    { "binaryName": "SwiftUI", "offsetIntoBinaryTextSegment": 300, "address": 4, "sampleCount": 1, "subFrames": [
                      { "binaryName": "CuePad", "offsetIntoBinaryTextSegment": 4096, "address": 5, "sampleCount": 1, "subFrames": [] } ] } ] } ] } ] }
            ] }
          }]
        }
        """.utf8)
    }

    @Test func 按时间存档_设置页取最新一份() throws {
        let archive = archive()
        try archive.store(Self.payload(end: "2026-10-08 22:00:00"))
        try archive.store(Self.payload(end: "2026-10-09 03:40:12", kind: "hangDiagnostics"))

        let reports = archive.reports()
        #expect(reports.map(\.kind) == [.hang, .crash])  // 新的在前
        #expect(reports.first?.date == Date(timeIntervalSince1970: 1_791_517_212))
        #expect(reports.first?.id == "2026-10-09T03-40-12Z-hang.json")
    }

    @Test func 同一份重复送达只存一份() throws {
        let archive = archive()
        try archive.store(Self.payload())
        try archive.store(Self.payload())
        #expect(archive.reports().count == 1)
    }

    @Test func 摘要_异常类型_信号_原因_崩溃线程顶部的帧() throws {
        let archive = archive()
        try archive.store(Self.payload(exceptionType: 1, signal: 11))
        let report = try #require(archive.reports().first)

        #expect(report.exception == "EXC_BAD_ACCESS" && report.signal == "SIGSEGV")
        #expect(report.reason == "Namespace SIGNAL, Code 11 Segmentation fault: 11")
        #expect(report.app?.visible == "0.1.0（2610082154） · iPhone18,3 · iPhone OS 27.0 (24A430)")
        // 取崩溃线程（不是第一条栈），最深的在前
        #expect(report.frames == ["CuePad +0x1000", "SwiftUI +0x12c", "CuePad +0x7d0", "dyld +0x64"])
    }

    @Test func 没有诊断内容的包不存_读不出的文件跳过() throws {
        let archive = archive()
        try archive.store(Data(#"{"timeStampEnd": "2026-10-09 03:40:12"}"#.utf8))
        #expect(archive.reports().isEmpty)

        try FileManager.default.createDirectory(at: archive.directory, withIntermediateDirectories: true)
        try Data("不是 JSON".utf8).write(to: archive.directory.appending(path: "2026-10-09T03-40-12Z-crash.json"))
        #expect(archive.reports().isEmpty)
    }
}
