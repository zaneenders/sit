import Foundation
import Testing

/// Shared `git` / `python3` helpers for dogfood tests across suites.
enum GitDogfoodHelpers {
  static func packageRoot(testFile: String = #filePath) -> URL {
    URL(fileURLWithPath: testFile)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  static func gitExecutable() -> String? {
    for p in ["/usr/bin/git", "/bin/git", "/usr/local/bin/git"] {
      if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
  }

  static func python3Path() -> String? {
    for p in ["/usr/bin/python3", "/usr/local/bin/python3", "/bin/python3"] {
      if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
  }

  /// Fails the test if `python3` is not on `PATH` (dogfood tests cross-check zlib with CPython).
  @discardableResult
  static func requirePython3ForDogfood() throws -> String {
    try #require(
      python3Path(),
      "dogfood tests require python3 on PATH (e.g. /usr/bin/python3) to cross-check zlib."
    )
  }

  /// Unique 40-hex object names reachable from **any ref** (`git rev-list --objects --all`).
  static func gitRevListUniqueShas40(packageRoot: URL) -> [String] {
    guard let git = gitExecutable() else { return [] }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: git)
    proc.arguments = ["-C", packageRoot.path, "rev-list", "--objects", "--all"]
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = Pipe()
    do {
      try proc.run()
      let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else { return [] }
      let text = String(decoding: data, as: UTF8.self)
      var seen = Set<String>()
      for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = parts.first else { continue }
        let sha = String(first)
        guard sha.count == 40, Self.isHex40(sha) else { continue }
        seen.insert(sha)
      }
      return seen.sorted()
    } catch {
      return []
    }
  }

