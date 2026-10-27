import Foundation

/// 卡片搜索条件。所有条件同时满足；筛选在分页之前生效。
/// 没有关键词、没有任何筛选时列出该范围内的全部卡片（按最近修改）。
public struct SearchQuery: Sendable, ExpressibleByStringLiteral {
  /// 按空白拆成多个词，每个词都要命中（子串，大小写不敏感）。卡片按正文命中；项目名只用于单列的项目结果。
  /// 空表示不按文字过滤。
  public var text: String
  /// 限定所属项目；nil 表示不限；空集合无结果。
  public var projects: Set<UUID>?
  /// true 只要含附件（图片或文件）的卡，false 只要不含附件的卡，nil 不限。
  public var hasAttachments: Bool?
  /// 发送条件：不限、从未发送过、或发送过（可限目标）。
  public var sent: SendCondition
  /// 卡片最近修改时间落在区间内（含两端）。
  public var modifiedIn: ClosedRange<Date>?
  /// true 只搜回收站里的内容（含随项目进回收站的卡片），false 只搜未删除内容。
  public var inTrash: Bool

  public init(
    text: String = "", projects: Set<UUID>? = nil, hasAttachments: Bool? = nil, sent: SendCondition = .any,
    modifiedIn: ClosedRange<Date>? = nil, inTrash: Bool = false
  ) {
    self.text = text
    self.projects = projects
    self.hasAttachments = hasAttachments
    self.sent = sent
    self.modifiedIn = modifiedIn
    self.inTrash = inTrash
  }

  public init(stringLiteral value: String) { self.init(text: value) }

  var hasCardFilters: Bool { projects != nil || hasAttachments != nil || sent != .any || modifiedIn != nil }
}

public enum SendCondition: Equatable, Sendable {
  case any
  /// 从未发送过（没有任何关联该卡的发送记录）。
  case never
  /// 至少发送过一次；可限目标种类与名称（名称精确匹配），都省略表示发到哪里都行。
  case sent(kind: Open<SendTargetKind>? = nil, name: String? = nil)
}

public struct SearchResults: Sendable {
  /// 项目名命中的项目；只在有关键词、没有卡片筛选、第一页时返回。
  public var projects: [Project]
  /// 当前页的卡片，按最近修改。
  public var cards: [Card]
  /// 符合条件的卡片总数（不受分页影响）。
  public var totalCards: Int
}
