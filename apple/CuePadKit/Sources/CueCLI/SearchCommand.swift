import CueStore
import Foundation

private let defaultLimit = 20

extension Command {
  static let search = Command(
    path: ["search"], summary: "搜索灵感与任务（多个词都要命中，子串，不分大小写；命中正文）", arguments: "[词...]",
    options: [
      .project("限定项目，可重复"), .inbox, .allProjects,
      Opt("images", "只要含图片的"), Opt("no-images", "只要不含图片的"),
      Opt("sent", "只要交给过 Agent 的"), Opt("unsent", "只要从没交给过 Agent 的"),
      Opt("to", "只要交给过这个 Agent 会话的（会话名）", value: "会话名"),
      Opt("days", "只要最近 N 天内修改过的", value: "N"),
      Opt("trash", "搜回收站里的内容"),
      Opt("limit", "最多返回几条（默认 \(defaultLimit)）", value: "N"),
      Opt("offset", "跳过前几条", value: "N"),
    ],
    notes: Schema.defaultProject(otherwise: "搜所有项目") + """

      没有词也没有筛选时列出全部灵感与任务（最近修改在前）。项目名命中的项目在 projects 里（仅第一页、有词、无筛选时）；
      total 是命中总数，不受 --limit 影响。

      """ + Schema.output(Schema.search, Schema.card, Schema.project)
  ) { call in
    try await runSearch(call)
  }

  private static func runSearch(_ call: Call) async throws -> Reply {
    let args = call.args
    let query = try await searchQuery(call)
    let limit = try args.integer("limit", minimum: 1) ?? defaultLimit
    let offset = try args.integer("offset", minimum: 0) ?? 0
    let results = try await call.store.search(query, limit: limit, offset: offset)

    let projects = try await call.projectViews(results.projects)
    let cards = try await call.cardViews(results.cards)

    var lines = projects.map { "项目  \($0.line)" } + cards.map(\.line)
    if lines.isEmpty { lines = ["（无匹配）"] }
    if results.totalCards > offset + cards.count {
      lines.append("共 \(results.totalCards) 条，已显示 \(offset + 1)–\(offset + cards.count)（--offset 翻页）")
    }
    let json: JSONObject = [
      "total": results.totalCards, "projects": projects.map(\.json), "cards": cards.map(\.json),
    ]
    return Reply(text: lines.joined(separator: "\n") + "\n", json: json)
  }

  private static func searchQuery(_ call: Call) async throws -> SearchQuery {
    let args = call.args
    var query = SearchQuery(text: args.positionals.joined(separator: " "), inTrash: args.has("trash"))

    if args.has("all-projects"), !args.all("project").isEmpty || args.has("inbox") {
      throw CLIError.usage("--all-projects 不能与 --project / --inbox 同用")
    }
    var owners = Set<UUID?>()
    for ref in args.all("project") { owners.insert(try await call.project(ref).id) }
    if args.has("inbox") { owners.insert(nil) }
    if owners.isEmpty, case .project(let project) = try await call.scope() { owners.insert(project.id) }
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
    guard let name = args.value("to") else { return wantsSent ? .sent() : .any }
    return .sent(kind: .known(.piSession), name: name)
  }
}
