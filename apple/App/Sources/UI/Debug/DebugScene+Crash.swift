#if DEBUG
import Foundation

extension DebugScene {
    /// `-CuePadSampleCrash YES` 存进存档的样例：照 2611060241 上真机交来的那份（从后台划掉卡住的 App，5 秒没退出被看门狗结束）的形状，
    /// 同一种两次（导出时并成一条、计两次），其中一个包里同时带一次卡死（一个包里的几次各算一份），外加一条本机记下的主线程卡住。
    static var sampleDiagnostics: [Data] {
        [watchdogCrash(end: "2026-11-06 12:02:47", cpu: "5.408", hang: true), watchdogCrash(end: "2026-11-06 11:41:05", cpu: "5.391", hang: false)]
    }

    static var sampleFreeze: FreezeNote {
        FreezeNote(
            start: Date(timeIntervalSince1970: 1_793_937_740), seconds: nil, page: "cue > session",
            actions: ["12:02:31 open panel", "12:02:33 close modal", "12:02:36 scene inactive"],
            version: "2026.11.6（2611060241）", device: "iPhone18,1", os: "Version 27.2 (Build 24B5089g)")
    }

    /// `cpu`：App 在那 5 秒里的 CPU 用时，每次都不同（同一种并成一条时原因原文各列一行）。
    private static func watchdogCrash(end: String, cpu: String, hang: Bool) -> Data {
        let reason = "RBSTerminateContext domain:10 code:0x8BADF00D explanation:[app<com.sugeh.cuepad>] Failed to terminate gracefully after 5.0s "
            + "ProcessVisibility: Foreground ProcessState: Running WatchdogEvent: process-exit WatchdogVisibility: Foreground "
            + "WatchdogCPUStatistics: ( \\\"Elapsed total CPU time (seconds): 16.470 (user 10.110, system 6.360), 51% CPU\\\", "
            + "\\\"Elapsed application CPU time (seconds): \(cpu), 17% CPU\\\" ) ThermalInfo: ( \\\"Thermal Level: 1\\\", \\\"Thermal State: fair\\\" )"
        return Data("""
        {
          "timeStampBegin": "2026-11-06 00:00:00", "timeStampEnd": "\(end)",
          "crashDiagnostics": [{
            "version": "1.0.0",
            "diagnosticMetaData": {
              "appVersion": "2026.11.6", "appBuildVersion": "2611060241", "deviceType": "iPhone18,1", "osVersion": "iPhone OS 27.2 (24B5089g)",
              "platformArchitecture": "arm64e", "bundleIdentifier": "com.sugeh.cuepad", "regionFormat": "CN", "isTestFlightApp": true, "lowPowerModeEnabled": false,
              "exceptionType": 10, "exceptionCode": 0, "signal": 9, "pid": 4211, "terminationReason": "\(reason)"
            },
            "callStackTree": { "callStackPerThread": true, "callStacks": [
              { "threadAttributed": true, "callStackRootFrames": [\(chain(sampleFrames))] }
            ] }
          }]\(hang ? ", \(sampleHang)" : "")
        }
        """.utf8)
    }

    /// 同一个包里的一次卡死：主线程停在 SwiftUI 的更新里，往下是 CuePad 自己的帧。
    private static var sampleHang: String {
        """
        "hangDiagnostics": [{
          "version": "1.0.0",
          "diagnosticMetaData": {
            "appVersion": "2026.11.6", "appBuildVersion": "2611060241", "deviceType": "iPhone18,1", "osVersion": "iPhone OS 27.2 (24B5089g)", "hangDuration": "4.2 sec"
          },
          "callStackTree": { "callStackPerThread": true, "callStacks": [
            { "threadAttributed": true, "callStackRootFrames": [\(chain(sampleFrames.dropFirst(3)))] }
          ] }
        }]
        """
    }

    /// 自顶向下：前 13 帧照那份真机诊断（UUID 与偏移），之后是常见的主线程底部；CuePad 那一帧的 UUID 是 2611060241 的主程序。
    private static let sampleFrames: [(String, String, Int)] = [
        ("libsystem_malloc.dylib", "23C72FA4-C616-3B28-B7AC-1285D74905B1", 239_736),
        ("libswiftCore.dylib", "1626B042-8BEF-3CD5-B323-614D439C4279", 35_888),
        ("libswiftCore.dylib", "1626B042-8BEF-3CD5-B323-614D439C4279", 31_032),
        ("SwiftUICore", "B1A5583A-A8F5-3744-B244-91DD148A4CC5", 1_463_044),
        ("SwiftUICore", "B1A5583A-A8F5-3744-B244-91DD148A4CC5", 596_800),
        ("AttributeGraph", "AFB18C4B-5472-396A-854D-9A2F96D7F4FA", 43_352),
        ("AttributeGraph", "AFB18C4B-5472-396A-854D-9A2F96D7F4FA", 47_436),
        ("AttributeGraph", "AFB18C4B-5472-396A-854D-9A2F96D7F4FA", 17_156),
        ("AttributeGraph", "AFB18C4B-5472-396A-854D-9A2F96D7F4FA", 15_372),
        ("SwiftUICore", "B1A5583A-A8F5-3744-B244-91DD148A4CC5", 614_240),
        ("SwiftUICore", "B1A5583A-A8F5-3744-B244-91DD148A4CC5", 249_836),
        ("SwiftUICore", "B1A5583A-A8F5-3744-B244-91DD148A4CC5", 248_488),
        ("CuePad", "E69ABC5E-C989-3D3B-A3E6-65ADA0877B19", 4_210_884),
        ("UIKitCore", "0E5A3C1D-0000-3A00-9000-000000000001", 9_081_220),
        ("CoreFoundation", "0E5A3C1D-0000-3A00-9000-000000000002", 345_112),
        ("GraphicsServices", "0E5A3C1D-0000-3A00-9000-000000000003", 4_424),
        ("UIKitCore", "0E5A3C1D-0000-3A00-9000-000000000001", 1_201_644),
        ("CuePad", "E69ABC5E-C989-3D3B-A3E6-65ADA0877B19", 46_092),
        ("dyld", "0E5A3C1D-0000-3A00-9000-000000000004", 23_672),
    ]

    /// MetricKit 的栈是树：每一帧的调用方是它唯一的子帧。
    private static func chain(_ frames: some Collection<(String, String, Int)>) -> String {
        guard let (name, uuid, offset) = frames.first else { return "" }
        return """
        { "binaryName": "\(name)", "binaryUUID": "\(uuid)", "offsetIntoBinaryTextSegment": \(offset), "address": \(offset + 4_294_967_296), "sampleCount": 1, "subFrames": [\(chain(frames.dropFirst()))] }
        """
    }
}
#endif
