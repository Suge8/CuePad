extension ChatMessage.Tools.Kind {
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
