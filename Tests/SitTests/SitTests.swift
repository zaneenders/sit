import Foundation
import Testing

@testable import Sit

@Suite
struct SitTests: ~Copyable {
  /// `python3 -c "import zlib; ... blob 5\\x00hello"` — full zlib + Adler32.
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

  /// `python3 -c "import zlib; zlib.compress(b'blob 11\\x00hello world')"` — exercises dynamic Huffman.
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

  /// Build a real `blob <n>\\0` + `Package.swift` bytes, zlib-compress with
  /// Python, then inflate + parse purely in Sit — tight loop against this repo.
  @Test func dogfoodPackageSwiftAsGitBlobRoundTrip() throws {
    guard Self.python3Path() != nil else {
      Issue.record("skip dogfood: python3 not found on PATH")
      return
    }
    let packageRoot = Self.packageRoot()
    let packageSwift = packageRoot.appendingPathComponent("Package.swift")
    guard FileManager.default.fileExists(atPath: packageSwift.path) else {
      Issue.record("skip dogfood: Package.swift not found at \(packageSwift.path)")
      return
    }
    let fileData = try Data(contentsOf: packageSwift)
    let header = Data("blob \(fileData.count)\0".utf8)
    let rawObject = header + fileData

    guard let zlibData = Self.zlibCompressViaPython(rawObject) else {
      Issue.record("skip dogfood: zlib.compress via python3 failed")
      return
    }

    let inflated = try ZlibLooseObject.decompress([UInt8](zlibData))
    #expect(inflated.elementsEqual(rawObject))
    let parsed = try ParsedGitBlob(decodedLooseObjectBytes: inflated)
    #expect(parsed.declaredSize == fileData.count)
    #expect(Data(parsed.payload) == fileData)
  }

  /// `git cat-file blob <sha>` (file bytes) plus a synthetic `blob <n>\\0` header
  /// round-trips through Python’s zlib and Sit’s inflater.
  @Test func dogfoodMatchesGitCatFileBlob() throws {
    guard Self.python3Path() != nil else {
      Issue.record("skip dogfood: python3 not found on PATH")
      return
    }
    let packageRoot = Self.packageRoot()
    guard let sha = Self.gitRevParse(packageRoot: packageRoot, rev: "HEAD:Package.swift"),
      let fileBytes = Self.gitCatFileBlob(packageRoot: packageRoot, object: sha)
    else {
      Issue.record("skip dogfood: git rev-parse / cat-file failed (not a git checkout?)")
      return
    }
    let header = Data("blob \(fileBytes.count)\0".utf8)
    let rawObject = header + fileBytes
    guard let zlibData = Self.zlibCompressViaPython(rawObject) else {
      Issue.record("skip dogfood: zlib.compress via python3 failed")
      return
    }
    let inflated = try ZlibLooseObject.decompress([UInt8](zlibData))
    #expect(inflated.elementsEqual(rawObject))
  }

  @Test func parsesZlibWrappedBlobObjectPrefix() throws {
    let zlibBlob: [UInt8] = [
      0x78, 0x9c, 0x4b, 0xca, 0xc9, 0x4f, 0x52, 0x30, 0x65,
      0xc8, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x19, 0xaa, 0x04, 0x09,
    ]
    let lz77 = try LZ77(parsingCompressedBytes: zlibBlob)
    #expect(lz77.header.compressionMethod == 0x78)
    #expect(lz77.header.flags == 0x9c)
    #expect(lz77.firstBlockIsBFinal)
    #expect(lz77.firstBlockType == .fixedCompression)
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
    #expect(throws: LZ77Error.blockError("reserved BTYPE")) {
      _ = try Sit.blockBegin(value: 6)
    }
    #expect(throws: LZ77Error.blockError("reserved BTYPE")) {
      _ = try Sit.blockBegin(value: 7)
    }
  }

  private static func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func python3Path() -> String? {
    let paths = ["/usr/bin/python3", "/usr/local/bin/python3", "/bin/python3"]
    for p in paths where FileManager.default.isExecutableFile(atPath: p) {
      return p
    }
    return nil
  }

  private static func zlibCompressViaPython(_ data: Data) -> Data? {
    guard let py = python3Path() else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: py)
    proc.arguments = [
      "-c",
      "import zlib,sys; sys.stdout.buffer.write(zlib.compress(sys.stdin.buffer.read()))",
    ]
    let stdin = Pipe()
    let stdout = Pipe()
    proc.standardInput = stdin
    proc.standardOutput = stdout
    proc.standardError = Pipe()
    do {
      try proc.run()
      try stdin.fileHandleForWriting.write(contentsOf: data)
      try stdin.fileHandleForWriting.close()
      let out = try stdout.fileHandleForReading.readToEnd() ?? Data()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0, !out.isEmpty else { return nil }
      return out
    } catch {
      return nil
    }
  }

  private static func gitRevParse(packageRoot: URL, rev: String) -> String? {
    guard let git = Self.gitExecutable() else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: git)
    proc.arguments = ["-C", packageRoot.path, "rev-parse", rev]
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = Pipe()
    do {
      try proc.run()
      let out = try stdout.fileHandleForReading.readToEnd() ?? Data()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else { return nil }
      let s = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      return s.isEmpty ? nil : s
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

  private static func gitCatFileBlob(packageRoot: URL, object: String) -> Data? {
    guard let git = Self.gitExecutable() else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: git)
    proc.arguments = ["-C", packageRoot.path, "cat-file", "blob", object]
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = Pipe()
    do {
      try proc.run()
      let out = try stdout.fileHandleForReading.readToEnd() ?? Data()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0, !out.isEmpty else { return nil }
      return out
    } catch {
      return nil
    }
  }
}
