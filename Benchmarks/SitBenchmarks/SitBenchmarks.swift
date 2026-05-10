import CollectionsBenchmark
import Foundation
import Sit

// MARK: - Benchmark definitions

extension Benchmark {

  public mutating func registerSitBenchmarks() {

    // ══════════════════════════════════════════════════════════════════
    // SHA-1 Hashing
    // ══════════════════════════════════════════════════════════════════

    self.add(
      title: "SHA1.hash 1 KB blob",
      input: Int.self
    ) { _ in
      let content = [UInt8](repeating: 0x41, count: 1024)
      return { timer in
        timer.measure {
          blackHole(GitSHA1.digest(of: content))
        }
      }
    }

    self.add(
      title: "SHA1.hash 1 MB blob",
      input: Int.self
    ) { _ in
      let content = [UInt8](repeating: 0x41, count: 1_048_576)
      return { timer in
        timer.measure {
          blackHole(GitSHA1.digest(of: content))
        }
      }
    }

    self.add(
      title: "SHA1.hash 64 KB blob",
      input: Int.self
    ) { _ in
      let content = [UInt8](repeating: 0x41, count: 65_536)
      return { timer in
        timer.measure {
          blackHole(GitSHA1.digest(of: content))
        }
      }
    }

    // ══════════════════════════════════════════════════════════════════
    // Git Index Parse / Serialize
    // ══════════════════════════════════════════════════════════════════

    self.add(
      title: "Index.parse 100 entries",
      input: Int.self
    ) { _ in
      // Build a valid serialized index with 100 entries
      var idx = GitIndex()
      for i in 0..<100 {
        let entry = Self.makeFakeRawEntry(path: "src/file_\(i).swift", sha: Self.fakeSha(for: i))
        idx.insertEntry(entry)
      }
      let data = try! idx.serialized()
      let bytes = Array(data)
      return { timer in
        timer.measure {
          blackHole(try! GitIndex(bytes: bytes))
        }
      }
    }

    self.add(
      title: "Index.serialize 100 entries",
      input: Int.self
    ) { _ in
      var idx = GitIndex()
      for i in 0..<100 {
        let entry = Self.makeFakeRawEntry(path: "src/file_\(i).swift", sha: Self.fakeSha(for: i))
        idx.insertEntry(entry)
      }
      return { timer in
        timer.measure {
          blackHole(try! idx.serialized())
        }
      }
    }

    // ══════════════════════════════════════════════════════════════════
    // DEFLATE / Zlib
    // ══════════════════════════════════════════════════════════════════

    self.add(
      title: "Deflate.inflate 1 KB stored",
      input: Int.self
    ) { _ in
      let plain = [UInt8](repeating: 0x41, count: 1024)
      let deflated = try! DeflateCompress.compressStored(plain)
      return { timer in
        timer.measure {
          blackHole(try! DeflateInflate.inflate(deflated))
        }
      }
    }

    self.add(
      title: "Deflate.inflate 64 KB stored",
      input: Int.self
    ) { _ in
      let plain = [UInt8](repeating: 0x41, count: 65_536)
      let deflated = try! DeflateCompress.compressStored(plain)
      return { timer in
        timer.measure {
          blackHole(try! DeflateInflate.inflate(deflated))
        }
      }
    }

    self.add(
      title: "Deflate.compress 1 KB stored",
      input: Int.self
    ) { _ in
      let plain = [UInt8](repeating: 0x41, count: 1024)
      return { timer in
        timer.measure {
          blackHole(try! DeflateCompress.compressStored(plain))
        }
      }
    }

    self.add(
      title: "Deflate.compress 64 KB stored",
      input: Int.self
    ) { _ in
      let plain = [UInt8](repeating: 0x41, count: 65_536)
      return { timer in
        timer.measure {
          blackHole(try! DeflateCompress.compressStored(plain))
        }
      }
    }

    self.add(
      title: "Zlib roundtrip 1 KB",
      input: Int.self
    ) { _ in
      let plain = [UInt8](repeating: 0x41, count: 1024)
      return { timer in
        timer.measure {
          let compressed = try! ZlibLooseObject.compress(plain)
          blackHole(try! ZlibLooseObject.decompress(Array(compressed)))
        }
      }
    }

    self.add(
      title: "Zlib roundtrip 64 KB",
      input: Int.self
    ) { _ in
      let plain = [UInt8](repeating: 0x41, count: 65_536)
      return { timer in
        timer.measure {
          let compressed = try! ZlibLooseObject.compress(plain)
          blackHole(try! ZlibLooseObject.decompress(Array(compressed)))
        }
      }
    }

    // ══════════════════════════════════════════════════════════════════
    // GitIgnore Matching
    // ══════════════════════════════════════════════════════════════════

    self.add(
      title: "GitIgnore.match 100 patterns 50 paths",
      input: Int.self
    ) { _ in
      // Create a matcher with 100 patterns and test 50 paths
      let workTree = URL(fileURLWithPath: "/tmp/bench_ignore", isDirectory: true)
      let gitDir = workTree.appendingPathComponent(".git", isDirectory: true)
      let matcher = try! Self.makeFakeMatcher(workTree: workTree, gitDir: gitDir, patternCount: 100)
      let paths = (0..<50).map { "src/module_\($0 % 10)/file_\($0).swift" }
      return { timer in
        timer.measure {
          for path in paths {
            blackHole(matcher.isIgnored(relativePath: path, isDirectory: false))
          }
        }
      }
    }

    // ══════════════════════════════════════════════════════════════════
    // Pack Delta Apply
    // ══════════════════════════════════════════════════════════════════

    self.add(
      title: "PackDelta.apply 1 KB base + delta",
      input: Int.self
    ) { _ in
      let base = [UInt8](0..<255) + [UInt8](0..<255) + [UInt8](0..<255) + [UInt8](0..<255)
      let delta = Self.makeSimpleDelta(base: base, insertSize: 100)
      return { timer in
        timer.measure {
          blackHole(try! PackDelta.apply(base: base, delta: delta))
        }
      }
    }

    self.add(
      title: "PackDelta.apply 64 KB base + delta",
      input: Int.self
    ) { _ in
      var base = [UInt8](repeating: 0, count: 65_536)
      for i in 0..<base.count { base[i] = UInt8(i & 0xff) }
      let delta = Self.makeSimpleDelta(base: base, insertSize: 100)
      return { timer in
        timer.measure {
          blackHole(try! PackDelta.apply(base: base, delta: delta))
        }
      }
    }

    // ══════════════════════════════════════════════════════════════════
    // Loose Object Write
    // ══════════════════════════════════════════════════════════════════

    self.add(
      title: "LooseObject.write blob 1 KB",
      input: Int.self
    ) { _ in
      let content = [UInt8](repeating: 0x42, count: 1024)
      let tmpDir = try! Self.makeTempGitDir()
      let gitDir = tmpDir.appendingPathComponent(".git", isDirectory: true)
      return { timer in
        timer.measure {
          blackHole(try! GitLooseObjectWriter.writeBlob(gitDir: gitDir, content: content))
        }
      }
    }

    self.add(
      title: "LooseObject.write blob 64 KB",
      input: Int.self
    ) { _ in
      let content = [UInt8](repeating: 0x42, count: 65_536)
      let tmpDir = try! Self.makeTempGitDir()
      let gitDir = tmpDir.appendingPathComponent(".git", isDirectory: true)
      return { timer in
        timer.measure {
          blackHole(try! GitLooseObjectWriter.writeBlob(gitDir: gitDir, content: content))
        }
      }
    }

    // ══════════════════════════════════════════════════════════════════
    // GitHex Encode / Decode
    // ══════════════════════════════════════════════════════════════════

    self.add(
      title: "Hex.encode 20 bytes",
      input: Int.self
    ) { _ in
      let sha: [UInt8] = (0..<20).map { UInt8($0) }
      return { timer in
        timer.measure {
          blackHole(GitHex.encodeLower(sha))
        }
      }
    }

    self.add(
      title: "Hex.decode 40 hex → 20 bytes",
      input: Int.self
    ) { _ in
      let hex = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
      return { timer in
        timer.measure {
          blackHole(try! GitHex.decode20(hex))
        }
      }
    }

    // ══════════════════════════════════════════════════════════════════
    // Tree Build
    // ══════════════════════════════════════════════════════════════════

    self.add(
      title: "Tree.build flat 200 entries",
      input: Int.self
    ) { _ in
      var idx = GitIndex()
      for i in 0..<200 {
        let entry = Self.makeFakeRawEntry(path: "file_\(i).txt", sha: Self.fakeSha(for: i))
        idx.insertEntry(entry)
      }
      let tmpDir = try! Self.makeTempGitDir()
      let gitDir = tmpDir.appendingPathComponent(".git", isDirectory: true)
      return { timer in
        timer.measure {
          blackHole(try! idx.writeRootTree(gitDir: gitDir))
        }
      }
    }

    self.add(
      title: "Tree.build nested 200 entries (10 dirs)",
      input: Int.self
    ) { _ in
      var idx = GitIndex()
      for i in 0..<200 {
        let dir = "dir_\(i % 10)"
        let entry = Self.makeFakeRawEntry(path: "\(dir)/file_\(i).txt", sha: Self.fakeSha(for: i))
        idx.insertEntry(entry)
      }
      let tmpDir = try! Self.makeTempGitDir()
      let gitDir = tmpDir.appendingPathComponent(".git", isDirectory: true)
      return { timer in
        timer.measure {
          blackHole(try! idx.writeRootTree(gitDir: gitDir))
        }
      }
    }

    // ══════════════════════════════════════════════════════════════════
    // Repository Discovery
    // ══════════════════════════════════════════════════════════════════

    self.add(
      title: "Repository.discover 5 levels up",
      input: Int.self
    ) { _ in
      let tmpDir = try! Self.makeTempGitDir()
      let gitDir = tmpDir.appendingPathComponent(".git", isDirectory: true)
      let deepDir = tmpDir.appendingPathComponent("a/b/c/d/e", isDirectory: true)
      try! FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
      _ = try! Data("ref: refs/heads/main\n".utf8).write(to: gitDir.appendingPathComponent("HEAD"))
      return { timer in
        timer.measure {
          blackHole(try! GitRepository.discover(from: deepDir))
        }
      }
    }
  }

