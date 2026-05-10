import Foundation
import Testing
import Subprocess

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct SitTests: ~Copyable {
  @Test func deflateStoredRoundTripsViaSitInflate() throws {
    let plain = Array("hello world".utf8)
    let deflated = try DeflateCompress.compressStored(plain)
    let got = try DeflateInflate.inflate(deflated)
    #expect(Array(got) == plain)
  }

  @Test func deflateStoredEmptyRoundTrips() throws {
    let deflated = try DeflateCompress.compressStored([])
    let got = try DeflateInflate.inflate(deflated)
    #expect(got.isEmpty)
  }

  @Test func deflateStoredSpansMultipleBlocks() throws {
    let plain = [UInt8](repeating: 0xab, count: 70_000)
    let deflated = try DeflateCompress.compressStored(plain)
    let got = try DeflateInflate.inflate(deflated)
    #expect(Array(got) == plain)
  }

  @Test func zlibCompressDecompressRoundTripSitOnly() throws {
    let plain = Array("blob 5\0hello".utf8)
    let zlib = try ZlibLooseObject.compress(plain)
    let back = try ZlibLooseObject.decompress(Array(zlib))
    #expect(Array(back) == plain)
  }

  @Test func dogfoodAllReachableObjectsZlibSitRoundTrip() async throws {
    let root = GitDogfoodHelpers.packageRoot(testFile: #filePath)
    let shas = await GitDogfoodHelpers.gitRevListUniqueShas40(packageRoot: root)
    guard !shas.isEmpty else {
      Issue.record("skip dogfood: no SHAs from git rev-list (not a git checkout?)")
      return
    }
    guard let batch = await GitDogfoodHelpers.gitCatFileBatchRaw(packageRoot: root, shas: shas) else {
      Issue.record("skip dogfood: git cat-file --batch failed")
      return
    }
    let allowed = Set(["blob", "tree", "commit", "tag"])
    for (_, type, raw) in batch {
      guard allowed.contains(type) else { continue }
      let z = try ZlibLooseObject.compress([UInt8](raw))
      let back = try ZlibLooseObject.decompress(Array(z))
      #expect(back.elementsEqual(raw))
    }
  }

  @Test func dogfoodAllReachableObjectsZlibPythonDecompress() async throws {
    try GitDogfoodHelpers.requirePython3ForDogfood()
    let root = GitDogfoodHelpers.packageRoot(testFile: #filePath)
    let shas = await GitDogfoodHelpers.gitRevListUniqueShas40(packageRoot: root)
    guard !shas.isEmpty else {
      Issue.record("skip dogfood: no SHAs from git rev-list")
      return
    }
    guard let batch = await GitDogfoodHelpers.gitCatFileBatchRaw(packageRoot: root, shas: shas) else {
      Issue.record("skip dogfood: git cat-file --batch failed")
      return
    }
    let allowed = Set(["blob", "tree", "commit", "tag"])
    for (_, type, raw) in batch {
      guard allowed.contains(type) else { continue }
      let swiftZlib = try ZlibLooseObject.compress([UInt8](raw))
      let pyPlain = try await GitDogfoodHelpers.zlibDecompressViaPythonRequired(Data(swiftZlib))
      #expect(pyPlain == raw)
    }
  }

  @Test func dogfoodEveryHeadTreeBlobAsLooseObjectZlibPython() async throws {
    try GitDogfoodHelpers.requirePython3ForDogfood()
    let root = GitDogfoodHelpers.packageRoot(testFile: #filePath)
    let rows = await GitDogfoodHelpers.gitLsTreeRecursive(packageRoot: root)
    guard !rows.isEmpty else {
      Issue.record("skip dogfood: git ls-tree empty (not a git checkout?)")
      return
    }
    for (_, type, sha, _) in rows where type == "blob" {
      guard let body = await GitDogfoodHelpers.gitCatFileRaw(packageRoot: root, type: "blob", sha: sha) else {
        Issue.record("skip dogfood: git cat-file blob failed for \(sha)")
        return
      }
      var raw = Data()
      raw.append(contentsOf: "blob \(body.count)\0".utf8)
      raw.append(body)
      let swiftZlib = try ZlibLooseObject.compress([UInt8](raw))
      let pyPlain = try await GitDogfoodHelpers.zlibDecompressViaPythonRequired(Data(swiftZlib))
      #expect(pyPlain == raw)
    }
  }

  @Test func dogfoodSwiftZlibDecompressedByPythonMatchesGitBlob() async throws {
    try GitDogfoodHelpers.requirePython3ForDogfood()
    let packageRoot = Self.packageRoot()
    guard let sha = await Self.gitRevParse(packageRoot: packageRoot, rev: "HEAD:Package.swift"),
      let fileBytes = await Self.gitCatFileBlob(packageRoot: packageRoot, object: sha)
    else {
      Issue.record("skip dogfood: git rev-parse / cat-file failed (not a git checkout?)")
      return
    }
    let header = Data("blob \(fileBytes.count)\0".utf8)
    let rawObject = header + fileBytes
    let swiftZlib = try ZlibLooseObject.compress([UInt8](rawObject))
    let pyPlain = try await GitDogfoodHelpers.zlibDecompressViaPythonRequired(Data(swiftZlib))
    #expect(pyPlain == rawObject)
  }

  @Test func zlibDecompressesSyntheticLooseObject() throws {
    let zlibBlob: [UInt8] = [
      0x78, 0x9c, 0x4b, 0xca, 0xc9, 0x4f, 0x52, 0x30, 0x65,
      0xc8, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x19, 0xaa, 0x04, 0x09,
    ]
    let plain = try ZlibLooseObject.decompress(zlibBlob)
    let blob = try ParsedGitBlob(decodedLooseObjectBytes: plain)
    #expect(blob.declaredSize == 5)
    #expect(Array(blob.payload) == Array("hello".utf8))
  }

  @Test func zlibDecompressesHelloWorldBlob() throws {
    let zlibBlob: [UInt8] = [
      0x78, 0x9c, 0x4b, 0xca, 0xc9, 0x4f, 0x52, 0x30, 0x34, 0x64, 0xc8, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28,
      0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x3d, 0x7b, 0x06, 0x7e,
    ]
    let plain = try ZlibLooseObject.decompress(zlibBlob)
    let blob = try ParsedGitBlob(decodedLooseObjectBytes: plain)
    #expect(blob.declaredSize == 11)
    #expect(Array(blob.payload) == Array("hello world".utf8))
  }

  @Test func dogfoodPackageSwiftAsGitBlobRoundTrip() async throws {
    try GitDogfoodHelpers.requirePython3ForDogfood()
    let packageRoot = Self.packageRoot()
    let packageSwift = packageRoot.appendingPathComponent("Package.swift")
    guard FileManager.default.fileExists(atPath: packageSwift.path) else {
      Issue.record("skip dogfood: Package.swift not found at \(packageSwift.path)")
      return
    }
    let fileData = try Data(contentsOf: packageSwift)
    let header = Data("blob \(fileData.count)\0".utf8)
    let rawObject = header + fileData
    let zlibData = try await GitDogfoodHelpers.zlibCompressViaPythonRequired(rawObject)
    let inflated = try ZlibLooseObject.decompress([UInt8](zlibData))
    #expect(inflated.elementsEqual(rawObject))
    let parsed = try ParsedGitBlob(decodedLooseObjectBytes: inflated)
    #expect(parsed.declaredSize == fileData.count)
    #expect(Data(parsed.payload) == fileData)
  }

  @Test func dogfoodMatchesGitCatFileBlob() async throws {
    try GitDogfoodHelpers.requirePython3ForDogfood()
    let packageRoot = Self.packageRoot()
    guard let sha = await Self.gitRevParse(packageRoot: packageRoot, rev: "HEAD:Package.swift"),
      let fileBytes = await Self.gitCatFileBlob(packageRoot: packageRoot, object: sha)
    else {
      Issue.record("skip dogfood: git rev-parse / cat-file failed (not a git checkout?)")
      return
    }
    let header = Data("blob \(fileBytes.count)\0".utf8)
    let rawObject = header + fileBytes
    let zlibData = try await GitDogfoodHelpers.zlibCompressViaPythonRequired(rawObject)
    let inflated = try ZlibLooseObject.decompress([UInt8](zlibData))
    #expect(inflated.elementsEqual(rawObject))
  }

  @Test func parsesZlibWrappedBlobObjectPrefix() throws {
    let zlibBlob: [UInt8] = [
      0x78, 0x9c, 0x4b, 0xca, 0xc9, 0x4f, 0x52, 0x30, 0x65,
      0xc8, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x19, 0xaa, 0x04, 0x09,
    ]
    let zlibHeader = try ZlibHeader(parsingCompressedBytes: zlibBlob)
    #expect(zlibHeader.header.compressionMethod == 0x78)
    #expect(zlibHeader.header.flags == 0x9c)
    #expect(zlibHeader.firstBlockIsBFinal)
    #expect(zlibHeader.firstBlockType == .fixedCompression)
  }

  @Test func blockBegin() throws {
    var (isBFINAL, bType) = try Sit.blockBegin(value: 0)
    #expect(!isBFINAL)
    #expect(bType == .notCompressed)
    (isBFINAL, bType) = try Sit.blockBegin(value: 1)
    #expect(isBFINAL)
    #expect(bType == .notCompressed)
    (isBFINAL, bType) = try Sit.blockBegin(value: 2)
    #expect(!isBFINAL)
    #expect(bType == .fixedCompression)
    (isBFINAL, bType) = try Sit.blockBegin(value: 3)
    #expect(isBFINAL)
    #expect(bType == .fixedCompression)
    (isBFINAL, bType) = try Sit.blockBegin(value: 4)
    #expect(!isBFINAL)
    #expect(bType == .dynamicCompression)
    (isBFINAL, bType) = try Sit.blockBegin(value: 5)
    #expect(isBFINAL)
    #expect(bType == .dynamicCompression)
    #expect(throws: ZlibHeaderError.blockError("reserved BTYPE")) {
      _ = try Sit.blockBegin(value: 6)
    }
    #expect(throws: ZlibHeaderError.blockError("reserved BTYPE")) {
      _ = try Sit.blockBegin(value: 7)
    }
  }

  // MARK: - Helpers

  private static func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func gitRevParse(packageRoot: URL, rev: String) async -> String? {
    guard let git = Self.gitExecutable() else { return nil }
    do {
      let record = try await Subprocess.run(
        .name(git),
        arguments: Arguments(["-C", packageRoot.path, "rev-parse", rev]),
        output: .string(limit: Int.max),
        error: .discarded
      )
      guard record.terminationStatus.isSuccess, let s = record.standardOutput else { return nil }
      let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    } catch {
      return nil
    }
  }

  private static func gitExecutable() -> String? {
    for p in ["/usr/bin/git", "/bin/git", "/usr/local/bin/git"] {
      if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
  }

  private static func gitCatFileBlob(packageRoot: URL, object: String) async -> Data? {
    guard let git = Self.gitExecutable() else { return nil }
    do {
      let record = try await Subprocess.run(
        .name(git),
        arguments: Arguments(["-C", packageRoot.path, "cat-file", "blob", object]),
        output: .bytes(limit: Int.max),
        error: .discarded
      )
      guard record.terminationStatus.isSuccess, !record.standardOutput.isEmpty else { return nil }
      return Data(record.standardOutput)
    } catch {
      return nil
    }
  }

  // Quick size sanity check: Huffman beats stored significantly for repetitive data
  @Test func huffmanCompressesBetterThanStored() throws {
    let repetitive = [UInt8](repeating: UInt8(ascii: "A"), count: 400)
    let stored = try DeflateCompress.compressStored(repetitive)
    let fixed = try DeflateCompress.compressFixed(repetitive)
    let chosen = try DeflateCompress.compress(repetitive)
    // Fixed Huffman with LZ77 should be drastically smaller than stored
    #expect(fixed.count < stored.count / 5)
    // The chosen compression should be at least as good as fixed
    #expect(chosen.count <= fixed.count)
    // Should decompress correctly
    let roundtrip = try DeflateInflate.inflate(chosen)
    #expect(Array(roundtrip) == repetitive)
  }
}
