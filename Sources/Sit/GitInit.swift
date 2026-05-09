public import Foundation

/// Create a new non-bare repository layout compatible with command-line `git init`.
public enum GitInit {
  /// Same bytes as `git init -b <initialBranch>` for `core.repositoryformatversion = 0`.
  /// Includes macOS-specific settings (`ignorecase`, `precomposeunicode`) that Apple Git adds
  /// unconditionally on Darwin; they are harmless on other platforms.
  #if os(macOS)
  public static let defaultConfigBytes: [UInt8] = Array(
    "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n\tignorecase = true\n\tprecomposeunicode = true\n".utf8
  )
  #else
  public static let defaultConfigBytes: [UInt8] = Array(
    "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n".utf8
  )
  #endif

  /// Discover `share/git-core/templates` (same tree `git init` copies from on many systems).
  public static func discoverTemplateDirectory() throws -> URL {
    if let raw = ProcessInfo.processInfo.environment["GIT_TEMPLATE_DIR"], !raw.isEmpty {
      let u = URL(fileURLWithPath: raw, isDirectory: true)
      if FileManager.default.fileExists(atPath: u.appendingPathComponent("description").path) {
        return u
      }
    }
    for path in [
      "/usr/share/git-core/templates",
      "/usr/local/share/git-core/templates",
      "/Library/Developer/CommandLineTools/usr/share/git-core/templates",
      "/Applications/Xcode.app/Contents/Developer/usr/share/git-core/templates",
    ] {
      let u = URL(fileURLWithPath: path, isDirectory: true)
      if FileManager.default.fileExists(atPath: u.appendingPathComponent("description").path) {
        return u
      }
    }
    throw GitInitError.templateDirectoryNotFound
  }

  /// Creates `workTree/.git` matching `git init -b <initialBranch>` when `templateDirectory` matches git’s templates.
  public static func createEmptyRepository(
    workTree: URL,
    initialBranch: String,
    templateDirectory: URL?
  ) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: workTree, withIntermediateDirectories: true)
    let gitDir = workTree.appendingPathComponent(".git", isDirectory: true)
    if fm.fileExists(atPath: gitDir.path) {
      throw GitInitError.gitDirectoryAlreadyExists
    }
    let templates = try templateDirectory ?? discoverTemplateDirectory()
    try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
    try copyTemplate(from: templates, toGitDir: gitDir)
    try createEmptyRepositoryLayout(gitDir: gitDir)
    let headLine = "ref: refs/heads/\(initialBranch)\n"
    try Data(headLine.utf8).write(to: gitDir.appendingPathComponent("HEAD"))
    try Data(Self.defaultConfigBytes).write(to: gitDir.appendingPathComponent("config"))
  }

  private static func createEmptyRepositoryLayout(gitDir: URL) throws {
    let fm = FileManager.default
    let dirs = [
      "objects", "objects/info", "objects/pack",
      "refs", "refs/heads", "refs/tags",
    ]
    for rel in dirs {
      try fm.createDirectory(at: gitDir.appendingPathComponent(rel, isDirectory: true), withIntermediateDirectories: true)
    }
  }

  private static func copyTemplate(from templateRoot: URL, toGitDir: URL) throws {
    let fm = FileManager.default
    guard
      let enumerator = fm.enumerator(
        at: templateRoot,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      throw GitInitError.fileSystemError("cannot enumerate template at \(templateRoot.path)")
    }
    let base = templateRoot.standardizedFileURL.path
    let basePrefix = base.hasSuffix("/") ? base : base + "/"
    while let item = enumerator.nextObject() as? URL {
      let itemPath = item.standardizedFileURL.path
      guard itemPath.hasPrefix(basePrefix) else { continue }
      let rel = String(itemPath.dropFirst(basePrefix.count))
      guard !rel.isEmpty else { continue }
      let dest = toGitDir.appendingPathComponent(rel, isDirectory: false)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
      if isDir.boolValue {
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
      } else {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
          try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: item, to: dest)
        if let attrs = try? fm.attributesOfItem(atPath: item.path),
          let mode = attrs[.posixPermissions] as? NSNumber
        {
          try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: dest.path)
        }
      }
    }
  }
}
