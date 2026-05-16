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

  // MARK: - URL conversion

  /// Detect SSH Git URLs and return the parsed SSH URL, or `nil` for HTTP(S) URLs.
  private static func detectSSH(_ url: String) -> GitSSHTransport.SSHURL? {
    GitSSHTransport.parseSSHURL(url)
  }

  /// Convert SSH-style Git URLs to HTTPS so `async-http-client` can handle them.
  /// - `git@github.com:user/repo.git` → `https://github.com/user/repo.git`
  /// - `ssh://git@github.com/user/repo.git` → `https://github.com/user/repo.git`
  /// - `https://…` / `http://…` → returned unchanged
  private static func convertToHTTPURL(_ url: String) -> String {
    // Already HTTP(S)
    if url.hasPrefix("https://") || url.hasPrefix("http://") {
      return url
    }
    // ssh://git@host/path → https://host/path
    if url.hasPrefix("ssh://") {
      let rest = String(url.dropFirst(6))
      let noUser = rest.replacingOccurrences(of: "git@", with: "")
      return "https://\(noUser)"
    }
    // git@host:path → https://host/path
    if url.hasPrefix("git@") {
      let rest = String(url.dropFirst(4))
      let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count == 2 {
        return "https://\(parts[0])/\(parts[1])"
      }
    }
    // Fallback: assume it needs https://
    if !url.contains("://") {
      return "https://\(url)"
    }
    return url
  }

  // MARK: - Public entry point

  /// Push the current branch to its configured upstream remote (or `remoteName`
  /// if given), using the given refspecs (or the default push refspec).
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
        gitDir: gitDir,
        branch: branch,
        remoteName: remoteName)
    else {
      throw Error.noUpstreamConfigured(branch)
    }

    let rawURL = dest.remote.resolvedPushURL
    guard !rawURL.isEmpty else { throw Error.noRemoteURL }

    let pushRefspecs = refspecs.isEmpty ? dest.refspecs : refspecs

    // 3. Our branch tip
    guard let ourSHA = try GitRefs.readRef(gitDir: gitDir, refName: branchRef) else {
      throw Error.unbornBranch(branch)
    }

    // 4. Discover remote refs (dispatch on transport)
    let advert: GitSmartHTTP.RefAdvertisement
    let displayURL: String

    if let ssh = detectSSH(rawURL) {
      displayURL = "git@\(ssh.host):\(ssh.path)"
      advert = try await GitSSHTransport.advertiseRefs(ssh: ssh)
    } else {
      displayURL = convertToHTTPURL(rawURL)
      advert = try await GitSmartHTTP.advertiseRefs(url: displayURL)
    }

    // 5. Resolve refspecs into (remote ref, our SHA, remote SHA) triples
    var refUpdates: [(oldSha40: String, newSha40: String, refName: String)] = []
    var remoteSHAsToAvoid = Set<String>()

    for spec in pushRefspecs {
      let (_, dst) = parseRefspec(spec, branch: branch, branchRef: branchRef)
      let remoteSHA = advert.refs.first { $0.name == dst }?.sha20
      let remoteHex = remoteSHA.map { GitHex.encodeLower($0) } ?? String(repeating: "0", count: 40)
      refUpdates.append((oldSha40: remoteHex, newSha40: ourSHA, refName: dst))
      if let rh = remoteSHA.map({ GitHex.encodeLower($0) }) {
        remoteSHAsToAvoid.insert(rh)
      }
    }

    // 6. Collect and pack objects the remote doesn't have
    let packs = try GitObjectDatabase.openAllPacks(gitDir: gitDir)
    let objects = try collectObjectsToPush(
      gitDir: gitDir,
      packs: packs,
      tipHex: ourSHA,
      remoteHexes: remoteSHAsToAvoid)

    // 7. Nothing to push if remote is already up-to-date
    if objects.isEmpty {
      print("Everything up-to-date")
      return
    }

    let packResult = try GitPackWriter.write(objects: objects)

    // 8. Send to remote (dispatch on transport)
    let results: [String]
    if let ssh = detectSSH(rawURL) {
      results = try await GitSSHTransport.push(
        ssh: ssh,
        refUpdates: refUpdates,
        packData: packResult.packData,
        capabilities: advert.capabilities)
    } else {
      results = try await GitSmartHTTP.push(
        url: convertToHTTPURL(rawURL),
        refUpdates: refUpdates,
        packData: packResult.packData,
        capabilities: advert.capabilities)
    }

    // 9. Report results
    var ok = true
    for line in results {
      print(line)
      if line.hasPrefix("ng ") { ok = false }
    }
    guard ok else { throw Error.pushRejected("Push rejected by remote") }

    // 10. Update remote-tracking refs
    for update in refUpdates {
      let refName = update.refName
      guard refName.hasPrefix("refs/heads/") else { continue }
      let remoteBranch = refName.replacingOccurrences(of: "refs/heads/", with: "")
      let trackingRef = "refs/remotes/\(dest.remote.name)/\(remoteBranch)"
      try GitRefs.updateRef(
        gitDir: gitDir, refName: trackingRef, sha40HexLower: update.newSha40)
    }

    print("Pushed \(branch) to \(dest.remote.name) (\(displayURL))")
  }

  // MARK: - Refspec parsing

  /// Parse a push refspec like `refs/heads/main:refs/heads/main` or just
  /// `main` into `(source, destination)` ref names.
  private static func parseRefspec(
    _ spec: String, branch: String, branchRef: String
  ) -> (src: String, dst: String) {
    let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let src: String
    let dst: String
    if parts.count == 2 {
      src = expandShortRef(String(parts[0]))
      dst = expandShortRef(String(parts[1]))
    } else {
      // Single arg: push current branch to same name
      src = branchRef
      dst = "refs/heads/\(branch)"
    }
    return (src, dst)
  }

  /// Expand a short ref name like `main` → `refs/heads/main`.
  private static func expandShortRef(_ name: String) -> String {
    if name.hasPrefix("refs/") { return name }
    if name == "HEAD" { return "HEAD" }
    return "refs/heads/\(name)"
  }

  // MARK: - Object graph walking

  /// Collect all objects reachable from `tipHex` that are not already
  /// reachable from any SHA in `remoteHexes`.
  private static func collectObjectsToPush(
    gitDir: URL,
    packs: [GitPack],
    tipHex: String,
    remoteHexes: Set<String>
  ) throws -> [GitPackWriter.PackObject] {
    var objects: [GitPackWriter.PackObject] = []
    var visited: Set<String> = remoteHexes  // Don't traverse beyond what remote has
    var queue: [String] = [tipHex]

    while let shaHex = queue.first {
      queue.removeFirst()
      if visited.contains(shaHex) { continue }
      visited.insert(shaHex)

      let sha20 = try GitHex.decode20(shaHex)
      let (typeStr, payload) = try GitObjectDatabase.readObject(
        gitDir: gitDir, packs: packs, sha20: sha20)

      let typeInt = typeStrToInt(typeStr)
      objects.append(
        GitPackWriter.PackObject(sha20: sha20, type: typeInt, payload: payload))

      switch typeStr {
      case "commit":
        let (treeHex, parents) = parseCommit(payload)
        queue.append(treeHex)
        queue.append(contentsOf: parents)
      case "tree":
        for entry in parseTree(payload) {
          queue.append(entry.shaHex)
        }
      case "blob", "tag":
        break
      default:
        break
      }
    }

    return objects
  }

  private static func typeStrToInt(_ t: String) -> Int {
    switch t {
    case "commit": return 1
    case "tree": return 2
    case "blob": return 3
    case "tag": return 4
    default: return 1
    }
  }

  // MARK: - Commit parsing

  /// Extract tree and parent SHAs from a commit payload.
  private static func parseCommit(_ payload: [UInt8]) -> (
    treeHex: String, parentHexes: [String]
  ) {
    let str = String(decoding: payload, as: UTF8.self)
    var treeHex = ""
    var parents: [String] = []

    for line in str.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.isEmpty { break }  // header/body separator
      if line.hasPrefix("tree ") {
        treeHex = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
      } else if line.hasPrefix("parent ") {
        parents.append(
          String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces))
      }
    }

    return (treeHex, parents)
  }

  // MARK: - Tree parsing

  private struct TreeEntry {
    let shaHex: String
  }

  /// Extract entry SHAs from a tree payload.
  private static func parseTree(_ payload: [UInt8]) -> [TreeEntry] {
    var entries: [TreeEntry] = []
    var pos = 0

    while pos < payload.count {
      // Scan past "mode " — find the space
      guard let spaceIdx = payload[pos...].firstIndex(of: UInt8(ascii: " "))
      else { break }
      pos = spaceIdx + 1

      // Scan past "name\0" — find the null
      guard let nullIdx = payload[pos...].firstIndex(of: 0) else { break }
      pos = nullIdx + 1

      // Read 20-byte SHA
      guard pos + 20 <= payload.count else { break }
      let sha20 = Array(payload[pos..<(pos + 20)])
      pos += 20

      entries.append(TreeEntry(shaHex: GitHex.encodeLower(sha20)))
    }

    return entries
  }
}
