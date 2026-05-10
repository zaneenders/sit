import Foundation
import Testing
import Subprocess

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct GitWriterIntegrationTests: ~Copyable {
  @Test func sitInitMatchesGitInitByteForByte() async throws {
    guard let git = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    let templates = try GitInit.discoverTemplateDirectory()
    try await TempDirectory.withRemoval { root in
      let gitWork = root.appendingPathComponent("from-git", isDirectory: true)
      let sitWork = root.appendingPathComponent("from-sit", isDirectory: true)
      try FileManager.default.createDirectory(at: gitWork, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: sitWork, withIntermediateDirectories: true)
      #expect(try await Self.runGit(git, arguments: ["-C", gitWork.path, "init", "-b", "main"]) == 0)
      try GitInit.createEmptyRepository(workTree: sitWork, initialBranch: "main", templateDirectory: templates)
      let code = try await Self.runDiffQr(
        gitWork.appendingPathComponent(".git").path,
        sitWork.appendingPathComponent(".git").path
      )
      #expect(code == 0, "expected identical .git trees; run: diff -qr between the two paths")
    }
  }

  @Test func sitLooseCommitPassesGitFsck() async throws {
    guard let git = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    let templates = try GitInit.discoverTemplateDirectory()
    try await TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("repo", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      let text = Array("hello sit\n".utf8)
      let blobSha = try GitLooseObjectWriter.writeBlob(gitDir: gitDir, content: text)
      let treeSha = try GitLooseObjectWriter.writeTree(gitDir: gitDir, entries: [("100644", "note.txt", blobSha)])
      let treeHex = GitHex.encodeLower(treeSha)
      let commitSha = try GitLooseObjectWriter.writeCommit(
        gitDir: gitDir, treeSha40HexLower: treeHex, parentShas40HexLower: [],
        authorLine: "sit <sit@test> 1700000000 +0000",
        committerLine: "sit <sit@test> 1700000000 +0000", message: "first")
      let commitHex = GitHex.encodeLower(commitSha)
      try GitRefs.updateRef(gitDir: gitDir, refName: "refs/heads/main", sha40HexLower: commitHex)
      #expect(try await Self.runGit(git, arguments: ["-C", work.path, "fsck", "--strict"]) == 0)
      let head = try await Self.runGitStdout(git, arguments: ["-C", work.path, "rev-parse", "HEAD"])
      #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == commitHex)
    }
  }

  // MARK: - Helpers

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

  private static func runDiffQr(_ path1: String, _ path2: String) async throws -> Int32 {
    let record = try await Subprocess.run(
      .name("/usr/bin/diff"),
      arguments: Arguments(["-qr", path1, path2]),
      output: .discarded,
      error: .discarded
    )
    return record.terminationStatus.isSuccess ? 0 : 1
  }
}
