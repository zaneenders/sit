import Foundation
import Sit

/// Native push implementation using Sit's smart HTTP client, config parser,
/// pack writer, and object database.
enum GitPush {

  enum Error: Swift.Error, Equatable {
    case detachedHEAD
    case unbornBranch(String)
    case noUpstreamConfigured(String)
    case remoteNotFound(String)
    case noRemoteURL
    case pushRejected(String)
  }

  // Thrown internally when all objects are already on the remote.
  private struct NothingToPush: Swift.Error {}

  // MARK: - Public entry point

  static func push(
    gitDir: URL,
    workTree: URL,
    remoteName: String? = nil,
    refspecs: [String] = []
  ) async throws {
    // 1. Resolve current branch
    guard let branchRef = try GitHEAD.currentBranchRef(gitDir: gitDir) else {
      throw Error.detachedHEAD
    }
    let branch = branchRef.replacingOccurrences(of: "refs/heads/", with: "")

    // 2. Resolve remote + push refspecs
    guard
      let dest = try GitRemoteConfig.resolvePushDestination(
        gitDir: gitDir, branch: branch, remoteName: remoteName)
    else { throw Error.noUpstreamConfigured(branch) }

    let rawURL = dest.remote.resolvedPushURL
    guard !rawURL.isEmpty else { throw Error.noRemoteURL }

    let pushRefspecs = refspecs.isEmpty ? dest.refspecs : refspecs

    // 3. Open packs once — captured by the SSH closure and reused by other paths.
    let packs = try GitObjectDatabase.openAllPacks(gitDir: gitDir)

    // 4. Dispatch on transport
    let results: [String]
    let displayURL: String

    if let ssh = GitURL.detectSSH(rawURL) {
      // Single SSH session: advertisement + push in one connection.
      displayURL = "git@\(ssh.host):\(ssh.path)"
      do {
        results = try await GitSSHTransport.push(ssh: ssh) { advert in
          let (refUpdates, packData) = try Self.resolveRefUpdatesAndPack(
            advert: advert, gitDir: gitDir, packs: packs,
            pushRefspecs: pushRefspecs, branch: branch, branchRef: branchRef)
          return GitSSHTransport.encodePushRequest(
            refUpdates: refUpdates, packData: packData, capabilities: advert.capabilities)
        }
      } catch is NothingToPush {
        print("Everything up-to-date")
        return
      }
    } else {
      // HTTP or local: get advertisement first, then push.
      let advert: GitSmartHTTP.RefAdvertisement
      if GitLocalTransport.isLocalURL(rawURL) {
        displayURL = rawURL
        advert = try await GitLocalTransport.advertiseRefs(
          path: GitLocalTransport.localPath(from: rawURL))
      } else {
        displayURL = GitURL.convertToHTTPURL(rawURL)
        advert = try await GitSmartHTTP.advertiseRefs(url: displayURL)
      }

      let refUpdates: [(oldSha40: String, newSha40: String, refName: String)]
      let packData: [UInt8]
      do {
        (refUpdates, packData) = try Self.resolveRefUpdatesAndPack(
          advert: advert, gitDir: gitDir, packs: packs,
          pushRefspecs: pushRefspecs, branch: branch, branchRef: branchRef)
      } catch is NothingToPush {
        print("Everything up-to-date")
        return
      }

      if GitLocalTransport.isLocalURL(rawURL) {
        results = try await GitLocalTransport.push(
          path: GitLocalTransport.localPath(from: rawURL),
          refUpdates: refUpdates, packData: packData, capabilities: advert.capabilities)
      } else {
        results = try await GitSmartHTTP.push(
          url: displayURL, refUpdates: refUpdates, packData: packData,
          capabilities: advert.capabilities)
      }
    }

    // 5. Report results
    var ok = true
    for line in results {
      print(line)
      if line.hasPrefix("ng ") { ok = false }
    }
    guard ok else { throw Error.pushRejected("Push rejected by remote") }

    // 6. Update remote-tracking refs (works for all transports: src SHAs are still on disk).
    for spec in pushRefspecs {
      let (src, dst) = parseRefspec(spec, branch: branch, branchRef: branchRef)
      guard dst.hasPrefix("refs/heads/"),
        let srcSHA = try? GitRefs.readRef(gitDir: gitDir, refName: src)
      else { continue }
      let remoteBranch = String(dst.dropFirst(11))
      let trackingRef = "refs/remotes/\(dest.remote.name)/\(remoteBranch)"
      try GitRefs.updateRef(gitDir: gitDir, refName: trackingRef, sha40HexLower: srcSHA)
    }

    print("Pushed \(branch) to \(dest.remote.name) (\(displayURL))")
  }

