import ArgumentParser
import Foundation
import Sit

@main
struct SitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sit",
    abstract: "Initialize a repo, stage files, show status, and create commits in a Git-compatible layout.",
    subcommands: [
      SitInit.self, SitAdd.self, SitCommit.self, SitStatus.self, SitPush.self, SitPull.self,
    ]
  )
}

struct SitInit: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Create an empty Git repository in the given directory (or the current directory)."
  )

  @Option(
    name: [.customShort("b"), .customLong("initial-branch")],
    help: "Initial branch name (like git init -b)."
  )
  var initialBranch: String = "main"

  @Argument(help: "Directory for the new repository; default is the current directory.")
  var directory: String?

  mutating func run() throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let branch = initialBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branch.isEmpty else {
      throw ValidationError("Initial branch name must not be empty.")
    }
    let workTree: URL
    if let d = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
      workTree =
        d.hasPrefix("/")
        ? URL(fileURLWithPath: d, isDirectory: true).standardizedFileURL
        : cwd.appendingPathComponent(d, isDirectory: true).standardizedFileURL
    } else {
      workTree = cwd
    }
    do {
      try GitInit.createEmptyRepository(workTree: workTree, initialBranch: branch, templateDirectory: nil)
    } catch GitInitError.gitDirectoryAlreadyExists {
      throw ValidationError("A .git directory already exists at \(workTree.path).")
    } catch GitInitError.templateDirectoryNotFound {
      throw ValidationError(
        "Git template directory not found. Set GIT_TEMPLATE_DIR, or install git’s share/git-core/templates."
      )
    } catch GitInitError.fileSystemError(let message) {
      throw ValidationError(message)
    }
  }
}

struct SitAdd: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Stage file contents (writes blobs and updates the index)."
  )

  @Flag(name: [.customShort("A"), .customLong("all")], help: "Stage the whole work tree (like git add --all); remove index entries for deleted files.")
  var all = false

  @Argument(help: "Files or directories to stage (omit when using --all / -A).")
  var paths: [String] = []

  mutating func run() throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let (gitDir, workTree) = try GitRepository.discover(from: cwd)
    let indexURL = gitDir.appendingPathComponent("index")
    var index: GitIndex
    if FileManager.default.fileExists(atPath: indexURL.path) {
      index = try GitIndex.load(from: indexURL)
    } else {
      index = GitIndex()
    }

    if all {
      guard paths.isEmpty else {
        throw ValidationError("Do not pass paths together with --all / -A.")
      }
      let onDisk = try GitWorkTreeScan.allRelativeFilePaths(workTree: workTree, gitDir: gitDir)
      for path in index.trackedPaths where !onDisk.contains(path) {
        index.removeEntry(path: path)
      }
      let urls = GitWorkTreeScan.fileURLs(workTree: workTree, relativePaths: onDisk)
      guard !urls.isEmpty else {
        throw ValidationError("No files found under the work tree.")
      }
      try index.stage(gitDir: gitDir, workTree: workTree, files: urls)
    } else {
      guard !paths.isEmpty else {
        throw ValidationError("Pass at least one path, or use --all / -A.")
      }
      let files = try Self.expandPaths(cwd: cwd, workTree: workTree, gitDir: gitDir, userPaths: paths)
      guard !files.isEmpty else {
        throw ValidationError("No regular files found to stage.")
      }
      try index.stage(gitDir: gitDir, workTree: workTree, files: files)
    }
    try index.write(to: indexURL)
  }

  private static func expandPaths(cwd: URL, workTree: URL, gitDir: URL, userPaths: [String]) throws -> [URL] {
    let fm = FileManager.default
    let matcher = try GitIgnoreMatcher(workTree: workTree, gitDir: gitDir)
    var collected: [URL] = []
    for s in userPaths {
      let u = resolveURL(cwd: cwd, s)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else {
        throw ValidationError("Path not found: \(s)")
      }
      if isDir.boolValue {
        let dotGitDir = u.appendingPathComponent(".git", isDirectory: true).standardizedFileURL
        let dotGitPath = dotGitDir.path
        let dotGitPrefix = dotGitPath + "/"
        guard
          let en = fm.enumerator(
            at: u,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
          )
        else { continue }
        while let item = en.nextObject() as? URL {
          let p = item.standardizedFileURL.path
          if p == dotGitPath || p.hasPrefix(dotGitPrefix) { continue }
          var reg: ObjCBool = false
          guard fm.fileExists(atPath: item.path, isDirectory: &reg), !reg.boolValue else { continue }
          let fileURL = item.standardizedFileURL
          if let rel = try? GitWorkTreeScan.relativePath(file: fileURL, workTree: workTree),
            matcher.isIgnored(relativePath: rel, isDirectory: false)
          {
            continue
          }
          collected.append(fileURL)
        }
      } else {
        if let rel = try? GitWorkTreeScan.relativePath(file: u, workTree: workTree),
          matcher.isIgnored(relativePath: rel, isDirectory: false)
        {
          continue
        }
        collected.append(u)
      }
    }
    var seen = Set<String>()
    var unique: [URL] = []
    for u in collected {
      let p = u.path
      if seen.insert(p).inserted {
        unique.append(u)
      }
    }
    return unique
  }

  private static func resolveURL(cwd: URL, _ s: String) -> URL {
    if s.hasPrefix("/") {
      return URL(fileURLWithPath: s, isDirectory: false).standardizedFileURL
    }
    return cwd.appendingPathComponent(s).standardizedFileURL
  }
}

