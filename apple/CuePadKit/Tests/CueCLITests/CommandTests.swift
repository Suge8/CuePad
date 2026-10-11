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
    try await sb.store.updateProject(alpha.id) { $0.isPinned = true }  // 置顶的在前

    let projects = try array(try await sb.json("project", "list"))
    #expect(projects.compactMap { $0.string("name") } == ["Alpha", "Beta"])
    #expect(projects[0].string("id") == alpha.id.uuidString.lowercased())
    #expect(projects[0]["cardCount"] as? Int == 1)
    #expect(projects[1]["cardCount"] as? Int == 0)
    #expect(projects[0]["intro"] is NSNull)

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

  /// 引用写 id 或至少 4 位的唯一前缀：不分大小写，回收站里的也找得到，同前缀多条时列出来让人写长一点。
  @Test func cardReferencesResolveByUniquePrefix() async throws {
    let sb = try Sandbox()
    let first = try await sb.store.createCard(in: nil, body: "一号")
    let second = try await sb.store.createCard(in: nil, body: "二号")
    let trashed = try await sb.store.createCard(in: nil, body: "已删")
    try sb.assignID(first.id, "abcd1111-0000-4000-8000-000000000001")
    try sb.assignID(second.id, "abcd2222-0000-4000-8000-000000000002")
    try sb.assignID(trashed.id, "beef3333-0000-4000-8000-000000000003")
    try await sb.store.trashCard(UUID(uuidString: "beef3333-0000-4000-8000-000000000003")!)

    #expect(try await sb.object("card", "show", "ABCD1").string("body") == "一号")
    #expect(try await sb.object("card", "show", "beef").string("body") == "已删")

    let shared = await sb.run("card", "show", "abcd")
    #expect(shared.code == 1 && shared.err.contains("匹配到 2 个") && shared.err.contains("abcd1111") && shared.err.contains("abcd2222"))
    let short = await sb.run("card", "show", "abc")
    #expect(short.code == 1 && short.err.contains("找不到灵感或任务"))
    let missing = await sb.run("card", "show", "ffff")
    #expect(missing.code == 1 && missing.err.contains("找不到灵感或任务"))
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
    try await sb.store.updateCard(b.id) { $0.isPinned = true }
    #expect(try await ids("--pinned") == [id(b)])
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

}

@Suite struct TaskTests {
  @Test func taskLifecycle() async throws {
    let sb = try Sandbox()
    let alpha = try await sb.project("Alpha")

    let added = try await sb.object("task", "add", "写", "文档", "--project", "Alpha")
    let id = try #require(added.string("id"))
    #expect(added.string("body") == "写 文档" && added.string("kind") == "task")
    #expect(added.string("projectId") == alpha.id.uuidString.lowercased())
    #expect(added.string("status") == "todo")
    _ = try await sb.object("task", "add", "全局的")

    #expect(try array(try await sb.json("task", "list")).count == 2)

    // 进行中仍算未完成
    let started = try await sb.object("task", "start", id)
    #expect(started.string("status") == "inProgress" && started.string("startedAt") != nil)
    #expect(try array(try await sb.json("task", "list")).count == 2)

    let done = try await sb.object("task", "done", String(id.prefix(8)))
    #expect(done.string("status") == "done")
    #expect(done.string("completedAt") != nil)
    #expect(try array(try await sb.json("task", "list")).count == 1)
    #expect(try array(try await sb.json("task", "list", "--done")).compactMap { $0.string("id") } == [id])
    #expect(try array(try await sb.json("task", "list", "--all")).count == 2)
    #expect(try array(try await sb.json("task", "list", "--project", "Alpha")).isEmpty)

    let undone = try await sb.object("task", "undo", id)
    #expect(undone.string("status") == "todo" && undone["completedAt"] is NSNull && undone["startedAt"] is NSNull)

    // 正文、换项目、回收站与灵感共用 card 命令
    let trashed = try await sb.object("card", "trash", id)
    #expect(trashed.string("id") == id && trashed["deletedAt"] != nil)
    #expect(try array(try await sb.json("task", "list", "--all")).count == 1)
  }

  @Test func ideaBecomesATaskAndBack() async throws {
    let sb = try Sandbox()
    let idea = try await sb.object("card", "add", "--inbox", "--body", "修重连")
    let id = try #require(idea.string("id"))
    #expect(idea.string("kind") == "idea" && idea["status"] is NSNull)

    let task = try await sb.object("card", "todo", id)
    #expect(task.string("kind") == "task" && task.string("status") == "todo")
    #expect(try array(try await sb.json("task", "list")).compactMap { $0.string("id") } == [id])

    let back = try await sb.object("card", "todo", id, "--off")
    #expect(back.string("kind") == "idea")
    #expect(try array(try await sb.json("task", "list")).isEmpty)
  }

  @Test func addSubtaskUnderAParent() async throws {
    let sb = try Sandbox()
    let alpha = try await sb.project("Alpha")
    let parent = try await sb.store.createTask("上线", in: alpha.id)

    let child = try await sb.object("task", "add", "备份", "--parent", String(parent.id.uuidString.lowercased().prefix(8)))
    #expect(child.string("parentId") == parent.id.uuidString.lowercased())
    #expect(child.string("projectId") == alpha.id.uuidString.lowercased())

    let conflicting = await sb.run("task", "add", "x", "--parent", parent.id.uuidString, "--global")
    #expect(conflicting.code == 2)
    #expect(await sb.run("task", "add", "--help").out.contains("--parent"))
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
    _ = try await sb.store.recordSend("x", to: SendTarget(kind: .piSession, name: "atlas", ref: "s1"), card: other.id)

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
    #expect(try cardIDs(try await search(["--to", "atlas"])) == [otherID])
    #expect(try cardIDs(try await search(["--to", "review"])).isEmpty)
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
    "card restore", "card todo", "task list", "task add", "task start", "task done", "task undo", "search",
    "conflicts list", "conflicts resolve",
  ]

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
    #expect(Set(try await sb.object("task", "done", task.id.uuidString).keys) == (try await documented("Card", in: ["task", "done"])))
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
