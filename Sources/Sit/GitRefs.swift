public import Foundation
import SystemPackage

#if canImport(System)
import System
#endif

public enum GitRefs {
  /// Write `refs/<refName>` to `40-hex + LF` (e.g. `refs/heads/main`).
  public static func updateRef(gitDir: URL, refName: String, sha40HexLower: String) throws {
    guard sha40HexLower.count == 40 else { throw GitObjectWriterError.badHexSha }
    let url = gitDir.appendingPathComponent(refName)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let content = Array("\(sha40HexLower)\n".utf8)
    try GitAtomicWrite.write(content, to: FilePath(url.path))
  }

  /// Reads `40` lowercase hex bytes from `refName` (e.g. `refs/heads/main`), or `nil` if missing.
  public static func readRef(gitDir: URL, refName: String) throws -> String? {
    let url = gitDir.appendingPathComponent(refName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let raw = try String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = raw.lowercased()
    _ = try GitHex.decode20(lower)
    return lower
  }
}
