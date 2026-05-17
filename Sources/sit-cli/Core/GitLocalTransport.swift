import Foundation
import Sit

/// Git local transport: reads and writes a repository on disk directly,
/// without spawning `git upload-pack` / `git receive-pack` subprocesses.
/// Handles `file://` URLs and POSIX absolute paths.
enum GitLocalTransport {

  // MARK: - URL detection

  static func isLocalURL(_ url: String) -> Bool {
    url.hasPrefix("file://") || (url.hasPrefix("/") && !url.contains("://"))
  }

  static func localPath(from url: String) -> String {
    url.hasPrefix("file://") ? String(url.dropFirst(7)) : url
  }

  // MARK: - Ref advertisement

  static func advertiseFetchRefs(path: String) async throws -> GitSmartHTTP.RefAdvertisement {
    try buildAdvertisement(gitDir: resolveGitDir(path: path))
  }

  static func advertiseRefs(path: String) async throws -> GitSmartHTTP.RefAdvertisement {
    try buildAdvertisement(gitDir: resolveGitDir(path: path))
  }

  // MARK: - Fetch (object graph walk → pack)

  static func fetch(
    path: String,
    wantHashes: [String],
    haveHashes: [String] = [],
    capabilities: Set<String> = []
  ) async throws -> [UInt8] {
    let gitDir = resolveGitDir(path: path)
    let packs = try GitObjectDatabase.openAllPacks(gitDir: gitDir)
    let haveSet = Set(haveHashes)

    var packObjects: [GitPackWriter.PackObject] = []
    var seen = Set<String>()
    var queue: [[UInt8]] = []

    for hex in wantHashes where !haveSet.contains(hex) && !seen.contains(hex) {
      if let sha20 = try? GitHex.decode20(hex) {
        seen.insert(hex)
        queue.append(sha20)
      }
    }

    while !queue.isEmpty {
      let sha20 = queue.removeFirst()
      guard
        let (typeName, payload) = try? GitObjectDatabase.readObject(
          gitDir: gitDir, packs: packs, sha20: sha20)
      else { continue }

      packObjects.append(
        GitPackWriter.PackObject(sha20: sha20, type: typeNumber(typeName), payload: payload))

      for childSha20 in childSHAs(type: typeName, payload: payload) {
        let childHex = GitHex.encodeLower(childSha20)
        guard !haveSet.contains(childHex) && !seen.contains(childHex) else { continue }
        seen.insert(childHex)
        queue.append(childSha20)
      }
    }

    guard !packObjects.isEmpty else { return [] }
    return try GitPackWriter.write(objects: packObjects).packData
  }

  // MARK: - Push (import pack + update refs)

  static func push(
    path: String,
    refUpdates: [(oldSha40: String, newSha40: String, refName: String)],
    packData: [UInt8],
    capabilities: Set<String> = []
  ) async throws -> [String] {
    let gitDir = resolveGitDir(path: path)

    if !packData.isEmpty {
      let packs = try GitObjectDatabase.openAllPacks(gitDir: gitDir)
      _ = try GitPackImporter.importPack(gitDir: gitDir, packData: packData, packs: packs)
    }

    var results: [String] = []
    for (oldSha, newSha, refName) in refUpdates {
      do {
        let currentSha =
          (try? GitRefs.readRef(gitDir: gitDir, refName: refName))
          ?? String(repeating: "0", count: 40)
        guard currentSha.lowercased() == oldSha.lowercased() else {
          results.append("ng \(refName) non-fast-forward")
          continue
        }
        try GitRefs.updateRef(gitDir: gitDir, refName: refName, sha40HexLower: newSha)
        results.append("ok \(refName)")
      } catch {
        results.append("ng \(refName) \(error)")
      }
    }
    return results
  }

  // MARK: - Private helpers

  /// Returns the `.git` directory for `path`, handling both working trees and bare repos.
  private static func resolveGitDir(path: String) -> URL {
    let url = URL(fileURLWithPath: path)
    let candidate = url.appendingPathComponent(".git")
    if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    return url
  }

  private static func buildAdvertisement(gitDir: URL) throws -> GitSmartHTTP.RefAdvertisement {
    var advertised: [GitSmartHTTP.AdvertisedRef] = []
    for (name, hex) in try allRefs(gitDir: gitDir) {
      guard let sha20 = try? GitHex.decode20(hex) else { continue }
      advertised.append(GitSmartHTTP.AdvertisedRef(sha20: sha20, name: name, capabilities: []))
    }
    return GitSmartHTTP.RefAdvertisement(refs: advertised, capabilities: [])
  }

  /// All refs as (name, 40-hex-sha) pairs; loose refs shadow packed-refs entries.
  private static func allRefs(gitDir: URL) throws -> [(name: String, hex: String)] {
    var packed: [String: String] = [:]
    let packedURL = gitDir.appendingPathComponent("packed-refs")
    if let text = try? String(contentsOf: packedURL, encoding: .utf8) {
      for line in text.split(separator: "\n") {
        let s = String(line)
        guard !s.hasPrefix("#"), !s.hasPrefix("^") else { continue }
        let parts = s.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 40 else { continue }
        packed[String(parts[1])] = String(parts[0])
      }
    }

    var loose: [String: String] = [:]
    let refsDir = gitDir.appendingPathComponent("refs")
    if FileManager.default.fileExists(atPath: refsDir.path) {
      scanLooseRefs(at: refsDir, prefix: "refs", into: &loose)
    }

    var result: [(String, String)] = []
    var seen = Set<String>()
    for (name, hex) in loose {
      result.append((name, hex))
      seen.insert(name)
    }
    for (name, hex) in packed where !seen.contains(name) { result.append((name, hex)) }
    return result
  }

  private static func scanLooseRefs(at dir: URL, prefix: String, into out: inout [String: String]) {
    let fm = FileManager.default
    guard
      let items = try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
      )
    else { return }
    for item in items {
      let name = "\(prefix)/\(item.lastPathComponent)"
      var isDir: ObjCBool = false
      let exists = fm.fileExists(atPath: item.path, isDirectory: &isDir)
      guard exists else { continue }
      if isDir.boolValue {
        scanLooseRefs(at: item, prefix: name, into: &out)
      } else if let hex = try? String(contentsOf: item, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), hex.count == 40
      {
        out[name] = hex
      }
    }
  }

  private static func childSHAs(type: String, payload: [UInt8]) -> [[UInt8]] {
    switch type {
    case "commit": return commitChildren(payload)
    case "tree": return treeChildren(payload)
    case "tag": return tagChildren(payload)
    default: return []
    }
  }

  private static func commitChildren(_ payload: [UInt8]) -> [[UInt8]] {
    let (treeHex, parents) = GitObjectParser.parseCommit(payload)
    var result: [[UInt8]] = []
    if let sha20 = try? GitHex.decode20(treeHex) { result.append(sha20) }
    for hex in parents {
      if let sha20 = try? GitHex.decode20(hex) { result.append(sha20) }
    }
    return result
  }

  private static func treeChildren(_ payload: [UInt8]) -> [[UInt8]] {
    GitObjectParser.parseTree(payload).map(\.sha20)
  }

  private static func tagChildren(_ payload: [UInt8]) -> [[UInt8]] {
    if let sha20 = GitObjectParser.tagObjectSHA(payload) { return [sha20] }
    return []
  }

  private static func typeNumber(_ name: String) -> Int {
    GitObjectParser.typeInt(from: name)
  }
}
