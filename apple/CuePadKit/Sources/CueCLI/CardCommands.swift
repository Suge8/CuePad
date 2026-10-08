import CueStore
import Foundation

extension Command {
  static let card: [Command] = [
    Command(
      path: ["card", "list"], summary: "列出灵感（散放的，不含任务与相关灵感；默认所有项目，项目内按手动顺序）",
      options: [
        .project("只列该项目"), .inbox, .allProjects, Opt("pinned", "只列资料（长期参考的灵感）"),
        Opt("archived", "列归档的灵感与任务"), Opt("trash", "列回收站里单独删除的灵感与任务"),
      ],
      notes: Schema.defaultProject(otherwise: "列所有项目") + "\n" + Schema.output("[Card]", Schema.card)
    ) { call in
      try call.args.expect()
      let scope = try await call.scope()
      let cards = try await listedCards(call).filter {
        scope.contains($0.projectID) && (!call.args.has("pinned") || $0.isPinned)
      }
      let views = try await call.cardViews(cards)
      return listReply(views.map(\.line), json: views.map(\.json))
    },
    Command(
      path: ["card", "show"], summary: "显示一条灵感或任务", arguments: "<灵感或任务>",
      options: [Opt("body", "只输出正文，原样（供管道使用）")],
      notes: Schema.output("Card", Schema.card) + "\n--body 与 --json 同用时仍输出 JSON。"
    ) { call in
      try call.args.expect("灵感或任务")
      let card = try await call.card(call.args.positionals[0])
      let view = try await call.cardViews([card])[0]
      return Reply(text: call.args.has("body") ? card.body : view.detail + "\n", json: view.json)
    },
    Command(
      path: ["card", "add"], summary: "新建灵感（放在项目最前）",
      options: [.project("放进该项目"), .inbox, .body],
      notes: Schema.defaultProject(otherwise: "进未分类") + "\n"
        + "分割线是独占一行的 ---split---，图片是 ![](cuepad://img/<哈希>)。例：printf '第一段\\n---split---\\n第二段' | cuepad card add\n"
        + Schema.output("新建的 Card", Schema.card)
    ) { call in
      try call.args.expect()
      let scope = try await call.scope()
      let body = try call.bodyInput()
      let card = try await call.store.createCard(in: scope.target, body: body)
      return reply(try await call.cardViews([card])[0])
    },
    Command(
      path: ["card", "edit"], summary: "替换正文", arguments: "<灵感或任务>",
      options: [.body], notes: Schema.output("更新后的 Card", Schema.card)
    ) { call in
      try call.args.expect("灵感或任务")
      let card = try await call.card(call.args.positionals[0])
      let body = try call.bodyInput()
      try await call.store.updateCard(card.id) { $0.body = body }
      return reply(try await fresh(call, card.id))
    },
    Command(
      path: ["card", "move"], summary: "把灵感或任务移到另一个项目或未分类", arguments: "<灵感或任务>",
      options: [
        .project("目标项目"), .inbox, Opt("after", "放在这一条之后（须在目标项目里）；省略则放最前", value: "灵感或任务"),
      ],
      notes: "--project 与 --inbox 必须给一个（移动不会猜目标）。\n" + Schema.output("移动后的 Card", Schema.card)
    ) { call in
      try call.args.expect("灵感或任务")
      let scope = try await call.scope(implicit: false)
      if case .any = scope { throw CLIError.usage("需要 --project <项目> 或 --inbox") }
      let card = try await call.card(call.args.positionals[0])
      let previous = try await call.args.value("after").asyncMap { try await call.card($0).id }
      try await call.store.moveCard(card.id, to: .top(project: scope.target), after: previous)
      return reply(try await fresh(call, card.id))
    },
    Command(
      path: ["card", "todo"], summary: "设为任务（待办）；--off 改回灵感", arguments: "<灵感或任务>",
      options: [Opt("off", "改回灵感：状态与会话关联清掉，它的下级提到它的位置")],
      notes: Schema.output("更新后的 Card", Schema.card)
    ) { call in
      try call.args.expect("灵感或任务")
      let card = try await call.card(call.args.positionals[0])
      try await call.store.setTodo(card.id, !call.args.has("off"))
      return reply(try await fresh(call, card.id))
    },
    Command(
      path: ["card", "archive"], summary: "归档（连同下级）：不占列表、仍可搜；--off 取回", arguments: "<灵感或任务>",
      options: [Opt("off", "从归档取回，连同下级回到原处")],
      notes: Schema.output("更新后的 Card（archivedAt 有值是已归档）", Schema.card)
    ) { call in
      try call.args.expect("灵感或任务")
      let card = try await call.card(call.args.positionals[0])
      if call.args.has("off") { try await call.store.unarchive(card.id) } else { try await call.store.archive(card.id) }
      return reply(try await fresh(call, card.id))
    },
    Command(
      path: ["card", "trash"], summary: "移进回收站（它的下级提到它的位置）", arguments: "<灵感或任务>",
      notes: Schema.output("Card（deletedAt 有值）", Schema.card)
    ) { call in
      try call.args.expect("灵感或任务")
      let card = try await call.card(call.args.positionals[0])
      try await call.store.trashCard(card.id)
      return reply(try await fresh(call, card.id))
    },
    Command(
      path: ["card", "restore"], summary: "从回收站恢复（原项目仍在回收站时回到未分类）", arguments: "<灵感或任务>",
      notes: Schema.output("恢复后的 Card", Schema.card)
    ) { call in
      try call.args.expect("灵感或任务")
      let card = try await call.card(call.args.positionals[0])
      try await call.store.restoreCard(card.id)
      return reply(try await fresh(call, card.id))
    },
  ]

  private static func listedCards(_ call: Call) async throws -> [Card] {
    if call.args.has("trash") { return try await call.store.trashedCards() }
    if call.args.has("archived") { return try await call.store.archived() }
    var cards: [Card] = []
    for project in try await call.store.projects() { cards += try await call.store.cards(in: project.id) }
    return cards + (try await call.store.cards(in: nil))
  }

  private static func fresh(_ call: Call, _ id: UUID) async throws -> CardView {
    guard let card = try await call.store.card(id) else { throw CLIError.notFound("\(id.uuidString.lowercased()) 已不存在") }
    return try await call.cardViews([card])[0]
  }
}
