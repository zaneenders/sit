import Foundation
import Sit

enum GitFetch {

  enum Error: Swift.Error, Equatable {
    case detachedHEAD
    case noUpstreamConfigured(String)
    case remoteNotFound(String)
    case noRemoteURL
    case noRefsToFetch
    case fetchFailed(String)
  }

  /// Fetch refs from a remote and update remote-tracking refs.
  ///
  /// - Returns: Map of remote ref name → fetched SHA hex
  static func fetch(
    gitDir: URL,
    workTree: URL,
    remote: GitRemote,
    refspecs: [String] = []
  ) async throws -> [String: String] {
    let rawURL = remote.url
    guard !rawURL.isEmpty else { throw Error.noRemoteURL }

    let packs = try GitObjectDatabase.openAllPacks(gitDir: gitDir)

    // 1. Discover remote refs
    let advert: GitSmartHTTP.RefAdvertisement
    let displayURL: String

    if let ssh = GitURL.detectSSH(rawURL) {
      displayURL = "git@\(ssh.host):\(ssh.path)"
      advert = try await GitSSHTransport.advertiseFetchRefs(ssh: ssh)
    } else if GitLocalTransport.isLocalURL(rawURL) {
      displayURL = rawURL
      advert = try await GitLocalTransport.advertiseFetchRefs(
        path: GitLocalTransport.localPath(from: rawURL))
    } else {
      displayURL = GitURL.convertToHTTPURL(rawURL)
      advert = try await GitSmartHTTP.advertiseFetchRefs(url: displayURL)
    }

    // 2. Determine which refs to fetch
    let fetchRefs: [(name: String, sha20: [UInt8])]
    if refspecs.isEmpty {
      // Default: fetch all refs (HEAD + branches + tags) — same as `git fetch`
      fetchRefs = advert.refs.map { ($0.name, $0.sha20) }
        .filter { $0.sha20 != [UInt8](repeating: 0, count: 20) }
    } else {
      fetchRefs = resolveFetchRefspecs(refspecs, advert: advert)
    }

    guard !fetchRefs.isEmpty else {
      throw Error.noRefsToFetch
    }

    // 3. Collect want/have hashes
    let wantHashes = fetchRefs.map { GitHex.encodeLower($0.sha20) }
    let haveHashes = Self.buildHaveHashes(gitDir: gitDir)

    // 4. Fetch pack from remote
    let packData: [UInt8]
    if let ssh = GitURL.detectSSH(rawURL) {
      packData = try await GitSSHTransport.fetch(
        ssh: ssh,
        wantHashes: Array(wantHashes),
        haveHashes: Array(haveHashes),
        capabilities: advert.capabilities)
    } else if GitLocalTransport.isLocalURL(rawURL) {
      packData = try await GitLocalTransport.fetch(
        path: GitLocalTransport.localPath(from: rawURL),
        wantHashes: Array(wantHashes),
        haveHashes: Array(haveHashes),
        capabilities: advert.capabilities)
    } else {
      packData = try await GitSmartHTTP.fetch(
        url: GitURL.convertToHTTPURL(rawURL),
        wantHashes: Array(wantHashes),
        haveHashes: Array(haveHashes),
        capabilities: advert.capabilities)
    }

    // 5. Import pack objects (skip if server sent no pack)
    let result: GitPackImporter.ImportResult
    if packData.isEmpty {
      result = GitPackImporter.ImportResult(importedSHAs: [], unresolvedDeltas: 0)
    } else {
      result = try GitPackImporter.importPack(
        gitDir: gitDir,
        packData: packData,
        packs: packs)
    }

    if result.unresolvedDeltas > 0 {
      let msg = "warning: \(result.unresolvedDeltas) delta objects could not be resolved\n"
      try? FileHandle.standardError.write(contentsOf: Data(msg.utf8))
    }

    // 6. Update remote-tracking refs
    var fetchedRefs: [String: String] = [:]
    for (refName, sha20) in fetchRefs {
      let shaHex = GitHex.encodeLower(sha20)
      let objectExists =
        result.importedSHAs.contains(shaHex)
        || (try? GitObjectDatabase.readObject(gitDir: gitDir, packs: packs, sha20: sha20)) != nil
      if objectExists {
        // Only update tracking ref if we have the object
        let trackingRef = remoteTrackingRef(remoteName: remote.name, remoteRef: refName)
        if let trackingRef = trackingRef {
          try? GitRefs.updateRef(gitDir: gitDir, refName: trackingRef, sha40HexLower: shaHex)
        }
        fetchedRefs[refName] = shaHex
      }

    }

    return fetchedRefs
  }

