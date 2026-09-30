#if os(macOS)
import CueStore
import Foundation
import Testing

@testable import CueCLI

@Suite struct ProjectAndCardTests {
  @Test func projectListReportsProjectsInOrderWithCounts() async throws {
    let sb = try Sandbox()
    let alpha = try await sb.project("Alpha")
    _ = try await sb.project("Beta")
    _ = try await sb.store.createCard(in: alpha.id, body: "x")

    let projects = try array(try await sb.json("project", "list"))
    #expect(projects.compactMap { $0.string("name") } == ["Alpha", "Beta"])
    #expect(projects[0].string("id") == alpha.id.uuidString.lowercased())
    #expect(projects[0]["cardCount"] as? Int == 1)
    #expect(projects[1]["cardCount"] as? Int == 0)
    #expect(projects[0]["goalCardId"] is NSNull)

    let text = await sb.run("project", "list")
    #expect(text.code == 0)
    #expect(text.out.contains("Alpha") && text.out.contains("Beta"))
  }

  @Test func cardBodyRoundTripsVerbatimThroughStdinAndArgument() async throws {
    let sb = try Sandbox()
    _ = try await sb.project("Alpha")
    let body = "第一段  \n---split---\n![](cuepad://img/\(String(repeating: "a", count: 64)))\n\n结尾\n"

    let added = try await sb.object("card", "add", "--project", "alpha", stdin: body)
    let id = try #require(added.string("id"))
    #expect(added.string("project") == "Alpha")
    #expect(added.string("body") == body)

    let shown = await sb.run("card", "show", String(id.prefix(8)), "--body")
    #expect(shown.out == body)

    let edited = try await sb.object("card", "edit", id, "--body", "- 新正文")
    #expect(edited.string("body") == "- 新正文")
    #expect(try await sb.store.card(UUID(uuidString: id)!)?.body == "- 新正文")
  }

  @Test func cardJSONShape() async throws {
    let sb = try Sandbox()
    let alpha = try await sb.project("Alpha")
    let card = try await sb.store.createCard(in: alpha.id, body: "正文")
    try await sb.store.addTag("t1", to: card.id)

    let shown = try await sb.object("card", "show", card.id.uuidString)
    #expect(shown.string("id") == card.id.uuidString.lowercased())
    #expect(shown.string("projectId") == alpha.id.uuidString.lowercased())
    #expect(shown["tags"] as? [String] == ["t1"])
    #expect(shown["favorite"] as? Bool == false)
    #expect(shown["conflictOf"] is NSNull && shown["deletedAt"] is NSNull)
    #expect(shown.string("modifiedAt")?.hasSuffix("Z") == true)
  }

  @Test func cardListScopes() async throws {
    let sb = try Sandbox()
    let alpha = try await sb.project("Alpha")
    let beta = try await sb.project("Beta")
    let a = try await sb.store.createCard(in: alpha.id, body: "a")
    let b = try await sb.store.createCard(in: beta.id, body: "b")
    let inbox = try await sb.store.createCard(in: nil, body: "i")

    func ids(_ args: String...) async throws -> Set<String> {
      let items = try array(try await sb.jsonValue(["card", "list"] + args))
      return Set(items.compactMap { $0.string("id") })
    }
    func id(_ card: Card) -> String { card.id.uuidString.lowercased() }
    #expect(try await ids() == [id(a), id(b), id(inbox)])
    #expect(try await ids("--project", "Beta") == [id(b)])
    #expect(try await ids("--inbox") == [id(inbox)])
  }

  @Test func cardMoveTrashRestore() async throws {
    let sb = try Sandbox()
    let alpha = try await sb.project("Alpha")
    let beta = try await sb.project("Beta")
    let card = try await sb.store.createCard(in: alpha.id, body: "a")
    let id = card.id.uuidString

    let moved = try await sb.object("card", "move", id, "--project", "Beta")
    #expect(moved.string("projectId") == beta.id.uuidString.lowercased())
    let toInbox = try await sb.object("card", "move", id, "--inbox")
    #expect(toInbox["projectId"] is NSNull)

    let trashed = try await sb.object("card", "trash", id)
    #expect(trashed.string("deletedAt") != nil)
    #expect(try await sb.store.cards(in: nil).isEmpty)
    let inTrash = try array(try await sb.json("card", "list", "--trash"))
    #expect(inTrash.compactMap { $0.string("id") } == [id.lowercased()])

    let restored = try await sb.object("card", "restore", id)
    #expect(restored["deletedAt"] is NSNull)
    #expect(try await sb.store.cards(in: nil).map(\.id) == [card.id])
  }