  // MARK: - Helpers

  private static func fakeSha(for i: Int) -> [UInt8] {
    var sha: [UInt8] = []
    sha.reserveCapacity(20)
    for j in 0..<20 {
      sha.append(UInt8((i &* 37 &+ j) & 0xff))
    }
    return sha
  }

  private static func makeFakeRawEntry(path: String, sha: [UInt8]) -> GitIndex.RawEntry {
    GitIndex.RawEntry(
      path: path,
      ctimeSec: 1_700_000_000,
      ctimeNSec: 0,
      mtimeSec: 1_700_000_000,
      mtimeNSec: 0,
      dev: 0,
      ino: UInt32(path.hashValue & 0xffff),
      mode: 0o100644,
      uid: 501,
      gid: 20,
      size: 1024,
      sha: sha
    )
  }

  private static func makeSimpleDelta(base: [UInt8], insertSize: Int) -> [UInt8] {
    // Delta that copies the first half of base, inserts `insertSize` bytes of new data,
    // then copies the second half.
    let half = base.count / 2
    var delta: [UInt8] = []

    // Source size
    delta.append(contentsOf: Self.encodeLEB128(UInt64(base.count)))
    // Target size
    let targetSize = base.count + insertSize
    delta.append(contentsOf: Self.encodeLEB128(UInt64(targetSize)))

    // Copy first half — command byte first, then offset/size bytes
    if half > 0 {
      var cmd: UInt8 = 0x80  // copy
      let offset = 0
      let size = half
      // Encode offset
      if offset & 0xff != 0 || true { cmd |= 0x01 }
      if (offset >> 8) & 0xff != 0 || true { cmd |= 0x02 }
      if (offset >> 16) & 0xff != 0 { cmd |= 0x04 }
      if offset >> 24 != 0 { cmd |= 0x08 }
      // Encode size
      if size & 0xff != 0 || true { cmd |= 0x10 }
      if (size >> 8) & 0xff != 0 { cmd |= 0x20 }
      if size >> 16 != 0 { cmd |= 0x40 }
      delta.append(cmd)
      // Offset bytes (LSB first)
      if cmd & 0x01 != 0 { delta.append(UInt8(offset & 0xff)) }
      if cmd & 0x02 != 0 { delta.append(UInt8((offset >> 8) & 0xff)) }
      if cmd & 0x04 != 0 { delta.append(UInt8((offset >> 16) & 0xff)) }
      if cmd & 0x08 != 0 { delta.append(UInt8((offset >> 24) & 0xff)) }
      // Size bytes (LSB first)
      if cmd & 0x10 != 0 { delta.append(UInt8(size & 0xff)) }
      if cmd & 0x20 != 0 { delta.append(UInt8((size >> 8) & 0xff)) }
      if cmd & 0x40 != 0 { delta.append(UInt8((size >> 16) & 0xff)) }
    }

    // Insert new data — must emit as bytewise insert commands where each is < 128 (0x80 = copy)
    if insertSize > 0 {
      var remaining = insertSize
      var dataOffset = 0
      let insertData = [UInt8](repeating: 0x58, count: insertSize)
      while remaining > 0 {
        let chunk = min(remaining, 127)
        delta.append(UInt8(chunk))
        delta.append(contentsOf: insertData[dataOffset..<(dataOffset + chunk)])
        dataOffset += chunk
        remaining -= chunk
      }
    }

    // Copy second half
    if half > 0 {
      var cmd: UInt8 = 0x80
      let offset = half
      let size = base.count - half
      if offset & 0xff != 0 || true { cmd |= 0x01 }
      if (offset >> 8) & 0xff != 0 || true { cmd |= 0x02 }
      if offset >> 16 != 0 { cmd |= 0x04 }
      if offset >> 24 != 0 { cmd |= 0x08 }
      if size & 0xff != 0 || true { cmd |= 0x10 }
      if (size >> 8) & 0xff != 0 { cmd |= 0x20 }
      if size >> 16 != 0 { cmd |= 0x40 }
      delta.append(cmd)
      if cmd & 0x01 != 0 { delta.append(UInt8(offset & 0xff)) }
      if cmd & 0x02 != 0 { delta.append(UInt8((offset >> 8) & 0xff)) }
      if cmd & 0x04 != 0 { delta.append(UInt8((offset >> 16) & 0xff)) }
      if cmd & 0x08 != 0 { delta.append(UInt8((offset >> 24) & 0xff)) }
      if cmd & 0x10 != 0 { delta.append(UInt8(size & 0xff)) }
      if cmd & 0x20 != 0 { delta.append(UInt8((size >> 8) & 0xff)) }
      if cmd & 0x40 != 0 { delta.append(UInt8((size >> 16) & 0xff)) }
    }

    return delta
  }

