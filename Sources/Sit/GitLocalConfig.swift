public import Foundation

/// Minimal `.git/config` reader for `user.name` / `user.email`.
public enum GitLocalConfig: Sendable {
  public struct UserIdentity: Equatable, Sendable {
    public var name: String
    public var email: String
  }

  public static func readUserIdentity(gitDir: URL) throws -> UserIdentity {
    let path = gitDir.appendingPathComponent("config").path
    guard FileManager.default.fileExists(atPath: path) else {
      throw GitIndexError.missingUserIdentity
    }
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var section = ""
    var name: String?
    var email: String?
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let t = line.trimmingCharacters(in: .whitespaces)
      if t.hasPrefix("[") && t.hasSuffix("]") {
        section = String(t.dropFirst().dropLast()).lowercased()
        continue
      }
      guard section == "user" else { continue }
      if let v = parseKeyValue(t, key: "name") { name = v }
      if let v = parseKeyValue(t, key: "email") { email = v }
    }
    guard let n = name, let e = email, !n.isEmpty, !e.isEmpty else {
      throw GitIndexError.missingUserIdentity
    }
    return UserIdentity(name: n, email: e)
  }

  /// `GIT_AUTHOR_*` then `.git/config` `[user]`.
  public static func resolveAuthorIdentity(gitDir: URL) throws -> UserIdentity {
    let env = ProcessInfo.processInfo.environment
    if let n = env["GIT_AUTHOR_NAME"], let e = env["GIT_AUTHOR_EMAIL"], !n.isEmpty, !e.isEmpty {
      return UserIdentity(name: n, email: e)
    }
    return try readUserIdentity(gitDir: gitDir)
  }

  /// `GIT_COMMITTER_*`, else same as ``resolveAuthorIdentity(gitDir:)``.
  public static func resolveCommitterIdentity(gitDir: URL) throws -> UserIdentity {
    let env = ProcessInfo.processInfo.environment
    if let n = env["GIT_COMMITTER_NAME"], let e = env["GIT_COMMITTER_EMAIL"], !n.isEmpty, !e.isEmpty {
      return UserIdentity(name: n, email: e)
    }
    return try resolveAuthorIdentity(gitDir: gitDir)
  }

  private static func parseKeyValue(_ line: String, key: String) -> String? {
    let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let k = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
    guard k == key else { return nil }
    return unquote(parts[1].trimmingCharacters(in: .whitespaces))
  }

  private static func unquote(_ s: String) -> String {
    if s.count >= 2, s.first == "\"", s.last == "\"" {
      return String(s.dropFirst().dropLast())
    }
    return s
  }
}
