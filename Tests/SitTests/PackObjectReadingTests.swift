import Foundation
import Subprocess
import Testing

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct PackObjectReadingTests: ~Copyable {
  @Test func readsUndeltifiedBlobFromPackfile() async throws {
    let (pack, idx) = try Self.loadSitPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let sha = Self.sha20("40755ccd19c2cd3f55d2e2e15a1d2f50eabe2f10")
    let got = try git.serializedObject(sha20: sha)
    let want = try await Self.gitCatFile(
      packageRoot: Self.packageRoot(),
      args: ["cat-file", "blob", "40755ccd19c2cd3f55d2e2e15a1d2f50eabe2f10"]
    )
    #expect(Array(got) == want)
  }

  @Test func readsUndeltifiedCommitFromPackfile() async throws {
    let (pack, idx) = try Self.loadSitPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let sha = Self.sha20("aed4b92c79f9142fdf2aeb920e7105302d14e9af")
    let got = try git.serializedObject(sha20: sha)
    let want = try await Self.gitCatFile(
      packageRoot: Self.packageRoot(),
      args: ["cat-file", "commit", "aed4b92c79f9142fdf2aeb920e7105302d14e9af"]
    )
    #expect(Array(got) == want)
  }

  @Test func readsOfsDeltaBlobFromPackfile() async throws {
    let (pack, idx) = try Self.loadSitPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let sha = Self.sha20("608b965d0fae32711d0c5a03de66c8c2ebc82f66")
    let got = try git.serializedObject(sha20: sha)
    let want = try await Self.gitCatFile(
      packageRoot: Self.packageRoot(),
      args: ["cat-file", "blob", "608b965d0fae32711d0c5a03de66c8c2ebc82f66"]
    )
    #expect(Array(got) == want)
  }

  @Test func readsTreeFromPackfile() async throws {
    let (pack, idx) = try Self.loadSitPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let sha = Self.sha20("1695d68b7d4da126abca17c308ef3729ecf5e6d3")
    let got = try git.serializedObject(sha20: sha)
    let want = try await Self.gitCatFile(
      packageRoot: Self.packageRoot(),
      args: ["cat-file", "tree", "1695d68b7d4da126abca17c308ef3729ecf5e6d3"]
    )
    #expect(Array(got) == want)
  }

  @Test func readsEveryIndexedReachableObjectInSitPackMatchesGitCatFile() async throws {
    let root = Self.packageRoot()
    let shas = await GitDogfoodHelpers.gitRevListUniqueShas40(packageRoot: root)
    guard !shas.isEmpty else {
      Issue.record("skip: git rev-list --objects --all produced no SHAs")
      return
    }
    guard let batch = await GitDogfoodHelpers.gitCatFileBatchRaw(packageRoot: root, shas: shas) else {
      Issue.record("skip: git cat-file --batch failed")
      return
    }
    let (pack, idx) = try Self.loadSitPack()
    let gitPack = try GitPack(packBytes: pack, indexBytes: idx)
    let allowed: Set<String> = ["blob", "tree", "commit", "tag"]
    var matched = 0
    for (sha, type, _) in batch {
      guard allowed.contains(type) else { continue }
      guard let shaBytes = GitDogfoodHelpers.sha20(fromHex40: sha) else { continue }
      guard gitPack.index.offset(for: shaBytes) != nil else { continue }
      let got = try gitPack.serializedObject(sha20: shaBytes)
      guard let want = await GitDogfoodHelpers.gitCatFileRaw(packageRoot: root, type: type, sha: sha) else {
        Issue.record("skip: git cat-file \(type) \(sha) failed")
        return
      }
      #expect(Array(got) == Array(want))
      matched += 1
    }
    guard matched > 0 else {
      Issue.record("skip: no rev-list --all objects from this repo appear in pack-58dfe777… idx")
      return
    }
  }

  private static func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
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
    var out: [UInt8] = []
    out.reserveCapacity(20)
    var i = hex.startIndex
    while i < hex.endIndex {
      let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
      let pair = hex[i..<j]
      guard let b = UInt8(pair, radix: 16) else { fatalError("bad hex") }
      out.append(b)
      i = j
    }
    precondition(out.count == 20)
    return out
  }

  private static func gitCatFile(packageRoot: URL, args: [String]) async throws -> [UInt8] {
    guard
      let git = ["/usr/bin/git", "/bin/git", "/usr/local/bin/git"].first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
      })
    else {
      throw GitPackError.truncatedPack
    }
    let record = try await Subprocess.run(
      .name(git),
      arguments: Arguments(["-C", packageRoot.path] + args),
      output: .bytes(limit: Int.max),
      error: .discarded
    )
    guard record.terminationStatus.isSuccess else {
      throw GitPackError.truncatedPack
    }
    return record.standardOutput
  }
}
