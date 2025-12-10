import CryptoKit
import Foundation
import NIOFileSystem

extension String {
  func hexToBytes() -> [UInt8] {
    var bytes: [UInt8] = []
    var index = startIndex
    while index < endIndex {
      let nextIndex = self.index(index, offsetBy: 2)
      let byteString = String(self[index..<nextIndex])
      if let byte = UInt8(byteString, radix: 16) {
        bytes.append(byte)
      }
      index = nextIndex
    }
    return bytes
  }
}

enum Sit {
  static func sha1(_ data: Data) -> String {
    let hash = Insecure.SHA1.hash(data: data)
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  /// Get git status information
  /// - Parameter path: Path to repository (defaults to current directory)
  /// - Returns: Status result with staged, unstaged, and untracked changes
  /// - Throws: GitError if status cannot be determined
  static func status(at path: FilePath = ".") async throws -> StatusResult {
    let repository = try await GitRepository(at: path)
    let statusCalculator = StatusCalculator(repository: repository)
    return try await statusCalculator.calculateStatus()
  }

  /// Create a new commit
  /// - Parameters:
  ///   - message: Commit message
  ///   - path: Path to repository (defaults to current directory)
  /// - Returns: The SHA-1 of the created commit
  /// - Throws: GitError if commit cannot be created
  static func commit(message: String, at path: FilePath = ".") async throws -> String {
    let repository = try await GitRepository(at: path)
    return try await createCommit(repository: repository, message: message)
  }

  /// Internal method to create a commit
  private static func createCommit(repository: GitRepository, message: String) async throws -> String {
    var parentCommit: String?
    do {
      parentCommit = try repository.getCurrentCommitSHA()
    } catch {
      parentCommit = nil
    }

    let treeSHA1 = try await createTreeFromIndex(repository: repository)

    let author = "Test User <test@example.com>"
    let committer = author
    let timestamp = Int(Date().timeIntervalSince1970)
    let timezone = "+0000"

    var commitContent = "tree \(treeSHA1)\n"
    if let parent = parentCommit {
      commitContent += "parent \(parent)\n"
    }
    commitContent += "author \(author) \(timestamp) \(timezone)\n"
    commitContent += "committer \(committer) \(timestamp) \(timezone)\n"
    commitContent += "\n"
    commitContent += message

    let commitData = commitContent.data(using: .utf8)!
    let commitHeader = "commit \(commitData.count)\0"
    let fullCommitData = commitHeader.data(using: .utf8)! + commitData
    let commitSHA1 = sha1(fullCommitData)

    try await writeGitObject(repository: repository, sha1: commitSHA1, data: fullCommitData)

    try await updateHEAD(repository: repository, commitSHA1: commitSHA1)

    return commitSHA1
  }

  /// Create a tree object from the current index
  private static func createTreeFromIndex(repository: GitRepository) async throws -> String {
    let indexEntries = try repository.readIndex()

    // Group entries by directory
    var directoryEntries: [String: [IndexEntry]] = [:]
    for entry in indexEntries {
      let pathComponents = entry.path.components(separatedBy: "/")
      if pathComponents.count == 1 {
        // Root level file
        if directoryEntries[""] == nil {
          directoryEntries[""] = []
        }
        directoryEntries[""]?.append(entry)
      } else {
        let directory = pathComponents.dropLast().joined(separator: "/")
        if directoryEntries[directory] == nil {
          directoryEntries[directory] = []
        }
        directoryEntries[directory]?.append(entry)
      }
    }

    // Create tree entries (simplified - just for root level)
    var treeEntries: [String] = []
    for entry in indexEntries {
      if !entry.path.contains("/") {
        let mode = entry.fileMode
        let name = entry.path
        let sha1 = entry.sha1Hex
        treeEntries.append("\(mode) \(name)\0\(Data(sha1.hexToBytes()))")
      }
    }

    // Build tree data
    var treeData = Data()
    for entry in treeEntries.sorted() {
      treeData.append(entry.data(using: .utf8)!)
    }

    let treeHeader = "tree \(treeData.count)\0"
    let fullTreeData = treeHeader.data(using: .utf8)! + treeData
    let treeSHA1 = sha1(fullTreeData)

    // Write tree object
    try await writeGitObject(repository: repository, sha1: treeSHA1, data: fullTreeData)

    return treeSHA1
  }

  /// Write a Git object to the objects directory
  private static func writeGitObject(repository: GitRepository, sha1: String, data: Data) async throws {
    let objectDir = repository.gitPath("objects", String(sha1.prefix(2)))
    let objectFile = objectDir.appendingPathComponent(String(sha1.dropFirst(2)))

    // Create directory if needed
    try await FileSystem.shared.createDirectory(at: FilePath(objectDir.path), withIntermediateDirectories: true)

    // Compress the data using zlib
    let compressedData = try compressData(data)
    try compressedData.write(to: objectFile)
  }

  /// Compress data using zlib
  private static func compressData(_ data: Data) throws -> Data {
    return try (data as NSData).compressed(using: .zlib) as Data
  }

  /// Update HEAD to point to the new commit
  private static func updateHEAD(repository: GitRepository, commitSHA1: String) async throws {
    let headPath = repository.gitPath("HEAD")

    // Read current HEAD to see if it's a branch or detached
    if repository.fileExists(headPath) {
      let headContent = try repository.readFileString(headPath).trimmingCharacters(in: .whitespacesAndNewlines)

      if headContent.hasPrefix("ref: ") {
        // Update the branch reference
        let refPath = String(headContent.dropFirst(5))
        let refFile = repository.gitPath(refPath)
        try commitSHA1.write(to: refFile, atomically: true, encoding: .utf8)
      } else {
        // Detached HEAD, update directly
        try commitSHA1.write(to: headPath, atomically: true, encoding: .utf8)
      }
    } else {
      // No HEAD, create one pointing to the commit
      try commitSHA1.write(to: headPath, atomically: true, encoding: .utf8)
    }
  }
}

/// Calculates git status by comparing index, working directory, and HEAD
class StatusCalculator {
  private let repository: GitRepository

