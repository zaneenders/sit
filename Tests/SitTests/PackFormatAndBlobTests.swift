import Foundation
import Testing

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct PackFormatAndBlobTests: ~Copyable {
  @Test func packIndexRejectsBadMagic() {
    let junk = [UInt8](repeating: 0, count: 2048)
    #expect(throws: GitPackError.badIndexMagic) {
      _ = try PackIndexV2.parse(bytes: junk)
    }
  }

  @Test func packIndexRejectsUnsupportedVersion() throws {
    let (_, idx) = try Self.loadSitPack()
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
    let (pack, idx) = try Self.loadSitPack()
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
    let (pack, idx) = try Self.loadSitPack()
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
    let (pack, idx) = try Self.loadSitPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let missing = [UInt8](repeating: 0xab, count: 20)
    #expect(throws: GitPackError.shaNotFoundInIndex) {
      _ = try git.serializedObject(sha20: missing)
    }
  }

  // MARK: - More objects from dogfood pack (verify-pack corpus)

  @Test func readsSecondOfsDeltaBlobFromPackfile() async throws {
    try await Self.assertPackBlobMatchesGit(
      "84d55bd7c2dc77ead3b1043d8e33f43ed8d1567b"
    )
  }

  @Test func readsTinyOfsDeltaBlobFromPackfile() async throws {
    try await Self.assertPackBlobMatchesGit(
      "e42418b39e4e69cf8facb72c1da091490310073e"
    )
  }

  @Test func readsOfsDeltaTreeFromPackfile() async throws {
    try await Self.assertPackObjectMatchesGit(
      type: "tree",
      sha: "6d067e8e3edc807aa2b8ae7a4c1ac858ae047fe6"
    )
  }

  @Test func readsLargeUndeltifiedBlobFromPackfile() async throws {
    try await Self.assertPackBlobMatchesGit(
      "2bd5af0a91af49ea8665c468f74199e2009bf0e4"
    )
  }

  @Test func readsAnotherCommitFromPackfile() async throws {
    try await Self.assertPackObjectMatchesGit(
      type: "commit",
      sha: "585b8e26bee7b4228f06a8c94b0352463852c29d"
    )
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
    let root = GitDogfoodHelpers.packageRoot(testFile: #filePath)
    let tips = await GitDogfoodHelpers.gitLocalBranchTipCommitShas(packageRoot: root)
    guard !tips.isEmpty else {
      Issue.record("skip: no local refs/heads tips")
      return
    }
    let (pack, idx) = try Self.loadSitPack()
    let gitPack = try GitPack(packBytes: pack, indexBytes: idx)
    var checked = 0
    for sha in tips {
      guard let shaBytes = GitDogfoodHelpers.sha20(fromHex40: sha) else { continue }
      guard gitPack.index.offset(for: shaBytes) != nil else { continue }
      let got = try gitPack.serializedObject(sha20: shaBytes)
      guard let want = await GitDogfoodHelpers.gitCatFileRaw(packageRoot: root, type: "commit", sha: sha) else {
        Issue.record("skip: git cat-file commit \(sha)")
        return
      }
      #expect(Array(got) == Array(want))
      checked += 1
    }
    guard checked > 0 else {
      Issue.record("skip: no branch tips present in pack fixture idx")
      return
    }
  }

  // MARK: - helpers

  private static func packageRoot() -> URL {
    GitDogfoodHelpers.packageRoot(testFile: #filePath)
  }

  private static func loadSitPack() throws -> (pack: [UInt8], idx: [UInt8]) {
    let root = packageRoot()
    let packDir = root.appendingPathComponent(".git/objects/pack", isDirectory: true)
    let fm = FileManager.default
    guard
      let packName = try fm.contentsOfDirectory(atPath: packDir.path)
        .first(where: { $0.hasSuffix(".pack") })?
        .replacingOccurrences(of: ".pack", with: "")
    else {
      throw GitPackError.badPackSignature  // no pack found
    }
    let packURL = packDir.appendingPathComponent("\(packName).pack")
    let idxURL = packDir.appendingPathComponent("\(packName).idx")
    let pack = try [UInt8](Data(contentsOf: packURL))
    let idx = try [UInt8](Data(contentsOf: idxURL))
    return (pack, idx)
  }

  private static func sha20(_ hex: String) -> [UInt8] {
    guard let b = GitDogfoodHelpers.sha20(fromHex40: hex) else {
      preconditionFailure("bad test SHA \(hex)")
    }
    return b
  }

  private static func assertPackBlobMatchesGit(_ hex40: String) async throws {
    try await assertPackObjectMatchesGit(type: "blob", sha: hex40)
  }

  private static func assertPackObjectMatchesGit(type: String, sha: String) async throws {
    let root = packageRoot()
    let (pack, idx) = try loadSitPack()
    let gitPack = try GitPack(packBytes: pack, indexBytes: idx)
    let got = try gitPack.serializedObject(sha20: sha20(sha))
    guard let want = await GitDogfoodHelpers.gitCatFileRaw(packageRoot: root, type: type, sha: sha) else {
      Issue.record("skip: git cat-file \(type) \(sha)")
      return
    }
    #expect(Array(got) == Array(want))
  }
}