  @Test func projectReferenceErrorsAreActionable() async throws {
    let sb = try Sandbox()
    let first = try await sb.project("Dup")
    let second = try await sb.project("Dup")
    _ = try await sb.project("Solo")

    let ambiguous = await sb.run("card", "add", "--project", "dup", "--body", "x")
    #expect(ambiguous.code == 1 && ambiguous.out.isEmpty)
    #expect(ambiguous.err.contains(first.id.uuidString.lowercased()))
    #expect(ambiguous.err.contains(second.id.uuidString.lowercased()))

    let unknown = await sb.run("card", "add", "--project", "nope", "--body", "x")
    #expect(unknown.code == 1)
    #expect(unknown.err.contains("nope") && unknown.err.contains("Solo"))

    let json = await sb.run("card", "add", "--project", "nope", "--body", "x", "--json")
    let error = try #require(
      (JSONSerialization.jsonObject(with: Data(json.err.utf8)) as? [String: Any])?["error"] as? [String: Any])
    #expect(error.string("code") == "not_found")
    #expect(error.string("message")?.contains("nope") == true)
    #expect(try await sb.store.cards(in: nil).isEmpty)

    try await sb.store.trashProject(first.id)
    let trashed = await sb.run("card", "add", "--project", first.id.uuidString, "--body", "x")
    #expect(trashed.code == 1)
    #expect(try await sb.store.cards(in: first.id).isEmpty)
  }

  @Test func missingBodyOrIdIsRejected() async throws {
    let sb = try Sandbox()
    let noBody = await sb.run("card", "add", stdin: nil)
    #expect(noBody.code == 2 && noBody.err.contains("--body"))
    let emptyPipe = await sb.run("card", "add", stdin: "")
    #expect(emptyPipe.code == 1 && emptyPipe.err.contains("--body"))
    let explicitEmpty = await sb.run("card", "add", "--body", "")
    #expect(explicitEmpty.code == 0)
    let missing = await sb.run("card", "show", UUID().uuidString)
    #expect(missing.code == 1 && missing.err.contains("找不到"))
    #expect(try await sb.store.cards(in: nil).count == 1)
  }
}

@Suite struct TaskTests {
  @Test func taskLifecycle() async throws {
    let sb = try Sandbox()
    let alpha = try await sb.project("Alpha")

    let added = try await sb.object("task", "add", "写", "文档", "--project", "Alpha")
    let id = try #require(added.string("id"))
    #expect(added.string("content") == "写 文档")
    #expect(added.string("projectId") == alpha.id.uuidString.lowercased())
    #expect(added["done"] as? Bool == false)
    _ = try await sb.object("task", "add", "全局的")

    #expect(try array(try await sb.json("task", "list")).count == 2)

    let done = try await sb.object("task", "done", String(id.prefix(8)))
    #expect(done["done"] as? Bool == true)
    #expect(done.string("completedAt") != nil)
    #expect(try array(try await sb.json("task", "list")).count == 1)
    #expect(try array(try await sb.json("task", "list", "--done")).compactMap { $0.string("id") } == [id])
    #expect(try array(try await sb.json("task", "list", "--all")).count == 2)
    #expect(try array(try await sb.json("task", "list", "--project", "Alpha")).isEmpty)

    let undone = try await sb.object("task", "undo", id)
    #expect(undone["done"] as? Bool == false && undone["completedAt"] is NSNull)

    let edited = try await sb.object("task", "edit", id, "改名", "--global")
    #expect(edited.string("content") == "改名" && edited["projectId"] is NSNull)

    let deleted = try await sb.object("task", "delete", id)
    #expect(deleted.string("id") == id && deleted["deleted"] as? Bool == true)
    #expect(try array(try await sb.json("task", "list", "--all")).count == 1)
  }

