public import Foundation

public enum GitRefs {
  /// Write `refs/<refName>` to `40-hex + LF` (e.g. `refs/heads/main`).
  public static func updateRef(gitDir: URL, refName: String, sha40HexLower: String) throws {
    guard sha40HexLower.count == 40 else { throw GitObjectWriterError.badHexSha }
    let url = gitDir.appendingPathComponent(refName)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("\(sha40HexLower)\n".utf8).write(to: url)
  }
}
