import Foundation
import _NIOFileSystem

/// Scans the working directory and collects file information
class WorkingDirectoryScanner {
  private let repository: GitRepository

  init(repository: GitRepository) {
    self.repository = repository
  }

  /// Scan the working directory and collect file information
  /// - Parameter includeIgnored: Whether to include ignored files
  /// - Returns: Dictionary mapping file paths to file info
  /// - Throws: GitError if scanning fails
  func scanWorkTree(includeIgnored: Bool = false) throws -> [String: FileInfo] {
    var files: [String: FileInfo] = [:]

    try scanDirectory(
      at: repository.workTree,
      relativePath: "",
      files: &files,
      includeIgnored: includeIgnored
    )

    return files
  }

  /// Scan a directory recursively
  private func scanDirectory(
    at url: URL,
    relativePath: String,
    files: inout [String: FileInfo],
    includeIgnored: Bool
  ) throws {
    let fileManager = FileManager.default

    // Skip .git directory
    if url.lastPathComponent == ".git" {
      return
    }

    // Get directory contents
    let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)

    for item in contents {
      // Skip .git directory
      if item.lastPathComponent == ".git" {
        continue
      }

      // Get relative path
      let itemRelativePath = relativePath.isEmpty ? item.lastPathComponent : "\(relativePath)/\(item.lastPathComponent)"

      // Check if file should be ignored
      if !includeIgnored && isIgnored(itemRelativePath) {
        continue
      }

      var isDir: ObjCBool = false
      var isSymlink: ObjCBool = false

      // Check if it's a symbolic link first
      if fileManager.fileExists(atPath: item.path, isDirectory: &isDir) {
        // Get file attributes
        let attributes = try fileManager.attributesOfItem(atPath: item.path)

        let fileType = attributes[.type] as? FileAttributeType
        isSymlink = ObjCBool(fileType == .typeSymbolicLink)

        if isSymlink.boolValue {
          // Handle symbolic link
          let symlinkInfo = try getSymlinkInfo(item, relativePath: itemRelativePath)
          files[itemRelativePath] = symlinkInfo
        } else if isDir.boolValue {
          // Recursively scan subdirectory
          try scanDirectory(
            at: item,
            relativePath: itemRelativePath,
            files: &files,
            includeIgnored: includeIgnored
          )
        } else {
          // Handle regular file
          let fileInfo = try getFileInfo(item, relativePath: itemRelativePath)
          files[itemRelativePath] = fileInfo
        }
      }
    }
  }

  /// Get file information for a regular file
  private func getFileInfo(_ url: URL, relativePath: String) throws -> FileInfo {
    let attributes = try repository.getFileAttributes(url)

    return FileInfo(
      path: relativePath,
      size: attributes.size,
      mtime: attributes.mtime,
      mode: attributes.mode,
      isDirectory: false,
      isSymlink: false,
      targetPath: nil
    )
  }

  /// Get file information for a symbolic link
  private func getSymlinkInfo(_ url: URL, relativePath: String) throws -> FileInfo {
    let fileManager = FileManager.default

    // Get the target path
    let targetPath = try fileManager.destinationOfSymbolicLink(atPath: url.path)

    // Get basic attributes (symlink itself)
    let attributes = try repository.getFileAttributes(url)

    return FileInfo(
      path: relativePath,
      size: attributes.size,
      mtime: attributes.mtime,
      mode: attributes.mode,
      isDirectory: false,
      isSymlink: true,
      targetPath: targetPath
    )
  }

  /// Check if a file should be ignored based on .gitignore rules
  private func isIgnored(_ relativePath: String) -> Bool {
    // Simple implementation - check basic ignore patterns
    // In a full implementation, this would parse .gitignore files

    let ignorePatterns = [
      ".DS_Store",
      "*.tmp",
      "*.swp",
      "*.swo",
      "*~",
      ".gitignore",
      ".gitmodules",
    ]

    for pattern in ignorePatterns {
      if matchesPattern(relativePath, pattern: pattern) {
        return true
      }
    }

    // Check for .gitignore file and parse it
    if let gitignoreRules = try? parseGitignore() {
      for rule in gitignoreRules {
        if matchesPattern(relativePath, pattern: rule) {
          return true
        }
      }
    }

    return false
  }

  /// Parse .gitignore file and return ignore rules
  private func parseGitignore() throws -> [String] {
    let gitignorePath = repository.workTreePath(".gitignore")

    guard repository.fileExists(gitignorePath) else {
      return []
    }

    let content = try repository.readFileString(gitignorePath)
    let lines = content.components(separatedBy: .newlines)

    var rules: [String] = []

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

      // Skip empty lines and comments
      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        continue
      }

      // Skip negation patterns for now (simplified)
      if trimmed.hasPrefix("!") {
        continue
      }

      rules.append(trimmed)
    }

    return rules
  }

  /// Simple pattern matching for gitignore-style patterns
  private func matchesPattern(_ path: String, pattern: String) -> Bool {
    // Handle exact match
    if path == pattern {
      return true
    }

    // Handle directory patterns (ending with /)
    if pattern.hasSuffix("/") {
      let dirPattern = String(pattern.dropLast())
      return path.hasPrefix(dirPattern)
        && (path.count == dirPattern.count || path[path.index(after: dirPattern.endIndex)...].hasPrefix("/"))
    }

    // Handle wildcard patterns (simplified)
    if pattern.contains("*") {
      return matchesWildcard(path, pattern: pattern)
    }

    // Handle directory component matching
    let pathComponents = path.components(separatedBy: "/")
    let patternComponents = pattern.components(separatedBy: "/")

    // Check if pattern matches any component
    for patternComp in patternComponents {
      for pathComp in pathComponents {
        if matchesWildcard(pathComp, pattern: patternComp) {
          return true
        }
      }
    }

    // Check if path ends with pattern
    if path.hasSuffix(pattern) {
      return true
    }

    return false
  }

  /// Simple wildcard matching
  private func matchesWildcard(_ string: String, pattern: String) -> Bool {
    // Convert pattern to regex
    let regexPattern =
      pattern
      .replacingOccurrences(of: ".", with: "\\.")
      .replacingOccurrences(of: "*", with: ".*")
      .replacingOccurrences(of: "?", with: ".")

    do {
      let regex = try NSRegularExpression(pattern: "^\(regexPattern)$", options: [])
      let range = NSRange(location: 0, length: string.utf16.count)
      return regex.firstMatch(in: string, options: [], range: range) != nil
    } catch {
      // If regex fails, fall back to simple string comparison
      return string == pattern
    }
  }

  /// Get statistics about the working directory
  func getWorkTreeStats() throws -> (totalFiles: Int, totalDirectories: Int, totalSize: Int) {
    let files = try scanWorkTree()

    var totalFiles = 0
    var totalDirectories = 0
    var totalSize = 0

    for (_, fileInfo) in files {
      if fileInfo.isDirectory {
        totalDirectories += 1
      } else {
        totalFiles += 1
        totalSize += fileInfo.size
      }
    }

    return (totalFiles: totalFiles, totalDirectories: totalDirectories, totalSize: totalSize)
  }

  /// Find files that have been modified since a given date
  func findModifiedFiles(since date: Date) throws -> [String] {
    let files = try scanWorkTree()
    var modifiedFiles: [String] = []

    for (path, fileInfo) in files {
      if fileInfo.mtime > date {
        modifiedFiles.append(path)
      }
    }

    return modifiedFiles.sorted()
  }

  /// Find files matching a pattern
  func findFiles(matching pattern: String) throws -> [String] {
    let files = try scanWorkTree()
    var matchingFiles: [String] = []

    for (path, _) in files {
      if matchesPattern(path, pattern: pattern) {
        matchingFiles.append(path)
      }
    }

    return matchingFiles.sorted()
  }
}