struct SitCommit: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "commit",
    abstract: "Create a commit from the current index (like git commit)."
  )

  @Option(name: .shortAndLong, help: "Commit message.")
  var message: String

  @Option(name: .customLong("author-name"), help: "Author name (use with --author-email to skip config).")
  var authorName: String?

  @Option(name: .customLong("author-email"), help: "Author email (use with --author-name).")
  var authorEmail: String?

  mutating func run() throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let (gitDir, workTree) = try GitRepository.discover(from: cwd)
    let author: GitLocalConfig.UserIdentity
    let committer: GitLocalConfig.UserIdentity
    switch (authorName, authorEmail) {
    case let (.some(n), .some(e)) where !n.isEmpty && !e.isEmpty:
      author = GitLocalConfig.UserIdentity(name: n, email: e)
      committer = author
    case (nil, nil):
      author = try GitLocalConfig.resolveAuthorIdentity(gitDir: gitDir)
      committer = try GitLocalConfig.resolveCommitterIdentity(gitDir: gitDir)
    default:
      throw ValidationError(
        "Pass both --author-name and --author-email together, or omit them to use .git/config or GIT_AUTHOR_*."
      )
    }
    let hex = try GitStaging.commit(
      gitDir: gitDir,
      workTree: workTree,
      message: message,
      author: author,
      committer: committer
    )
    print(hex)
  }
}

struct SitStatus: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show staged, unstaged, and untracked changes (simplified git status)."
  )

  mutating func run() throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let (gitDir, workTree) = try GitRepository.discover(from: cwd)
    let text = try GitWorkdirStatusText.format(gitDir: gitDir, workTree: workTree)
    print(text, terminator: "")
  }
}

struct SitPush: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "push",
    abstract: "Push the current branch to its upstream remote using native smart HTTP."
  )

  @Argument(help: "Remote name (default: upstream remote for the current branch).")
  var remote: String?

  @Argument(help: "Refspecs to push (default: push the current branch to the matching remote ref).")
  var refspecs: [String] = []

  mutating func run() async throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let (gitDir, workTree) = try GitRepository.discover(from: cwd)
    try await GitPush.push(
      gitDir: gitDir,
      workTree: workTree,
      remoteName: remote,
      refspecs: refspecs)
  }
}

struct SitPull: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pull",
    abstract: "Fetch from and integrate with the upstream remote (native implementation)."
  )

  @Argument(help: "Remote name (default: upstream remote for the current branch).")
  var remote: String?

  mutating func run() async throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let (gitDir, workTree) = try GitRepository.discover(from: cwd)
    try await GitPull.pull(
      gitDir: gitDir,
      workTree: workTree,
      remoteName: remote)
  }
}
