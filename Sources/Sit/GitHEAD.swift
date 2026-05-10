public import Foundation

public enum GitHEADError: Error, Equatable, Sendable {
  case unrecognized(String)
}

public enum GitHEAD: Sendable {
  public enum Kind: Equatable, Sendable {
    case symbolic(String)
    case detached(String)
  }

  public static func readKind(gitDir: URL) throws -> Kind {
    let raw = try String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("ref: ") {
      let ref = String(raw.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !ref.isEmpty else { throw GitHEADError.unrecognized(raw) }
      return .symbolic(ref)
    }
    guard raw.count == 40 else { throw GitHEADError.unrecognized(raw) }
    let lower = raw.lowercased()
    _ = try GitHex.decode20(lower)
    return .detached(lower)
  }

  /// Current branch tip (or `nil` if unborn), or detached `HEAD` SHA.
  public static func resolveCommitHex(gitDir: URL) throws -> String? {
    switch try readKind(gitDir: gitDir) {
    case .detached(let sha):
      return sha
    case .symbolic(let ref):
      return try GitRefs.readRef(gitDir: gitDir, refName: ref)
    }
  }

  /// `refs/heads/main` when `HEAD` is `ref: refs/heads/main\n`.
  public static func currentBranchRef(gitDir: URL) throws -> String? {
    guard case .symbolic(let ref) = try readKind(gitDir: gitDir) else { return nil }
    return ref
  }
}
