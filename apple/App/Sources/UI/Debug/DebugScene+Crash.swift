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
              "exceptionType": 1, "exceptionCode": 1, "signal": 11,
              "terminationReason": "Namespace SIGNAL, Code 11 Segmentation fault: 11"
            },
            "callStackTree": { "callStackPerThread": true, "callStacks": [
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
}
#endif
