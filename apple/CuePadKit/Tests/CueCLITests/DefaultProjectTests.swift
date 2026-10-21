#if os(macOS)
import CueStore
import Foundation
import Testing

@testable import CueCLI

/// 不给 --project 时，默认范围是绑定了当前目录（或其祖先目录）的项目；不在这样的目录里新建的进默认项目。
@Suite struct DefaultProjectTests {
  private struct World {
    let sb: Sandbox
    let alpha: Project
    let beta: Project
    let inAlpha: Card
    let inBeta: Card
    let inDefault: Card
    static let alphaDirectory = "/work/alpha"
    static let inside = "/work/alpha/src/deep"

    init() async throws {
      sb = try Sandbox()
      alpha = try await sb.project("Alpha")
      beta = try await sb.project("Beta")
      try await sb.store.setDirectory(Self.alphaDirectory, for: alpha.id)
      inAlpha = try await sb.store.createCard(in: alpha.id, body: "共同词 alpha")
      inBeta = try await sb.store.createCard(in: beta.id, body: "共同词 beta")
      inDefault = try await sb.store.createCard(body: "共同词 默认")
      _ = try await sb.store.createTask("alpha 任务", in: alpha.id)
      _ = try await sb.store.createTask("默认任务")
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
    #expect(try await w.cards(["card", "list", "--project", "默认"]) == ["共同词 默认"])
    #expect(try await w.cards(["card", "list", "--all-projects"]) == ["共同词 alpha", "共同词 beta", "共同词 默认"])
    #expect(try await w.cards(["card", "list"], cwd: nil) == ["共同词 alpha", "共同词 beta", "共同词 默认"])  // 不在绑定了目录的项目里：列所有项目
    try await w.sb.store.updateCard(w.inBeta.id) { $0.isPinned = true }
    #expect(try await w.cards(["card", "list", "--pinned"], cwd: nil) == ["共同词 beta"])
    #expect(try await w.cards(["search", "共同词", "--all-projects"]).count == 3)
    #expect(try await w.tasks(["--project", "默认"]) == ["默认任务"])
    #expect(try await w.tasks(["--all-projects"]) == ["alpha 任务", "默认任务"])

    let beta = try await w.sb.object("card", "add", "--project", "Beta", "--body", "y", cwd: World.inside)
    #expect(beta.string("projectId") == w.beta.id.uuidString.lowercased())
    // 不在绑定了目录的项目里：新建的进默认项目
    let home = Project.defaultID.uuidString.lowercased()
    #expect(try await w.sb.object("card", "add", "--body", "x", cwd: nil).string("projectId") == home)
    #expect(try await w.sb.object("task", "add", "g", cwd: nil).string("projectId") == home)

    let conflicting = await w.sb.run("card", "list", "--project", "Beta", "--all-projects", cwd: World.inside)
    #expect(conflicting.code == 2)
  }

  @Test func moveNeverGuessesADestination() async throws {
    let w = try await World()
    let result = await w.sb.run("card", "move", w.inBeta.id.uuidString, cwd: World.inside)
    #expect(result.code == 2 && result.err.contains("--project"))
    #expect(try await w.sb.store.card(w.inBeta.id)?.projectID == w.beta.id)
  }
}
#endif