  /// `(mode, type, sha, path)` entries from `git ls-tree -r HEAD` (blobs only for file paths).
  static func gitLsTreeRecursive(packageRoot: URL) -> [(mode: String, type: String, sha: String, path: String)] {
    guard let git = gitExecutable() else { return [] }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: git)
    proc.arguments = ["-C", packageRoot.path, "ls-tree", "-r", "HEAD"]
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = Pipe()
    do {
      try proc.run()
      let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else { return [] }
      let text = String(decoding: data, as: UTF8.self)
      var rows: [(String, String, String, String)] = []
      for line in text.split(whereSeparator: \.isNewline) {
        let s = String(line)
        // "<mode> <type> <sha>\t<path>"
        let parts = s.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let head = parts[0].split(separator: " ")
        guard head.count >= 3 else { continue }
        let mode = String(head[0])
        let type = String(head[1])
        let sha = String(head[2])
        let path = String(parts[1])
        rows.append((mode, type, sha, path))
      }
      return rows
    } catch {
      return []
    }
  }

  /// Raw uncompressed bytes (`git cat-file <type> <sha>`), excluding `-p` pretty forms.
  static func gitCatFileRaw(packageRoot: URL, type: String, sha: String) -> Data? {
    guard let git = gitExecutable() else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: git)
    proc.arguments = ["-C", packageRoot.path, "cat-file", type, sha]
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = Pipe()
    do {
      try proc.run()
      let out = try stdout.fileHandleForReading.readToEnd() ?? Data()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else { return nil }
      return out
    } catch {
      return nil
    }
  }

  /// One `git cat-file --batch` round-trip for all `shas` (each must be a full 40-char hex id).
  static func gitCatFileBatchRaw(packageRoot: URL, shas: [String]) -> [(sha: String, type: String, raw: Data)]? {
    guard let git = gitExecutable(), !shas.isEmpty else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: git)
    proc.arguments = ["-C", packageRoot.path, "cat-file", "--batch"]
    let stdin = Pipe()
    let stdout = Pipe()
    proc.standardInput = stdin
    proc.standardOutput = stdout
    proc.standardError = Pipe()
    do {
      try proc.run()
      let inData = Data(shas.joined(separator: "\n").utf8 + [0x0a])
      try stdin.fileHandleForWriting.write(contentsOf: inData)
      try stdin.fileHandleForWriting.close()
      let all = try stdout.fileHandleForReading.readToEnd() ?? Data()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else { return nil }
      var results: [(String, String, Data)] = []
      results.reserveCapacity(shas.count)
      var i = all.startIndex
      for _ in shas {
        guard let nl = all[i...].firstIndex(of: 0x0a) else { return nil }
        let headerLine = String(decoding: all[i..<nl], as: UTF8.self)
        i = all.index(after: nl)
        let parts = headerLine.split(separator: " ")
        guard parts.count >= 3,
          let size = Int(parts[2])
        else {
          return nil
        }
        let sha = String(parts[0])
        let type = String(parts[1])
        guard size >= 0, all.distance(from: i, to: all.endIndex) >= size + 1 else { return nil }
        let payloadStart = i
        let payloadEnd = all.index(payloadStart, offsetBy: size)
        let payload = all[payloadStart..<payloadEnd]
        i = payloadEnd
        guard i < all.endIndex, all[i] == 0x0a else { return nil }
        i = all.index(after: i)
        results.append((sha, type, Data(payload)))
      }
      guard i == all.endIndex else { return nil }
      return results
    } catch {
      return nil
    }
  }

  /// `zlib.adler32(data) & 0xffffffff` (Python 3).
  static func zlibAdler32ViaPython(_ bytes: Data) -> UInt32? {
    guard let py = python3Path() else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: py)
    proc.arguments = [
      "-c",
      """
      import zlib,sys
      d=sys.stdin.buffer.read()
      sys.stdout.write(str(zlib.adler32(d) & 0xffffffff))
      """,
    ]
    let stdin = Pipe()
    let stdout = Pipe()
    proc.standardInput = stdin
    proc.standardOutput = stdout
    proc.standardError = Pipe()
    do {
      try proc.run()
      try stdin.fileHandleForWriting.write(contentsOf: bytes)
      try stdin.fileHandleForWriting.close()
      let out = try stdout.fileHandleForReading.readToEnd() ?? Data()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0,
        let s = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
        let v = UInt32(s, radix: 10)
      else { return nil }
      return v
    } catch {
      return nil
    }
  }

  /// One line per full SHA for each `refs/heads/*` tip.
  static func gitLocalBranchTipCommitShas(packageRoot: URL) -> [String] {
    guard let git = gitExecutable() else { return [] }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: git)
    proc.arguments = [
      "-C", packageRoot.path, "for-each-ref", "refs/heads/", "--format=%(objectname)",
    ]
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = Pipe()
    do {
      try proc.run()
      let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else { return [] }
      let lines = String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .filter { $0.count == 40 && isHex40($0) }
      return Array(Set(lines)).sorted()
    } catch {
      return []
    }
  }

  static func zlibDecompressViaPython(_ data: Data) -> Data? {
    guard let py = python3Path() else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: py)
    proc.arguments = [
      "-c",
      "import zlib,sys; sys.stdout.buffer.write(zlib.decompress(sys.stdin.buffer.read()))",
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
      guard proc.terminationStatus == 0 else { return nil }
      return out
    } catch {
      return nil
    }
  }

  static func zlibCompressViaPython(_ data: Data) -> Data? {
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

  static func zlibDecompressViaPythonRequired(_ data: Data) throws -> Data {
    try #require(
      zlibDecompressViaPython(data),
      "python3 zlib.decompress failed (invalid zlib stream or subprocess error)."
    )
  }

  static func zlibCompressViaPythonRequired(_ data: Data) throws -> Data {
    try #require(
      zlibCompressViaPython(data),
      "python3 zlib.compress failed (subprocess error)."
    )
  }

  static func zlibAdler32ViaPythonRequired(_ bytes: Data) throws -> UInt32 {
    try #require(
      zlibAdler32ViaPython(bytes),
      "python3 zlib.adler32 failed (subprocess error)."
    )
  }

  static func sha20(fromHex40 hex: String) -> [UInt8]? {
    guard hex.count == 40 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(20)
    var i = hex.startIndex
    while i < hex.endIndex {
      let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
      guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
      out.append(b)
      i = j
    }
    guard out.count == 20 else { return nil }
    return out
  }

  private static func isHex40(_ s: String) -> Bool {
    s.unicodeScalars.allSatisfy { $0.properties.isHexDigit }
  }

}
