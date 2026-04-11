public import Foundation

/// Reads `user.name` / `user.email` from Git config files (same layering as Git: global then repo).
public enum GitLocalConfig: Sendable {
  public struct UserIdentity: Equatable, Sendable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
      self.name = name
      self.email = email
    }
  }

  /// Merges `[user]` from global config(s) then `.git/config` in `gitDir` (later files override per key).
  public static func readUserIdentity(gitDir: URL) throws -> UserIdentity {
    var name: String?
    var email: String?
    let fm = FileManager.default
    for url in userConfigFileURLs(gitDir: gitDir) {
      guard fm.fileExists(atPath: url.path) else { continue }
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      let parsed = Self.parseUserSection(in: text)
      if let n = parsed.name, !n.isEmpty { name = n }
      if let e = parsed.email, !e.isEmpty { email = e }
    }
    guard let n = name, let e = email, !n.isEmpty, !e.isEmpty else {
      throw GitIndexError.missingUserIdentity
    }
    return UserIdentity(name: n, email: e)
  }

  /// `GIT_AUTHOR_*` then merged Git config (`~/.gitconfig`, etc., then `.git/config`).
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

  /// Same order Git uses before per-repository `config`: XDG file, then `~/.gitconfig`, then `gitDir/config`.
  private static func userConfigFileURLs(gitDir: URL) -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var urls: [URL] = []
    if let raw = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !raw.isEmpty {
      urls.append(URL(fileURLWithPath: raw, isDirectory: true).appendingPathComponent("git/config"))
    } else {
      urls.append(home.appendingPathComponent(".config/git/config"))
    }
    urls.append(home.appendingPathComponent(".gitconfig"))
    urls.append(gitDir.appendingPathComponent("config"))
    return urls
  }

  private static func parseUserSection(in text: String) -> (name: String?, email: String?) {
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
    return (name, email)
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
