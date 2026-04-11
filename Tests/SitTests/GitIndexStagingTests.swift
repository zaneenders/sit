import Foundation
import Testing

@testable import Sit

@Suite
struct GitIndexStagingTests: ~Copyable {
  @Test func indexSerializeRoundTrip() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      let file = work.appendingPathComponent("x.txt")
      try Data("ok".utf8).write(to: file)
      var index = GitIndex()
      try index.stage(gitDir: gitDir, workTree: work, files: [file])
      let a = try index.serialized()
      let parsed = try GitIndex(bytes: Array(a))
      let b = try parsed.serialized()
      #expect(a == b)
    }
  }

  @Test func sitTreeMatchesGitWriteTree() throws {
    guard let git = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try Self.appendUserConfig(gitDir: gitDir)
      try Data("alpha\n".utf8).write(to: work.appendingPathComponent("a.txt"))
      try Data("beta\n".utf8).write(to: work.appendingPathComponent("b.txt"))
      var index = GitIndex()
      try index.stage(
        gitDir: gitDir, workTree: work,
        files: [
          work.appendingPathComponent("a.txt"),
          work.appendingPathComponent("b.txt"),
        ])
      try index.write(to: gitDir.appendingPathComponent("index"))
      let reloaded = try GitIndex.load(from: gitDir.appendingPathComponent("index"))
      let sitHex = GitHex.encodeLower(try reloaded.writeRootTree(gitDir: gitDir))
      let gitTree = try Self.runGitStdout(git, cwd: work, arguments: ["write-tree"]).trimmingCharacters(
        in: .whitespacesAndNewlines)
      #expect(sitHex == gitTree)
    }
  }

  @Test func sitStagingCommitPassesGitFsck() throws {
    guard let git = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try Self.appendUserConfig(gitDir: gitDir)
      let file = work.appendingPathComponent("note.txt")
      try Data("hello sit index\n".utf8).write(to: file)
      var index = GitIndex()
      try index.stage(gitDir: gitDir, workTree: work, files: [file])
      try index.write(to: gitDir.appendingPathComponent("index"))
      let author = GitLocalConfig.UserIdentity(name: "sit", email: "sit@test")
      let commitHex = try GitStaging.commit(
        gitDir: gitDir,
        workTree: work,
        message: "from index",
        author: author,
        committer: author
      )
      let fsck = try Self.runGit(git, cwd: work, arguments: ["fsck", "--strict"])
      #expect(fsck == 0)
      let head = try Self.runGitStdout(git, cwd: work, arguments: ["rev-parse", "HEAD"]).trimmingCharacters(
        in: .whitespacesAndNewlines)
      #expect(head == commitHex)
    }
  }

  private static func appendUserConfig(gitDir: URL) throws {
    let url = gitDir.appendingPathComponent("config")
    var s = try String(contentsOf: url, encoding: .utf8)
    s += "\n[user]\n\tname = Sit Tests\n\temail = sit-tests@example.com\n"
    try s.write(to: url, atomically: true, encoding: .utf8)
  }

  private static func gitPath() -> String? {
    for p in ["/usr/bin/git", "/bin/git", "/usr/local/bin/git"] {
      if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
  }

  private static func devNullForProcess() -> FileHandle {
    try! FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
  }

  private static func runGit(_ git: String, cwd: URL, arguments: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: git)
    p.arguments = ["-C", cwd.path] + arguments
    p.standardOutput = Self.devNullForProcess()
    p.standardError = Self.devNullForProcess()
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }

  private static func runGitStdout(_ git: String, cwd: URL, arguments: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: git)
    p.arguments = ["-C", cwd.path] + arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Self.devNullForProcess()
    try p.run()
    let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
      throw GitInitError.fileSystemError("git \(arguments.joined(separator: " ")) failed")
    }
    return String(decoding: data, as: UTF8.self)
  }
}
