import Foundation
import Testing
import Subprocess

#if canImport(System)
import System
#else
import SystemPackage
#endif

@testable import Sit

/// Spawns the built `sit` executable (not in-process library calls).
@Suite(.timeLimit(.minutes(1)))
struct SitCLIProcessTests: ~Copyable {
  /// `sit init` should produce the same `.git` tree as `git init -b <branch>` when templates match.
  @Test func sitInitProcessMatchesGitInitLayout() async throws {
    guard let gitPath = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    guard let sitURL = Self.sitExecutableURL() else {
      Issue.record("skip: could not find built `sit` (set SIT_BINARY or run swift test from the package root)")
      return
    }
    _ = try GitInit.discoverTemplateDirectory()
    try await TempDirectory.withRemoval { root in
      let gitWork = root.appendingPathComponent("from-git", isDirectory: true)
      let sitWork = root.appendingPathComponent("from-sit", isDirectory: true)
      try FileManager.default.createDirectory(at: gitWork, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: sitWork, withIntermediateDirectories: true)
      #expect(try await Self.runGitQuiet(gitPath, arguments: ["-C", gitWork.path, "init", "-b", "main"]) == 0)
      let (code, _, stderr) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: sitWork, arguments: ["init", "-b", "main"])
      #expect(code == 0, "sit init failed: \(stderr)")
      let diff = try await Self.runDiffQr(
        gitWork.appendingPathComponent(".git").path,
        sitWork.appendingPathComponent(".git").path
      )
      #expect(diff == 0)
    }
  }

  @Test func sitInitWithDirectoryArgumentMatchesGit() async throws {
    guard let gitPath = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    guard let sitURL = Self.sitExecutableURL() else {
      Issue.record("skip: could not find built `sit`")
      return
    }
    _ = try GitInit.discoverTemplateDirectory()
    try await TempDirectory.withRemoval { root in
      let (codeG, _, _) = try await Self.runCapturing(
        executable: gitPath, arguments: ["-C", root.path, "init", "-b", "main", "gdir"])
      #expect(codeG == 0)
      let (codeS, _, errS) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: root, arguments: ["init", "-b", "main", "sdir"])
      #expect(codeS == 0, "sit init sdir: \(errS)")
      let diff = try await Self.runDiffQr(
        root.appendingPathComponent("gdir/.git").path,
        root.appendingPathComponent("sdir/.git").path
      )
      #expect(diff == 0)
    }
  }

  @Test func sitInitSecondInvocationFails() async throws {
    guard let sitURL = Self.sitExecutableURL() else {
      Issue.record("skip: could not find built `sit`")
      return
    }
    try await TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("repo", isDirectory: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let (first, _, e1) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work, arguments: ["init", "-b", "main"])
      #expect(first == 0, "first sit init: \(e1)")
      let (second, _, _) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work, arguments: ["init", "-b", "main"])
      #expect(second != 0)
    }
  }

  @Test func sitPushFailsWithoutUpstream() async throws {
    guard let sitURL = Self.sitExecutableURL() else {
      Issue.record("skip: could not find built `sit`")
      return
    }
    try await TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("repo", isDirectory: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let (initCode, _, errInit) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work, arguments: ["init", "-b", "main"])
      #expect(initCode == 0, "sit init: \(errInit)")

      // Native push should fail (non-zero) when no upstream remote is configured
      let codeSitPush = try await Self.runSitQuiet(
        executable: sitURL.path, workingDirectory: work, arguments: ["push"])
      #expect(codeSitPush != 0, "sit push without remote should fail")
    }
  }

  @Test func sitPullFailsWithoutUpstream() async throws {
    guard let sitURL = Self.sitExecutableURL() else {
      Issue.record("skip: could not find built `sit`")
      return
    }
    try await TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("repo", isDirectory: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let (initCode, _, errInit) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work, arguments: ["init", "-b", "main"])
      #expect(initCode == 0, "sit init: \(errInit)")

      let codeSitPull = try await Self.runSitQuiet(
        executable: sitURL.path, workingDirectory: work, arguments: ["pull"])
      #expect(codeSitPull != 0, "sit pull without remote should fail")
    }
  }

  @Test func sitFetchFailsWithoutUpstream() async throws {
    guard let sitURL = Self.sitExecutableURL() else {
      Issue.record("skip: could not find built `sit`")
      return
    }
    try await TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("repo", isDirectory: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let (initCode, _, _) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work, arguments: ["init", "-b", "main"])
      #expect(initCode == 0)
      let code = try await Self.runSitQuiet(
        executable: sitURL.path, workingDirectory: work, arguments: ["fetch"])
      #expect(code != 0, "sit fetch without remote should fail")
    }
  }

  @Test func sitAddCommitStatusWorkflow() async throws {
    guard let sitURL = Self.sitExecutableURL() else {
      Issue.record("skip: could not find built `sit`")
      return
    }
    try await TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("repo", isDirectory: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

      // init
      let (initCode, _, initErr) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work, arguments: ["init", "-b", "main"])
      #expect(initCode == 0, "sit init: \(initErr)")

      // Write a file
      let file = work.appendingPathComponent("hello.txt")
      try Data("hello\n".utf8).write(to: file)

      // status before add: should show untracked
      let (_, statusBefore, _) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work, arguments: ["status"])
      #expect(statusBefore.contains("hello.txt"))

      // add
      let addCode = try await Self.runSitQuiet(
        executable: sitURL.path, workingDirectory: work, arguments: ["add", "hello.txt"])
      #expect(addCode == 0, "sit add failed")

      // commit
      let (commitCode, commitOut, commitErr) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work,
        arguments: ["commit", "-m", "initial", "--author-name", "Test", "--author-email", "t@t.com"])
      #expect(commitCode == 0, "sit commit failed: \(commitErr)")
      #expect(commitOut.count == 41)  // 40-hex SHA + newline

      // status after commit: should be clean
      let (_, statusAfter, _) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work, arguments: ["status"])
      #expect(!statusAfter.contains("hello.txt"),
        "status should be clean after commit, got: \(statusAfter)")
    }
  }

  @Test func sitAddAllAndCommit() async throws {
    guard let sitURL = Self.sitExecutableURL() else {
      Issue.record("skip: could not find built `sit`")
      return
    }
    try await TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("repo", isDirectory: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

      let (initCode, _, _) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work, arguments: ["init", "-b", "main"])
      #expect(initCode == 0)

      try Data("a\n".utf8).write(to: work.appendingPathComponent("a.txt"))
      try Data("b\n".utf8).write(to: work.appendingPathComponent("b.txt"))

      let addCode = try await Self.runSitQuiet(
        executable: sitURL.path, workingDirectory: work, arguments: ["add", "--all"])
      #expect(addCode == 0)

      let (commitCode, _, commitErr) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work,
        arguments: ["commit", "-m", "two files", "--author-name", "Test", "--author-email", "t@t.com"])
      #expect(commitCode == 0, "sit commit: \(commitErr)")
    }
  }

  @Test func sitCommitProducesGitReadableObject() async throws {
    guard let gitPath = Self.gitPath() else {
      Issue.record("skip: git not found")
      return
    }
    guard let sitURL = Self.sitExecutableURL() else {
      Issue.record("skip: could not find built `sit`")
      return
    }
    try await TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("repo", isDirectory: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

      let (initCode, _, _) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work, arguments: ["init", "-b", "main"])
      #expect(initCode == 0)

      try Data("content\n".utf8).write(to: work.appendingPathComponent("f.txt"))
      _ = try await Self.runSitQuiet(
        executable: sitURL.path, workingDirectory: work, arguments: ["add", "f.txt"])
      let (commitCode, commitOut, _) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: work,
        arguments: ["commit", "-m", "msg", "--author-name", "A", "--author-email", "a@b.com"])
      #expect(commitCode == 0)

      let sha = commitOut.trimmingCharacters(in: .whitespacesAndNewlines)
      #expect(sha.count == 40)

      // git cat-file should be able to read the commit object sit wrote
      let (gitCode, gitOut, _) = try await Self.runCapturing(
        executable: gitPath,
        arguments: ["-C", work.path, "cat-file", "-t", sha])
      #expect(gitCode == 0)
      #expect(gitOut.trimmingCharacters(in: .whitespacesAndNewlines) == "commit")
    }
  }

  // MARK: - Helpers

  private static func packageRootURL() -> URL? {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: #filePath, isDirectory: false).deletingLastPathComponent()
    for _ in 0..<16 {
      if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
        return dir.standardizedFileURL
      }
      let parent = dir.deletingLastPathComponent()
      if parent.path == dir.path { break }
      dir = parent
    }
    return nil
  }

  private static func sitExecutableURL() -> URL? {
    let fm = FileManager.default
    if let raw = ProcessInfo.processInfo.environment["SIT_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    {
      let u = URL(fileURLWithPath: raw)
      if fm.isExecutableFile(atPath: u.path) { return u.standardizedFileURL }
    }
    guard let root = packageRootURL() else { return nil }
    let candidates = [
      root.appendingPathComponent(".build/debug/sit"),
      root.appendingPathComponent(".build/release/sit"),
    ]
    for c in candidates where fm.isExecutableFile(atPath: c.path) {
      return c.standardizedFileURL
    }
    let buildDir = root.appendingPathComponent(".build", isDirectory: true)
    guard let kids = try? fm.contentsOfDirectory(at: buildDir, includingPropertiesForKeys: nil) else {
      return nil
    }
    for kid in kids {
      let debugSit = kid.appendingPathComponent("debug/sit")
      if fm.isExecutableFile(atPath: debugSit.path) { return debugSit.standardizedFileURL }
      let releaseSit = kid.appendingPathComponent("release/sit")
      if fm.isExecutableFile(atPath: releaseSit.path) { return releaseSit.standardizedFileURL }
    }
    return nil
  }

  private static func gitPath() -> String? {
    for p in ["/usr/bin/git", "/bin/git", "/usr/local/bin/git"] {
      if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
  }

  /// Runs a process, discards output, returns 0 or 1.
  private static func runQuiet(executable: String, arguments: [String]) async throws -> Int32 {
    let record = try await Subprocess.run(
      .name(executable),
      arguments: Arguments(arguments),
      output: .discarded,
      error: .discarded
    )
    return record.terminationStatus.isSuccess ? 0 : 1
  }

  /// Runs git, discards output, returns 0 or 1.
  private static func runGitQuiet(_ git: String, arguments: [String]) async throws -> Int32 {
    try await runQuiet(executable: git, arguments: arguments)
  }

  /// Runs `sit` with a working directory (sit doesn't understand -C).
  private static func runSitQuiet(executable: String, workingDirectory: URL, arguments: [String]) async throws -> Int32 {
    let record = try await Subprocess.run(
      .name(executable),
      arguments: Arguments(arguments),
      workingDirectory: FilePath(workingDirectory.path),
      output: .discarded,
      error: .discarded
    )
    return record.terminationStatus.isSuccess ? 0 : 1
  }

  /// Runs `sit` with a working directory, captures stdout and stderr.
  private static func runSit(executable: String, workingDirectory: URL, arguments: [String]) async throws -> (
    code: Int32, stdout: String, stderr: String
  ) {
    let record = try await Subprocess.run(
      .name(executable),
      arguments: Arguments(arguments),
      workingDirectory: FilePath(workingDirectory.path),
      output: .string(limit: Int.max),
      error: .string(limit: Int.max)
    )
    return (
      record.terminationStatus.isSuccess ? 0 : 1,
      record.standardOutput ?? "",
      record.standardError ?? ""
    )
  }

  /// Runs a process, captures stdout and stderr.
  private static func runCapturing(executable: String, arguments: [String]) async throws -> (
    code: Int32, stdout: String, stderr: String
  ) {
    let record = try await Subprocess.run(
      .name(executable),
      arguments: Arguments(arguments),
      output: .string(limit: Int.max),
      error: .string(limit: Int.max)
    )
    return (
      record.terminationStatus.isSuccess ? 0 : 1,
      record.standardOutput ?? "",
      record.standardError ?? ""
    )
  }

  private static func runDiffQr(_ path1: String, _ path2: String) async throws -> Int32 {
    try await runQuiet(executable: "/usr/bin/diff", arguments: ["-qr", path1, path2])
  }
}
