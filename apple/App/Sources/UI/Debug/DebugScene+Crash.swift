#if DEBUG
import Foundation

extension DebugScene {
    /// 一份 MetricKit 形状的样例崩溃诊断（`-CuePadSampleCrash YES`）。
    static var sampleCrash: Data {
        Data("""
        {
          "timeStampBegin": "2026-10-09 00:00:00", "timeStampEnd": "2026-10-09 03:40:12",
          "crashDiagnostics": [{
            "version": "1.0.0",
            "diagnosticMetaData": {
              "appVersion": "0.1.0", "appBuildVersion": "2610082154", "deviceType": "iPhone18,3", "osVersion": "iPhone OS 27.0 (24A430)",
              "exceptionType": 10, "exceptionCode": 0, "signal": 6,
              "terminationReason": "Namespace SIGNAL, Code 6 Aborted: 6",
              "objectiveCexceptionReason": { "exceptionName": "NSInvalidArgumentException", "composedMessage": "Invalid scene state" }
            },
            "callStackTree": { "callStackPerThread": true, "callStacks": [
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
}
#endif