  private static func encodeLEB128(_ value: UInt64) -> [UInt8] {
    var v = value
    var out: [UInt8] = []
    repeat {
      var b = UInt8(v & 0x7f)
      v >>= 7
      if v != 0 { b |= 0x80 }
      out.append(b)
    } while v != 0
    return out
  }

  private static func makeTempGitDir() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("sit-bench-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let gitDir = root.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
    for dir in ["objects", "objects/info", "objects/pack", "refs", "refs/heads", "refs/tags"] {
      try FileManager.default.createDirectory(
        at: gitDir.appendingPathComponent(dir, isDirectory: true), withIntermediateDirectories: true)
    }
    return root
  }

  private static func makeFakeMatcher(workTree: URL, gitDir: URL, patternCount: Int) throws -> GitIgnoreMatcher {
    // We can't easily construct GitIgnoreMatcher with fake rules, so we create a
    // real .gitignore file on disk instead.
    let ignoreURL = workTree.appendingPathComponent(".gitignore")
    var patterns = ""
    for i in 0..<patternCount {
      patterns += "*.gen_\(i)\n"
      if i % 5 == 0 { patterns += "!important_\(i).gen\n" }
    }
    try FileManager.default.createDirectory(at: workTree, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("info", isDirectory: true), withIntermediateDirectories: true)
    try Data(patterns.utf8).write(to: ignoreURL)
    return try GitIgnoreMatcher(workTree: workTree, gitDir: gitDir)
  }
}

