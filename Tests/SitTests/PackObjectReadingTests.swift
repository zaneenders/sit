import Foundation
import Subprocess
import Testing

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct PackObjectReadingTests: ~Copyable {
  // MARK: - Undeltified objects from synthetic pack

  @Test func readsUndeltifiedBlobFromPackfile() throws {
    let (pack, idx, blobHex) = try Self.singleBlobPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let sha = try GitHex.decode20(blobHex)
    let got = try git.serializedObject(sha20: sha)
    // Pack stores payload only — "hello\n" without the loose-object header
    #expect(Array(got) == Array("hello\n".utf8))
  }

  @Test func readsUndeltifiedCommitFromPackfile() throws {
    let (pack, idx, _, treeHex, commitHex) = try Self.multiObjectPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let sha = try GitHex.decode20(commitHex)
    let got = try git.serializedObject(sha20: sha)
    let gotStr = String(decoding: got, as: UTF8.self)
    // Pack stores payload only (no loose-object "commit N\0" header)
    #expect(gotStr.hasPrefix("tree \(treeHex)"))
    #expect(gotStr.contains("author T"))
  }

  @Test func readsTreeFromPackfile() throws {
    let (pack, idx, _, treeHex, _) = try Self.multiObjectPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let sha = try GitHex.decode20(treeHex)
    let got = try git.serializedObject(sha20: sha)
    let gotArr = Array(got)
    #expect(gotArr.count >= 20)
    let treeStr = String(decoding: gotArr, as: UTF8.self)
    #expect(treeStr.contains("f.txt"))
  }

  // MARK: - Delta objects from shared git-generated pack (generated once)

  @Test func readsOfsDeltaBlobFromPackfile() async throws {
    let generated = try await Self.gitGeneratedPack()
    let blob = generated.shuffledSHAs.first(where: { $0.type == "blob" })
    guard let blob else {
      Issue.record("skip: no blob in git-generated pack")
      return
    }
    let gitPack = try GitPack(packBytes: generated.pack, indexBytes: generated.idx)
    let sha20 = try GitHex.decode20(blob.sha)
    let got = try gitPack.serializedObject(sha20: sha20)
    guard
      let want = await GitDogfoodHelpers.gitCatFileRaw(
        packageRoot: generated.repoRoot, type: "blob", sha: blob.sha)
    else {
      Issue.record("skip: git cat-file blob \(blob.sha) failed")
      return
    }
    #expect(Array(got) == Array(want))
  }

  @Test func readsEveryIndexedReachableObjectInSitPackMatchesGitCatFile() async throws {
    let generated = try await Self.gitGeneratedPack()
    let gitPack = try GitPack(packBytes: generated.pack, indexBytes: generated.idx)
    var matched = 0
    for (sha, type) in generated.shuffledSHAs {
      guard ["blob", "tree", "commit", "tag"].contains(type) else { continue }
      guard let shaBytes = GitDogfoodHelpers.sha20(fromHex40: sha) else { continue }
      guard gitPack.index.offset(for: shaBytes) != nil else { continue }
      let got = try gitPack.serializedObject(sha20: shaBytes)
      guard
        let want = await GitDogfoodHelpers.gitCatFileRaw(
          packageRoot: generated.repoRoot, type: type, sha: sha)
      else {
        Issue.record("skip: git cat-file \(type) \(sha) failed")
        return
      }
      #expect(Array(got) == Array(want))
      matched += 1
    }
    guard matched > 0 else {
      Issue.record("skip: no matching objects between pack index and git cat-file")
      return
    }
  }

  // MARK: - Helpers

  private static func singleBlobPack() throws -> (pack: [UInt8], idx: [UInt8], blobHex: String) {
    let blobContent: [UInt8] = Array("hello\n".utf8)
    let body: [UInt8] = Array("blob \(blobContent.count)\0".utf8) + blobContent
    let sha20 = GitSHA1.digest(of: body)
    let hex = GitHex.encodeLower(sha20)
    let obj = GitPackWriter.PackObject(sha20: sha20, type: 3, payload: blobContent)
    let result = try GitPackWriter.write(objects: [obj])
    return (result.packData, result.indexData, hex)
  }

  private static func multiObjectPack() throws -> (
    pack: [UInt8], idx: [UInt8],
    blobHex: String, treeHex: String, commitHex: String
  ) {
    let blobContent: [UInt8] = Array("hello\n".utf8)
    let blobBody: [UInt8] = Array("blob \(blobContent.count)\0".utf8) + blobContent
    let blobSHA = GitSHA1.digest(of: blobBody)
    let blobHex = GitHex.encodeLower(blobSHA)

    let treePayload = Array("100644 f.txt\0".utf8) + blobSHA
    let treeBody: [UInt8] = Array("tree \(treePayload.count)\0".utf8) + treePayload
    let treeSHA = GitSHA1.digest(of: treeBody)
    let treeHex = GitHex.encodeLower(treeSHA)

    let commitPayload = Array(
      "tree \(treeHex)\nauthor T <t@t> 0 +0000\ncommitter T <t@t> 0 +0000\n\nmsg\n".utf8)
    let commitBody: [UInt8] = Array("commit \(commitPayload.count)\0".utf8) + commitPayload
    let commitSHA = GitSHA1.digest(of: commitBody)
    let commitHex = GitHex.encodeLower(commitSHA)

    let objects: [GitPackWriter.PackObject] = [
      GitPackWriter.PackObject(sha20: blobSHA, type: 3, payload: blobContent),
      GitPackWriter.PackObject(sha20: treeSHA, type: 2, payload: treePayload),
      GitPackWriter.PackObject(sha20: commitSHA, type: 1, payload: commitPayload),
    ]
    let result = try GitPackWriter.write(objects: objects)
    return (result.packData, result.indexData, blobHex, treeHex, commitHex)
  }

  /// Cached result of generating a git pack via `git repack`. Generated once;
  /// all delta-reading tests share the same pack to avoid concurrent subprocess
  /// spawning on Linux.
  private struct GeneratedPack: Sendable {
    let pack: [UInt8]
    let idx: [UInt8]
    let repoRoot: URL
    /// Shuffled list of (sha40, type) to avoid any order-dependent bias.
    let shuffledSHAs: [(sha: String, type: String)]
  }

  private nonisolated(unsafe) static var _cachedGeneratedPack: GeneratedPack? = nil

  private static func gitGeneratedPack() async throws -> GeneratedPack {
    if let cached = _cachedGeneratedPack { return cached }
    guard let gitPath = GitDogfoodHelpers.gitExecutable() else {
      Issue.record("skip: git not on PATH")
      throw GitPackError.badPackSignature
    }
    // Use a persistent temp dir so the repo survives for git cat-file lookups.
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("sit-test-pack-\(UUID().uuidString.prefix(8))")
    // We don't use TempDirectory because we need the dir to survive.
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let repo = tmpDir.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    _ = try await runGit(gitPath, ["-C", repo.path, "init", "-b", "main"])
    _ = try await runGit(
      gitPath,
      [
        "-c", "user.name=T", "-c", "user.email=t@t", "-C", repo.path,
        "commit", "--allow-empty", "-m", "first",
      ])
    try Data("hello\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
    _ = try await runGit(gitPath, ["-C", repo.path, "add", "a.txt"])
    _ = try await runGit(
      gitPath,
      [
        "-c", "user.name=T", "-c", "user.email=t@t", "-C", repo.path,
        "commit", "-m", "second",
      ])
    try Data("hello world\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
    _ = try await runGit(gitPath, ["-C", repo.path, "add", "a.txt"])
    _ = try await runGit(
      gitPath,
      [
        "-c", "user.name=T", "-c", "user.email=t@t", "-C", repo.path,
        "commit", "-m", "third",
      ])
    _ = try await runGit(gitPath, ["-C", repo.path, "repack", "-ad"])

    let packDir = repo.appendingPathComponent(".git/objects/pack", isDirectory: true)
    let fm = FileManager.default
    guard
      let packName = try fm.contentsOfDirectory(atPath: packDir.path)
        .first(where: { $0.hasSuffix(".pack") })?
        .replacingOccurrences(of: ".pack", with: "")
    else {
      Issue.record("skip: repack produced no pack")
      throw GitPackError.badPackSignature
    }
    let packURL = packDir.appendingPathComponent("\(packName).pack")
    let idxURL = packDir.appendingPathComponent("\(packName).idx")
    let pack = try [UInt8](Data(contentsOf: packURL))
    let idx = try [UInt8](Data(contentsOf: idxURL))

    let lines = await GitDogfoodHelpers.gitRevListUniqueShas40(packageRoot: repo)
    var shas: [(sha: String, type: String)] = []
    if let batch = await GitDogfoodHelpers.gitCatFileBatchRaw(packageRoot: repo, shas: lines) {
      for (sha, type, _) in batch {
        shas.append((sha, type))
      }
    }
    guard !shas.isEmpty else {
      Issue.record("skip: no objects in generated pack")
      throw GitPackError.badPackSignature
    }
    let result = GeneratedPack(pack: pack, idx: idx, repoRoot: repo, shuffledSHAs: shas.shuffled())
    _cachedGeneratedPack = result
    return result
  }

  private static func runGit(_ git: String, _ args: [String]) async throws -> (Int32, String, String) {
    let record: ExecutionRecord<StringOutput, DiscardedOutput> = try await Subprocess.run(
      .name(git),
      arguments: Arguments(args),
      output: .string(limit: Int.max),
      error: .discarded)
    return (
      record.terminationStatus.isSuccess ? 0 : 1,
      record.standardOutput ?? "",
      ""
    )
  }
}
