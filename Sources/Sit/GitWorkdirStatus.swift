public import Foundation

/// `git status`-style summary using the index, `HEAD`’s tree (loose + pack), and the work tree.
public enum GitWorkdirStatusText: Sendable {
  private struct Classification: Sendable {
    var stagedMod: [String]
    var stagedAdd: [String]
    var stagedDel: [String]
    var unstagedMod: [String]
    var unstagedDel: [String]
    var untracked: [String]
  }

  /// True when the work tree differs from the index (modified/deleted on disk) or paths exist that are not in the index (untracked).
  ///
  /// Staged-only changes (index ≠ `HEAD` but disk matches index) return false, matching a common reading of `git status --porcelain`’s work-tree column plus `??` lines.
  public static func hasUnstagedWorktreeChanges(gitDir: URL, workTree: URL) throws -> Bool {
    let c = try classify(gitDir: gitDir, workTree: workTree)
    return !c.unstagedMod.isEmpty || !c.unstagedDel.isEmpty || !c.untracked.isEmpty
  }

  public static func format(gitDir: URL, workTree: URL) throws -> String {
    let c = try classify(gitDir: gitDir, workTree: workTree)
    let stagedMod = c.stagedMod
    let stagedAdd = c.stagedAdd
    let stagedDel = c.stagedDel
    let unstagedMod = c.unstagedMod
    let unstagedDel = c.unstagedDel
    let untracked = c.untracked

    var lines: [String] = []
    lines.append(branchLine(gitDir: gitDir))
    lines.append("")
    if !stagedMod.isEmpty || !stagedAdd.isEmpty || !stagedDel.isEmpty {
      lines.append("Changes to be committed:")
      for p in stagedAdd.sorted() { lines.append("\tnew file:   \(p)") }
      for p in stagedDel.sorted() { lines.append("\tdeleted:    \(p)") }
      for p in stagedMod.sorted() { lines.append("\tmodified:   \(p)") }
      lines.append("")
    }
    if !unstagedMod.isEmpty || !unstagedDel.isEmpty {
      lines.append("Changes not staged for commit:")
      for p in unstagedDel.sorted() { lines.append("\tdeleted:    \(p)") }
      for p in unstagedMod.sorted() { lines.append("\tmodified:   \(p)") }
      lines.append("")
    }
    if !untracked.isEmpty {
      lines.append("Untracked files:")
      for p in untracked {
        lines.append("\t\(p)")
      }
      lines.append("")
    }
    if stagedMod.isEmpty && stagedAdd.isEmpty && stagedDel.isEmpty && unstagedMod.isEmpty && unstagedDel.isEmpty
      && untracked.isEmpty
    {
      lines.append("nothing to commit, working tree clean")
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  private static func classify(gitDir: URL, workTree: URL) throws -> Classification {
    let packs = try GitObjectDatabase.openAllPacks(gitDir: gitDir)
    let indexURL = gitDir.appendingPathComponent("index")
    let index: GitIndex
    if FileManager.default.fileExists(atPath: indexURL.path) {
      index = try GitIndex.load(from: indexURL)
    } else {
      index = GitIndex()
    }
    let indexMap = index.pathToBlobSha
    let headMap = try headBlobMap(gitDir: gitDir, packs: packs)
    let diskPaths = try GitWorkTreeScan.allRelativeFilePaths(workTree: workTree)

    var stagedMod: [String] = []
    var stagedAdd: [String] = []
    var stagedDel: [String] = []
    for path in Set(indexMap.keys).union(headMap.keys).sorted() {
      let i = indexMap[path]
      let h = headMap[path]
      switch (i, h) {
      case (let i?, let h?) where i != h:
        stagedMod.append(path)
      case (_?, nil):
        stagedAdd.append(path)
      case (nil, _?):
        stagedDel.append(path)
      default:
        break
      }
    }

    var unstagedMod: [String] = []
    var unstagedDel: [String] = []
    for path in indexMap.keys.sorted() {
      guard let idxSha = indexMap[path] else { continue }
      let abs = workTree.appendingPathComponent(path)
      let fm = FileManager.default
      guard fm.fileExists(atPath: abs.path) else {
        unstagedDel.append(path)
        continue
      }
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: abs.path, isDirectory: &isDir), !isDir.boolValue else { continue }
      let data = try Data(contentsOf: abs)
      let diskSha = GitLooseObjectWriter.blobSha1(content: Array(data))
      if diskSha != idxSha {
        unstagedMod.append(path)
      }
    }

    var untracked: [String] = []
    for path in diskPaths.sorted() where indexMap[path] == nil {
      untracked.append(path)
    }

    return Classification(
      stagedMod: stagedMod,
      stagedAdd: stagedAdd,
      stagedDel: stagedDel,
      unstagedMod: unstagedMod,
      unstagedDel: unstagedDel,
      untracked: untracked
    )
  }

  private static func branchLine(gitDir: URL) -> String {
    if let ref = try? GitHEAD.currentBranchRef(gitDir: gitDir), ref.hasPrefix("refs/heads/") {
      let b = String(ref.dropFirst("refs/heads/".count))
      return "On branch \(b)"
    }
    if let h = try? GitHEAD.resolveCommitHex(gitDir: gitDir) {
      return "HEAD detached at \(h.prefix(7))"
    }
    return "On branch (no commits yet)"
  }

  private static func headBlobMap(gitDir: URL, packs: [GitPack]) throws -> [String: [UInt8]] {
    guard let commitHex = try GitHEAD.resolveCommitHex(gitDir: gitDir) else {
      return [:]
    }
    let commitSha = try GitHex.decode20(commitHex)
    let (type, body) = try GitObjectDatabase.readObject(gitDir: gitDir, packs: packs, sha20: commitSha)
    guard type == "commit" else { return [:] }
    let treeSha = try treeShaFromCommitBody(body)
    var map: [String: [UInt8]] = [:]
    try walkTree(gitDir: gitDir, packs: packs, treeSha: treeSha, prefix: "", into: &map)
    return map
  }

  private static func treeShaFromCommitBody(_ body: [UInt8]) throws -> [UInt8] {
    guard let text = String(bytes: body, encoding: .utf8) else {
      throw GitObjectReadError.commitMissingTreeLine
    }
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = String(raw)
      guard line.hasPrefix("tree ") else { continue }
      let hex = line.dropFirst(5).prefix(40)
      guard hex.count == 40 else { continue }
      return try GitHex.decode20(String(hex).lowercased())
    }
    throw GitObjectReadError.commitMissingTreeLine
  }

  private static func walkTree(
    gitDir: URL,
    packs: [GitPack],
    treeSha: [UInt8],
    prefix: String,
    into map: inout [String: [UInt8]]
  ) throws {
    let (type, body) = try GitObjectDatabase.readObject(gitDir: gitDir, packs: packs, sha20: treeSha)
    guard type == "tree" else { throw GitObjectReadError.malformedLooseObject("not a tree") }
    var i = 0
    while i < body.count {
      var j = i
      while j < body.count, body[j] != UInt8(ascii: " ") {
        j += 1
      }
      guard j < body.count else { break }
      let mode = String(decoding: body[i..<j], as: UTF8.self)
      j += 1
      var k = j
      while k < body.count, body[k] != 0 {
        k += 1
      }
      guard k < body.count else { break }
      let name = String(decoding: body[j..<k], as: UTF8.self)
      k += 1
      guard k + 20 <= body.count else { break }
      let sha = Array(body[k..<(k + 20)])
      k += 20
      i = k
      let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
      if mode == "040000" || mode == "40000" {
        try walkTree(gitDir: gitDir, packs: packs, treeSha: sha, prefix: path, into: &map)
      } else {
        map[path] = sha
      }
    }
  }

}
