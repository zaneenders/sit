import Foundation
import Testing

@testable import Sit
@testable import sit_cli

/// Tests for GitPackImporter: error paths and round-trip happy path.
@Suite(.timeLimit(.minutes(1)))
struct GitPackImporterTests: ~Copyable {

  // MARK: - Error paths (no disk needed)

  @Test func rejectsTooShortPack() throws {
    let tiny: [UInt8] = [0x50, 0x41, 0x43, 0x4b, 0, 0]  // only 6 bytes
    #expect(throws: GitPackImporter.Error.truncatedPack(6)) {
      _ = try GitPackImporter.importPack(
        gitDir: URL(fileURLWithPath: "/dev/null"), packData: tiny, packs: [])
    }
  }

  @Test func rejectsBadSignature() throws {
    var pack = [UInt8](repeating: 0, count: 20)
    pack[0] = 0x58  // 'X' instead of 'P'
    pack[1] = 0x41
    pack[2] = 0x43
    pack[3] = 0x4b
    #expect(throws: GitPackImporter.Error.badPackSignature) {
      _ = try GitPackImporter.importPack(
        gitDir: URL(fileURLWithPath: "/dev/null"), packData: pack, packs: [])
    }
  }

  @Test func rejectsWrongVersion() throws {
    // PACK + version=3 + count=1 + 12 trailing zeros (for length ≥12)
    var pack: [UInt8] = [0x50, 0x41, 0x43, 0x4b]  // PACK
    pack += [0, 0, 0, 3]  // version = 3
    pack += [0, 0, 0, 1]  // objectCount = 1
    pack += [UInt8](repeating: 0, count: 8)
    #expect(throws: GitPackImporter.Error.unknownPackVersion(3)) {
      _ = try GitPackImporter.importPack(
        gitDir: URL(fileURLWithPath: "/dev/null"), packData: pack, packs: [])
    }
  }

  @Test func rejectsZeroObjectCount() throws {
    // PACK v2 + 0 objects + 20-byte SHA trailer
    var pack: [UInt8] = [0x50, 0x41, 0x43, 0x4b]  // PACK
    pack += [0, 0, 0, 2]  // version = 2
    pack += [0, 0, 0, 0]  // objectCount = 0
    pack += [UInt8](repeating: 0, count: 20)  // SHA trailer (wrong but passes size check)
    #expect(throws: GitPackImporter.Error.emptyPack) {
      _ = try GitPackImporter.importPack(
        gitDir: URL(fileURLWithPath: "/dev/null"), packData: pack, packs: [])
    }
  }

  @Test func rejectsChecksumMismatch() throws {
    // Build a valid 1-object pack then corrupt the trailing SHA
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)

      let obj = GitPackWriter.PackObject(
        sha20: try GitHex.decode20("3b18e512dba79e4c8300dd08aeb37f8e728b8dad"),
        type: 3,  // blob
        payload: Array("hello".utf8)
      )
      var result = try GitPackWriter.write(objects: [obj])
      var pack = result.packData
      // Flip last byte of SHA trailer
      pack[pack.count - 1] ^= 0xFF

      #expect(throws: GitPackImporter.Error.packChecksumMismatch) {
        _ = try GitPackImporter.importPack(gitDir: gitDir, packData: pack, packs: [])
      }
    }
  }

  // MARK: - Happy path: pack round-trip

  @Test func importsSingleBlobFromPackWriter() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)

      let content = Array("hello world".utf8)
      let sha20 = try GitLooseObjectWriter.writeObject(gitDir: gitDir, type: "blob", body: content)
      let shaHex = GitHex.encodeLower(sha20)

      let obj = GitPackWriter.PackObject(sha20: sha20, type: 3, payload: content)
      let packResult = try GitPackWriter.write(objects: [obj])

      // Remove the loose object so we can test the importer wrote it back
      let looseDir = gitDir.appendingPathComponent("objects/\(String(shaHex.prefix(2)))")
      let looseFile = looseDir.appendingPathComponent(String(shaHex.dropFirst(2)))
      try FileManager.default.removeItem(at: looseFile)

      let importResult = try GitPackImporter.importPack(
        gitDir: gitDir, packData: packResult.packData, packs: [])

      #expect(importResult.importedSHAs.contains(shaHex))
      #expect(importResult.unresolvedDeltas == 0)

      // Verify the object is now readable
      let (type, payload) = try GitObjectDatabase.readObject(
        gitDir: gitDir, packs: [], sha20: sha20)
      #expect(type == "blob")
      #expect(payload == content)
    }
  }

  @Test func importsMultipleObjectsFromPackWriter() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)

      let contents: [([UInt8], String)] = [
        (Array("alpha".utf8), "blob"),
        (Array("beta".utf8), "blob"),
      ]
      var objects: [GitPackWriter.PackObject] = []
      var sha20s: [[UInt8]] = []
      for (body, type) in contents {
        let sha20 = try GitLooseObjectWriter.writeObject(gitDir: gitDir, type: type, body: body)
        let typeInt = type == "blob" ? 3 : 1
        objects.append(GitPackWriter.PackObject(sha20: sha20, type: typeInt, payload: body))
        sha20s.append(sha20)
      }

      let packResult = try GitPackWriter.write(objects: objects)

      // Delete loose objects
      for sha20 in sha20s {
        let hex = GitHex.encodeLower(sha20)
        let path =
          gitDir
          .appendingPathComponent("objects/\(String(hex.prefix(2)))/\(String(hex.dropFirst(2)))")
        try? FileManager.default.removeItem(at: path)
      }

      let importResult = try GitPackImporter.importPack(
        gitDir: gitDir, packData: packResult.packData, packs: [])
      #expect(importResult.importedSHAs.count == 2)
      #expect(importResult.unresolvedDeltas == 0)
    }
  }

  @Test func importsPackWrittenByPackWriter_isReadableAfterImport() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)

      // Create a tree+blob and pack them
      let blobContent = Array("Hello, pack round-trip!".utf8)
      let blobSHA = try GitLooseObjectWriter.writeObject(gitDir: gitDir, type: "blob", body: blobContent)

      let treeEntry = (mode: "100644", name: "hello.txt", sha20: blobSHA)
      let treeSHA = try GitLooseObjectWriter.writeTree(gitDir: gitDir, entries: [treeEntry])

      let objects = [
        GitPackWriter.PackObject(sha20: blobSHA, type: 3, payload: blobContent),
        GitPackWriter.PackObject(sha20: treeSHA, type: 2, payload: buildTreePayload(treeEntry)),
      ]
      let packResult = try GitPackWriter.write(objects: objects)

      // Delete loose objects
      for sha20 in [blobSHA, treeSHA] {
        let hex = GitHex.encodeLower(sha20)
        let path =
          gitDir
          .appendingPathComponent("objects/\(String(hex.prefix(2)))/\(String(hex.dropFirst(2)))")
        try? FileManager.default.removeItem(at: path)
      }

      let importResult = try GitPackImporter.importPack(
        gitDir: gitDir, packData: packResult.packData, packs: [])
      #expect(importResult.importedSHAs.count == 2)

      // Both objects should be readable from loose storage after import
      let (blobType, blobPayload) = try GitObjectDatabase.readObject(
        gitDir: gitDir, packs: [], sha20: blobSHA)
      #expect(blobType == "blob")
      #expect(blobPayload == blobContent)

      let (treeType, _) = try GitObjectDatabase.readObject(
        gitDir: gitDir, packs: [], sha20: treeSHA)
      #expect(treeType == "tree")
    }
  }

  // MARK: - Helper

  private func buildTreePayload(_ entry: (mode: String, name: String, sha20: [UInt8])) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.append(contentsOf: Array(entry.mode.utf8))
    bytes.append(0x20)  // space
    bytes.append(contentsOf: Array(entry.name.utf8))
    bytes.append(0x00)  // null
    bytes.append(contentsOf: entry.sha20)
    return bytes
  }
}
