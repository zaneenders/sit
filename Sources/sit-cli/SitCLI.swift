import ArgumentParser
import Foundation
import Sit

@main
struct SitCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sit",
    abstract: "Stage files and create commits in a compatible Git repository.",
    subcommands: [SitAdd.self, SitCommit.self]
  )
}

struct SitAdd: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Stage file contents (writes blobs and updates the index)."
  )

  @Argument(help: "Files or directories to stage.")
  var paths: [String]

  mutating func run() throws {
    guard !paths.isEmpty else {
      throw ValidationError("Pass at least one path (file or directory).")
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let (gitDir, workTree) = try GitRepository.discover(from: cwd)
    let indexURL = gitDir.appendingPathComponent("index")
    var index: GitIndex
    if FileManager.default.fileExists(atPath: indexURL.path) {
      index = try GitIndex.load(from: indexURL)
    } else {
      index = GitIndex()
    }
    let files = try Self.expandPaths(cwd: cwd, userPaths: paths)
    guard !files.isEmpty else {
      throw ValidationError("No regular files found to stage.")
    }
    try index.stage(gitDir: gitDir, workTree: workTree, files: files)
    try index.write(to: indexURL)
  }

  private static func expandPaths(cwd: URL, userPaths: [String]) throws -> [URL] {
    let fm = FileManager.default
    var collected: [URL] = []
    for s in userPaths {
      let u = resolveURL(cwd: cwd, s)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else {
        throw ValidationError("Path not found: \(s)")
      }
      if isDir.boolValue {
        guard
          let en = fm.enumerator(
            at: u,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
          )
        else { continue }
        while let item = en.nextObject() as? URL {
          if item.path.split(separator: "/").contains(".git") { continue }
          var reg: ObjCBool = false
          guard fm.fileExists(atPath: item.path, isDirectory: &reg), !reg.boolValue else { continue }
          collected.append(item.standardizedFileURL)
        }
      } else {
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

  mutating func run() throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let (gitDir, workTree) = try GitRepository.discover(from: cwd)
    let author = try GitLocalConfig.resolveAuthorIdentity(gitDir: gitDir)
    let committer = try GitLocalConfig.resolveCommitterIdentity(gitDir: gitDir)
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
