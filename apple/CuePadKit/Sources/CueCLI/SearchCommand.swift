import CueStore
import Foundation

private let defaultLimit = 20

extension Command {
  static let search = Command(
    path: ["search"], summary: "搜索卡片（多个词都要命中，子串，不分大小写；命中正文与标签）", arguments: "[词...]",
    options: [
      .project("限定项目，可重复"), .inbox,
      Opt("images", "只要含图片的卡"), Opt("no-images", "只要不含图片的卡"),
      Opt("sent", "只要发送过的卡"), Opt("unsent", "只要从未发送过的卡"),
      Opt("to", "只要发送到该目标的卡：pi | app | clipboard，可加 :名称（如 app:Cursor）", value: "目标"),
      Opt("days", "只要最近 N 天内修改过的卡", value: "N"),
      Opt("trash", "搜回收站里的内容"),
      Opt("limit", "最多返回几张卡（默认 \(defaultLimit)）", value: "N"),
      Opt("offset", "跳过前几张卡", value: "N"),
    ],
    notes: """
      没有词也没有筛选时列出全部卡片（最近修改在前）。项目名命中的项目在 projects 里（仅第一页、有词、无筛选时）。
      输出：Search，cards 是 [Card]，total 是命中总数（不受 limit 影响），projects 是 [Project]。
      """
  ) { call in
    try await runSearch(call)
  }

  private static func runSearch(_ call: Call) async throws -> Reply {
    let args = call.args
    let query = try await searchQuery(call)
    let limit = try args.integer("limit", minimum: 1) ?? defaultLimit
    let offset = try args.integer("offset", minimum: 0) ?? 0
    let results = try await call.store.search(query, limit: limit, offset: offset)

    let counts = Dictionary(
      uniqueKeysWithValues: try await call.store.projectSummaries().map { ($0.projectID, $0.cardCount) })
    let directories = try await call.store.projectDirectories()
    let projects = results.projects.map {
      ProjectView(project: $0, cardCount: counts[$0.id] ?? 0, directory: directories[$0.id])
    }
    let cards = try await call.cardViews(results.cards)

    var lines = projects.map { "项目  \($0.line)" } + cards.map(\.line)
    if lines.isEmpty { lines = ["（无匹配）"] }
    if results.totalCards > offset + cards.count {
      lines.append("共 \(results.totalCards) 张，已显示 \(offset + 1)–\(offset + cards.count)（--offset 翻页）")
    }
    let json: JSONObject = [
      "total": results.totalCards, "projects": projects.map(\.json), "cards": cards.map(\.json),
    ]
    return Reply(text: lines.joined(separator: "\n") + "\n", json: json)
  }

  private static func searchQuery(_ call: Call) async throws -> SearchQuery {
    let args = call.args
    var query = SearchQuery(text: args.positionals.joined(separator: " "), inTrash: args.has("trash"))

    var owners = Set<UUID?>()
    for ref in args.all("project") { owners.insert(try await call.project(ref).id) }
    if args.has("inbox") { owners.insert(nil) }
    if !owners.isEmpty { query.projects = owners }

    if args.has("images") && args.has("no-images") { throw CLIError.usage("--images 与 --no-images 只能选一个") }
    if args.has("images") || args.has("no-images") { query.hasImages = args.has("images") }

    query.sent = try sentCondition(args)
    if let days = try args.integer("days", minimum: 1) {
      let now = Date()
      query.modifiedIn = now.addingTimeInterval(-Double(days) * 86_400)...now
    }
    return query
  }

  private static func sentCondition(_ args: Arguments) throws -> SendCondition {
    let wantsSent = args.has("sent") || args.value("to") != nil
    if args.has("unsent") {
      if wantsSent { throw CLIError.usage("--unsent 不能与 --sent / --to 同用") }
      return .never
    }
    guard let target = args.value("to") else { return wantsSent ? .sent() : .any }
    let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
    let kinds: [String: SendTargetKind] = ["pi": .piSession, "app": .app, "clipboard": .clipboard]
    guard let kind = kinds[parts[0].lowercased()] else {
      throw CLIError.usage("--to 的目标种类是 pi / app / clipboard，收到「\(target)」")
    }
    return .sent(kind: kind, name: parts.count > 1 ? parts[1] : nil)
  }
}
