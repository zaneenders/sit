import Foundation
import Testing

@testable import Sit

/// Tests targeting uncovered error paths and edge cases across the Sit library.
@Suite(.timeLimit(.minutes(1)))
struct CoverageEdgeTests: ~Copyable {

  // MARK: - ZlibHeader error paths

  @Test func zlibHeaderRejectsTruncatedHeader() {
    let empty: [UInt8] = []
    #expect(throws: ZlibHeaderError.message("truncated zlib header")) {
      _ = try ZlibHeader.Header(parsingCompressedBytes: empty)
    }
  }

  @Test func zlibHeaderRejectsOneByte() {
    let oneByte: [UInt8] = [0x78]
    #expect(throws: ZlibHeaderError.message("truncated zlib header")) {
      _ = try ZlibHeader.Header(parsingCompressedBytes: oneByte)
    }
  }

  @Test func zlibHeaderRejectsTruncatedStreamAfterHeader() {
    let twoBytes: [UInt8] = [0x78, 0x9c]
    #expect(
      throws: ZlibHeaderError.message(
        "truncated stream: expected deflate block prefix after zlib header")
    ) {
      _ = try ZlibHeader(parsingCompressedBytes: twoBytes)
    }
  }

  @Test func zlibHeaderRejectsInvalidCM() throws {
    // CM=7 (low nibble) is not deflate (8)
    var invalid: [UInt8] = [0x78, 0x9c, 0x00]
    // 0x77: CM=7, CINFO=7
    invalid[0] = 0x77
    #expect(
      throws: ZlibHeaderError.message(
        "Invalid zlib CM: RFC 1950 requires CM=8 (deflate), got 77 (CM=7)")
    ) {
      _ = try ZlibHeader(parsingCompressedBytes: invalid)
    }
  }

  @Test func zlibHeaderRejectsInvalidCINFO() throws {
    // CINFO must be ≤7. 0xf8 has CINFO=15 (upper nibble >> 4).
    var invalid: [UInt8] = [0xf8, 0x00, 0x00]
    // CM=8, CINFO=15.  Need a valid FCHECK: cmf*256+flg must be %31==0.
    // 0xf8 = 248. 248*256=63488. Need flg such that 63488+flg %31==0.
    // 63488 % 31 = 63488 - 31*2048 = 63488 - 63488 = 0. So flg must be multiple of 31 and have FDICT=0.
    // flg=0 works (0%31==0, FDICT=0).
    invalid[0] = 0xf8
    invalid[1] = 0x00
    invalid[2] = 0x00
    #expect(throws: ZlibHeaderError.message("Invalid zlib CINFO (window size): 15 > 7")) {
      _ = try ZlibHeader(parsingCompressedBytes: invalid)
    }
  }

  @Test func zlibHeaderRejectsBadFCHECK() throws {
    // Valid CM=8, CINFO=7 → 0x78.  0x78*256 = 30720. 30720 % 31 = 30.
    // For FCHECK to pass, need flg such that (30720+flg) % 31 == 0, so flg % 31 == 1.
    // flg=0x9c: 156. 156%31 = 1 ✓. Let's use flg that fails.
    // flg=0x00: 0. 30720%31=30 ≠ 0.
    let bytes: [UInt8] = [0x78, 0x00, 0x00]
    #expect(throws: ZlibHeaderError.message("Invalid zlib header checksum (FCHECK)")) {
      _ = try ZlibHeader(parsingCompressedBytes: bytes)
    }
  }

  @Test func zlibHeaderRejectsFDICT() throws {
    // FDICT is bit 5 (0x20) of FLG. Need valid CM/CINFO/FCHECK otherwise.
    // 0x78 (CM=8, CINFO=7). 0x78*256=30720. 30720%31=30. Need flg%31=1 and FDICT=1.
    // flg = 0x20 | 1 = 0x21 = 33. 33%31=2 ≠ 1.
    // Try flg = 0x20 | 0x20 = 0x40? No. Let's find flg where flg%31==1 and bit5 set.
    // 31*N + 1 with bit 5 set: N=1→32 (bit5 set) → flg=32=0x20. 0x20%31=1 ✓. FDICT=1.
    let bytes: [UInt8] = [0x78, 0x20, 0x00]
    #expect(throws: ZlibHeaderError.message("zlib preset dictionary (FDICT) is not supported")) {
      _ = try ZlibHeader(parsingCompressedBytes: bytes)
    }
  }

  @Test func blockBeginReservedBTYPE() {
    // value=6: btypeBits = (6 & 0b0110) >> 1 = (0b0110) >> 1 = 3
    #expect(throws: ZlibHeaderError.blockError("reserved BTYPE")) {
      _ = try blockBegin(value: 6)
    }
    // value=7: btypeBits = 3
    #expect(throws: ZlibHeaderError.blockError("reserved BTYPE")) {
      _ = try blockBegin(value: 7)
    }
  }

  // MARK: - GitHex error paths

  @Test func decode20RejectsWrongLength() {
    #expect(throws: GitObjectWriterError.badHexSha) {
      _ = try GitHex.decode20("abcd")
    }
    #expect(throws: GitObjectWriterError.badHexSha) {
      _ = try GitHex.decode20(String(repeating: "0", count: 41))
    }
  }

  @Test func decode20RejectsInvalidHex() {
    let invalid = String(repeating: "g", count: 40)  // 'g' is not hex
    #expect(throws: GitObjectWriterError.badHexSha) {
      _ = try GitHex.decode20(invalid)
    }
  }

  @Test func encodeLowerRoundTripsWithDecode20() throws {
    let sha: [UInt8] = (0..<20).map { UInt8($0) }
    let hex = GitHex.encodeLower(sha)
    #expect(hex.count == 40)
    let decoded = try GitHex.decode20(hex)
    #expect(decoded == sha)
  }

  // MARK: - GitHEAD detached path

  @Test func readKindDetachedHEAD() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      // Write a detached-HEAD SHA
      let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      try sha.write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
      let kind = try GitHEAD.readKind(gitDir: gitDir)
      guard case .detached(let s) = kind else {
        Issue.record("expected detached HEAD, got \(kind)")
        return
      }
      #expect(s == sha)
    }
  }

  @Test func resolveCommitHexDetached() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      try sha.write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
      let resolved = try GitHEAD.resolveCommitHex(gitDir: gitDir)
      #expect(resolved == sha)
    }
  }

  @Test func readKindRejectsInvalidDetachedLength() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try "abc".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
      #expect(throws: GitHEADError.unrecognized("abc")) {
        _ = try GitHEAD.readKind(gitDir: gitDir)
      }
    }
  }

  @Test func readKindRejectsInvalidDetachedHex() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      // 40 hex chars but invalid hex
      let bad = String(repeating: "g", count: 40)
      try bad.write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
      #expect(throws: GitObjectWriterError.badHexSha) {
        _ = try GitHEAD.readKind(gitDir: gitDir)
      }
    }
  }

  // MARK: - GitWorkTreeScan

  @Test func fileURLsMapsRelativePathsToURLs() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let paths: Set<String> = ["a.txt", "sub/b.txt"]
      let urls = GitWorkTreeScan.fileURLs(workTree: work, relativePaths: paths)
      #expect(urls.count == 2)
      #expect(urls.map { $0.lastPathComponent }.sorted() == ["a.txt", "b.txt"])
    }
  }

  @Test func relativePathThrowsForFileOutsideWorkTree() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let outside = root.appendingPathComponent("other.txt")
      try Data("x".utf8).write(to: outside)
      #expect(throws: GitIndexError.fileNotInWorkTree(outside.path)) {
        _ = try GitWorkTreeScan.relativePath(file: outside, workTree: work)
      }
    }
  }

  // MARK: - GitObjectDatabase parseLooseHeader error paths

  @Test func readObjectRejectsEmptyLooseFile() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      // Create a fake loose object that decompresses to empty
      let emptyZlib = try ZlibLooseObject.compress([])
      // We need it at a path that looks like a valid SHA
      let hex = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      let dir = String(hex.prefix(2))
      let leaf = String(hex.dropFirst(2))
      let objDir = gitDir.appendingPathComponent("objects/\(dir)", isDirectory: true)
      try FileManager.default.createDirectory(at: objDir, withIntermediateDirectories: true)
      try Data(emptyZlib).write(to: objDir.appendingPathComponent(leaf))
      let sha = try GitHex.decode20(hex)
      #expect(throws: GitObjectReadError.malformedLooseObject("empty")) {
        _ = try GitObjectDatabase.readObject(gitDir: gitDir, packs: [], sha20: sha)
      }
    }
  }

  @Test func readObjectRejectsLooseFileWithNoSpace() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      // Decompresses to "blob" (no space, no nul)
      let zlib = try ZlibLooseObject.compress(Array("blob".utf8))
      let hex = "cccccccccccccccccccccccccccccccccccccccc"
      let dir = String(hex.prefix(2))
      let leaf = String(hex.dropFirst(2))
      let objDir = gitDir.appendingPathComponent("objects/\(dir)", isDirectory: true)
      try FileManager.default.createDirectory(at: objDir, withIntermediateDirectories: true)
      try Data(zlib).write(to: objDir.appendingPathComponent(leaf))
      let sha = try GitHex.decode20(hex)
      #expect(throws: GitObjectReadError.malformedLooseObject("no space")) {
        _ = try GitObjectDatabase.readObject(gitDir: gitDir, packs: [], sha20: sha)
      }
    }
  }

  @Test func readObjectRejectsLooseFileWithNoNul() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      // "blob 5hello" — no NUL after size
      let zlib = try ZlibLooseObject.compress(Array("blob 5hello".utf8))
      let hex = "dddddddddddddddddddddddddddddddddddddddd"
      let dir = String(hex.prefix(2))
      let leaf = String(hex.dropFirst(2))
      let objDir = gitDir.appendingPathComponent("objects/\(dir)", isDirectory: true)
      try FileManager.default.createDirectory(at: objDir, withIntermediateDirectories: true)
      try Data(zlib).write(to: objDir.appendingPathComponent(leaf))
      let sha = try GitHex.decode20(hex)
      #expect(throws: GitObjectReadError.malformedLooseObject("no nul")) {
        _ = try GitObjectDatabase.readObject(gitDir: gitDir, packs: [], sha20: sha)
      }
    }
  }

  @Test func readObjectRejectsLooseFileWithNoSize() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      // "blob \0" — space then NUL, no size digits
      let zlib = try ZlibLooseObject.compress(Array("blob \0".utf8))
      let hex = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      let dir = String(hex.prefix(2))
      let leaf = String(hex.dropFirst(2))
      let objDir = gitDir.appendingPathComponent("objects/\(dir)", isDirectory: true)
      try FileManager.default.createDirectory(at: objDir, withIntermediateDirectories: true)
      try Data(zlib).write(to: objDir.appendingPathComponent(leaf))
      let sha = try GitHex.decode20(hex)
      #expect(throws: GitObjectReadError.malformedLooseObject("no size")) {
        _ = try GitObjectDatabase.readObject(gitDir: gitDir, packs: [], sha20: sha)
      }
    }
  }

  @Test func readObjectThrowsObjectNotFoundForUnknownSha() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      let sha = try GitHex.decode20("ffffffffffffffffffffffffffffffffffffffff")
      #expect(throws: GitObjectReadError.objectNotFound) {
        _ = try GitObjectDatabase.readObject(gitDir: gitDir, packs: [], sha20: sha)
      }
    }
  }

  // MARK: - GitPack.objectTypeAndPayload

  @Test func objectTypeAndPayloadReturnsType() throws {
    let (pack, idx) = try Self.syntheticPack()
    let gitPack = try GitPack(packBytes: pack, indexBytes: idx)
    // The synthetic pack contains a single blob "hello\n"
    let blobContent: [UInt8] = [0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a]
    let body: [UInt8] = Array("blob \(blobContent.count)\0".utf8) + blobContent
    let sha = GitSHA1.digest(of: body)
    let (type, payload) = try gitPack.objectTypeAndPayload(sha20: sha)
    #expect(type == 3)  // blob
    #expect(!payload.isEmpty)
  }

  // MARK: - PackDelta error paths

  @Test func packDeltaRejectsTruncatedDelta() throws {
    let base: [UInt8] = [1, 2, 3]
    let delta: [UInt8] = [0x80]  // too short (<4 bytes)
    #expect(throws: GitPackError.truncatedDelta) {
      _ = try PackDelta.apply(base: base, delta: delta)
    }
  }

  @Test func packDeltaRejectsBaseSizeMismatch() throws {
    let base: [UInt8] = [1, 2, 3]  // length 3
    // Delta claiming base size = 5 (first varint), result size = 0
    let delta: [UInt8] = [0x05, 0x00, 0x00, 0x00]
    #expect(throws: GitPackError.deltaBaseSizeMismatch) {
      _ = try PackDelta.apply(base: base, delta: delta)
    }
  }

  // MARK: - GitIgnore extra patterns

  @Test func doubleStarGlobMatchesAcrossDirectories() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try "a/**/b.txt\n".write(to: work.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
      let m = try GitIgnoreMatcher(workTree: work, gitDir: gitDir)
      #expect(m.isIgnored(relativePath: "a/x/b.txt", isDirectory: false))
      #expect(m.isIgnored(relativePath: "a/x/y/b.txt", isDirectory: false))
      #expect(!m.isIgnored(relativePath: "a/b.txt", isDirectory: false))
    }
  }

  @Test func questionMarkGlobMatchesSingleChar() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try "a?c.txt\n".write(to: work.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
      let m = try GitIgnoreMatcher(workTree: work, gitDir: gitDir)
      #expect(m.isIgnored(relativePath: "abc.txt", isDirectory: false))
      #expect(!m.isIgnored(relativePath: "ac.txt", isDirectory: false))
      #expect(!m.isIgnored(relativePath: "abbc.txt", isDirectory: false))
    }
  }

  @Test func directoryOnlyPatternMatchesDirectory() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try "logs/\n".write(to: work.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
      let m = try GitIgnoreMatcher(workTree: work, gitDir: gitDir)
      #expect(m.isIgnored(relativePath: "logs", isDirectory: true))
      #expect(!m.isIgnored(relativePath: "logs", isDirectory: false))
      #expect(m.isIgnored(relativePath: "logs/x.txt", isDirectory: false))
    }
  }

  @Test func internalSlashPatternAnchored() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try "/sub/file.txt\n".write(to: work.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
      let m = try GitIgnoreMatcher(workTree: work, gitDir: gitDir)
      #expect(m.isIgnored(relativePath: "sub/file.txt", isDirectory: false))
      #expect(!m.isIgnored(relativePath: "other/sub/file.txt", isDirectory: false))
    }
  }

  // MARK: - GitPack error path: shaNotFoundInIndex via objectTypeAndPayload

  @Test func objectTypeAndPayloadThrowsForUnknownSha() throws {
    let (pack, idx) = try Self.syntheticPack()
    let gitPack = try GitPack(packBytes: pack, indexBytes: idx)
    let missing = [UInt8](repeating: 0xab, count: 20)
    #expect(throws: GitPackError.shaNotFoundInIndex) {
      _ = try gitPack.objectTypeAndPayload(sha20: missing)
    }
  }

  // MARK: - Helpers

  private static func syntheticPack() throws -> (pack: [UInt8], idx: [UInt8]) {
    let blobContent: [UInt8] = [0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a]  // "hello\n"
    let body: [UInt8] = Array("blob \(blobContent.count)\0".utf8) + blobContent
    let sha20 = GitSHA1.digest(of: body)
    let obj = GitPackWriter.PackObject(sha20: sha20, type: 3, payload: blobContent)
    let result = try GitPackWriter.write(objects: [obj])
    return (result.packData, result.indexData)
  }
}