  /// Build the set of commit SHAs we can claim to already have.
  ///
  /// Only includes commits from local branches and HEAD — never tracking refs
  /// (refs/remotes/*), because a tracking ref is just a cached pointer and does
  /// not guarantee the object is present in the local object store.
  static func buildHaveHashes(gitDir: URL) -> Set<String> {
    var haveHashes = Set<String>()
    if let headHex = try? GitHEAD.resolveCommitHex(gitDir: gitDir) {
      haveHashes.insert(headHex)
    }

    // Loose refs under refs/heads/
    let refsDir = gitDir.appendingPathComponent("refs/heads", isDirectory: true)
    if FileManager.default.fileExists(atPath: refsDir.path) {
      if let refs = try? collectRefs(in: refsDir, base: gitDir, prefix: "refs/heads/") {
        haveHashes.formUnion(refs.values)
      }
    }

    // Packed refs (refs/heads/* only — never refs/remotes/*)
    let packedURL = gitDir.appendingPathComponent("packed-refs")
    if let text = try? String(contentsOf: packedURL, encoding: .utf8) {
      for line in text.split(separator: "\n") {
        let s = String(line)
        guard !s.hasPrefix("#"), !s.hasPrefix("^") else { continue }
        let parts = s.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 40 else { continue }
        let refName = String(parts[1])
        guard refName.hasPrefix("refs/heads/") else { continue }
        haveHashes.insert(String(parts[0]))
      }
    }

    return haveHashes
  }

  /// Resolve fetch refspecs against the advertisement.
  private static func resolveFetchRefspecs(
    _ refspecs: [String],
    advert: GitSmartHTTP.RefAdvertisement
  ) -> [(name: String, sha20: [UInt8])] {
    var result: [(name: String, sha20: [UInt8])] = []
    for spec in refspecs {
      let parts = spec.split(separator: ":", maxSplits: 1)
      let src = parts.count == 2 ? String(parts[0]) : spec
      let dst = parts.count == 2 ? String(parts[1]) : src

      // Expand short ref names
      let srcExpanded = expandFetchRef(src)
      let dstExpanded = expandFetchRef(dst)

      // Find matching ref in advertisement
      if let match = advert.refs.first(where: { $0.name == srcExpanded }) {
        if match.sha20 != [UInt8](repeating: 0, count: 20) {
          result.append((name: dstExpanded, sha20: match.sha20))
        }
      }
    }
    return result
  }

  private static func expandFetchRef(_ name: String) -> String {
    if name.hasPrefix("refs/") { return name }
    if name == "HEAD" { return "HEAD" }
    return "refs/heads/\(name)"
  }

  private static func remoteTrackingRef(remoteName: String, remoteRef: String) -> String? {
    if remoteRef.hasPrefix("refs/heads/") {
      let branch = String(remoteRef.dropFirst(11))
      return "refs/remotes/\(remoteName)/\(branch)"
    }
    if remoteRef == "HEAD" {
      return "refs/remotes/\(remoteName)/HEAD"
    }
    if remoteRef.hasPrefix("refs/tags/") {
      let tag = String(remoteRef.dropFirst(10))
      return "refs/tags/\(tag)"
    }
    return nil
  }

  /// Collect all refs in a directory (non-recursive).
  private static func collectRefs(
    in dir: URL, base: URL, prefix: String
  ) throws -> [String: String] {
    var refs: [String: String] = [:]
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
      return refs
    }
    for entry in entries {
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), !isDir.boolValue else {
        continue
      }
      let raw = try String(contentsOf: entry, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if raw.count == 40 {
        refs[prefix + entry.lastPathComponent] = raw.lowercased()
      }
    }
    return refs
  }

}
