import Foundation
import Testing
import Subprocess

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
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

  @Test func sitTreeMatchesGitWriteTree() async throws {
    guard let git = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    let templates = try GitInit.discoverTemplateDirectory()
    try await TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try Self.appendUserConfig(gitDir: gitDir)
      try Data("alpha\n".utf8).write(to: work.appendingPathComponent("a.txt"))
      try Data("beta\n".utf8).write(to: work.appendingPathComponent("b.txt"))
      var index = GitIndex()
      try index.stage(gitDir: gitDir, workTree: work,
        files: [work.appendingPathComponent("a.txt"), work.appendingPathComponent("b.txt")])
      try index.write(to: gitDir.appendingPathComponent("index"))
      let reloaded = try GitIndex.load(from: gitDir.appendingPathComponent("index"))
      let sitHex = GitHex.encodeLower(try reloaded.writeRootTree(gitDir: gitDir))
      let gitTree = try await Self.runGitStdout(git, arguments: ["-C", work.path, "write-tree"])
      #expect(sitHex == gitTree.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  @Test func sitStagingCommitPassesGitFsck() async throws {
    guard let git = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    let templates = try GitInit.discoverTemplateDirectory()
    try await TempDirectory.withRemoval { root in
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
      let commitHex = try GitStaging.commit(gitDir: gitDir, workTree: work,
        message: "from index", author: author, committer: author)
      #expect(try await Self.runGit(git, arguments: ["-C", work.path, "fsck", "--strict"]) == 0)
      let head = try await Self.runGitStdout(git, arguments: ["-C", work.path, "rev-parse", "HEAD"])
      #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == commitHex)
    }
  }

  // MARK: - Helpers

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

  private static func runGit(_ git: String, arguments: [String]) async throws -> Int32 {
    let record = try await Subprocess.run(
      .name(git),
      arguments: Arguments(arguments),
      output: .discarded,
      error: .discarded
    )
    return record.terminationStatus.isSuccess ? 0 : 1
  }

  private static func runGitStdout(_ git: String, arguments: [String]) async throws -> String {
    let record = try await Subprocess.run(
      .name(git),
      arguments: Arguments(arguments),
      output: .string(limit: Int.max),
      error: .discarded
    )
    guard record.terminationStatus.isSuccess, let out = record.standardOutput else {
      throw GitInitError.fileSystemError("git \(arguments.joined(separator: " ")) failed")
    }
    return out
  }
}