  // MARK: - Refspec parsing

  static func parseRefspec(
    _ spec: String, branch: String, branchRef: String
  ) -> (src: String, dst: String) {
    let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2 {
      return (expandShortRef(String(parts[0])), expandShortRef(String(parts[1])))
    }
    return (branchRef, "refs/heads/\(branch)")
  }

  private static func expandShortRef(_ name: String) -> String {
    if name.hasPrefix("refs/") { return name }
    if name == "HEAD" { return "HEAD" }
    return "refs/heads/\(name)"
  }

  // MARK: - Build ref updates + pack data

  /// Resolve push refspecs against the advertisement, collect the objects the
  /// remote doesn't have, and write a packfile.  Throws `NothingToPush` when
  /// every reachable object is already known to the remote.
  static func resolveRefUpdatesAndPack(
    advert: GitSmartHTTP.RefAdvertisement,
    gitDir: URL,
    packs: [GitPack],
    pushRefspecs: [String],
    branch: String,
    branchRef: String
  ) throws -> ([(oldSha40: String, newSha40: String, refName: String)], [UInt8]) {
    // Seed the "remote already has" set with every advertised SHA.
    var remoteSHAsToAvoid = Set<String>()
    for ref in advert.refs where ref.sha20 != [UInt8](repeating: 0, count: 20) {
      remoteSHAsToAvoid.insert(GitHex.encodeLower(ref.sha20))
    }

    var refUpdates: [(oldSha40: String, newSha40: String, refName: String)] = []
    for spec in pushRefspecs {
      let (src, dst) = parseRefspec(spec, branch: branch, branchRef: branchRef)
      guard let srcSHA = try GitRefs.readRef(gitDir: gitDir, refName: src) else {
        throw Error.unbornBranch(src)
      }
      let remoteSHA = advert.refs.first { $0.name == dst }?.sha20
      let remoteHex =
        remoteSHA.map { GitHex.encodeLower($0) } ?? String(repeating: "0", count: 40)
      refUpdates.append((oldSha40: remoteHex, newSha40: srcSHA, refName: dst))
    }

    let tipHexes = refUpdates.map(\.newSha40)
    let objects = try collectObjectsToPush(
      gitDir: gitDir, packs: packs, tipHexes: tipHexes, remoteHexes: remoteSHAsToAvoid)

    guard !objects.isEmpty else { throw NothingToPush() }

    let packResult = try GitPackWriter.write(objects: objects)
    return (refUpdates, packResult.packData)
  }

  // MARK: - Object graph walking

  /// Collect all objects reachable from any tip in `tipHexes` that are not
  /// reachable from any SHA in `remoteHexes`.
  private static func collectObjectsToPush(
    gitDir: URL,
    packs: [GitPack],
    tipHexes: [String],
    remoteHexes: Set<String>
  ) throws -> [GitPackWriter.PackObject] {
    var objects: [GitPackWriter.PackObject] = []
    var visited: Set<String> = remoteHexes
    var queue: [String] = tipHexes.filter { !remoteHexes.contains($0) }

    while let shaHex = queue.first {
      queue.removeFirst()
      if visited.contains(shaHex) { continue }
      visited.insert(shaHex)

      let sha20 = try GitHex.decode20(shaHex)
      let (typeStr, payload) = try GitObjectDatabase.readObject(
        gitDir: gitDir, packs: packs, sha20: sha20)

      let typeInt = GitObjectParser.typeInt(from: typeStr)
      objects.append(
        GitPackWriter.PackObject(sha20: sha20, type: typeInt, payload: payload))

      switch typeStr {
      case "commit":
        let (treeHex, parents) = GitObjectParser.parseCommit(payload)
        queue.append(treeHex)
        queue.append(contentsOf: parents)
      case "tree":
        for entry in GitObjectParser.parseTree(payload) {
          queue.append(GitHex.encodeLower(entry.sha20))
        }
      default:
        break
      }
    }

    return objects
  }
}
