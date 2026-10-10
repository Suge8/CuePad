import Testing
@testable import CuePad

/// 段落末尾的英文单词不单独掉到下一行：最后两个英文单词之间换成不断行空格，要换行就一起换（中文行里夹的英文原因常见这样）。
struct WidowTests {
    @Test func 末尾两个英文单词连在一起() {
        #expect(Widow.joined("模型拒绝了请求（400）：prompt is too long") == "模型拒绝了请求（400）：prompt is too\u{00A0}long")
        #expect(Widow.joined("Connection reset by peer") == "Connection reset by\u{00A0}peer")
    }

    @Test func 末尾单词带标点也连在一起() {
        #expect(Widow.joined("请求失败：request failed (timeout).") == "请求失败：request failed\u{00A0}(timeout).")
        #expect(Widow.joined("rate limited, retry later,") == "rate limited, retry\u{00A0}later,")
        #expect(Widow.joined("\"bad request\"") == "\"bad\u{00A0}request\"")
    }

    @Test func 末尾不是两个英文单词的不动() {
        #expect(Widow.joined("那台 Mac 上的 Pi 已经退出，没能送进去") == "那台 Mac 上的 Pi 已经退出，没能送进去")
        #expect(Widow.joined("timeout") == "timeout")
        #expect(Widow.joined("出错了 ") == "出错了 ")
    }
}
