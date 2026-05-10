import Foundation
import Testing
import Subprocess
import SystemPackage

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

  @Test func sitPushAndPullMatchGitExitCodes() async throws {
    guard let gitPath = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
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

      let codeSitPush = try await Self.runSitQuiet(executable: sitURL.path, workingDirectory: work, arguments: ["push"])
      let codeGitPush = try await Self.runQuiet(executable: gitPath, arguments: ["-C", work.path, "push"])
      #expect(codeSitPush == codeGitPush)

      let codeSitPull = try await Self.runSitQuiet(executable: sitURL.path, workingDirectory: work, arguments: ["pull"])
      let codeGitPull = try await Self.runQuiet(executable: gitPath, arguments: ["-C", work.path, "pull"])
      #expect(codeSitPull == codeGitPull)

      let codeSitPushArg = try await Self.runSitQuiet(executable: sitURL.path, workingDirectory: work, arguments: ["push", "--dry-run", "nope", "main"])
      let codeGitPushArg = try await Self.runQuiet(executable: gitPath, arguments: ["-C", work.path, "push", "--dry-run", "nope", "main"])
      #expect(codeSitPushArg == codeGitPushArg)
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
      workingDirectory: FilePath(platformString: workingDirectory.path),
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
      workingDirectory: FilePath(platformString: workingDirectory.path),
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
