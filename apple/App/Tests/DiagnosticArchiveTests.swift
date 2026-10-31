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
    /// 栈是树，根是崩溃处，最深的叶子是最外层（dyld）。
    static func payload(end: String = "2026-10-09 03:40:12", kind: String = "crashDiagnostics", exceptionType: Int = 10, signal: Int = 6) -> Data {
        Data("""
        {
          "timeStampBegin": "2026-10-09 00:00:00", "timeStampEnd": "\(end)",
          "\(kind)": [{
            "version": "1.0.0",
            "diagnosticMetaData": {
              "appVersion": "0.1.0", "appBuildVersion": "2610082154", "deviceType": "iPhone18,3", "osVersion": "iPhone OS 27.0 (24A430)",
              "exceptionType": \(exceptionType), "exceptionCode": 1, "signal": \(signal),
              "terminationReason": "Namespace SIGNAL, Code 6 Aborted: 6",
              "objectiveCexceptionReason": { "exceptionName": "NSInvalidArgumentException", "composedMessage": "Invalid scene state" }
            },
            "callStackTree": { "callStackPerThread": true, "callStacks": [
              { "threadAttributed": false, "callStackRootFrames": [
                { "binaryName": "libsystem_kernel.dylib", "offsetIntoBinaryTextSegment": 100, "address": 1, "sampleCount": 1, "subFrames": [] } ] },
              { "threadAttributed": true, "callStackRootFrames": [
                { "binaryName": "libsystem_kernel.dylib", "offsetIntoBinaryTextSegment": 4096, "address": 5, "sampleCount": 1, "subFrames": [
                  { "binaryName": "libsystem_pthread.dylib", "offsetIntoBinaryTextSegment": 300, "address": 4, "sampleCount": 1, "subFrames": [
                    { "binaryName": "UIKitCore", "offsetIntoBinaryTextSegment": 2000, "address": 3, "sampleCount": 1, "subFrames": [
                      { "binaryName": "dyld", "offsetIntoBinaryTextSegment": 100, "address": 2, "sampleCount": 1, "subFrames": [] } ] } ] } ] } ] }
            ] }
          }]
        }
        """.utf8)
    }

    /// 新的在前；同一份重复送达只存一份；没有诊断内容的包不存，读不出的文件跳过。
    @Test func 按时间存档_设置页取最新一份_重复与坏的不算() throws {
        let archive = archive()
        try archive.store(Self.payload(end: "2026-10-08 22:00:00"))
        try archive.store(Self.payload(end: "2026-10-09 03:40:12", kind: "hangDiagnostics"))
        try archive.store(Self.payload(end: "2026-10-09 03:40:12", kind: "hangDiagnostics"))
        try archive.store(Data(#"{"timeStampEnd": "2026-10-09 05:00:00"}"#.utf8))
        try Data("不是 JSON".utf8).write(to: archive.directory.appending(path: "2026-10-09T06-00-00Z-crash.json"))

        let reports = archive.reports()
        #expect(reports.map(\.kind) == [.hang, .crash])
        #expect(reports.first?.date == Date(timeIntervalSince1970: 1_791_517_212))
        #expect(reports.first?.id == "2026-10-09T03-40-12Z-hang.json")
    }

    @Test func 摘要_异常类型_信号_原因_崩溃线程顶部的帧() throws {
        let archive = archive()
        try archive.store(Self.payload(exceptionType: 10, signal: 6))
        let report = try #require(archive.reports().first)

        #expect(report.exception == "EXC_CRASH" && report.signal == "SIGABRT")
        #expect(report.reason == "NSInvalidArgumentException: Invalid scene state\nNamespace SIGNAL, Code 6 Aborted: 6")
        #expect(report.app?.visible == "0.1.0（2610082154） · iPhone18,3 · iPhone OS 27.0 (24A430)")
        // 取崩溃线程（不是第一条栈），崩溃处在前
        #expect(report.frames == ["libsystem_kernel.dylib +0x1000", "libsystem_pthread.dylib +0x12c", "UIKitCore +0x7d0", "dyld +0x64"])
    }

}
