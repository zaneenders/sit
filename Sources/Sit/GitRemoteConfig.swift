public import Foundation

// MARK: - Data types

/// A parsed `[remote "name"]` section from a Git config file.
public struct GitRemote: Equatable, Sendable {
  public let name: String
  public let url: String
  public let pushURL: String?
  /// Raw fetch refspecs (e.g. `+refs/heads/*:refs/remotes/origin/*`).
  public let fetchRefspecs: [String]
  /// Raw push refspecs.  If empty, Git defaults to pushing matching branches.
  public let pushRefspecs: [String]

  /// The URL to use for pushing (`pushurl` if set, otherwise `url`).
  public var resolvedPushURL: String { pushURL ?? url }

  public init(
    name: String,
    url: String,
    pushURL: String? = nil,
    fetchRefspecs: [String] = [],
    pushRefspecs: [String] = []
  ) {
    self.name = name
    self.url = url
    self.pushURL = pushURL
    self.fetchRefspecs = fetchRefspecs
    self.pushRefspecs = pushRefspecs
  }
}

/// A parsed `[branch "name"]` section from a Git config file.
public struct GitBranchConfig: Equatable, Sendable {
  public let name: String
  /// The remote this branch tracks (value of `remote` key).
  public let remoteName: String?
  /// The upstream merge ref (value of `merge` key, e.g. `refs/heads/main`).
  public let mergeRef: String?

  public init(name: String, remoteName: String? = nil, mergeRef: String? = nil) {
    self.name = name
    self.remoteName = remoteName
    self.mergeRef = mergeRef
  }
}

// MARK: - Reader

/// Reads `[remote]` and `[branch]` sections from `.git/config`.
public enum GitRemoteConfig: Sendable {

  /// Parse all remotes from `gitDir/config`.
  /// Returns an empty array if the config file is missing or has no remotes.
  public static func readRemotes(gitDir: URL) throws -> [GitRemote] {
    let configURL = gitDir.appendingPathComponent("config")
    guard FileManager.default.fileExists(atPath: configURL.path) else { return [] }
    let text = try String(contentsOf: configURL, encoding: .utf8)
    let entries = GitConfigParser.parse(text)

    // Group by (section, subsection) for "remote"
    var remoteMap: [String: [GitConfigParser.Entry]] = [:]
    for e in entries where e.section == "remote" {
      let name = e.subsection ?? ""
      guard !name.isEmpty else { continue }
      remoteMap[name, default: []].append(e)
    }

    var remotes: [GitRemote] = []
    for (name, kvs) in remoteMap {
      var url: String?
      var pushURL: String?
      var fetchRefspecs: [String] = []
      var pushRefspecs: [String] = []

      for kv in kvs {
        switch kv.key {
        case "url":
          url = kv.value
        case "pushurl":
          pushURL = kv.value
        case "fetch":
          fetchRefspecs.append(kv.value)
        case "push":
          pushRefspecs.append(kv.value)
        default:
          break
        }
      }

      guard let u = url, !u.isEmpty else { continue }
      remotes.append(
        GitRemote(
          name: name,
          url: u,
          pushURL: pushURL,
          fetchRefspecs: fetchRefspecs,
          pushRefspecs: pushRefspecs))
    }

    return remotes
  }

  /// Parse branch config for a single branch from `gitDir/config`.
  /// Returns `nil` if the branch has no config section.
  public static func readBranchConfig(gitDir: URL, branch: String) throws -> GitBranchConfig? {
    let configURL = gitDir.appendingPathComponent("config")
    guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
    let text = try String(contentsOf: configURL, encoding: .utf8)
    let entries = GitConfigParser.parse(text)

    var remoteName: String?
    var mergeRef: String?

    for e in entries where e.section == "branch" && e.subsection == branch {
      switch e.key {
      case "remote":
        remoteName = e.value
      case "merge":
        mergeRef = e.value
      default:
        break
      }
    }

    if remoteName == nil && mergeRef == nil { return nil }
    return GitBranchConfig(name: branch, remoteName: remoteName, mergeRef: mergeRef)
  }

  /// Read all branch configs from `gitDir/config`.
  public static func readAllBranchConfigs(gitDir: URL) throws -> [GitBranchConfig] {
    let configURL = gitDir.appendingPathComponent("config")
    guard FileManager.default.fileExists(atPath: configURL.path) else { return [] }
    let text = try String(contentsOf: configURL, encoding: .utf8)
    let entries = GitConfigParser.parse(text)

    var branchMap: [String: [GitConfigParser.Entry]] = [:]
    for e in entries where e.section == "branch" {
      let name = e.subsection ?? ""
      guard !name.isEmpty else { continue }
      branchMap[name, default: []].append(e)
    }

    return branchMap.map { name, kvs in
      var remoteName: String?
      var mergeRef: String?
      for kv in kvs {
        switch kv.key {
        case "remote": remoteName = kv.value
        case "merge": mergeRef = kv.value
        default: break
        }
      }
      return GitBranchConfig(name: name, remoteName: remoteName, mergeRef: mergeRef)
    }
  }

  /// Resolve the push destination for a branch: the remote to push to and the
  /// refspec to use.  Returns `nil` if no upstream is configured.
  public static func resolvePushDestination(
    gitDir: URL,
    branch: String,
    remoteName: String? = nil
  ) throws -> (remote: GitRemote, refspecs: [String])? {
    // Determine which remote to use
    let resolvedRemoteName: String
    if let rn = remoteName {
      resolvedRemoteName = rn
    } else if let bc = try readBranchConfig(gitDir: gitDir, branch: branch),
      let rn = bc.remoteName
    {
      resolvedRemoteName = rn
    } else {
      return nil
    }

    let remotes = try readRemotes(gitDir: gitDir)
    guard let remote = remotes.first(where: { $0.name == resolvedRemoteName }) else {
      return nil
    }

    // Determine refspecs
    let refspecs: [String]
    if !remote.pushRefspecs.isEmpty {
      refspecs = remote.pushRefspecs
    } else {
      // Default: push current branch to matching name on remote
      refspecs = ["refs/heads/\(branch):refs/heads/\(branch)"]
    }

    return (remote, refspecs)
  }
}