  init(repository: GitRepository) {
    self.repository = repository
  }

  /// Calculate the complete status of the repository
  func calculateStatus() async throws -> StatusResult {
    // Get current branch information
    let branch = try await repository.getCurrentBranch()
    let isDetached = try await repository.isDetachedHEAD()

    // Read index entries
    let indexEntries = try repository.readIndex()
    let indexMap = Dictionary(uniqueKeysWithValues: indexEntries.map { ($0.path, $0) })

    // Scan working directory
    let workTreeFiles = try repository.scanWorkTree()

    // Get HEAD commit if available
    var headCommit: Commit?
    var headTree: [String: TreeEntry] = [:]

    do {
      let headSha1 = try repository.getCurrentCommitSHA()
      let headObject = try repository.readObject(sha1: headSha1)
      if let commit = headObject as? Commit {
        headCommit = commit
        let treeObject = try repository.readObject(sha1: commit.tree)
        if let tree = treeObject as? Tree {
          headTree = Dictionary(uniqueKeysWithValues: tree.entries.map { ($0.name, $0) })
        }
      }
    } catch {
      // New repository or no commits
      headCommit = nil
      headTree = [:]
    }

    // Calculate changes
    let staged = try calculateStagedChanges(indexMap: indexMap, headTree: headTree)
    let unstaged = try calculateUnstagedChanges(indexMap: indexMap, workTreeFiles: workTreeFiles)
    let untracked = calculateUntrackedFiles(indexMap: indexMap, workTreeFiles: workTreeFiles)
    let conflicted = calculateConflictedFiles(indexMap: indexMap)

    // Calculate ahead/behind (simplified - would need remote tracking for full implementation)
    let ahead = 0
    let behind = 0

    return StatusResult(
      staged: staged,
      unstaged: unstaged,
      untracked: untracked,
      conflicted: conflicted,
      branch: branch,
      ahead: ahead,
      behind: behind
    )
  }

