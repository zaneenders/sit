import Foundation
import Subprocess
import Testing

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct PackObjectReadingTests: ~Copyable {
  @Test func readsUndeltifiedBlobFromPackfile() async throws {
    let (pack, idx) = try Self.loadSitPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let sha = Self.sha20("90983f8ae8fe9c65756a363085cda5013c2e4498")
    let got = try git.serializedObject(sha20: sha)
    let want = try await Self.gitCatFile(
      packageRoot: Self.packageRoot(),
      args: ["cat-file", "blob", "90983f8ae8fe9c65756a363085cda5013c2e4498"]
    )
    #expect(Array(got) == want)
  }

  @Test func readsUndeltifiedCommitFromPackfile() async throws {
    let (pack, idx) = try Self.loadSitPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let sha = Self.sha20("cb68a4e9d8bef20c2c1e57339b4eb9eb47f83afa")
    let got = try git.serializedObject(sha20: sha)
    let want = try await Self.gitCatFile(
      packageRoot: Self.packageRoot(),
      args: ["cat-file", "commit", "cb68a4e9d8bef20c2c1e57339b4eb9eb47f83afa"]
    )
    #expect(Array(got) == want)
  }

  @Test func readsOfsDeltaBlobFromPackfile() async throws {
    let (pack, idx) = try Self.loadSitPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let sha = Self.sha20("7c04d3e507ca0603378812cca832cdd3f2985699")
    let got = try git.serializedObject(sha20: sha)
    let want = try await Self.gitCatFile(
      packageRoot: Self.packageRoot(),
      args: ["cat-file", "blob", "7c04d3e507ca0603378812cca832cdd3f2985699"]
    )
    #expect(Array(got) == want)
  }

  @Test func readsTreeFromPackfile() async throws {
    let (pack, idx) = try Self.loadSitPack()
    let git = try GitPack(packBytes: pack, indexBytes: idx)
    let sha = Self.sha20("b688726bf0de0d7460a249fc286d931cbb4764a8")
    let got = try git.serializedObject(sha20: sha)
    let want = try await Self.gitCatFile(
      packageRoot: Self.packageRoot(),
      args: ["cat-file", "tree", "b688726bf0de0d7460a249fc286d931cbb4764a8"]
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
      Issue.record("skip: no rev-list --all objects from this repo appear in the pack idx")
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
    let packDir = root.appendingPathComponent(".git/objects/pack", isDirectory: true)
    let fm = FileManager.default
    guard
      let packName = try fm.contentsOfDirectory(atPath: packDir.path)
        .first(where: { $0.hasSuffix(".pack") })?
        .replacingOccurrences(of: ".pack", with: "")
    else {
      throw GitPackError.badPackSignature  // no pack found
    }
    let packURL = packDir.appendingPathComponent("\(packName).pack")
    let idxURL = packDir.appendingPathComponent("\(packName).idx")
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
