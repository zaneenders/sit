import Foundation
import Testing

@testable import Sit

/// Spawns the built `sit` executable (not in-process library calls).
@Suite
struct SitCLIProcessTests: ~Copyable {
  /// `sit init` should produce the same `.git` tree as `git init -b <branch>` when templates match.
  @Test func sitInitProcessMatchesGitInitLayout() throws {
    guard let git = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    guard let sit = Self.sitExecutableURL() else {
      Issue.record(
        "skip: could not find built `sit` (set SIT_BINARY or run swift test from the package root)"
      )
      return
    }
    _ = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let gitWork = root.appendingPathComponent("from-git", isDirectory: true)
      let sitWork = root.appendingPathComponent("from-sit", isDirectory: true)
      try FileManager.default.createDirectory(at: gitWork, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: sitWork, withIntermediateDirectories: true)
      #expect(try Self.runGit(git, cwd: gitWork, arguments: ["init", "-b", "main"]) == 0)
      let (code, _, stderr) = try Self.runProcess(
        executable: sit, cwd: sitWork, arguments: ["init", "-b", "main"])
      #expect(code == 0, "sit init failed: \(stderr)")
      let diff = try Self.runDiffQr(
        gitWork.appendingPathComponent(".git").path,
        sitWork.appendingPathComponent(".git").path
      )
      #expect(diff == 0)
    }
  }

  /// `sit init -b main <dir>` from a parent directory matches `git init` in the same relative layout.
  @Test func sitInitWithDirectoryArgumentMatchesGit() throws {
    guard let git = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    guard let sit = Self.sitExecutableURL() else {
      Issue.record("skip: could not find built `sit`")
      return
    }
    _ = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let (codeG, _, _) = try Self.runProcessCapturing(
        executable: URL(fileURLWithPath: git),
        cwd: root,
        arguments: ["-C", root.path, "init", "-b", "main", "gdir"]
      )
      #expect(codeG == 0)
      let (codeS, _, errS) = try Self.runProcess(
        executable: sit, cwd: root, arguments: ["init", "-b", "main", "sdir"])
      #expect(codeS == 0, "sit init sdir: \(errS)")
      let diff = try Self.runDiffQr(
        root.appendingPathComponent("gdir/.git").path,
        root.appendingPathComponent("sdir/.git").path
      )
      #expect(diff == 0)
    }
  }

  @Test func sitInitSecondInvocationFails() throws {
    guard let sit = Self.sitExecutableURL() else {
      Issue.record("skip: could not find built `sit`")
      return
    }
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("repo", isDirectory: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let (first, _, e1) = try Self.runProcess(executable: sit, cwd: work, arguments: ["init", "-b", "main"])
      #expect(first == 0, "first sit init: \(e1)")
      let (second, _, _) = try Self.runProcess(executable: sit, cwd: work, arguments: ["init", "-b", "main"])
      #expect(second != 0)
    }
  }

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

  /// Prefer `SIT_BINARY` when set (absolute path to the `sit` executable).
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

  private static func devNullForWriting() -> FileHandle {
    try! FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
  }

  private static func runGit(_ git: String, cwd: URL, arguments: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: git)
    p.arguments = ["-C", cwd.path] + arguments
    p.standardOutput = Self.devNullForWriting()
    p.standardError = Self.devNullForWriting()
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }

  private static func runProcess(executable: URL, cwd: URL, arguments: [String]) throws -> (
    code: Int32, stdout: String, stderr: String
  ) {
    try runProcessCapturing(executable: executable, cwd: cwd, arguments: arguments)
  }

  private static func runProcessCapturing(executable: URL, cwd: URL, arguments: [String]) throws -> (
    code: Int32, stdout: String, stderr: String
  ) {
    let p = Process()
    p.executableURL = executable
    p.arguments = arguments
    p.currentDirectoryURL = cwd
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    try p.run()
    let outData = try outPipe.fileHandleForReading.readToEnd() ?? Data()
    let errData = try errPipe.fileHandleForReading.readToEnd() ?? Data()
    p.waitUntilExit()
    return (
      p.terminationStatus,
      String(decoding: outData, as: UTF8.self),
      String(decoding: errData, as: UTF8.self)
    )
  }

  private static func runDiffQr(_ path1: String, _ path2: String) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
    p.arguments = ["-qr", path1, path2]
    p.standardOutput = Self.devNullForWriting()
    p.standardError = Self.devNullForWriting()
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }
}
