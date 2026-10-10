import Foundation
import Testing
@testable import CueStore

/// 同步记录里存的 JSON 同样的内容同样的字节：上传只带改动的字段（`CueSync.ServerValues`）靠它认出"没变"；默认的键序每次编码都不一样。
@Suite struct StoredJSONTests {
  @Test func equalContentIsStoredAsEqualBytes() {
    let models = (0..<40).map { PiModelOption(key: PiModelKey(provider: "p", id: "m\($0)"), name: "名字 \($0)", thinkingLevels: [.off, .low, .high]) }
    let commands = (0..<40).map { PiSlashCommand(name: "c\($0)", summary: "说明 \($0)", source: .known(.builtin), hint: "<x>") }
    let texts = (0..<20).map { _ in [JSONColumn.encodeList(models), JSONColumn.encodeList(commands), models.first.map(JSONColumn.encode)] }
    #expect(Set(texts.map { $0[0] }).count == 1)
    #expect(Set(texts.map { $0[1] }).count == 1)
    #expect(Set(texts.map { $0[2] }).count == 1)
  }
}
