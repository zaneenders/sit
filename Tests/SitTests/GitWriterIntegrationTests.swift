import Foundation
import Testing

@testable import Sit

@Suite
struct GitWriterIntegrationTests: ~Copyable {
  /// `Sit`’s `git init` layout should match `git init -b main` when using the same template directory.
  @Test func sitInitMatchesGitInitByteForByte() throws {
    guard let git = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let gitWork = root.appendingPathComponent("from-git", isDirectory: true)
      let sitWork = root.appendingPathComponent("from-sit", isDirectory: true)
      try FileManager.default.createDirectory(at: gitWork, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: sitWork, withIntermediateDirectories: true)
      #expect(try Self.runGit(git, cwd: gitWork, arguments: ["init", "-b", "main"]) == 0)
      try GitInit.createEmptyRepository(
        workTree: sitWork,
        initialBranch: "main",
        templateDirectory: templates
      )
      let code = try Self.runDiffQr(
        gitWork.appendingPathComponent(".git").path,
        sitWork.appendingPathComponent(".git").path
      )
      #expect(code == 0, "expected identical .git trees; run: diff -qr between the two paths")
    }
  }

  /// One blob + tree + commit + ref update; `git fsck --strict` must succeed.
  @Test func sitLooseCommitPassesGitFsck() throws {
    guard let git = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("repo", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      let text = Array("hello sit\n".utf8)
      let blobSha = try GitLooseObjectWriter.writeBlob(gitDir: gitDir, content: text)
      let treeSha = try GitLooseObjectWriter.writeTree(
        gitDir: gitDir,
        entries: [("100644", "note.txt", blobSha)]
      )
      let treeHex = GitHex.encodeLower(treeSha)
      let commitSha = try GitLooseObjectWriter.writeCommit(
        gitDir: gitDir,
        treeSha40HexLower: treeHex,
        parentShas40HexLower: [],
        authorLine: "sit <sit@test> 1700000000 +0000",
        committerLine: "sit <sit@test> 1700000000 +0000",
        message: "first"
      )
      let commitHex = GitHex.encodeLower(commitSha)
      try GitRefs.updateRef(gitDir: gitDir, refName: "refs/heads/main", sha40HexLower: commitHex)
      let fsck = try Self.runGit(git, cwd: work, arguments: ["fsck", "--strict"])
      #expect(fsck == 0)
      let head = try Self.runGitStdout(git, cwd: work, arguments: ["rev-parse", "HEAD"]).trimmingCharacters(
        in: .whitespacesAndNewlines)
      #expect(head == commitHex)
    }
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

  private static func runDiffQr(_ path1: String, _ path2: String) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
    p.arguments = ["-qr", path1, path2]
    p.standardOutput = Self.devNullForProcess()
    p.standardError = Self.devNullForProcess()
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }
}
