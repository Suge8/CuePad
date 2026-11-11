import CueStore

enum TaskAction: String, CaseIterable {
  case add, edit, start, bind, unbind, say, peek, stop, leave, take, done

  var kind: ChatMessage.Tools.Kind? {
    switch self {
    case .add: .add
    case .edit: .edit
    case .start: .start
    case .say: .talk
    case .peek: .read
    case .stop: .stop
    case .leave: .leave
    case .done: .done
    case .bind, .unbind, .take: nil
    }
  }

  var settlesStop: Bool {
    switch self {
    case .say, .leave, .take, .done: true
    default: false
    }
  }

  func words(_ named: String, board: Bool, starts: Bool) -> String? {
    switch self {
    case .add: starts ? "建任务并开工\(named)" : "建任务\(named)"
    case .edit: "改\(named)"
    case .start: "开工\(named)"
    case .say: "对\(named)说"
    case .peek: board ? "看板" : "看\(named)的近况"
    case .stop: "停下\(named)"
    case .leave: "\(named)留给你回"
    case .take: "收回\(named)（不用他回）"
    case .done: "做完\(named)"
    case .bind, .unbind: nil
    }
  }
}
