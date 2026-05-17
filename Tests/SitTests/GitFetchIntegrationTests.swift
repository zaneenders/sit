import Foundation
import Subprocess
import SystemPackage

#if canImport(System)
import System
#endif

import Testing

@testable import Sit
@testable import sit_cli

@Suite(.timeLimit(.minutes(2)))
struct GitFetchIntegrationTests: ~Copyable {

  // MARK: - Option 4: buildHaveHashes unit test

  @Test func buildHaveHashesIncludesLocalBranchesNotTrackingRefs() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("repo", isDirectory: true)
      try GitInit.createEmptyRepository(
        workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git")

      // Write a real commit to refs/heads/main
      let blobSHA = try GitLooseObjectWriter.writeObject(
        gitDir: gitDir, type: "blob", body: Array("hello".utf8))
      let treeSHA = try GitLooseObjectWriter.writeTree(
        gitDir: gitDir, entries: [(mode: "100644", name: "f.txt", sha20: blobSHA)])
      let commitSHA = try GitLooseObjectWriter.writeCommit(
        gitDir: gitDir,
        treeSha40HexLower: GitHex.encodeLower(treeSHA),
        parentShas40HexLower: [],
        authorLine: "T <t@t.com> 0 +0000",
        committerLine: "T <t@t.com> 0 +0000",
        message: "first")
      let commitHex = GitHex.encodeLower(commitSHA)
      try GitRefs.updateRef(gitDir: gitDir, refName: "refs/heads/main", sha40HexLower: commitHex)

      // Plant a tracking ref with a different SHA (simulating a stale cached pointer)
      let fakeHex = "aaaa000000000000000000000000000000000000"
      let remoteDir = gitDir.appendingPathComponent("refs/remotes/origin")
      try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
      try Data((fakeHex + "\n").utf8).write(to: remoteDir.appendingPathComponent("main"))

      let haveHashes = GitFetch.buildHaveHashes(gitDir: gitDir)

      #expect(haveHashes.contains(commitHex), "local branch commit should be in haveHashes")
      #expect(!haveHashes.contains(fakeHex), "tracking ref SHA must NOT appear in haveHashes")
    }
  }

  // MARK: - Option 1: local two-repo transport tests

  /// Uses GitLocalTransport directly to fetch from a git repo on disk, then
  /// imports the pack and verifies the objects are in the local store.
  @Test func fetchDownloadsObjectsFromLocalRepo() async throws {
    guard let git = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }

    let templates = try GitInit.discoverTemplateDirectory()
    try await TempDirectory.withRemoval { root in
      // 1. Server: git repo with one commit
      let serverDir = root.appendingPathComponent("server")
      try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)

      let (initCode, _, initErr) = try await Self.runGit(
        git, ["-C", serverDir.path, "init", "-b", "main"])
      guard initCode == 0 else {
        Issue.record("git init: \(initErr)")
        return
      }

      try Data("hello\n".utf8).write(to: serverDir.appendingPathComponent("f.txt"))
      _ = try await Self.runGit(git, ["-C", serverDir.path, "add", "f.txt"])
      let (commitCode, _, commitErr) = try await Self.runGit(
        git,
        [
          "-c", "user.name=T", "-c", "user.email=t@t.com",
          "-C", serverDir.path, "commit", "-m", "first",
        ])
      guard commitCode == 0 else {
        Issue.record("git commit: \(commitErr)")
        return
      }

      let (_, headOut, _) = try await Self.runGit(git, ["-C", serverDir.path, "rev-parse", "HEAD"])
      let expectedHex = headOut.trimmingCharacters(in: .whitespacesAndNewlines)
      guard expectedHex.count == 40 else {
        Issue.record("bad SHA")
        return
      }

      // 2. Client: empty sit repo
      let clientDir = root.appendingPathComponent("client")
      try FileManager.default.createDirectory(at: clientDir, withIntermediateDirectories: true)
      try GitInit.createEmptyRepository(
        workTree: clientDir, initialBranch: "main", templateDirectory: templates)
      let clientGitDir = clientDir.appendingPathComponent(".git")

      // 3. Advertise + fetch via local transport
      let advert = try await GitLocalTransport.advertiseFetchRefs(path: serverDir.path)
      let wantRef = advert.refs.first(where: { $0.name == "refs/heads/main" })
      guard let wantRef else {
        Issue.record("refs/heads/main not in advertisement")
        return
      }
      let wantHex = GitHex.encodeLower(wantRef.sha20)
      #expect(wantHex == expectedHex)

      let packData = try await GitLocalTransport.fetch(
        path: serverDir.path,
        wantHashes: [wantHex],
        capabilities: advert.capabilities)
      #expect(!packData.isEmpty, "server must return a non-empty pack")

      let packs = try GitObjectDatabase.openAllPacks(gitDir: clientGitDir)
      let result = try GitPackImporter.importPack(
        gitDir: clientGitDir, packData: packData, packs: packs)

      #expect(result.importedSHAs.contains(wantHex))
      #expect(result.unresolvedDeltas == 0)
    }
  }

  /// Full CLI test: sit pull fast-forwards a local branch when the server has
  /// an additional commit that the client doesn't yet have.
  @Test func sitPullFastForwardsFromLocalRepo() async throws {
    guard let git = Self.gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }
    guard let sitURL = Self.sitExecutableURL() else {
      Issue.record("skip: could not find built `sit`")
      return
    }

    let templates = try GitInit.discoverTemplateDirectory()
    try await TempDirectory.withRemoval { root in
      // 1. Server: two commits
      let serverDir = root.appendingPathComponent("server")
      try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
      _ = try await Self.runGit(git, ["-C", serverDir.path, "init", "-b", "main"])
      _ = try await Self.runGit(
        git,
        [
          "-c", "user.name=T", "-c", "user.email=t@t.com",
          "-C", serverDir.path, "commit", "--allow-empty", "-m", "first",
        ])
      let (_, firstOut, _) = try await Self.runGit(
        git, ["-C", serverDir.path, "rev-parse", "HEAD"])
      let firstHex = firstOut.trimmingCharacters(in: .whitespacesAndNewlines)
      guard firstHex.count == 40 else {
        Issue.record("bad first SHA")
        return
      }

      _ = try await Self.runGit(
        git,
        [
          "-c", "user.name=T", "-c", "user.email=t@t.com",
          "-C", serverDir.path, "commit", "--allow-empty", "-m", "second",
        ])
      let (_, secondOut, _) = try await Self.runGit(
        git, ["-C", serverDir.path, "rev-parse", "HEAD"])
      let secondHex = secondOut.trimmingCharacters(in: .whitespacesAndNewlines)
      guard secondHex.count == 40 else {
        Issue.record("bad second SHA")
        return
      }
      #expect(firstHex != secondHex)

      // 2. Client: sit repo seeded with both commit objects by fetching the tip.
      //    We request secondHex (the advertised tip), which causes the server to
      //    send a pack containing all reachable objects — including firstHex.
      //    We then pin the client branch to firstHex so pull has to fast-forward.
      let clientDir = root.appendingPathComponent("client")
      try FileManager.default.createDirectory(at: clientDir, withIntermediateDirectories: true)
      try GitInit.createEmptyRepository(
        workTree: clientDir, initialBranch: "main", templateDirectory: templates)
      let clientGitDir = clientDir.appendingPathComponent(".git")

      let advert1 = try await GitLocalTransport.advertiseFetchRefs(path: serverDir.path)
      let pack1 = try await GitLocalTransport.fetch(
        path: serverDir.path, wantHashes: [secondHex], capabilities: advert1.capabilities)
      guard !pack1.isEmpty else {
        Issue.record("initial fetch returned empty pack")
        return
      }
      let packs = try GitObjectDatabase.openAllPacks(gitDir: clientGitDir)
      let importResult = try GitPackImporter.importPack(
        gitDir: clientGitDir, packData: pack1, packs: packs)
      guard importResult.importedSHAs.contains(firstHex) else {
        Issue.record("firstHex not in imported pack: \(importResult.importedSHAs)")
        return
      }

      // Pin client's main to firstHex — one commit behind the server
      try GitRefs.updateRef(
        gitDir: clientGitDir, refName: "refs/heads/main", sha40HexLower: firstHex)

      // Write git config: remote pointing to the server + branch tracking
      let remoteURL = "file://\(serverDir.path)"
      let config = """
        [core]
          repositoryformatversion = 0
          filemode = true
          bare = false
        [remote "origin"]
          url = \(remoteURL)
          fetch = +refs/heads/*:refs/remotes/origin/*
        [branch "main"]
          remote = origin
          merge = refs/heads/main
        """
      try Data(config.utf8).write(to: clientGitDir.appendingPathComponent("config"))

      // 3. sit pull should fast-forward to second commit
      let (code, out, err) = try await Self.runSit(
        executable: sitURL.path, workingDirectory: clientDir, arguments: ["pull"])
      #expect(code == 0, "sit pull failed: \(err)\nstdout: \(out)")
      #expect(
        out.lowercased().contains("fast-forward") || out.lowercased().contains("fast forward"),
        "expected fast-forward message, got: \(out)")

      // 4. Verify the local branch is now at the server's second commit
      let currentHex = try GitRefs.readRef(
        gitDir: clientGitDir, refName: "refs/heads/main")
      #expect(currentHex == secondHex)
    }
  }

  // MARK: - Helpers

  private static func gitPath() -> String? {
    for p in ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"] {
      if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
  }

  private static func sitExecutableURL() -> URL? {
    let fm = FileManager.default
    if let raw = ProcessInfo.processInfo.environment["SIT_BINARY"]?
      .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
    {
      let u = URL(fileURLWithPath: raw)
      if fm.isExecutableFile(atPath: u.path) { return u.standardizedFileURL }
    }
    guard let root = packageRootURL() else { return nil }
    for c in [
      root.appendingPathComponent(".build/debug/sit"),
      root.appendingPathComponent(".build/release/sit"),
    ] where fm.isExecutableFile(atPath: c.path) {
      return c.standardizedFileURL
    }
    return nil
  }

  private static func packageRootURL() -> URL? {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
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

  private static func runGit(_ git: String, _ args: [String]) async throws -> (
    Int32, String, String
  ) {
    try await runCapturing(git, args)
  }

  private static func runSit(executable: String, workingDirectory: URL, arguments: [String])
    async throws -> (code: Int32, stdout: String, stderr: String)
  {
    let record = try await Subprocess.run(
      .name(executable),
      arguments: Arguments(arguments),
      workingDirectory: FilePath(workingDirectory.path),
      output: .string(limit: Int.max),
      error: .string(limit: Int.max))
    return (
      record.terminationStatus.isSuccess ? 0 : 1,
      record.standardOutput ?? "",
      record.standardError ?? ""
    )
  }

  private static func runCapturing(_ exe: String, _ args: [String]) async throws -> (
    Int32, String, String
  ) {
    let record = try await Subprocess.run(
      .name(exe),
      arguments: Arguments(args),
      output: .string(limit: Int.max),
      error: .string(limit: Int.max))
    return (
      record.terminationStatus.isSuccess ? 0 : 1,
      record.standardOutput ?? "",
      record.standardError ?? ""
    )
  }
}
