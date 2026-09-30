import Foundation

let result = await CLI.run(
  Array(CommandLine.arguments.dropFirst()),
  environment: ProcessInfo.processInfo.environment,
  stdin: {
    guard isatty(STDIN_FILENO) == 0 else { return nil }
    return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
  })
FileHandle.standardOutput.write(Data(result.out.utf8))
FileHandle.standardError.write(Data(result.err.utf8))
exit(result.code)
