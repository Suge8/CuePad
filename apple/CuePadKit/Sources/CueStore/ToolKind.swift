extension ChatMessage.Tools.Kind {
  /// 各家工具名归到哪一类的唯一一份：会话文件里记下的步（`ToolLog`）与此刻正在跑的那一步（会话页、近况）都按它。
  public init(tool name: String) {
    switch name.lowercased() {
    case "edit", "write", "strreplace", "str_replace", "multiedit": self = .edit
    case "read": self = .read
    case "bash", "shell": self = .command
    case "grep", "find", "ls", "glob": self = .search
    default: self = .other
    }
  }
}
