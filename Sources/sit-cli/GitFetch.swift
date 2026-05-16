import Foundation
import Sit

fileprivate func writeCLIWarningStderr(_ message: String) {
  let msg = "warning: \(message)\n"
  try? FileHandle.standardError.write(contentsOf: Data(msg.utf8))
}

// MARK: - Pack Importer

/// Parses a raw packfile (as received from `git-upload-pack`) and writes every
/// object as a loose object under `.git/objects/`.  Handles undeltified objects
/// (types 1–4) as well as OFS_DELTA (6) and REF_DELTA (7).
enum GitPackImporter {

  /// Errors that can occur during pack import.
  enum Error: Swift.Error, Equatable {
    case truncatedPack(Int)
    case badPackSignature
    case unknownPackVersion(UInt32)
    case unknownObjectType(Int)
    case baseObjectNotFound
    case deltaBaseNotInPack
    case packChecksumMismatch
    case emptyPack
  }

  /// Result of importing a pack.
  struct ImportResult {
    /// 40-hex SHAs of all objects written.
    let importedSHAs: Set<String>
    /// Number of object references that could not be resolved (REF_DELTA with missing base).
    let unresolvedDeltas: Int

    init(importedSHAs: Set<String>, unresolvedDeltas: Int) {
      self.importedSHAs = importedSHAs
      self.unresolvedDeltas = unresolvedDeltas
    }
  }