// MARK: - Repository Extensions

extension GitRepository {

  /// Create a working directory scanner for this repository
  func workingDirectoryScanner() -> WorkingDirectoryScanner {
    return WorkingDirectoryScanner(repository: self)
  }

  /// Scan the working directory and collect file information
  /// - Parameter includeIgnored: Whether to include ignored files
  /// - Returns: Dictionary mapping file paths to file info
  /// - Throws: GitError if scanning fails
  func scanWorkTree(includeIgnored: Bool = false) throws -> [String: FileInfo] {
    let scanner = workingDirectoryScanner()
    return try scanner.scanWorkTree(includeIgnored: includeIgnored)
  }

  /// Get working directory statistics
  func getWorkTreeStats() throws -> (totalFiles: Int, totalDirectories: Int, totalSize: Int) {
    let scanner = workingDirectoryScanner()
    return try scanner.getWorkTreeStats()
  }

  /// Find files modified since a given date
  func findModifiedFiles(since date: Date) throws -> [String] {
    let scanner = workingDirectoryScanner()
    return try scanner.findModifiedFiles(since: date)
  }

  /// Find files matching a pattern
  func findFiles(matching pattern: String) throws -> [String] {
    let scanner = workingDirectoryScanner()
    return try scanner.findFiles(matching: pattern)
  }
}
