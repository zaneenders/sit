public import Foundation

/// Loads `.git/info/exclude` and all `.gitignore` files under the work tree (skipping `.git/`) and answers ignore queries with Git-style **last matching rule wins** semantics.
///
/// Supported subset: `*` / `?` / `**` within segments, `!` negation, trailing `/` (directory-only), leading `/` (anchored under the `.gitignore` directory). Does **not** read `core.excludesfile`; parent-directory ignore / negation interactions may differ from Git in edge cases.
public struct GitIgnoreMatcher: Sendable {
  private struct Rule: Sendable {
    var negated: Bool
    var regex: NSRegularExpression
  }

  private let rules: [Rule]

  public init(workTree: URL, gitDir: URL) throws {
    self.rules = try Self.loadRules(workTree: workTree, gitDir: gitDir)
  }

  public func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
    let path = relativePath.replacingOccurrences(of: "\\", with: "/")
    var ignored = false
    for r in rules {
      if Self.match(r.regex, path: path, isDirectory: isDirectory) {
        ignored = !r.negated
      }
    }
    return ignored
  }

  private static func match(_ re: NSRegularExpression, path: String, isDirectory: Bool) -> Bool {
    let ns = path as NSString
    let range = NSRange(location: 0, length: ns.length)
    if re.firstMatch(in: path, options: [], range: range) != nil {
      return true
    }
    if isDirectory, !path.hasSuffix("/") {
      let dirPath = path + "/"
      let ns2 = dirPath as NSString
      return re.firstMatch(in: dirPath, options: [], range: NSRange(location: 0, length: ns2.length)) != nil
    }
    return false
  }

  private static func loadRules(workTree: URL, gitDir: URL) throws -> [Rule] {
    var sources: [(base: String, text: String)] = []
    let excludeURL = gitDir.appendingPathComponent("info/exclude", isDirectory: false)
    if FileManager.default.fileExists(atPath: excludeURL.path),
      let t = try? String(contentsOf: excludeURL, encoding: .utf8)
    {
      sources.append(("", t))
    }
    let wt = workTree.standardizedFileURL
    let dotGitDir = wt.appendingPathComponent(".git", isDirectory: true).standardizedFileURL
    let dotGitPath = dotGitDir.path
    let dotGitPrefix = dotGitPath + "/"
    guard
      let en = FileManager.default.enumerator(
        at: wt,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
      )
    else { return try compile(sources: sources) }
    var ignoreFiles: [(base: String, text: String)] = []
    while let item = en.nextObject() as? URL {
      let p = item.standardizedFileURL.path
      if p == dotGitPath || p.hasPrefix(dotGitPrefix) { continue }
      guard item.lastPathComponent == ".gitignore" else { continue }
      guard let text = try? String(contentsOf: item, encoding: .utf8) else { continue }
      let parent = item.deletingLastPathComponent().standardizedFileURL
      let base: String
      if parent.path == wt.path {
        base = ""
      } else {
        let prefix = wt.path.hasSuffix("/") ? wt.path : wt.path + "/"
        guard parent.path.hasPrefix(prefix) else { continue }
        base = String(parent.path.dropFirst(prefix.count)).replacingOccurrences(of: "\\", with: "/")
      }
      ignoreFiles.append((base, text))
    }
    ignoreFiles.sort {
      let d0 = $0.base.split(separator: "/").count
      let d1 = $1.base.split(separator: "/").count
      if d0 != d1 { return d0 < d1 }
      return $0.base < $1.base
    }
    sources.append(contentsOf: ignoreFiles)
    return try compile(sources: sources)
  }

  private static func compile(sources: [(base: String, text: String)]) throws -> [Rule] {
    var out: [Rule] = []
    for (base, text) in sources {
      for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var raw = String(line)
        raw = stripTrailingUnescapedSpaces(raw)
        if raw.isEmpty || raw.hasPrefix("#") { continue }
        var negated = false
        if raw.first == "!" {
          negated = true
          raw.removeFirst()
        }
        var directoryOnly = false
        if raw.hasSuffix("/"), raw.count > 1 {
          directoryOnly = true
          raw.removeLast()
        }
        raw = raw.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { continue }
        var anchoredToDir = false
        if raw.first == "/" {
          anchoredToDir = true
          raw.removeFirst()
        }
        let re = try patternToRegex(
          raw: raw,
          base: base,
          anchoredToDir: anchoredToDir,
          directoryOnly: directoryOnly
        )
        out.append(Rule(negated: negated, regex: re))
      }
    }
    return out
  }

  private static func stripTrailingUnescapedSpaces(_ s: String) -> String {
    var t = String(s)
    while t.last == " " {
      var i = t.endIndex
      var slashes = 0
      while i > t.startIndex {
        i = t.index(before: i)
        if t[i] == "\\" { slashes += 1 } else { break }
      }
      if slashes % 2 == 1 { break }
      t.removeLast()
    }
    return t.trimmingCharacters(in: .whitespaces)
  }

  private static func patternToRegex(
    raw: String,
    base: String,
    anchoredToDir: Bool,
    directoryOnly: Bool
  ) throws -> NSRegularExpression {
    let internalSlash = raw.contains("/")
    let baseEsc = NSRegularExpression.escapedPattern(for: base)
    let patternBody = try globPathToRegex(raw)

    let suf = matchSuffix(directoryOnly: directoryOnly)
    let full: String
    if internalSlash {
      if anchoredToDir {
        if base.isEmpty {
          full = "^" + patternBody + suf
        } else {
          full = "^" + baseEsc + "/" + patternBody + suf
        }
      } else {
        if base.isEmpty {
          full = "^" + patternBody + suf
        } else {
          full = "^(?:" + baseEsc + "/)?" + patternBody + suf
        }
      }
    } else {
      let seg = try globOneSegment(raw)
      if anchoredToDir {
        if base.isEmpty {
          full = "^" + seg + suf
        } else {
          full = "^" + baseEsc + "/" + seg + suf
        }
      } else {
        let root = base.isEmpty ? "^" : "^" + baseEsc + "/"
        full = root + "(?:.*/)?" + seg + suf
      }
    }
    return try NSRegularExpression(pattern: full, options: [])
  }

  /// Git: a pattern without a trailing `/` matches a file or directory at that path; when the
  /// path is a directory, everything under it matches. A trailing `/` matches only directories
  /// (paths with a `/` after the matched prefix).
  private static func matchSuffix(directoryOnly: Bool) -> String {
    directoryOnly ? "/.*$" : "(?:/.*)?$"
  }

  /// Slash-separated glob segments (each segment uses `*` / `?` / `**` rules).
  private static func globPathToRegex(_ pattern: String) throws -> String {
    let parts = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    var pieces: [String] = []
    for p in parts where !p.isEmpty {
      pieces.append(try globOneSegment(p))
    }
    return pieces.joined(separator: "/")
  }

  private static func globOneSegment(_ s: String) throws -> String {
    var out = ""
    var i = s.startIndex
    while i < s.endIndex {
      if s[i] == "*" {
        if s[i...].hasPrefix("**") {
          out += ".*"
          i = s.index(i, offsetBy: 2)
        } else {
          out += "[^/]*"
          i = s.index(after: i)
        }
      } else if s[i] == "?" {
        out += "[^/]"
        i = s.index(after: i)
      } else {
        out += NSRegularExpression.escapedPattern(for: String(s[i]))
        i = s.index(after: i)
      }
    }
    return out
  }
}