  /// Process a raw pack and write all objects as loose objects.
  ///
  /// - Parameter gitDir: Path to `.git` directory
  /// - Parameter packData: Raw pack bytes (including header and trailer)
  /// - Parameter packs: Existing pack files for resolving REF_DELTA bases
  /// - Returns: Result with imported SHAs and unresolved count
  static func importPack(
    gitDir: URL,
    packData: [UInt8],
    packs: [GitPack]
  ) throws -> ImportResult {
    guard packData.count >= 12 else { throw Error.truncatedPack(packData.count) }
    guard packData[0] == 0x50, packData[1] == 0x41,
          packData[2] == 0x43, packData[3] == 0x4b else {
      throw Error.badPackSignature
    }
    let version = readBigEndianUInt32(packData, 4)
    guard version == 2 else { throw Error.unknownPackVersion(version) }
    let objectCount = readBigEndianUInt32(packData, 8)
    guard objectCount > 0 else { throw Error.emptyPack }

    // Verify trailing SHA-1
    let bodyEnd = packData.count - 20
    guard bodyEnd >= 12 else {
      throw Error.truncatedPack(packData.count)
    }
    let storedSHA = Array(packData[bodyEnd...])
    let computedSHA = GitSHA1.digest(of: Array(packData[0..<bodyEnd]))
    guard storedSHA == computedSHA else { throw Error.packChecksumMismatch }

    // Tracking: pack offset → (sha20: [UInt8], type: Int, payload: [UInt8])
    struct Imported {
      let sha20: [UInt8]
      let type: Int
      let payload: [UInt8]
    }
    var imported: [Int: Imported] = [:]
    var importedSHAs = Set<String>()
    var unresolvedDeltas = 0

    // Read pack in reverse to handle deltas — deltas may reference later objects
    var pos = 12
    for _ in 0..<Int(objectCount) {
      let objOffset = pos
      let (type, _) = try readPackObjectHeader(packData, pos: &pos)

      switch type {
      case 1, 2, 3, 4:
        // Undeltified: decompress zlib, compute SHA, write as loose
        let (payload, zlibConsumed) = try ZlibLooseObject.decompressPrefix(in: packData, at: pos)
        pos += zlibConsumed

        let typeStr = packTypeName(type)
        let sha20 = try writeLooseObject(gitDir: gitDir, type: typeStr, body: Array(payload))
        let shaHex = GitHex.encodeLower(sha20)

        imported[objOffset] = Imported(sha20: sha20, type: type, payload: Array(payload))
        importedSHAs.insert(shaHex)

      case 6:
        // OFS_DELTA: read negative offset, decompress delta, resolve base, apply
        let negativeOffset = try readVariableWidthInt(packData, pos: &pos)
        let (deltaBody, zlibConsumed) = try ZlibLooseObject.decompressPrefix(in: packData, at: pos)
        pos += zlibConsumed

        let baseOffset = objOffset - Int(negativeOffset)
        guard let base = imported[baseOffset] else {
          // Base not yet imported — attempt to walk back
          // The base should be at an earlier offset; try to reconstruct
          throw Error.deltaBaseNotInPack
        }

        let rebuilt = try PackDelta.apply(base: base.payload, delta: Array(deltaBody))
        let rebuiltTypeStr = packTypeName(base.type)
        let sha20 = try writeLooseObject(gitDir: gitDir, type: rebuiltTypeStr, body: Array(rebuilt))
        let shaHex = GitHex.encodeLower(sha20)

        imported[objOffset] = Imported(sha20: sha20, type: base.type, payload: Array(rebuilt))
        importedSHAs.insert(shaHex)

      case 7:
        // REF_DELTA: read base SHA, decompress delta, look up base, apply
        guard pos + 20 <= packData.count else { throw Error.truncatedPack(packData.count) }
        let baseSHA = Array(packData[pos..<(pos + 20)])
        pos += 20
        let (deltaBody, zlibConsumed) = try ZlibLooseObject.decompressPrefix(in: packData, at: pos)
        pos += zlibConsumed

        // Look up base: first in newly imported objects, then in existing packs
        let basePayload: [UInt8]
        let baseType: Int
        if let known = imported.first(where: { $0.value.sha20 == baseSHA }) {
          basePayload = known.value.payload
          baseType = known.value.type
        } else if let (typeStr, payload) = try? GitObjectDatabase.readObject(
          gitDir: gitDir, packs: packs, sha20: baseSHA) {
          basePayload = payload
          baseType = typeStrToInt(typeStr)
        } else {
          unresolvedDeltas += 1
          continue
        }

        let rebuilt = try PackDelta.apply(base: basePayload, delta: Array(deltaBody))
        let rebuiltTypeStr = packTypeName(baseType)
        let sha20 = try writeLooseObject(gitDir: gitDir, type: rebuiltTypeStr, body: Array(rebuilt))
        let shaHex = GitHex.encodeLower(sha20)

        imported[objOffset] = Imported(sha20: sha20, type: baseType, payload: Array(rebuilt))
        importedSHAs.insert(shaHex)

      default:
        throw Error.unknownObjectType(type)
      }
    }

    return ImportResult(importedSHAs: importedSHAs, unresolvedDeltas: unresolvedDeltas)
  }

  // MARK: - Pack header helpers

  private static func readPackObjectHeader(
    _ pack: [UInt8],
    pos: inout Int
  ) throws -> (type: Int, size: Int) {
    guard pos < pack.count else { throw Error.truncatedPack(pack.count) }
    var c = pack[pos]
    pos += 1
    let type = (Int(c) >> 4) & 7
    var size = Int(c & 0x0f)
    var shift = 4
    while c & 0x80 != 0 {
      guard pos < pack.count else { throw Error.truncatedPack(pack.count) }
      c = pack[pos]
      pos += 1
      size |= Int(c & 0x7f) << shift
      shift += 7
    }
    return (type, size)
  }

  private static func readVariableWidthInt(_ pack: [UInt8], pos: inout Int) throws -> Int64 {
    guard pos < pack.count else { throw Error.truncatedPack(pack.count) }
    var c = pack[pos]
    pos += 1
    var v = Int64(c & 127)
    while c & 128 != 0 {
      v += 1
      guard pos < pack.count else { throw Error.truncatedPack(pack.count) }
      c = pack[pos]
      pos += 1
      v = (v << 7) + Int64(c & 127)
    }
    return v
  }

  // MARK: - Helpers

