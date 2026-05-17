import Foundation
import Subprocess
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

  // MARK: - Git helpers (async)

  /// Unique 40-hex object names reachable from **any ref** (`git rev-list --objects --all`).
  static func gitRevListUniqueShas40(packageRoot: URL) async -> [String] {
    guard let git = gitExecutable() else { return [] }
    return await runGitLines(
      git: git,
      arguments: ["-C", packageRoot.path, "rev-list", "--objects", "--all"]
    ) { lines in
      var seen = Set<String>()
      for line in lines {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = parts.first else { continue }
        let sha = String(first)
        guard sha.count == 40, Self.isHex40(sha) else { continue }
        seen.insert(sha)
      }
      return seen.sorted()
    }
  }

  /// `(mode, type, sha, path)` entries from `git ls-tree -r HEAD`.
  static func gitLsTreeRecursive(packageRoot: URL) async -> [(mode: String, type: String, sha: String, path: String)] {
    guard let git = gitExecutable() else { return [] }
    return await runGitLines(
      git: git,
      arguments: ["-C", packageRoot.path, "ls-tree", "-r", "HEAD"]
    ) { lines in
      var rows: [(String, String, String, String)] = []
      for line in lines {
        let s = String(line)
        let parts = s.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let head = parts[0].split(separator: " ")
        guard head.count >= 3 else { continue }
        rows.append((String(head[0]), String(head[1]), String(head[2]), String(parts[1])))
      }
      return rows
    }
  }

  /// Raw uncompressed bytes (`git cat-file <type> <sha>`).
  static func gitCatFileRaw(packageRoot: URL, type: String, sha: String) async -> Data? {
    guard let git = gitExecutable() else { return nil }
    return await runGitData(
      git: git,
      arguments: ["-C", packageRoot.path, "cat-file", type, sha]
    )
  }

  /// One `git cat-file --batch` round-trip for all `shas`.
  static func gitCatFileBatchRaw(packageRoot: URL, shas: [String]) async -> [(sha: String, type: String, raw: Data)]? {
    guard let git = gitExecutable(), !shas.isEmpty else { return nil }
    let input = Data(shas.joined(separator: "\n").utf8 + [0x0a])
    guard
      let all = await runGitData(
        git: git,
        arguments: ["-C", packageRoot.path, "cat-file", "--batch"],
        stdinData: input
      )
    else { return nil }

    var results: [(String, String, Data)] = []
    results.reserveCapacity(shas.count)
    var i = all.startIndex
    for _ in shas {
      guard let nl = all[i...].firstIndex(of: 0x0a) else { return nil }
      let headerLine = String(decoding: all[i..<nl], as: UTF8.self)
      i = all.index(after: nl)
      let parts = headerLine.split(separator: " ")
      guard parts.count >= 3, let size = Int(parts[2]) else { return nil }
      let sha = String(parts[0])
      let type = String(parts[1])
      guard size >= 0, all.distance(from: i, to: all.endIndex) >= size + 1 else { return nil }
      let payloadEnd = all.index(i, offsetBy: size)
      results.append((sha, type, Data(all[i..<payloadEnd])))
      i = all.index(after: payloadEnd)  // skip trailing newline
    }
    guard i == all.endIndex else { return nil }
    return results
  }

  /// One line per full SHA for each `refs/heads/*` tip.
  static func gitLocalBranchTipCommitShas(packageRoot: URL) async -> [String] {
    guard let git = gitExecutable() else { return [] }
    return await runGitLines(
      git: git,
      arguments: ["-C", packageRoot.path, "for-each-ref", "refs/heads/", "--format=%(objectname)"]
    ) { lines in
      let shas = lines.map(String.init).filter { $0.count == 40 && isHex40($0) }
      return Array(Set(shas)).sorted()
    }
  }

  // MARK: - Python helpers (async)

  static func zlibAdler32ViaPython(_ bytes: Data) async -> UInt32? {
    guard let py = python3Path() else { return nil }
    do {
      let record = try await Subprocess.run(
        .name(py),
        arguments: Arguments([
          "-c",
          "import zlib,sys\nd=sys.stdin.buffer.read()\nsys.stdout.write(str(zlib.adler32(d) & 0xffffffff))",
        ]),
        input: .array(Array(bytes)),
        output: .string(limit: Int.max),
        error: .discarded
      )
      guard record.terminationStatus.isSuccess,
        let s = record.standardOutput,
        let v = UInt32(s.trimmingCharacters(in: .whitespacesAndNewlines), radix: 10)
      else { return nil }
      return v
    } catch {
      return nil
    }
  }

  static func zlibDecompressViaPython(_ data: Data) async -> Data? {
    guard let py = python3Path() else { return nil }
    return await runPythonData(
      py: py,
      code: "import zlib,sys; sys.stdout.buffer.write(zlib.decompress(sys.stdin.buffer.read()))",
      stdinData: data
    )
  }

  static func zlibCompressViaPython(_ data: Data) async -> Data? {
    guard let py = python3Path() else { return nil }
    return await runPythonData(
      py: py,
      code: "import zlib,sys; sys.stdout.buffer.write(zlib.compress(sys.stdin.buffer.read()))",
      stdinData: data
    )
  }

  // MARK: - Required wrappers

  static func zlibDecompressViaPythonRequired(_ data: Data) async throws -> Data {
    try #require(
      await zlibDecompressViaPython(data),
      "python3 zlib.decompress failed (invalid zlib stream or subprocess error)."
    )
  }

  static func zlibCompressViaPythonRequired(_ data: Data) async throws -> Data {
    try #require(
      await zlibCompressViaPython(data),
      "python3 zlib.compress failed (subprocess error)."
    )
  }

  static func zlibAdler32ViaPythonRequired(_ bytes: Data) async throws -> UInt32 {
    try #require(
      await zlibAdler32ViaPython(bytes),
      "python3 zlib.adler32 failed (subprocess error)."
    )
  }

  // MARK: - Low-level runners

  private static func runGitData(
    git: String,
    arguments: [String],
    stdinData: Data? = nil
  ) async -> Data? {
    do {
      let record: ExecutionRecord<BytesOutput, DiscardedOutput>
      if let stdinData {
        record = try await Subprocess.run(
          .name(git),
          arguments: Arguments(arguments),
          input: .array(Array(stdinData)),
          output: .bytes(limit: Int.max),
          error: .discarded
        )
      } else {
        record = try await Subprocess.run(
          .name(git),
          arguments: Arguments(arguments),
          output: .bytes(limit: Int.max),
          error: .discarded
        )
      }
      guard record.terminationStatus.isSuccess else { return nil }
      return Data(record.standardOutput)
    } catch {
      return nil
    }
  }

  private static func runGitLines<T>(
    git: String,
    arguments: [String],
    transform: ([Substring]) -> T
  ) async -> T {
    do {
      let record = try await Subprocess.run(
        .name(git),
        arguments: Arguments(arguments),
        output: .string(limit: Int.max),
        error: .discarded
      )
      guard record.terminationStatus.isSuccess, let text = record.standardOutput else {
        return transform([])
      }
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      return transform(lines)
    } catch {
      return transform([])
    }
  }

  private static func runPythonData(
    py: String,
    code: String,
    stdinData: Data
  ) async -> Data? {
    do {
      let record = try await Subprocess.run(
        .name(py),
        arguments: Arguments(["-c", code]),
        input: .array(Array(stdinData)),
        output: .bytes(limit: Int.max),
        error: .discarded
      )
      guard record.terminationStatus.isSuccess else { return nil }
      return Data(record.standardOutput)
    } catch {
      return nil
    }
  }

  // MARK: - Utilities

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
