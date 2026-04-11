public import Foundation

public enum GitWorkTreeScan: Sendable {
  /// All regular files under `workTree`, as repo-relative `/`-separated paths (excludes anything under `.git`).
  public static func allRelativeFilePaths(workTree: URL) throws -> Set<String> {
    let fm = FileManager.default
    let wt = workTree.standardizedFileURL
    let dotGitDir = wt.appendingPathComponent(".git", isDirectory: true).standardizedFileURL
    let dotGitPath = dotGitDir.path
    let dotGitPrefix = dotGitPath + "/"
    guard
      let en = fm.enumerator(
        at: wt,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
      )
    else { return [] }
    var out = Set<String>()
    while let item = en.nextObject() as? URL {
      let p = item.standardizedFileURL.path
      if p == dotGitPath || p.hasPrefix(dotGitPrefix) { continue }
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: item.path, isDirectory: &isDir), !isDir.boolValue else { continue }
      out.insert(try relativePath(file: item.standardizedFileURL, workTree: wt))
    }
    return out
  }

  public static func fileURLs(workTree: URL, relativePaths: Set<String>) -> [URL] {
    let wt = workTree.standardizedFileURL.path
    let prefix = wt.hasSuffix("/") ? wt : wt + "/"
    return relativePaths.sorted().map { URL(fileURLWithPath: prefix + $0, isDirectory: false).standardizedFileURL }
  }

  private static func relativePath(file: URL, workTree: URL) throws -> String {
    let f = file.standardizedFileURL.path
    let w = workTree.standardizedFileURL.path
    let prefix = w.hasSuffix("/") ? w : w + "/"
    guard f.hasPrefix(prefix) || f == w else {
      throw GitIndexError.fileNotInWorkTree(file.path)
    }
    let rel: Substring
    if f == w {
      rel = ""
    } else {
      rel = f.dropFirst(prefix.count)
    }
    guard !rel.isEmpty else { throw GitIndexError.fileNotInWorkTree(file.path) }
    return String(rel).replacingOccurrences(of: "\\", with: "/")
  }
}