  private static func packTypeName(_ t: Int) -> String {
    switch t {
    case 1: return "commit"
    case 2: return "tree"
    case 3: return "blob"
    case 4: return "tag"
    default: return "blob"
    }
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

  /// Write a loose object to `.git/objects/`, returning the 20-byte SHA-1.
  private static func writeLooseObject(
    gitDir: URL, type: String, body: [UInt8]
  ) throws -> [UInt8] {
    return try GitLooseObjectWriter.writeObject(gitDir: gitDir, type: type, body: body)
  }
}

// MARK: - Git Fetch

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

    if let ssh = GitSSHTransport.parseSSHURL(rawURL) {
      displayURL = "git@\(ssh.host):\(ssh.path)"
      advert = try await GitSSHTransport.advertiseFetchRefs(ssh: ssh)
    } else {
      displayURL = convertToHTTPURL(rawURL)
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

    // Collect local refs as "have" for common-commit negotiation
    var haveHashes = Set<String>()
    // Add HEAD
    if let headHex = try? GitHEAD.resolveCommitHex(gitDir: gitDir) {
      haveHashes.insert(headHex)
    }
    // Add all local branches
    let refsDir = gitDir.appendingPathComponent("refs/heads", isDirectory: true)
    if FileManager.default.fileExists(atPath: refsDir.path) {
      if let refs = try? collectRefs(in: refsDir, base: gitDir, prefix: "refs/heads/") {
        haveHashes.formUnion(refs.values)
      }
    }
    // Add all remote-tracking refs
    let remotesDir = gitDir.appendingPathComponent("refs/remotes", isDirectory: true)
    if FileManager.default.fileExists(atPath: remotesDir.path) {
      if let refs = try? collectRefsRecursive(in: remotesDir, base: gitDir, prefix: "refs/remotes/") {
        haveHashes.formUnion(refs.values)
      }
    }

    // 4. Fetch pack from remote
    let packData: [UInt8]
    if let ssh = GitSSHTransport.parseSSHURL(rawURL) {
      packData = try await GitSSHTransport.fetch(
        ssh: ssh,
        wantHashes: Array(wantHashes),
        haveHashes: Array(haveHashes),
        capabilities: advert.capabilities)
    } else {
      packData = try await GitSmartHTTP.fetch(
        url: convertToHTTPURL(rawURL),
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
      writeCLIWarningStderr(
        "\(result.unresolvedDeltas) delta objects could not be resolved")
    }

    // 6. Update remote-tracking refs
    var fetchedRefs: [String: String] = [:]
    for (refName, sha20) in fetchRefs {
      let shaHex = GitHex.encodeLower(sha20)
      let willUpdate = result.importedSHAs.contains(shaHex) || haveHashes.contains(shaHex)
      if willUpdate {
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

  /// Collect all refs recursively in a directory tree.
  private static func collectRefsRecursive(
    in dir: URL, base: URL, prefix: String
  ) throws -> [String: String] {
    var refs: [String: String] = [:]
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
      return refs
    }
    for entry in entries {
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }
      if isDir.boolValue {
        let sub = try collectRefsRecursive(
          in: entry, base: base,
          prefix: prefix + entry.lastPathComponent + "/")
        refs.merge(sub) { _, new in new }
      } else {
        let raw = try String(contentsOf: entry, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.count == 40 {
          refs[prefix + entry.lastPathComponent] = raw.lowercased()
        }
      }
    }
    return refs
  }

  private static func convertToHTTPURL(_ url: String) -> String {
    if url.hasPrefix("https://") || url.hasPrefix("http://") { return url }
    if url.hasPrefix("ssh://") {
      let rest = String(url.dropFirst(6))
      let noUser = rest.replacingOccurrences(of: "git@", with: "")
      return "https://\(noUser)"
    }
    if url.hasPrefix("git@") {
      let rest = String(url.dropFirst(4))
      let parts = rest.split(separator: ":", maxSplits: 1)
      if parts.count == 2 {
        return "https://\(parts[0])/\(parts[1])"
      }
    }
    if !url.contains("://") { return "https://\(url)" }
    return url
  }
}

// MARK: - Git Pull

enum GitPull {

  enum Error: Swift.Error, Equatable {
    case detachedHEAD
    case noUpstreamConfigured(String)
    case remoteNotFound(String)
    case notFastForward(String)
    case mergeConflict(String)
    case fetchFailed(String)
    case workTreeDirty
  }

  /// Pull (fetch + merge) from the upstream remote of the current branch.
  static func pull(
    gitDir: URL,
    workTree: URL,
    remoteName: String? = nil
  ) async throws {
    // 1. Resolve current branch
    guard let branchRef = try GitHEAD.currentBranchRef(gitDir: gitDir) else {
      throw Error.detachedHEAD
    }
    let branch = branchRef.replacingOccurrences(of: "refs/heads/", with: "")

    // 2. Resolve upstream remote and merge ref
    guard let bc = try GitRemoteConfig.readBranchConfig(gitDir: gitDir, branch: branch),
          let upstreamRemoteName = remoteName ?? bc.remoteName,
          let mergeRef = bc.mergeRef else {
      throw Error.noUpstreamConfigured(branch)
    }

    let remotes = try GitRemoteConfig.readRemotes(gitDir: gitDir)
    guard let remote = remotes.first(where: { $0.name == upstreamRemoteName }) else {
      throw Error.remoteNotFound(upstreamRemoteName)
    }

    // 3. Determine the fetch refspec
    let fetchRefspec = "\(mergeRef):\(mergeRef)"

    // 4. Fetch
    _ = try await GitFetch.fetch(
      gitDir: gitDir,
      workTree: workTree,
      remote: remote,
      refspecs: [fetchRefspec])

    // 5. Determine the fetched tracking ref
    let trackingRef: String
    if mergeRef.hasPrefix("refs/heads/") {
      let remoteBranch = String(mergeRef.dropFirst(11))
      trackingRef = "refs/remotes/\(upstreamRemoteName)/\(remoteBranch)"
    } else {
      trackingRef = mergeRef
    }

    guard let fetchedHex = try GitRefs.readRef(gitDir: gitDir, refName: trackingRef) else {
      throw Error.fetchFailed("Could not read tracking ref \(trackingRef)")
    }

    guard let ourHex = try GitHEAD.resolveCommitHex(gitDir: gitDir) else {
      // No commits yet — just point our branch at the fetched ref
      try GitRefs.updateRef(gitDir: gitDir, refName: branchRef, sha40HexLower: fetchedHex)
      try checkoutCommit(gitDir: gitDir, workTree: workTree, shaHex: fetchedHex)
      print("Initialized branch '\(branch)' from '\(upstreamRemoteName)/\(branch)'")
      return
    }

    // 6. Determine merge strategy
    if ourHex == fetchedHex {
      print("Already up to date.")
      return
    }

    if try isAncestor(gitDir: gitDir, ancestorHex: ourHex, descendantHex: fetchedHex) {
      // Fast-forward
      try GitRefs.updateRef(gitDir: gitDir, refName: branchRef, sha40HexLower: fetchedHex)
      try checkoutCommit(gitDir: gitDir, workTree: workTree, shaHex: fetchedHex)
      print("Fast-forward \(branch) to \(upstreamRemoteName)/\(branch)")
    } else {
      // Non-fast-forward: create merge commit
      try mergeCommits(
        gitDir: gitDir,
        workTree: workTree,
        branchRef: branchRef,
        ourHex: ourHex,
        theirHex: fetchedHex,
        message: "Merge branch '\(mergeRef)' of \(remote.resolvedPushURL) into \(branch)")
    }
  }

  // MARK: - Ancestry check

  /// Check whether `ancestorHex` is an ancestor of `descendantHex` by walking
  /// parent chain from descendant.
  private static func isAncestor(
    gitDir: URL, ancestorHex: String, descendantHex: String
  ) throws -> Bool {
    if ancestorHex == descendantHex { return true }
    let packs = try GitObjectDatabase.openAllPacks(gitDir: gitDir)
    var visited = Set<String>()
    var queue = [descendantHex]
    while let sha = queue.first {
      queue.removeFirst()
      if sha == ancestorHex { return true }
      if !visited.insert(sha).inserted { continue }

      let sha20 = try GitHex.decode20(sha)
      guard let (type, payload) = try? GitObjectDatabase.readObject(
        gitDir: gitDir, packs: packs, sha20: sha20),
        type == "commit"
      else { continue }

      let (_, parents) = parseCommit(payload)
      queue.append(contentsOf: parents)
    }
    return false
  }

  // MARK: - Merge

  private static func mergeCommits(
    gitDir: URL,
    workTree: URL,
    branchRef: String,
    ourHex: String,
    theirHex: String,
    message: String
  ) throws {
    let packs = try GitObjectDatabase.openAllPacks(gitDir: gitDir)

    // Find merge base
    guard let baseHex = try findMergeBase(
      gitDir: gitDir, packs: packs, a: ourHex, b: theirHex)
    else {
      throw Error.mergeConflict("No common ancestor found")
    }

    // If theirs is ancestor of ours, nothing to merge
    if ourHex == baseHex {
      // Theirs is descendant, but we already checked for FF
      throw Error.notFastForward("Diverged — unable to fast-forward")
    }
    if theirHex == baseHex {
      print("Already up to date.")
      return
    }

    // For now, create a basic merge commit by doing a three-way tree merge
    let ourSHA20 = try GitHex.decode20(ourHex)
    let theirSHA20 = try GitHex.decode20(theirHex)
    let baseSHA20 = try GitHex.decode20(baseHex)

    let (_, ourPayload) = try GitObjectDatabase.readObject(
      gitDir: gitDir, packs: packs, sha20: ourSHA20)
    let (_, theirPayload) = try GitObjectDatabase.readObject(
      gitDir: gitDir, packs: packs, sha20: theirSHA20)
    let (_, basePayload) = try GitObjectDatabase.readObject(
      gitDir: gitDir, packs: packs, sha20: baseSHA20)

    let (ourTreeHex, _) = parseCommit(ourPayload)
    let (theirTreeHex, _) = parseCommit(theirPayload)
    let (baseTreeHex, _) = parseCommit(basePayload)

    // Simple merge: if trees are the same, no merge needed
    // Otherwise attempt a basic tree-level merge
    let mergedTreeHex: String
    if ourTreeHex == theirTreeHex {
      mergedTreeHex = ourTreeHex
    } else if ourTreeHex == baseTreeHex {
      // Our tree unchanged — use theirs
      mergedTreeHex = theirTreeHex
    } else if theirTreeHex == baseTreeHex {
      // Their tree unchanged — use ours
      mergedTreeHex = ourTreeHex
    } else {
      // Attempt three-way tree merge
      mergedTreeHex = try threeWayTreeMerge(
        gitDir: gitDir,
        packs: packs,
        baseTreeHex: baseTreeHex,
        ourTreeHex: ourTreeHex,
        theirTreeHex: theirTreeHex)
    }

    // Create merge commit
    let author = try GitLocalConfig.resolveAuthorIdentity(gitDir: gitDir)
    let committer = try GitLocalConfig.resolveCommitterIdentity(gitDir: gitDir)

    let date = Date()
    let tz = gitTimezoneOffset(for: date)
    let ts = Int64(date.timeIntervalSince1970)
    let authorLine = "\(author.name) <\(author.email)> \(ts) \(tz)"
    let committerLine = "\(committer.name) <\(committer.email)> \(ts) \(tz)"

    let mergeSHA = try GitLooseObjectWriter.writeCommit(
      gitDir: gitDir,
      treeSha40HexLower: mergedTreeHex,
      parentShas40HexLower: [ourHex, theirHex],
      authorLine: authorLine,
      committerLine: committerLine,
      message: message)

    let mergeHex = GitHex.encodeLower(mergeSHA)
    try GitRefs.updateRef(gitDir: gitDir, refName: branchRef, sha40HexLower: mergeHex)
    try checkoutCommit(gitDir: gitDir, workTree: workTree, shaHex: mergeHex)

    print("Merge commit created: \(String(mergeHex.prefix(7)))")
  }

  // MARK: - Three-way tree merge

  private static func threeWayTreeMerge(
    gitDir: URL,
    packs: [GitPack],
    baseTreeHex: String,
    ourTreeHex: String,
    theirTreeHex: String
  ) throws -> String {
    let baseEntries = try readTree(
      gitDir: gitDir, packs: packs, treeHex: baseTreeHex)
    let ourEntries = try readTree(
      gitDir: gitDir, packs: packs, treeHex: ourTreeHex)
    let theirEntries = try readTree(
      gitDir: gitDir, packs: packs, treeHex: theirTreeHex)

    let baseMap = makeTreeMap(baseEntries)
    let ourMap = makeTreeMap(ourEntries)
    let theirMap = makeTreeMap(theirEntries)

    var mergedEntries: [(mode: String, name: String, sha20: [UInt8])] = []
    var allNames = Set(baseMap.keys)
    allNames.formUnion(ourMap.keys)
    allNames.formUnion(theirMap.keys)

    for name in allNames.sorted() {
      let base = baseMap[name]
      let ours = ourMap[name]
      let theirs = theirMap[name]

      switch (ours, theirs) {
      case let (.some(o), .some(t)) where o.mode == t.mode && o.sha20 == t.sha20:
        // Both same — take either
        mergedEntries.append((o.mode, name, o.sha20))
      case let (.some(o), .some(t)):
        // Both modified — check if one side matches base
        if let b = base, b.mode == o.mode && b.sha20 == o.sha20 {
          // Only theirs changed
          mergedEntries.append((t.mode, name, t.sha20))
        } else if let b = base, b.mode == t.mode && b.sha20 == t.sha20 {
          // Only ours changed
          mergedEntries.append((o.mode, name, o.sha20))
        } else if base != nil {
          // Both changed — handle tree vs tree recursively
          if o.mode.hasPrefix("04") && t.mode.hasPrefix("04") {
            // Both are subtrees — recurse
            let mergedHex = try threeWayTreeMerge(
              gitDir: gitDir,
              packs: packs,
              baseTreeHex: base.flatMap { GitHex.encodeLower($0.sha20) } ?? "4b825dc642cb6eb9a060e54bf899d44e8e2a91c2", // empty tree
              ourTreeHex: GitHex.encodeLower(o.sha20),
              theirTreeHex: GitHex.encodeLower(t.sha20))
            let mergedSHA = try GitHex.decode20(mergedHex)
            mergedEntries.append((o.mode, name, mergedSHA))
          } else {
            // File-level conflict: take ours (simple strategy)
            mergedEntries.append((o.mode, name, o.sha20))
            writeCLIWarningStderr("conflict in '\(name)', keeping our version")
          }
        } else {
          // Both added same-named entry differently — take ours
          mergedEntries.append((o.mode, name, o.sha20))
          writeCLIWarningStderr("both added '\(name)' differently, keeping our version")
        }
      case let (.some(o), nil):
        // Only we have it — keep if changed from base, drop if deleted by them
        if base == nil || (base?.mode != o.mode || base?.sha20 != o.sha20) {
          // Check if they deleted it intentionally
          if base != nil {
            writeCLIWarningStderr("'\(name)' deleted by them, modified by us — keeping ours")
          }
          mergedEntries.append((o.mode, name, o.sha20))
        }
        // else: we deleted it, they didn't touch it — keep deleted
      case let (nil, .some(t)):
        // Only they have it — take theirs if changed from base
        if base == nil || (base?.mode != t.mode || base?.sha20 != t.sha20) {
          if base != nil {
            writeCLIWarningStderr("'\(name)' deleted by us, modified by them — taking theirs")
          }
          mergedEntries.append((t.mode, name, t.sha20))
        }
        // else: they deleted it, we didn't touch it — keep deleted
      case (nil, nil):
        break // Both deleted — fine
      }
    }

    let treeSHA = try GitLooseObjectWriter.writeTree(
      gitDir: gitDir, entries: mergedEntries)
    return GitHex.encodeLower(treeSHA)
  }

  private struct TreeEntry {
    let mode: String
    let name: String
    let sha20: [UInt8]
  }

  private static func readTree(
    gitDir: URL, packs: [GitPack], treeHex: String
  ) throws -> [TreeEntry] {
    guard treeHex.count == 40 else { return [] }
    let sha20 = try GitHex.decode20(treeHex)
    let (_, payload) = try GitObjectDatabase.readObject(
      gitDir: gitDir, packs: packs, sha20: sha20)
    var entries: [TreeEntry] = []
    var pos = 0
    while pos < payload.count {
      guard let spaceIdx = payload[pos...].firstIndex(of: UInt8(ascii: " ")) else { break }
      let mode = String(decoding: payload[pos..<spaceIdx], as: UTF8.self)
      pos = spaceIdx + 1
      guard let nullIdx = payload[pos...].firstIndex(of: 0) else { break }
      let name = String(decoding: payload[pos..<nullIdx], as: UTF8.self)
      pos = nullIdx + 1
      guard pos + 20 <= payload.count else { break }
      let sha = Array(payload[pos..<(pos + 20)])
      pos += 20
      entries.append(TreeEntry(mode: mode, name: name, sha20: sha))
    }
    return entries
  }

  private static func makeTreeMap(_ entries: [TreeEntry]) -> [String: TreeEntry] {
    var map: [String: TreeEntry] = [:]
    for e in entries { map[e.name] = e }
    return map
  }

  // MARK: - Merge base

  /// Find the best common ancestor (merge base) of two commits using
  /// breadth-first search from the older side.
  private static func findMergeBase(
    gitDir: URL, packs: [GitPack], a: String, b: String
  ) throws -> String? {
    // Collect ancestors of one side
    var ancestorsOfA = Set<String>()
    var queue = [a]
    while let sha = queue.first {
      queue.removeFirst()
      if !ancestorsOfA.insert(sha).inserted { continue }
      let sha20 = try GitHex.decode20(sha)
      guard let (type, payload) = try? GitObjectDatabase.readObject(
        gitDir: gitDir, packs: packs, sha20: sha20),
        type == "commit"
      else { continue }
      let (_, parents) = parseCommit(payload)
      queue.append(contentsOf: parents)
    }

    // Walk from b, return first ancestor that's in a's set
    queue = [b]
    var visitedB = Set<String>()
    while let sha = queue.first {
      queue.removeFirst()
      if ancestorsOfA.contains(sha) { return sha }
      if !visitedB.insert(sha).inserted { continue }
      let sha20 = try GitHex.decode20(sha)
      guard let (type, payload) = try? GitObjectDatabase.readObject(
        gitDir: gitDir, packs: packs, sha20: sha20),
        type == "commit"
      else { continue }
      let (_, parents) = parseCommit(payload)
      queue.append(contentsOf: parents)
    }

    return nil
  }

  // MARK: - Checkout

  /// Checkout a commit: write all blobs from the commit's tree to the work tree,
  /// and update the index.
  private static func checkoutCommit(
    gitDir: URL, workTree: URL, shaHex: String
  ) throws {
    let packs = try GitObjectDatabase.openAllPacks(gitDir: gitDir)
    let sha20 = try GitHex.decode20(shaHex)
    let (_, commitPayload) = try GitObjectDatabase.readObject(
      gitDir: gitDir, packs: packs, sha20: sha20)
    let (treeHex, _) = parseCommit(commitPayload)

    try checkoutTree(gitDir: gitDir, workTree: workTree, packs: packs, treeHex: treeHex, prefix: "")

    // Update index
    let index = try buildIndexFromTree(
      gitDir: gitDir, workTree: workTree, packs: packs, treeHex: treeHex, prefix: "")
    try index.write(to: gitDir.appendingPathComponent("index"))
  }

  private static func checkoutTree(
    gitDir: URL, workTree: URL, packs: [GitPack],
    treeHex: String, prefix: String
  ) throws {
    let entries = try readTree(gitDir: gitDir, packs: packs, treeHex: treeHex)
    let fm = FileManager.default

    for entry in entries {
      let path = prefix.isEmpty ? entry.name : "\(prefix)/\(entry.name)"
      let fileURL = workTree.appendingPathComponent(path)

      if entry.mode.hasPrefix("04") {
        // Subtree: recurse
        try fm.createDirectory(at: fileURL, withIntermediateDirectories: true)
        try checkoutTree(
          gitDir: gitDir, workTree: workTree, packs: packs,
          treeHex: GitHex.encodeLower(entry.sha20), prefix: path)
      } else {
        // Blob: write file
        let (_, blobPayload) = try GitObjectDatabase.readObject(
          gitDir: gitDir, packs: packs, sha20: entry.sha20)
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(blobPayload).write(to: fileURL, options: .atomic)
      }
    }
  }

  private static func buildIndexFromTree(
    gitDir: URL, workTree: URL, packs: [GitPack],
    treeHex: String, prefix: String
  ) throws -> GitIndex {
    var index = GitIndex()
    try buildIndexFromTreeHelper(
      gitDir: gitDir, workTree: workTree, packs: packs,
      treeHex: treeHex, prefix: prefix, index: &index)
    return index
  }

  private static func buildIndexFromTreeHelper(
    gitDir: URL, workTree: URL, packs: [GitPack],
    treeHex: String, prefix: String, index: inout GitIndex
  ) throws {
    let entries = try readTree(gitDir: gitDir, packs: packs, treeHex: treeHex)
    for entry in entries {
      let path = prefix.isEmpty ? entry.name : "\(prefix)/\(entry.name)"
      if entry.mode.hasPrefix("04") {
        try buildIndexFromTreeHelper(
          gitDir: gitDir, workTree: workTree, packs: packs,
          treeHex: GitHex.encodeLower(entry.sha20), prefix: path, index: &index)
      } else {
        index.insertEntry(GitIndex.RawEntry(
          path: path,
          ctimeSec: 0, ctimeNSec: 0,
          mtimeSec: 0, mtimeNSec: 0,
          dev: 0, ino: 0,
          mode: modeStringToUInt32(entry.mode),
          uid: 0, gid: 0,
          size: 0,
          sha: entry.sha20))
      }
    }
  }

  private static func modeStringToUInt32(_ mode: String) -> UInt32 {
    switch mode {
    case "100755": return 0o100755
    case "120000": return 0o120000
    default: return 0o100644
    }
  }

  // MARK: - Helpers

  private static func parseCommit(_ payload: [UInt8]) -> (
    treeHex: String, parentHexes: [String]
  ) {
    let str = String(decoding: payload, as: UTF8.self)
    var treeHex = ""
    var parents: [String] = []

    for line in str.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.isEmpty { break }
      if line.hasPrefix("tree ") {
        treeHex = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
      } else if line.hasPrefix("parent ") {
        parents.append(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces))
      }
    }

    return (treeHex, parents)
  }

  private static func gitTimezoneOffset(for date: Date) -> String {
    let sec = TimeZone.current.secondsFromGMT(for: date)
    let sign = sec >= 0 ? "+" : "-"
    let a = abs(sec)
    let hh = a / 3600
    let mm = (a % 3600) / 60
    return String(format: "%@%02d%02d", sign, hh, mm)
  }
}
