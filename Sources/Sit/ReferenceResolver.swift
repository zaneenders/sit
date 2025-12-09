import Foundation

/// Handles Git reference resolution including HEAD, branches, and packed-refs
struct ReferenceResolver {

  /// Resolve the current HEAD to a commit SHA-1
  /// - Parameter repository: Git repository instance
  /// - Returns: The commit SHA-1 that HEAD points to
  /// - Throws: GitError if resolution fails
  static func resolveHEAD(_ repository: GitRepository) throws -> String {
    let headPath = repository.gitPath("HEAD")

    guard repository.fileExists(headPath) else {
      throw GitError.referenceNotFound("HEAD file not found")
    }

    let headContent = try repository.readFileString(headPath)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Check if HEAD is detached (direct SHA-1)
    if headContent.isValidSHA1 {
      return headContent
    }

    // HEAD should point to a reference
    guard headContent.hasPrefix("ref: ") else {
      throw GitError.invalidHEAD("Invalid HEAD format: \(headContent)")
    }

    let refPath = String(headContent.dropFirst(5))  // Remove "ref: "
    return try resolveReference(repository, refPath)
  }

  /// Resolve a reference path to a commit SHA-1
  /// - Parameters:
  ///   - repository: Git repository instance
  ///   - refPath: Reference path (e.g., "refs/heads/main")
  /// - Returns: The commit SHA-1 that the reference points to
  /// - Throws: GitError if resolution fails
  static func resolveReference(_ repository: GitRepository, _ refPath: String) throws -> String {
    // Try loose reference first
    let refURL = repository.gitPath(refPath)
    if repository.fileExists(refURL) {
      let sha1 = try repository.readFileString(refURL)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return try validateSHA1(sha1)
    }

    // Try packed-refs
    return try resolveFromPackedRefs(repository, refPath)
  }

  /// Resolve a reference from the packed-refs file
  /// - Parameters:
  ///   - repository: Git repository instance
  ///   - refPath: Reference path to find
  /// - Returns: The commit SHA-1 that the reference points to
  /// - Throws: GitError if reference not found
  private static func resolveFromPackedRefs(_ repository: GitRepository, _ refPath: String) throws -> String {
    let packedRefsPath = repository.gitPath("packed-refs")

    guard repository.fileExists(packedRefsPath) else {
      throw GitError.referenceNotFound("Reference '\(refPath)' not found in loose refs or packed-refs")
    }

    let content = try repository.readFileString(packedRefsPath)
    let lines = content.components(separatedBy: .newlines)

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

      // Skip comments and empty lines
      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        continue
      }

      // Skip peeled tag lines (start with ^)
      if trimmed.hasPrefix("^") {
        continue
      }

      let components = trimmed.components(separatedBy: .whitespaces)
      guard components.count >= 2 else { continue }

      let sha1 = components[0]
      let ref = components[1]

