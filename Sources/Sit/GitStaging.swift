public import Foundation

public enum GitStaging: Sendable {
  /// Create a commit from the current `.git/index`, update `HEAD`’s branch ref (or detached `HEAD`), return commit id hex.
  public static func commit(
    gitDir: URL,
    workTree: URL,
    message: String,
    author: GitLocalConfig.UserIdentity,
    committer: GitLocalConfig.UserIdentity? = nil,
    date: Date = Date()
  ) throws -> String {
    let indexURL = gitDir.appendingPathComponent("index")
    let index: GitIndex
    do {
      index = try GitIndex.load(from: indexURL)
    } catch GitIndexError.indexNotFound {
      throw GitIndexError.emptyIndex
    }
    if index.isEmpty { throw GitIndexError.emptyIndex }
    let treeSha = try index.writeRootTree(gitDir: gitDir)
    let treeHex = GitHex.encodeLower(treeSha)
    let parent = try GitHEAD.resolveCommitHex(gitDir: gitDir)
    let parents = parent.map { [$0] } ?? []
    let tz = Self.gitTimezoneOffset(for: date)
    let ts = Int64(date.timeIntervalSince1970)
    let authorLine = "\(author.name) <\(author.email)> \(ts) \(tz)"
    let committerPerson = committer ?? author
    let committerLine = "\(committerPerson.name) <\(committerPerson.email)> \(ts) \(tz)"
    let commitSha = try GitLooseObjectWriter.writeCommit(
      gitDir: gitDir,
      treeSha40HexLower: treeHex,
      parentShas40HexLower: parents,
      authorLine: authorLine,
      committerLine: committerLine,
      message: message
    )
    let commitHex = GitHex.encodeLower(commitSha)
    switch try GitHEAD.readKind(gitDir: gitDir) {
    case .symbolic(let ref):
      try GitRefs.updateRef(gitDir: gitDir, refName: ref, sha40HexLower: commitHex)
    case .detached:
      try Data("\(commitHex)\n".utf8).write(to: gitDir.appendingPathComponent("HEAD"))
    }
    return commitHex
  }

  private static func gitTimezoneOffset(for date: Date) -> String {
    let sec = TimeZone.current.secondsFromGMT(for: date)
    let sign = sec >= 0 ? "+" : "-"
    let a = abs(sec)
    let hh = a / 3600
    let mm = (a % 3600) / 60
    return String(format: "%@%02d%02d", sign, hh, mm)
  }
}
