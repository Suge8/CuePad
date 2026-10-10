import CueSync
import Testing
@testable import CuePad

/// 同步出错时给人看的是人话（本机的内容都在、会自动重试），底层原因（错误码、服务端说明）不出现在状态里，
/// 只在"没能同步"的明细里按记录类型说明（iOS 与 Mac 设置共用）。
struct SyncSummaryTests {
    @Test func 同步出错_状态说明不带底层原因() {
        let raw = "CKErrorDomain 14: invalid attempt to update record from type tasks to cards"
        let summary = SyncSummary(.failed(raw))

        #expect(summary.detail?.contains("本机的内容都在") == true)
        #expect(summary.detail?.contains(raw) != true)
    }
}
