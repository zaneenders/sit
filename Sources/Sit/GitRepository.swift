public import Foundation

public enum GitRepositoryError: Error, Equatable, Sendable {
  case notFound(searchRoot: String)
  case gitDirFileNotSupported
}

public enum GitRepository: Sendable {
  /// Walks up from `directory` to find a `.git` directory and returns `(gitDir, workTree)`.
  public static func discover(from directory: URL) throws -> (gitDir: URL, workTree: URL) {
    var cur = directory.standardizedFileURL.resolvingSymlinksInPath()
    if !cur.hasDirectoryPath {
      cur = cur.deletingLastPathComponent()
    }
    let fm = FileManager.default
    let start = cur.path
    /// Climb at most 256 levels (far deeper than any real filesystem hierarchy;
    /// the limit exists to prevent infinite loops on pathological mount setups).
    let maxDepth = 256
    for _ in 0..<maxDepth {
      let dotGit = cur.appendingPathComponent(".git", isDirectory: false)
      if fm.fileExists(atPath: dotGit.path) {
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: dotGit.path, isDirectory: &isDir)
        if isDir.boolValue {
          return (dotGit.standardizedFileURL, cur.standardizedFileURL)
        }
        throw GitRepositoryError.gitDirFileNotSupported
      }
      let parent = cur.deletingLastPathComponent()
      if parent.path == cur.path {
        throw GitRepositoryError.notFound(searchRoot: start)
      }
      cur = parent
    }
    throw GitRepositoryError.notFound(searchRoot: start)
  }
}
