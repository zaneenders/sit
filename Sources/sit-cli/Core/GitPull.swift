import Foundation
import Sit

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

    // 2. Refuse to overwrite local changes
    if try GitWorkdirStatusText.hasUncommittedChanges(gitDir: gitDir, workTree: workTree) {
      throw Error.workTreeDirty
    }

    // 3. Resolve upstream remote and merge ref
    guard let bc = try GitRemoteConfig.readBranchConfig(gitDir: gitDir, branch: branch),
      let upstreamRemoteName = remoteName ?? bc.remoteName,
      let mergeRef = bc.mergeRef
    else {
      throw Error.noUpstreamConfigured(branch)
    }

    let remotes = try GitRemoteConfig.readRemotes(gitDir: gitDir)
    guard let remote = remotes.first(where: { $0.name == upstreamRemoteName }) else {
      throw Error.remoteNotFound(upstreamRemoteName)
    }

    // 4. Determine the fetch refspec
    let fetchRefspec = "\(mergeRef):\(mergeRef)"

    // 5. Fetch
    _ = try await GitFetch.fetch(
      gitDir: gitDir,
      workTree: workTree,
      remote: remote,
      refspecs: [fetchRefspec])

    // 6. Determine the fetched tracking ref
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

    // 7. Determine merge strategy
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
      guard
        let (type, payload) = try? GitObjectDatabase.readObject(
          gitDir: gitDir, packs: packs, sha20: sha20),
        type == "commit"
      else { continue }

      let (_, parents) = GitObjectParser.parseCommit(payload)
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
    guard
      let baseHex = try findMergeBase(
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

    let (ourTreeHex, _) = GitObjectParser.parseCommit(ourPayload)
    let (theirTreeHex, _) = GitObjectParser.parseCommit(theirPayload)
    let (baseTreeHex, _) = GitObjectParser.parseCommit(basePayload)

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
    let tz = GitLooseObjectWriter.gitTimezoneOffset(for: date)
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
      case (.some(let o), .some(let t)) where o.mode == t.mode && o.sha20 == t.sha20:
        // Both same — take either
        mergedEntries.append((o.mode, name, o.sha20))
      case (.some(let o), .some(let t)):
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
              baseTreeHex: base.flatMap { GitHex.encodeLower($0.sha20) } ?? "4b825dc642cb6eb9a060e54bf899d44e8e2a91c2",  // empty tree
              ourTreeHex: GitHex.encodeLower(o.sha20),
              theirTreeHex: GitHex.encodeLower(t.sha20))
            let mergedSHA = try GitHex.decode20(mergedHex)
            mergedEntries.append((o.mode, name, mergedSHA))
          } else {
            // File-level conflict — fail like real Git
            throw Error.mergeConflict("conflict in '\(name)': both sides modified")
          }
        } else {
          // Both added same-named entry differently
          throw Error.mergeConflict("both added '\(name)' differently")
        }
      case (.some(let o), nil):
        // Only we have it — keep if changed from base, drop if deleted by them
        if base == nil || (base?.mode != o.mode || base?.sha20 != o.sha20) {
          // Check if they deleted it intentionally
          if base != nil {
            throw Error.mergeConflict("'\(name)' deleted by them, modified by us")
          }
          mergedEntries.append((o.mode, name, o.sha20))
        }
      // else: we deleted it, they didn't touch it — keep deleted
      case (nil, .some(let t)):
        // Only they have it — take theirs if changed from base
        if base == nil || (base?.mode != t.mode || base?.sha20 != t.sha20) {
          if base != nil {
            throw Error.mergeConflict("'\(name)' deleted by us, modified by them")
          }
          mergedEntries.append((t.mode, name, t.sha20))
        }
      // else: they deleted it, we didn't touch it — keep deleted
      case (nil, nil):
        break  // Both deleted — fine
      }
    }

    let treeSHA = try GitLooseObjectWriter.writeTree(
      gitDir: gitDir, entries: mergedEntries)
    return GitHex.encodeLower(treeSHA)
  }

  private typealias TreeEntry = GitObjectParser.TreeEntry

  private static func readTree(
    gitDir: URL, packs: [GitPack], treeHex: String
  ) throws -> [TreeEntry] {
    guard treeHex.count == 40 else { return [] }
    let sha20 = try GitHex.decode20(treeHex)
    let (_, payload) = try GitObjectDatabase.readObject(
      gitDir: gitDir, packs: packs, sha20: sha20)
    return GitObjectParser.parseTree(payload)
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
      guard
        let (type, payload) = try? GitObjectDatabase.readObject(
          gitDir: gitDir, packs: packs, sha20: sha20),
        type == "commit"
      else { continue }
      let (_, parents) = GitObjectParser.parseCommit(payload)
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
      guard
        let (type, payload) = try? GitObjectDatabase.readObject(
          gitDir: gitDir, packs: packs, sha20: sha20),
        type == "commit"
      else { continue }
      let (_, parents) = GitObjectParser.parseCommit(payload)
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
    let (treeHex, _) = GitObjectParser.parseCommit(commitPayload)

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
        try fm.createDirectory(
          at: fileURL.deletingLastPathComponent(),
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
        index.insertEntry(
          GitIndex.RawEntry(
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
}