  @Test func taskErrors() async throws {
    let sb = try Sandbox()
    let blank = await sb.run("task", "add", "  ")
    #expect(blank.code != 0 && blank.err.contains("内容"))
    let task = try await sb.store.createTask("a")
    let nothing = await sb.run("task", "edit", task.id.uuidString)
    #expect(nothing.code == 2)
    #expect(try await sb.store.tasks().map(\.content) == ["a"])
  }
}

@Suite struct SearchAndConflictTests {
  @Test func searchMatchesAllTermsAndAppliesFilters() async throws {
    let sb = try Sandbox()
    let alpha = try await sb.project("Alpha")
    let beta = try await sb.project("Beta")
    let hit = try await sb.store.createCard(in: alpha.id, body: "部署 脚本 说明")
    _ = try await sb.store.createCard(in: alpha.id, body: "部署 only")
    let other = try await sb.store.createCard(in: beta.id, body: "部署 脚本 ![](cuepad://img/\(String(repeating: "b", count: 64)))")
    _ = try await sb.store.recordSend("x", to: SendTarget(kind: .clipboard, name: "剪贴板"), card: other.id)

    func search(_ args: [String]) async throws -> [String: Any] {
      try #require(try await sb.jsonValue(["search"] + args) as? [String: Any])
    }
    func cardIDs(_ result: [String: Any]) throws -> Set<String> {
      Set(try array(result["cards"] as Any).compactMap { $0.string("id") })
    }
    let hitID = hit.id.uuidString.lowercased()
    let otherID = other.id.uuidString.lowercased()

    let both = try await search(["脚本", "部署"])
    #expect(try cardIDs(both) == [hitID, otherID])
    #expect(both["total"] as? Int == 2)
    #expect(try cardIDs(try await search(["部署", "--project", "alpha", "--limit", "1"])).count == 1)
    #expect(try cardIDs(try await search(["脚本", "--project", "Alpha"])) == [hitID])
    #expect(try cardIDs(try await search(["脚本", "--images"])) == [otherID])
    #expect(try cardIDs(try await search(["脚本", "--no-images"])) == [hitID])
    #expect(try cardIDs(try await search(["脚本", "--unsent"])) == [hitID])
    #expect(try cardIDs(try await search(["脚本", "--sent"])) == [otherID])
    #expect(try cardIDs(try await search(["--to", "clipboard"])) == [otherID])
    #expect(try cardIDs(try await search(["--to", "app:Cursor"])).isEmpty)
    #expect(try cardIDs(try await search(["脚本", "--days", "1"])) == [hitID, otherID])
    let named = try await search(["Alph"])
    #expect(try array(named["projects"] as Any).compactMap { $0.string("name") } == ["Alpha"])
  }

  @Test func conflictsListAndResolve() async throws {
    let sb = try Sandbox()
    let original = try await sb.store.createCard(in: nil, body: "新版本")
    let copy = try await sb.store.createCard(in: nil, body: "旧版本")
    try sb.markConflict(copy: copy.id, of: original.id)

    let listed = try array(try await sb.json("conflicts", "list"))
    #expect(listed.count == 1)
    #expect((listed[0]["original"] as? [String: Any])?.string("body") == "新版本")
    #expect((listed[0]["copy"] as? [String: Any])?.string("id") == copy.id.uuidString.lowercased())

    let resolved = try await sb.object("conflicts", "resolve", copy.id.uuidString, "--keep", "copy")
    #expect(resolved.string("kept") == "copy")
    #expect((resolved["card"] as? [String: Any])?.string("body") == "旧版本")
    #expect(try await sb.store.card(original.id)?.body == "旧版本")
    #expect(try await sb.store.card(copy.id) == nil)
    #expect(try array(try await sb.json("conflicts", "list")).isEmpty)

    let notCopy = await sb.run("conflicts", "resolve", original.id.uuidString, "--keep", "original")
    #expect(notCopy.code == 1)
    let noChoice = await sb.run("conflicts", "resolve", copy.id.uuidString)
    #expect(noChoice.code == 2 && noChoice.err.contains("--keep"))
  }
}

