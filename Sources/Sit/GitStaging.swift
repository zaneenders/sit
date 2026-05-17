public import Foundation
import SystemPackage

#if canImport(System)
import System
#endif

public enum GitStaging: Sendable {
  /// Create a commit from the current `.git/index`, update `HEAD`'s branch ref (or detached `HEAD`), return commit id hex.
  /// `authorDate` and `committerDate` allow the two timestamps to differ (as real Git does);
  /// when `committerDate` is `nil` it defaults to `authorDate`.
  public static func commit(
    gitDir: URL,
    workTree: URL,
    message: String,
    author: GitLocalConfig.UserIdentity,
    committer: GitLocalConfig.UserIdentity? = nil,
    authorDate: Date = Date(),
    committerDate: Date? = nil
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
    let authorTz = GitLooseObjectWriter.gitTimezoneOffset(for: authorDate)
    let authorTs = Int64(authorDate.timeIntervalSince1970)
    let authorLine = "\(author.name) <\(author.email)> \(authorTs) \(authorTz)"
    let committerPerson = committer ?? author
    let cDate = committerDate ?? authorDate
    let committerTz = GitLooseObjectWriter.gitTimezoneOffset(for: cDate)
    let committerTs = Int64(cDate.timeIntervalSince1970)
    let committerLine = "\(committerPerson.name) <\(committerPerson.email)> \(committerTs) \(committerTz)"
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
      let headURL = gitDir.appendingPathComponent("HEAD")
      let content = Array("\(commitHex)\n".utf8)
      try GitAtomicWrite.write(content, to: FilePath(headURL.path))
    }
    return commitHex
  }
}
