import Foundation
import Testing
import Subprocess

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct GitPackWriterTests: ~Copyable {

  // MARK: - Round-trip tests

  @Test func writeSingleBlobRoundTripsThroughGitPack() throws {
    let payload = Array("hello world\n".utf8)
    let sha20 = GitSHA1.digest(
      of: Array("blob 12".utf8) + [0] + payload)

    let obj = GitPackWriter.PackObject(sha20: sha20, type: 3, payload: payload)
    let result = try GitPackWriter.write(objects: [obj])

    let pack = try GitPack(packBytes: result.packData, indexBytes: result.indexData)
    let got = try pack.serializedObject(sha20: sha20)
    #expect(Array(got) == payload)
  }

  @Test func writeMultipleObjectsRoundTrip() throws {
    let blobPayload = Array("file content\n".utf8)
    let blobSHA = GitSHA1.digest(
      of: Array("blob 13".utf8) + [0] + blobPayload)

    let blob2Payload = Array("another file\n".utf8)
    let blob2SHA = GitSHA1.digest(
      of: Array("blob 13".utf8) + [0] + blob2Payload)

    let objects = [
      GitPackWriter.PackObject(sha20: blobSHA, type: 3, payload: blobPayload),
      GitPackWriter.PackObject(sha20: blob2SHA, type: 3, payload: blob2Payload),
    ]

    let result = try GitPackWriter.write(objects: objects)
    #expect(result.objectCount == 2)

    let pack = try GitPack(packBytes: result.packData, indexBytes: result.indexData)

    let got1 = try pack.serializedObject(sha20: blobSHA)
    #expect(Array(got1) == blobPayload)

    let got2 = try pack.serializedObject(sha20: blob2SHA)
    #expect(Array(got2) == blob2Payload)
  }

  @Test func writeEmptyBlobRoundTrips() throws {
    let payload: [UInt8] = []
    let sha20 = GitSHA1.digest(
      of: Array("blob 0".utf8) + [0])

    let obj = GitPackWriter.PackObject(sha20: sha20, type: 3, payload: payload)
    let result = try GitPackWriter.write(objects: [obj])

    let pack = try GitPack(packBytes: result.packData, indexBytes: result.indexData)
    let got = try pack.serializedObject(sha20: sha20)
    #expect(got.isEmpty)
  }

  @Test func writeCommitRoundTrips() throws {
    let commitPayload = Array(
      "tree abcdef0123456789abcdef0123456789abcdef01\nparent fedcba9876543210fedcba9876543210fedcba98\nauthor Test <test@test.com> 0 +0000\ncommitter Test <test@test.com> 0 +0000\n\ncommit message\n"
        .utf8)
    let sha20 = GitSHA1.digest(
      of: Array("commit \(commitPayload.count)".utf8) + [0] + commitPayload)

    let obj = GitPackWriter.PackObject(sha20: sha20, type: 1, payload: commitPayload)
    let result = try GitPackWriter.write(objects: [obj])

    let pack = try GitPack(packBytes: result.packData, indexBytes: result.indexData)
    let (type, gotPayload) = try pack.objectTypeAndPayload(sha20: sha20)
    #expect(type == 1)
    #expect(Array(gotPayload) == commitPayload)
  }

  @Test func writeTreeRoundTrips() throws {
    let mode = "100644"
    let name = "hello.txt"
    let fakeSHA = [UInt8](repeating: 0xab, count: 20)
    var treePayload: [UInt8] = []
    treePayload.append(contentsOf: mode.utf8)
    treePayload.append(UInt8(ascii: " "))
    treePayload.append(contentsOf: name.utf8)
    treePayload.append(0)
    treePayload.append(contentsOf: fakeSHA)

    let sha20 = GitSHA1.digest(
      of: Array("tree \(treePayload.count)".utf8) + [0] + treePayload)

    let obj = GitPackWriter.PackObject(sha20: sha20, type: 2, payload: treePayload)
    let result = try GitPackWriter.write(objects: [obj])

    let pack = try GitPack(packBytes: result.packData, indexBytes: result.indexData)
    let (type, gotPayload) = try pack.objectTypeAndPayload(sha20: sha20)
    #expect(type == 2)
    #expect(Array(gotPayload) == treePayload)
  }

  // MARK: - Index validation

  @Test func indexEntriesSortedBySHA() throws {
    var objects: [GitPackWriter.PackObject] = []
    for i in 0..<5 {
      let payload = Array("object \(i)\n".utf8)
      let sha20 = GitSHA1.digest(
        of: Array("blob \(payload.count)".utf8) + [0] + payload)
      objects.append(GitPackWriter.PackObject(sha20: sha20, type: 3, payload: payload))
    }

    let result = try GitPackWriter.write(objects: objects)
    let idx = try PackIndexV2.parse(bytes: result.indexData)

    #expect(idx.entries.count == 5)
    for i in 1..<idx.entries.count {
      let a = idx.entries[i - 1].sha20
      let b = idx.entries[i].sha20
      #expect(compareSHAs(a, b) <= 0)
    }
  }

  @Test func packHeaderHasCorrectSignatureAndVersion() throws {
    let payload = Array("test\n".utf8)
    let sha20 = GitSHA1.digest(
      of: Array("blob 5".utf8) + [0] + payload)

    let result = try GitPackWriter.write(
      objects: [GitPackWriter.PackObject(sha20: sha20, type: 3, payload: payload)])

    #expect(result.packData[0] == 0x50)
    #expect(result.packData[1] == 0x41)
    #expect(result.packData[2] == 0x43)
    #expect(result.packData[3] == 0x4b)
    #expect(result.packData[4...7].elementsEqual([0, 0, 0, 2]))
    #expect(result.packData[8...11].elementsEqual([0, 0, 0, 1]))
  }

  // MARK: - Index SHA-1 self-validation

  @Test func indexSelfChecksumIsCorrect() throws {
    let payload = Array("hello world\n".utf8)
    let sha20 = GitSHA1.digest(
      of: Array("blob 12".utf8) + [0] + payload)

    let result = try GitPackWriter.write(
      objects: [GitPackWriter.PackObject(sha20: sha20, type: 3, payload: payload)])

    let idxData = result.indexData
    let idxBody = idxData.dropLast(20)
    let idxTrailer = idxData.suffix(20)
    let computedIdxSHA = GitSHA1.digest(of: Array(idxBody))
    #expect(Array(computedIdxSHA) == Array(idxTrailer))
  }

  @Test func packChecksumInIndexMatchesActualPack() throws {
    let payload = Array("hello world\n".utf8)
    let sha20 = GitSHA1.digest(
      of: Array("blob 12".utf8) + [0] + payload)

    let result = try GitPackWriter.write(
      objects: [GitPackWriter.PackObject(sha20: sha20, type: 3, payload: payload)])

    let idxData = result.indexData
    let idxBody = idxData.dropLast(20)
    let storedPackSHA = idxBody.suffix(20)

    let packBody = result.packData.dropLast(20)
    let computedPackSHA = GitSHA1.digest(of: Array(packBody))
    #expect(Array(computedPackSHA) == Array(storedPackSHA))
  }

  // MARK: - Error cases

  @Test func emptyObjectsThrows() {
    #expect(throws: GitPackError.noObjectsToPack) {
      _ = try GitPackWriter.write(objects: [])
    }
  }

  @Test func badObjectSHALengthThrows() throws {
    let obj = GitPackWriter.PackObject(
      sha20: [0, 1, 2],
      type: 3,
      payload: [1, 2, 3])
    #expect(throws: GitPackError.badObjectSHA) {
      _ = try GitPackWriter.write(objects: [obj])
    }
  }

  @Test func unknownObjectTypeThrows() throws {
    let obj = GitPackWriter.PackObject(
      sha20: [UInt8](repeating: 0, count: 20),
      type: 5,
      payload: [1, 2, 3])
    #expect(throws: GitPackError.unknownObjectType(5)) {
      _ = try GitPackWriter.write(objects: [obj])
    }
  }

  // MARK: - CRC-32 validation

  @Test func crc32KnownValue() {
    let data = Array("123456789".utf8)
    let crc = CRC32.checksum(of: data)
    #expect(crc == 0xcbf4_3926)
  }

  // MARK: - Cross-validation: git can rebuild index from our pack

  @Test func gitCanIndexOurPack() async throws {
    guard let git = gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }

    try await TempDirectory.withRemoval { tmp in
      var objects: [GitPackWriter.PackObject] = []
      let contents = ["hello world\n", "goodbye\n", "middle earth\n"]
      for content in contents {
        let payload = Array(content.utf8)
        let sha20 = GitSHA1.digest(
          of: Array("blob \(payload.count)".utf8) + [0] + payload)
        objects.append(GitPackWriter.PackObject(sha20: sha20, type: 3, payload: payload))
      }

      let result = try GitPackWriter.write(objects: objects)

      // Write just the pack
      let packPath = tmp.appendingPathComponent("test.pack")
      try Data(result.packData).write(to: packPath)

      // Have git index-pack our pack
      let gitIdxResult = try await Subprocess.run(
        .name(git),
        arguments: Arguments([
          "index-pack", "-o", tmp.appendingPathComponent("git.idx").path, packPath.path,
        ]),
        output: .bytes(limit: Int.max),
        error: .bytes(limit: Int.max))
      #expect(
        gitIdxResult.terminationStatus.isSuccess,
        "git index-pack failed: \(String(decoding: gitIdxResult.standardError, as: UTF8.self))")
    }
  }

  @Test func gitIndexPackProducesReadableIndex() async throws {
    guard let git = gitPath() else {
      Issue.record("skip: git not found on PATH")
      return
    }

    try await TempDirectory.withRemoval { tmp in
      var objects: [GitPackWriter.PackObject] = []
      let contents = ["hello world\n", "goodbye\n", "middle earth\n"]
      for content in contents {
        let payload = Array(content.utf8)
        let sha20 = GitSHA1.digest(
          of: Array("blob \(payload.count)".utf8) + [0] + payload)
        objects.append(GitPackWriter.PackObject(sha20: sha20, type: 3, payload: payload))
      }

      let result = try GitPackWriter.write(objects: objects)

      let packPath = tmp.appendingPathComponent("test.pack")
      try Data(result.packData).write(to: packPath)

      // git index-pack
      _ = try await Subprocess.run(
        .name(git),
        arguments: Arguments([
          "index-pack", "-o", tmp.appendingPathComponent("git.idx").path, packPath.path,
        ]),
        output: .bytes(limit: Int.max),
        error: .bytes(limit: Int.max))

      // Read our pack with git's index using our own GitPack
      let gitIdxBytes = try [UInt8](
        Data(contentsOf: tmp.appendingPathComponent("git.idx")))
      let pack = try GitPack(packBytes: result.packData, indexBytes: gitIdxBytes)

      // Verify we can read back all objects
      for obj in objects {
        let got = try pack.serializedObject(sha20: obj.sha20)
        #expect(Array(got) == obj.payload)
      }
    }
  }

  // MARK: - Helpers

  private func gitPath() -> String? {
    for p in ["/usr/bin/git", "/bin/git", "/usr/local/bin/git"] {
      if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
  }

  private func compareSHAs(_ a: [UInt8], _ b: [UInt8]) -> Int {
    for i in 0..<min(a.count, b.count) {
      if a[i] < b[i] { return -1 }
      if a[i] > b[i] { return 1 }
    }
    return a.count - b.count
  }
}
