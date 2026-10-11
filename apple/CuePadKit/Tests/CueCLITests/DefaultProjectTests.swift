#if os(macOS)
import CueStore
import Foundation
import Testing

@testable import CueCLI

/// 不给 --project / --unfiled 时，默认范围是绑定了当前目录（或其祖先目录）的项目。
@Suite struct DefaultProjectTests {
  private struct World {
    let sb: Sandbox
    let alpha: Project
    let beta: Project
    let inAlpha: Card
    let inBeta: Card
    let inUnfiled: Card
    static let alphaDirectory = "/work/alpha"
    static let inside = "/work/alpha/src/deep"

    init() async throws {
      sb = try Sandbox()
      alpha = try await sb.project("Alpha")
      beta = try await sb.project("Beta")
      try await sb.store.setDirectory(Self.alphaDirectory, for: alpha.id)
      inAlpha = try await sb.store.createCard(in: alpha.id, body: "共同词 alpha")
      inBeta = try await sb.store.createCard(in: beta.id, body: "共同词 beta")
      inUnfiled = try await sb.store.createCard(in: nil, body: "共同词 unfiled")
      _ = try await sb.store.createTask("alpha 任务", in: alpha.id)
      _ = try await sb.store.createTask("全局任务", in: nil)
    }

    func cards(_ command: [String], cwd: String? = Self.inside) async throws -> Set<String> {
      let value = try await sb.jsonValue(command, cwd: cwd)
      let items = try array((value as? [String: Any])?["cards"] ?? value)
      return Set(items.compactMap { $0.string("body") })
    }

    func tasks(_ extra: [String], cwd: String? = Self.inside) async throws -> Set<String> {
      Set(try array(try await sb.jsonValue(["task", "list"] + extra, cwd: cwd)).compactMap { $0.string("body") })
    }
  }

  @Test func readsAndWritesDefaultToTheProjectBoundToTheDirectory() async throws {
    let w = try await World()

    #expect(try await w.cards(["card", "list"]) == ["共同词 alpha"])
    #expect(try await w.cards(["search", "共同词"]) == ["共同词 alpha"])
    #expect(try await w.tasks([]) == ["alpha 任务"])

    let card = try await w.sb.object("card", "add", "--body", "新卡", cwd: World.inside)
    #expect(card.string("projectId") == w.alpha.id.uuidString.lowercased())
    let task = try await w.sb.object("task", "add", "新任务", cwd: World.alphaDirectory)
    #expect(task.string("projectId") == w.alpha.id.uuidString.lowercased())
  }

  @Test func explicitFlagsOverrideTheDirectoryDefault() async throws {
    let w = try await World()

    #expect(try await w.cards(["card", "list", "--project", "Beta"]) == ["共同词 beta"])
    #expect(try await w.cards(["card", "list", "--unfiled"]) == ["共同词 unfiled"])
    #expect(try await w.cards(["card", "list", "--all-projects"]) == ["共同词 alpha", "共同词 beta", "共同词 unfiled"])
    #expect(try await w.cards(["search", "共同词", "--all-projects"]).count == 3)
    #expect(try await w.cards(["search", "共同词", "--unfiled"]) == ["共同词 unfiled"])
    #expect(try await w.tasks(["--global"]) == ["全局任务"])
    #expect(try await w.tasks(["--all-projects"]) == ["alpha 任务", "全局任务"])

    let unfiled = try await w.sb.object("card", "add", "--unfiled", "--body", "x", cwd: World.inside)
    #expect(unfiled["projectId"] is NSNull)
    let beta = try await w.sb.object("card", "add", "--project", "Beta", "--body", "y", cwd: World.inside)
    #expect(beta.string("projectId") == w.beta.id.uuidString.lowercased())
    let global = try await w.sb.object("task", "add", "--global", "g", cwd: World.inside)
    #expect(global["projectId"] is NSNull)

    let conflicting = await w.sb.run("card", "list", "--project", "Beta", "--all-projects", cwd: World.inside)
    #expect(conflicting.code == 2)
  }

  @Test func withoutABoundProjectBehaviourIsUnchanged() async throws {
    let w = try await World()

    #expect(try await w.cards(["card", "list"], cwd: "/work/other").count == 3)
    #expect(try await w.cards(["card", "list"], cwd: "/work/alphabet").count == 3)  // 目录前缀不是祖先
    #expect(try await w.tasks([], cwd: "/work/other") == ["alpha 任务", "全局任务"])
    let card = try await w.sb.object("card", "add", "--body", "x", cwd: "/work/other")
    #expect(card["projectId"] is NSNull)

    try await w.sb.store.trashProject(w.alpha.id)
    let afterTrash = try await w.sb.object("card", "add", "--body", "y", cwd: World.inside)
    #expect(afterTrash["projectId"] is NSNull, "回收站里的项目不作默认")
  }

  @Test func moveNeverGuessesADestination() async throws {
    let w = try await World()
    let result = await w.sb.run("card", "move", w.inBeta.id.uuidString, cwd: World.inside)
    #expect(result.code == 2 && result.err.contains("--project"))
    #expect(try await w.sb.store.card(w.inBeta.id)?.projectID == w.beta.id)
  }
}
#endif
