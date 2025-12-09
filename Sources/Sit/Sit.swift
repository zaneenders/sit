import CryptoKit
import Foundation
import NIOFileSystem

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
    return try statusCalculator.calculateStatus()
  }
}

/// Calculates git status by comparing index, working directory, and HEAD
class StatusCalculator {
  private let repository: GitRepository

  init(repository: GitRepository) {
    self.repository = repository
  }

  /// Calculate the complete status of the repository
  func calculateStatus() throws -> StatusResult {
    // Get current branch information
    let branch = try repository.getCurrentBranch()
    let isDetached = try repository.isDetachedHEAD()

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
