import Foundation
import Testing

@testable import Sit

@Suite
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

  // MARK: - More objects from pack-58dfe777… (verify-pack corpus)

  @Test func readsSecondOfsDeltaBlobFromPackfile() throws {
    try Self.assertPackBlobMatchesGit(
      "8ac869349a2a5a9cee73136d3f283966ade4377f"
    )
  }

  @Test func readsTinyOfsDeltaBlobFromPackfile() throws {
    try Self.assertPackBlobMatchesGit(
      "01ce9042fe2a5132f646fd896bb9ac657519cff2"
    )
  }

  @Test func readsOfsDeltaTreeFromPackfile() throws {
    try Self.assertPackObjectMatchesGit(
      type: "tree",
      sha: "ea9e62b9a09637b62470f0a8760d1f99a616aa6b"
    )
  }

  @Test func readsLargeUndeltifiedBlobFromPackfile() throws {
    try Self.assertPackBlobMatchesGit(
      "208e1f03013314fa2da02866da74d5ff0452a554"
    )
  }

  @Test func readsAnotherCommitFromPackfile() throws {
    try Self.assertPackObjectMatchesGit(
      type: "commit",
      sha: "dbc7a7efcab0551800aff9f61daa88afd40047df"
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

  @Test func sitZlibAdlerMatchesPythonForSeveralPayloads() throws {
    try GitDogfoodHelpers.requirePython3ForDogfood()
    let samples: [Data] = [
      Data(),
      Data("abc".utf8),
      Data(repeating: 0x5a, count: 5555),
    ]
    for sample in samples {
      let z = try ZlibLooseObject.compress([UInt8](sample))
      let pyAdler = try GitDogfoodHelpers.zlibAdler32ViaPythonRequired(sample)
      let storedBE =
        UInt32(z[z.count - 4]) << 24
          | UInt32(z[z.count - 3]) << 16
          | UInt32(z[z.count - 2]) << 8
          | UInt32(z[z.count - 1])
      #expect(storedBE == pyAdler)
    }
  }

  @Test func packMatchesGitForEachLocalBranchTipCommit() throws {
    let root = GitDogfoodHelpers.packageRoot(testFile: #filePath)
    let tips = GitDogfoodHelpers.gitLocalBranchTipCommitShas(packageRoot: root)
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
      guard let want = GitDogfoodHelpers.gitCatFileRaw(packageRoot: root, type: "commit", sha: sha) else {
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
    let packURL = root.appendingPathComponent(
      ".git/objects/pack/pack-58dfe777b898c1d6dd7b1c2e34747a7b562be6e5.pack")
    let idxURL = root.appendingPathComponent(
      ".git/objects/pack/pack-58dfe777b898c1d6dd7b1c2e34747a7b562be6e5.idx")
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

  private static func assertPackBlobMatchesGit(_ hex40: String) throws {
    try assertPackObjectMatchesGit(type: "blob", sha: hex40)
  }

  private static func assertPackObjectMatchesGit(type: String, sha: String) throws {
    let root = packageRoot()
    let (pack, idx) = try loadSitPack()
    let gitPack = try GitPack(packBytes: pack, indexBytes: idx)
    let got = try gitPack.serializedObject(sha20: sha20(sha))
    guard let want = GitDogfoodHelpers.gitCatFileRaw(packageRoot: root, type: type, sha: sha) else {
      Issue.record("skip: git cat-file \(type) \(sha)")
      return
    }
    #expect(Array(got) == Array(want))
  }
}
