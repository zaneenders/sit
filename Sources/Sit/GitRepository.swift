public import Foundation

public enum GitRepositoryError: Error, Equatable, Sendable {
  case notFound(searchRoot: String)
  case gitDirFileNotSupported
}

public enum GitRepository: Sendable {
  /// Walks up from `directory` to find a `.git` directory and returns `(gitDir, workTree)`.
  public static func discover(from directory: URL) throws -> (gitDir: URL, workTree: URL) {
    var cur = directory.resolvingSymlinksInPath().standardizedFileURL
    if !cur.hasDirectoryPath {
      cur = cur.deletingLastPathComponent()
    }
    let fm = FileManager.default
    let start = cur.path
    while true {
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
  }
}
