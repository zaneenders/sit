import Foundation
import Subprocess
import Testing

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct PackFormatAndBlobTests: ~Copyable {
  // MARK: - Index / Pack rejection (synthetic pack)

  @Test func packIndexRejectsBadMagic() {
    let junk = [UInt8](repeating: 0, count: 2048)
    #expect(throws: GitPackError.badIndexMagic) {
      _ = try PackIndexV2.parse(bytes: junk)
    }
  }

  @Test func packIndexRejectsUnsupportedVersion() throws {
    let (_, idx) = try Self.syntheticPack()
    var bytes = idx
    guard bytes.count >= 8 else { return }
    bytes[4] = 0
    bytes[5] = 0
    bytes[6] = 0
    bytes[7] = 9
    #expect(throws: GitPackError.unsupportedIndexVersion(9)) {
      _ = try PackIndexV2.parse(bytes: bytes)
    }
  }

  @Test func gitPackRejectsBadSignature() throws {
    let (pack, idx) = try Self.syntheticPack()
    var bad = pack
    bad[0] = 0
    bad[1] = 0
    bad[2] = 0
    bad[3] = 0
    #expect(throws: GitPackError.badPackSignature) {
      _ = try GitPack(packBytes: bad, indexBytes: idx)
    }
  }

  @Test func gitPackRejectsUnknownVersion() throws {
    let (pack, idx) = try Self.syntheticPack()
    var bad = pack
    guard bad.count >= 8 else { return }
    bad[4] = 0
    bad[5] = 0
    bad[6] = 0
    bad[7] = 3
    #expect(throws: GitPackError.unknownPackVersion(3)) {
      _ = try GitPack(packBytes: bad, indexBytes: idx)
    }
  }

  @Test func gitPackShaNotInIndexThrows() throws {
    let (pack, idx) = try Self.syntheticPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let missing = [UInt8](repeating: 0xab, count: 20)
    #expect(throws: GitPackError.shaNotFoundInIndex) {
      _ = try git.serializedObject(sha20: missing)
    }
  }

  // MARK: - Read undeltified objects from synthetic pack

  @Test func readsLargeUndeltifiedBlobFromPackfile() throws {
    let blobContent = [UInt8](repeating: 0x5a, count: 10_000)  // 10 KB blob
    let body: [UInt8] = Array("blob \(blobContent.count)\0".utf8) + blobContent
    let sha20 = GitSHA1.digest(of: body)
    let obj = GitPackWriter.PackObject(sha20: sha20, type: 3, payload: blobContent)
    let result = try GitPackWriter.write(objects: [obj])
    let gitPack = try GitPack(packBytes: result.packData, indexBytes: result.indexData)
    let got = try gitPack.serializedObject(sha20: sha20)
    // Pack stores payload only (no loose-object header)
    #expect(Array(got) == blobContent)
  }

  @Test func readsAnotherCommitFromPackfile() throws {
    let (pack, idx, _, treeHex, commitHex) = try Self.multiObjectPack()
    let gitPack = try GitPack(packBytes: pack, indexBytes: idx)

    let commitSHA = try GitHex.decode20(commitHex)
    let got = try gitPack.serializedObject(sha20: commitSHA)
    let gotStr = String(decoding: got, as: UTF8.self)
    #expect(gotStr.hasPrefix("tree \(treeHex)"))
    #expect(gotStr.contains("author "))
    #expect(gotStr.contains("committer "))
  }

  // MARK: - Delta objects from shared git-generated pack (generated once)

  @Test func readsTinyOfsDeltaBlobFromPackfile() async throws {
    let generated = try await Self.gitGeneratedPack()
    guard let deltaBlob = generated.shuffledSHAs.first(where: { $0.type == "blob" }) else {
      Issue.record("skip: no blob in git-generated pack")
      return
    }
    let gitPack = try GitPack(packBytes: generated.pack, indexBytes: generated.idx)
    let sha20 = try GitHex.decode20(deltaBlob.sha)
    let got = try gitPack.serializedObject(sha20: sha20)
    guard
      let want = await GitDogfoodHelpers.gitCatFileRaw(
        packageRoot: generated.repoRoot, type: "blob", sha: deltaBlob.sha)
    else {
      Issue.record("skip: git cat-file blob \(deltaBlob.sha) failed")
      return
    }
    #expect(Array(got) == Array(want))
  }

  @Test func readsSecondOfsDeltaBlobFromPackfile() async throws {
    let generated = try await Self.gitGeneratedPack()
    let blobs = generated.shuffledSHAs.filter { $0.type == "blob" }
    guard blobs.count >= 2 else {
      Issue.record("skip: need 2+ blobs, got \(blobs.count)")
      return
    }
    let gitPack = try GitPack(packBytes: generated.pack, indexBytes: generated.idx)
    let second = blobs[1]
    let sha20 = try GitHex.decode20(second.sha)
    let got = try gitPack.serializedObject(sha20: sha20)
    guard
      let want = await GitDogfoodHelpers.gitCatFileRaw(
        packageRoot: generated.repoRoot, type: "blob", sha: second.sha)
    else {
      Issue.record("skip: git cat-file blob \(second.sha)")
      return
    }
    #expect(Array(got) == Array(want))
  }

  @Test func readsOfsDeltaTreeFromPackfile() async throws {
    let generated = try await Self.gitGeneratedPack()
    guard let tree = generated.shuffledSHAs.first(where: { $0.type == "tree" }) else {
      Issue.record("skip: no tree in git-generated pack")
      return
    }
    let gitPack = try GitPack(packBytes: generated.pack, indexBytes: generated.idx)
    let sha20 = try GitHex.decode20(tree.sha)
    let got = try gitPack.serializedObject(sha20: sha20)
    guard
      let want = await GitDogfoodHelpers.gitCatFileRaw(
        packageRoot: generated.repoRoot, type: "tree", sha: tree.sha)
    else {
      Issue.record("skip: git cat-file tree \(tree.sha)")
      return
    }
    #expect(Array(got) == Array(want))
  }

  // MARK: - ParsedGitBlob

  @Test func parsedGitBlobRejectsWrongKind() {
    #expect(throws: GitBlobError.notABlob) {
      _ = try ParsedGitBlob(decodedLooseObjectBytes: Array("tree 12\0xxxx".utf8))
    }
  }

  @Test func parsedGitBlobRejectsMissingNul() {
    #expect(throws: GitBlobError.malformed("missing header nul")) {
      _ = try ParsedGitBlob(decodedLooseObjectBytes: Array("blob 3 abc".utf8))
    }
  }

  @Test func parsedGitBlobRejectsSizeMismatch() {
    #expect(throws: GitBlobError.sizeMismatch(declared: 2, actualPayload: 1)) {
      _ = try ParsedGitBlob(decodedLooseObjectBytes: Array("blob 2\0x".utf8))
    }
  }

  // MARK: - zlib prefix / Adler

  @Test func zlibDecompressPrefixConsumesFullSwiftZlibStream() throws {
    let plain = Array("blob 4\0abcd".utf8)
    let zlib = try ZlibLooseObject.compress(plain)
    let tail: [UInt8] = [0xde, 0xad, 0xbe, 0xef]
    let combined = Array(zlib) + tail
    let (out, consumed) = try ZlibLooseObject.decompressPrefix(in: combined, at: 0)
    #expect(Array(out) == plain)
    #expect(consumed == zlib.count)
    #expect(Array(combined[consumed...]) == tail)
  }

  @Test func sitZlibAdlerMatchesPythonForSeveralPayloads() async throws {
    try GitDogfoodHelpers.requirePython3ForDogfood()
    let samples: [Data] = [
      Data(),
      Data("abc".utf8),
      Data(repeating: 0x5a, count: 5555),
    ]
    for sample in samples {
      let z = try ZlibLooseObject.compress([UInt8](sample))
      let pyAdler = try await GitDogfoodHelpers.zlibAdler32ViaPythonRequired(sample)
      let storedBE =
        UInt32(z[z.count - 4]) << 24
        | UInt32(z[z.count - 3]) << 16
        | UInt32(z[z.count - 2]) << 8
        | UInt32(z[z.count - 1])
      #expect(storedBE == pyAdler)
    }
  }

  @Test func packMatchesGitForEachLocalBranchTipCommit() async throws {
    let generated = try await Self.gitGeneratedPack()
    let gitPack = try GitPack(packBytes: generated.pack, indexBytes: generated.idx)
    let commits = generated.shuffledSHAs.filter { $0.type == "commit" }
    guard !commits.isEmpty else {
      Issue.record("skip: no commits in generated pack")
      return
    }
    var checked = 0
    for (sha, _) in commits {
      guard let shaBytes = GitDogfoodHelpers.sha20(fromHex40: sha) else { continue }
      guard gitPack.index.offset(for: shaBytes) != nil else { continue }
      let got = try gitPack.serializedObject(sha20: shaBytes)
      guard let want = await GitDogfoodHelpers.gitCatFileRaw(packageRoot: generated.repoRoot, type: "commit", sha: sha)
      else {
        Issue.record("skip: git cat-file commit \(sha)")
        return
      }
      #expect(Array(got) == Array(want))
      checked += 1
    }
    guard checked > 0 else {
      Issue.record("skip: no commits found in pack index")
      return
    }
  }

  // MARK: - Helpers

  /// A small synthetic pack with a single blob — used for rejection/missing-SHA tests.
  private static func syntheticPack() throws -> (pack: [UInt8], idx: [UInt8]) {
    let blobContent: [UInt8] = [0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a]  // "hello\n"
    let body: [UInt8] = Array("blob \(blobContent.count)\0".utf8) + blobContent
    let sha20 = GitSHA1.digest(of: body)
    let obj = GitPackWriter.PackObject(sha20: sha20, type: 3, payload: blobContent)
    let result = try GitPackWriter.write(objects: [obj])
    return (result.packData, result.indexData)
  }

  /// A pack with blob + tree + commit (3 objects).
  private static func multiObjectPack() throws -> (
    pack: [UInt8], idx: [UInt8],
    blobHex: String, treeHex: String, commitHex: String
  ) {
    let blobContent: [UInt8] = Array("hello\n".utf8)
    let blobBody: [UInt8] = Array("blob \(blobContent.count)\0".utf8) + blobContent
    let blobSHA = GitSHA1.digest(of: blobBody)
    let blobHex = GitHex.encodeLower(blobSHA)

    let mode = "100644"
    let name = "f.txt"
    let treePayload = Array("\(mode) \(name)\0".utf8) + blobSHA
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
    let shuffledSHAs: [(sha: String, type: String)]
  }

  private nonisolated(unsafe) static var _cachedGeneratedPack: GeneratedPack? = nil

  private static func gitGeneratedPack() async throws -> GeneratedPack {
    if let cached = _cachedGeneratedPack { return cached }
    guard let gitPath = GitDogfoodHelpers.gitExecutable() else {
      Issue.record("skip: git not on PATH")
      throw GitPackError.badPackSignature
    }
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("sit-test-pack-\(UUID().uuidString.prefix(8))")
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