@Suite struct HelpTests {
  private static let commands = [
    "project list", "card list", "card show", "card add", "card edit", "card move", "card trash",
    "card restore", "task list", "task add", "task done", "task undo", "task edit", "task delete", "search",
    "conflicts list", "conflicts resolve",
  ]

  @Test func rootHelpFitsOneScreenAndTeachesTheCommonTasks() async throws {
    let sb = try Sandbox()
    let help = await sb.run("--help")
    #expect(help.code == 0 && help.err.isEmpty)
    #expect(help.out.split(separator: "\n", omittingEmptySubsequences: false).count <= 24, "一屏放不下")
    for example in ["cuepad search ", "cuepad card add", "cuepad task add", "cuepad task done", "cuepad card list", "cuepad task list"] {
      #expect(help.out.contains(example), "缺示例 \(example)")
    }
    #expect(help.out.contains("--json") && help.out.contains("退出码"))
    #expect(help.out.contains("CUEPAD_LIBRARY_DIR"))
    #expect(!help.out.contains("goalCardId"), "字段说明属于各命令的 --help")
  }

  @Test func everyCommandIsReachableFromRootAndItsOwnHelp() async throws {
    let sb = try Sandbox()
    let root = await sb.run("--help").out
    for command in Self.commands {
      let words = command.split(separator: " ").map(String.init)
      #expect(root.contains("cuepad \(words[0])"), "根帮助没有提到 \(words[0])")
      if words.count == 2 {
        #expect((await sb.run(words[0], "--help")).out.contains(command), "\(words[0]) --help 没列出 \(command)")
      }
      let own = await sb.call(words + ["--help"])
      #expect(own.code == 0 && own.out.contains("cuepad \(command)"), "\(command) --help")
    }
    let add = await sb.run("card", "add", "--help").out
    #expect(add.contains("--body") && add.contains("--project"))
  }

  @Test func documentedFieldsMatchActualJSON() async throws {
    let sb = try Sandbox()
    let project = try await sb.project("Alpha")
    let card = try await sb.store.createCard(in: project.id, body: "x")
    let task = try await sb.store.createTask("t", in: project.id)
    let copy = try await sb.store.createCard(in: nil, body: "旧")
    try sb.markConflict(copy: copy.id, of: card.id)

    func documented(_ type: String, in command: [String]) async throws -> Set<String> {
      let help = await sb.call(command + ["--help"]).out
      let start = try #require(help.range(of: "\(type) {"), "\(command) --help 没有 \(type) 的字段说明")
      let fields = try #require(help[start.upperBound...].split(separator: "}", maxSplits: 1).first)
      return Set(fields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
    let projects = try array(try await sb.json("project", "list"))
    #expect(Set(projects[0].keys) == (try await documented("Project", in: ["project", "list"])))
    #expect(Set(try await sb.object("card", "show", card.id.uuidString).keys) == (try await documented("Card", in: ["card", "show"])))
    #expect(Set(try await sb.object("task", "done", task.id.uuidString).keys) == (try await documented("Task", in: ["task", "done"])))
    #expect(Set(try await sb.object("search", "x").keys) == (try await documented("Search", in: ["search"])))
    let conflicts = try array(try await sb.json("conflicts", "list"))
    #expect(Set(conflicts[0].keys) == (try await documented("Conflict", in: ["conflicts", "list"])))
  }

  @Test func usageErrorsExitTwoWithPointerToHelp() async throws {
    let sb = try Sandbox()
    for arguments in [["nope"], ["card", "nope"], ["card", "show"], ["card", "list", "--bogus"], ["card", "add", "--body"]] {
      let result = await sb.call(arguments)
      #expect(result.code == 2 && result.out.isEmpty && result.err.contains("--help"), "\(arguments) → \(result)")
    }
  }
}
#endif