      if ref == refPath {
        return try validateSHA1(sha1)
      }
    }

    throw GitError.referenceNotFound("Reference '\(refPath)' not found in packed-refs")
  }

  /// Get the current branch name (nil if detached HEAD)
  /// - Parameter repository: Git repository instance
  /// - Returns: Current branch name or nil if detached
  /// - Throws: GitError if reading HEAD fails
  static func getCurrentBranch(_ repository: GitRepository) throws -> String? {
    let headPath = repository.gitPath("HEAD")
    let headContent = try repository.readFileString(headPath)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard headContent.hasPrefix("ref: ") else {
      return nil  // Detached HEAD
    }

    let refPath = String(headContent.dropFirst(5))

    // Extract branch name from refs/heads/branch-name
    if refPath.hasPrefix("refs/heads/") {
      return String(refPath.dropFirst("refs/heads/".count))
    }

    // Handle other reference types (remote branches, tags, etc.)
    if refPath.hasPrefix("refs/") {
      return String(refPath.dropFirst("refs/".count))
    }

    return refPath
  }

  /// Check if HEAD is detached
  /// - Parameter repository: Git repository instance
  /// - Returns: true if HEAD is detached, false otherwise
  /// - Throws: GitError if reading HEAD fails
  static func isDetachedHEAD(_ repository: GitRepository) throws -> Bool {
    let headPath = repository.gitPath("HEAD")
    let headContent = try repository.readFileString(headPath)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return !headContent.hasPrefix("ref: ")
  }

  /// Get all local branches
  /// - Parameter repository: Git repository instance
  /// - Returns: Array of branch names with their current commit SHA-1s
  /// - Throws: GitError if reading branches fails
  static func getLocalBranches(_ repository: GitRepository) throws -> [(name: String, sha1: String)] {
    var branches: [(name: String, sha1: String)] = []
    let headsDir = repository.gitPath("refs", "heads")

    if repository.directoryExists(headsDir) {
      branches.append(contentsOf: try getBranchesFromDirectory(repository, headsDir, prefix: ""))
    }

    // Also check packed-refs for branches
    if repository.fileExists(repository.gitPath("packed-refs")) {
      let packedBranches = try getBranchesFromPackedRefs(repository, filter: { $0.hasPrefix("refs/heads/") })
      for (ref, sha1) in packedBranches {
        let branchName = String(ref.dropFirst("refs/heads/".count))
        if !branches.contains(where: { $0.name == branchName }) {
          branches.append((name: branchName, sha1: sha1))
        }
      }
    }

    return branches.sorted { $0.name < $1.name }
  }

  /// Get all remote branches
  /// - Parameter repository: Git repository instance
  /// - Returns: Array of remote branch names with their commit SHA-1s
  /// - Throws: GitError if reading branches fails
  static func getRemoteBranches(_ repository: GitRepository) throws -> [(name: String, sha1: String)] {
    var branches: [(name: String, sha1: String)] = []
    let remotesDir = repository.gitPath("refs", "remotes")

    if repository.directoryExists(remotesDir) {
      branches.append(contentsOf: try getBranchesFromDirectory(repository, remotesDir, prefix: "remotes/"))
    }

    // Also check packed-refs for remote branches
    if repository.fileExists(repository.gitPath("packed-refs")) {
      let packedBranches = try getBranchesFromPackedRefs(repository, filter: { $0.hasPrefix("refs/remotes/") })
      for (ref, sha1) in packedBranches {
        let branchName = String(ref.dropFirst("refs/".count))
        if !branches.contains(where: { $0.name == branchName }) {
          branches.append((name: branchName, sha1: sha1))
        }
      }
    }

    return branches.sorted { $0.name < $1.name }
  }

  /// Get all tags
  /// - Parameter repository: Git repository instance
  /// - Returns: Array of tag names with their target SHA-1s
  /// - Throws: GitError if reading tags fails
  static func getTags(_ repository: GitRepository) throws -> [(name: String, sha1: String)] {
    var tags: [(name: String, sha1: String)] = []
    let tagsDir = repository.gitPath("refs", "tags")

    if repository.directoryExists(tagsDir) {
      tags.append(contentsOf: try getBranchesFromDirectory(repository, tagsDir, prefix: "tags/"))
    }

    // Also check packed-refs for tags
    if repository.fileExists(repository.gitPath("packed-refs")) {
      let packedTags = try getBranchesFromPackedRefs(repository, filter: { $0.hasPrefix("refs/tags/") })
      for (ref, sha1) in packedTags {
        let tagName = String(ref.dropFirst("refs/tags/".count))
        if !tags.contains(where: { $0.name == tagName }) {
          tags.append((name: tagName, sha1: sha1))
        }
      }
    }

    return tags.sorted { $0.name < $1.name }
  }

  /// Get branches from a directory (recursively)
  private static func getBranchesFromDirectory(_ repository: GitRepository, _ dir: URL, prefix: String) throws -> [(
    name: String, sha1: String
  )] {
    var branches: [(name: String, sha1: String)] = []

    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) else {
      return branches
    }

    for case let fileURL as URL in enumerator {
      var isDir: ObjCBool = false
      fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir)

      if isDir.boolValue {
        continue
      }

      let relativePath = fileURL.path.replacingOccurrences(of: dir.path, with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "/", with: "/")

      let branchName = prefix.isEmpty ? relativePath : "\(prefix)/\(relativePath)"

      do {
        let sha1 = try repository.readFileString(fileURL)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if sha1.isValidSHA1 {
          branches.append((name: branchName, sha1: sha1))
        }
      } catch {
        // Skip invalid references
        continue
      }
    }

    return branches
  }

  /// Get references from packed-refs file with optional filtering
  private static func getBranchesFromPackedRefs(_ repository: GitRepository, filter: ((String) -> Bool)? = nil) throws
    -> [(String, String)]
  {
    let packedRefsPath = repository.gitPath("packed-refs")
    let content = try repository.readFileString(packedRefsPath)
    let lines = content.components(separatedBy: .newlines)

    var refs: [(String, String)] = []

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

      // Skip comments, empty lines, and peeled tag lines
      if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("^") {
        continue
      }

      let components = trimmed.components(separatedBy: .whitespaces)
      guard components.count >= 2 else { continue }

      let sha1 = components[0]
      let ref = components[1]

      if let filter = filter {
        if !filter(ref) {
          continue
        }
      }

      if sha1.isValidSHA1 {
        refs.append((ref, sha1))
      }
    }

    return refs
  }

  /// Validate SHA-1 format
  private static func validateSHA1(_ sha1: String) throws -> String {
    let cleaned = sha1.trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.isValidSHA1 else {
      throw GitError.invalidSHA1(cleaned)
    }
    return cleaned
  }
}

// MARK: - Repository Extensions

extension GitRepository {

  /// Read the current HEAD and resolve to commit SHA-1
  func getCurrentCommitSHA() throws -> String {
    return try ReferenceResolver.resolveHEAD(self)
  }

  /// Get current branch name (nil if detached HEAD)
  func getCurrentBranch() throws -> String? {
    return try ReferenceResolver.getCurrentBranch(self)
  }

  /// Check if HEAD is detached
  func isDetachedHEAD() throws -> Bool {
    return try ReferenceResolver.isDetachedHEAD(self)
  }

  /// Get all local branches
  func getLocalBranches() throws -> [(name: String, sha1: String)] {
    return try ReferenceResolver.getLocalBranches(self)
  }

  /// Get all remote branches
  func getRemoteBranches() throws -> [(name: String, sha1: String)] {
    return try ReferenceResolver.getRemoteBranches(self)
  }

  /// Get all tags
  func getTags() throws -> [(name: String, sha1: String)] {
    return try ReferenceResolver.getTags(self)
  }
}
