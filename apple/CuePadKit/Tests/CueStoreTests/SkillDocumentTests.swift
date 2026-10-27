import CueStore
import Testing

/// 文件页写回 SKILL.md：只换改了的那一项，其余 frontmatter 与正文一个字节不动；读出的名字与说明是 YAML 的值。
/// 样例是各家真实技能里出现过的写法，合成的最小版。
@Suite struct SkillDocumentTests {
  struct Write: CustomTestStringConvertible, Sendable {
    let label: String, file: String
    var name: String? = nil, description: String? = nil, body: String? = nil
    let expected: String
    var testDescription: String { label }
  }

  static let writes: [Write] = [
    Write(label: "没改：Windows 换行、围栏后的空格原样", file: "--- \r\nname: a\r\ndescription: b\r\n---  \r\n\r\nx\r\n", expected: "--- \r\nname: a\r\ndescription: b\r\n---  \r\n\r\nx\r\n"),
    Write(label: "Windows 换行只改正文", file: "---\r\nname: a\r\ndescription: b\r\n---\r\n\r\nold\r\n", body: "new\nline\n",
          expected: "---\r\nname: a\r\ndescription: b\r\n---\r\n\r\nnew\r\nline\r\n"),
    Write(label: "Windows 换行改说明", file: "---\r\nname: a\r\ndescription: b\r\nlicense: MIT\r\n---\r\nx", description: "c",
          expected: "---\r\nname: a\r\ndescription: c\r\nlicense: MIT\r\n---\r\nx"),
    Write(label: "没改：收尾 --- 在文件末尾", file: "---\nname: a\n---", expected: "---\nname: a\n---"),
    Write(label: "收尾 --- 在文件末尾，补上正文", file: "---\nname: a\n---", body: "x", expected: "---\nname: a\n---\nx"),
    Write(label: "跨行的普通写法整段换掉", file: "---\nname: a\ndescription: one\n  two\nlicense: MIT\n---\nx", description: "new",
          expected: "---\nname: a\ndescription: new\nlicense: MIT\n---\nx"),
    Write(label: "跨行的双引号整段换掉", file: "---\ndescription: \"one\n  two\"\nname: a\n---\nx", description: "new",
          expected: "---\ndescription: \"new\"\nname: a\n---\nx"),
    Write(label: "多行说明写成块", file: "---\nname: a\ndescription: b\n---\nx", description: "first\n\nsecond",
          expected: "---\nname: a\ndescription: |-\n  first\n\n  second\n---\nx"),
    Write(label: "双引号的保留双引号并转义", file: "---\nname: a\ndescription: \"say \\\"hi\\\"\"\n---\nx", description: "say \"bye\" \\ ok",
          expected: "---\nname: a\ndescription: \"say \\\"bye\\\" \\\\ ok\"\n---\nx"),
  ]

  @Test(arguments: writes) func writesBackOnlyWhatChanged(_ write: Write) {
    let document = SkillDocument(write.file)
    let text = document.with(
      name: write.name ?? document.name ?? "", description: write.description ?? document.description ?? "", body: write.body ?? document.body)
    #expect(text == write.expected)
  }

  @Test(arguments: [
    ("description: \"say \\\"hi\\\" \\\\ \\u00e9\"", "say \"hi\" \\ é"),
    ("description: 'it''s: ok'", "it's: ok"),
    ("description: plain # 注释", "plain"),
    ("description: one\n  two", "one two"),
    ("description: |\n  a\n    b\n", "a\n  b"),
    ("description: >\n  a\n  b\n\n  c\n", "a b\nc"),
  ])
  func readsTheYAMLValue(_ field: String, _ expected: String) {
    #expect(SkillDocument("---\nname: a\n\(field)\n---\nx").description == expected)
  }
}