  /// Calculate staged changes (index vs HEAD)
  private func calculateStagedChanges(indexMap: [String: IndexEntry], headTree: [String: TreeEntry]) throws
    -> [FileChange]
  {
    var staged: [FileChange] = []

    // Check for new and modified files in index
    for (path, indexEntry) in indexMap {
      if indexEntry.stage != 0 {
        continue  // Skip conflicted entries
      }

      if let headEntry = headTree[path] {
        // File exists in HEAD, check if modified
        if headEntry.sha1 != indexEntry.sha1Hex {
          staged.append(
            FileChange(
              path: path,
              type: .modified,
              oldPath: nil,
              indexSha1: indexEntry.sha1Hex,
              workTreeSha1: headEntry.sha1
            ))
        }
      } else {
        // New file in index
        staged.append(
          FileChange(
            path: path,
            type: .added,
            oldPath: nil,
            indexSha1: indexEntry.sha1Hex,
            workTreeSha1: nil
          ))
      }
    }

    // Check for deleted files (in HEAD but not in index)
    for (path, headEntry) in headTree {
      if indexMap[path] == nil {
        staged.append(
          FileChange(
            path: path,
            type: .deleted,
            oldPath: nil,
            indexSha1: nil,
            workTreeSha1: headEntry.sha1
          ))
      }
    }

    return staged.sorted { $0.path < $1.path }
  }

  /// Calculate unstaged changes (working directory vs index)
  private func calculateUnstagedChanges(indexMap: [String: IndexEntry], workTreeFiles: [String: FileInfo]) throws
    -> [FileChange]
  {
    var unstaged: [FileChange] = []

    // Check for modified files in working directory
    for (path, fileInfo) in workTreeFiles {
      if let indexEntry = indexMap[path] {
        // File is in index, check if modified
        if try hasFileChanged(indexEntry: indexEntry, fileInfo: fileInfo) {
          unstaged.append(
            FileChange(
              path: path,
              type: .modified,
              oldPath: nil,
              indexSha1: indexEntry.sha1Hex,
              workTreeSha1: try calculateFileSHA1(fileInfo: fileInfo)
            ))
        }
      }
    }

    // Check for deleted files (in index but not in working directory)
    for (path, indexEntry) in indexMap {
      if indexEntry.stage != 0 {
        continue  // Skip conflicted entries
      }

      if workTreeFiles[path] == nil {
        unstaged.append(
          FileChange(
            path: path,
            type: .deleted,
            oldPath: nil,
            indexSha1: indexEntry.sha1Hex,
            workTreeSha1: nil
          ))
      }
    }

    return unstaged.sorted { $0.path < $1.path }
  }

  /// Calculate untracked files (in working directory but not in index or HEAD)
  private func calculateUntrackedFiles(indexMap: [String: IndexEntry], workTreeFiles: [String: FileInfo]) -> [String] {
    var untracked: [String] = []

    for (path, fileInfo) in workTreeFiles {
      if indexMap[path] == nil {
        untracked.append(path)
      }
    }

    return untracked.sorted()
  }

  /// Calculate conflicted files (merge conflicts)
  private func calculateConflictedFiles(indexMap: [String: IndexEntry]) -> [FileChange] {
    var conflicted: [FileChange] = []

    // Group entries by path and stage
    var pathStages: [String: [IndexEntry]] = [:]

    for (path, entry) in indexMap {
      if entry.stage != 0 {
        if pathStages[path] == nil {
          pathStages[path] = []
        }
        pathStages[path]?.append(entry)
      }
    }

    // Create conflict entries
    for (path, entries) in pathStages {
      conflicted.append(
        FileChange(
          path: path,
          type: .modified,  // Use modified for conflicts
          oldPath: nil,
          indexSha1: entries.first?.sha1Hex,
          workTreeSha1: nil
        ))
    }

    return conflicted.sorted { $0.path < $1.path }
  }

  /// Check if a file has changed compared to its index entry
  private func hasFileChanged(indexEntry: IndexEntry, fileInfo: FileInfo) throws -> Bool {
    // Check file size
    if Int(indexEntry.fileSize) != fileInfo.size {
      return true
    }

    // Check modification time (with some tolerance for filesystem precision)
    let indexTime = Date(timeIntervalSince1970: TimeInterval(indexEntry.mtimeSeconds))
    let timeDiff = abs(indexTime.timeIntervalSince(fileInfo.mtime))
    if timeDiff > 1.0 {  // 1 second tolerance
      return true
    }

    // If size and time match, check SHA-1 to be sure
    let currentSHA1 = try calculateFileSHA1(fileInfo: fileInfo)
    return currentSHA1 != indexEntry.sha1Hex
  }

  /// Calculate SHA-1 of a file in the working directory
  private func calculateFileSHA1(fileInfo: FileInfo) throws -> String {
    let filePath = repository.absolutePath(fileInfo.path)
    let data = try repository.readFileData(filePath)
    return Sit.sha1(data)
  }
}
