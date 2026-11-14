import CueStore
import Foundation
import Testing

/// 只有老用户的库走升级：建新库的 SQL 与升级步骤漏了一列、一个索引，新装的库测不出来。从每一份冻结的旧结构升上来，表、列、索引、触发器都与新库一样。
@Suite struct SchemaUpgradeTests {
  @Test(arguments: FrozenSchema.versions)
  func aLibraryUpgradedFromAnOldVersionIsLaidOutLikeANewOne(version: Int) throws {
    let fresh = TestLibraries.makeDirectory(), upgraded = TestLibraries.makeDirectory()
    _ = try CueStore(location: .isolated(fresh))
    try RawDB(upgraded.appending(path: "cuepad.db")).exec(FrozenSchema.sql(version))
    _ = try CueStore(location: .isolated(upgraded))
    #expect(try layout(of: upgraded) == layout(of: fresh))
  }

  private func layout(of directory: URL) throws -> [String] {
    let db = RawDB(directory.appending(path: "cuepad.db"))
    var lines = try db.rows("PRAGMA user_version").map { "version \($0[0])" }
    let tables = try db.rows("SELECT name, type, strict, wr FROM pragma_table_list WHERE schema = 'main' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    for table in tables {
      lines.append("table \(table.joined(separator: " "))")
      // 表定义里列与约束的先后随建法不同（升级加的列在表尾），逐项排序后比：CHECK、COLLATE、默认值这些 pragma 看不出的也在里面
      if let sql = try db.rows("SELECT sql FROM sqlite_schema WHERE name = '\(table[0])'").first?[0], sql != "NULL" {
        lines += definitionItems(sql).map { "  definition \($0)" }
      }
      lines += try db.rows("SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info('\(table[0])') ORDER BY name").map { "  column \($0.joined(separator: " "))" }
      // 约束带出的唯一索引没有 SQL、名字随建表的先后编号：只比它的列
      lines += try db.rows(
        """
        SELECT l.origin, l."unique", (SELECT group_concat(i.name) FROM pragma_index_info(l.name) i) FROM pragma_index_list('\(table[0])') l
        WHERE l.origin != 'c' ORDER BY 3
        """
      ).map { "  constraint \($0.joined(separator: " "))" }
    }
    lines += try db.rows("SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE type IN ('index', 'trigger') AND sql IS NOT NULL ORDER BY type, name")
      .map { "\($0[0]) \($0[1]) on \($0[2]): \($0[3].replacing(/\s+/, with: " ").replacing(/\ ?([(),])\ ?/) { $0.1 })" }
    return lines
  }

  /// 建表语句括号里的顶层各项（列定义与表约束），空白规整后排序；STRICT 等括号后的选项另算一项。
  private func definitionItems(_ sql: String) -> [String] {
    let text = sql.replacing(/\s+/, with: " ")
    guard let open = text.firstIndex(of: "(") else { return [text] }
    var items: [String] = [], current = "", depth = 0, index = text.index(after: open)
    while index < text.endIndex {
      let c = text[index]
      if c == "(" { depth += 1 }
      if c == ")" {
        if depth == 0 { break }
        depth -= 1
      }
      if c == ",", depth == 0 {
        items.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
      } else {
        current.append(c)
      }
      index = text.index(after: index)
    }
    items.append(current.trimmingCharacters(in: .whitespaces))
    let options = index < text.endIndex ? String(text[text.index(after: index)...]).trimmingCharacters(in: .whitespaces) : ""
    return items.map { $0.replacing(/\ ?([(),])\ ?/) { $0.1 } }.sorted() + ["options \(options)"]
  }
}
