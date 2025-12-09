import Foundation
import NIOFileSystem

/// Main repository class that encapsulates Git operations
struct GitRepository {
  let gitDir: URL
  let workTree: URL

  /// Initialize a Git repository at the given path
  /// - Parameter path: Path to the working tree (defaults to current directory)
  /// - Throws: GitError.invalidRepository if not a valid Git repository
  init(at path: FilePath = ".") async throws {
    let gitDir = path.appending(".git")
    if let info = try await FileSystem.shared.info(forFileAt: gitDir, infoAboutSymbolicLink: false) {
      switch info.type {
      case .directory:
        self.workTree = URL(fileURLWithPath: path.string).standardizedFileURL
        self.gitDir = URL(fileURLWithPath: gitDir.string).standardizedFileURL
      default:
        throw GitError.invalidRepository("No .git directory found at \(path). Found \(info.type).")
      }
    } else {
      try await FileSystem.shared.createDirectory(at: gitDir, withIntermediateDirectories: true)
      self.workTree = URL(fileURLWithPath: path.string).standardizedFileURL
      self.gitDir = URL(fileURLWithPath: gitDir.string).standardizedFileURL
    }
  }

  /// Initialize with explicit git directory and work tree paths
  /// - Parameters:
  ///   - gitDir: Path to .git directory
  ///   - workTree: Path to working tree
  init(gitDir: URL, workTree: URL) throws {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDir), isDir.boolValue else {
      throw GitError.invalidRepository("Invalid git directory: \(gitDir.path)")
    }

    self.gitDir = gitDir
    self.workTree = workTree
  }

  // MARK: - Path Utilities

  /// Get the path to a Git file relative to .git directory
  func gitPath(_ components: String...) -> URL {
    return components.reduce(gitDir) { $0.appendingPathComponent($1) }
  }

  /// Get the path to a work tree file
  func workTreePath(_ components: String...) -> URL {
    return components.reduce(workTree) { $0.appendingPathComponent($1) }
  }

  /// Convert a repository-relative path to absolute path
  func absolutePath(_ relativePath: String) -> URL {
    if relativePath.hasPrefix("/") {
      return URL(fileURLWithPath: relativePath)
    }
    return workTree.appendingPathComponent(relativePath)
  }

  /// Convert an absolute path to repository-relative path
  func relativePath(_ absolutePath: URL) -> String? {
    let workTreePath = workTree.path + "/"
    let absolutePathString = absolutePath.path

    if absolutePathString.hasPrefix(workTreePath) {
      return String(absolutePathString.dropFirst(workTreePath.count))
    }
    return nil
  }

  // MARK: - File I/O Utilities

  /// Read file contents as Data
  func readFileData(_ path: URL) throws -> Data {
    do {
      return try Data(contentsOf: path)
    } catch {
      throw GitError.ioError("Failed to read file at \(path.path): \(error.localizedDescription)")
    }
  }

  /// Read file contents as String
  func readFileString(_ path: URL) throws -> String {
    do {
      return try String(contentsOf: path, encoding: .utf8)
    } catch {
      throw GitError.ioError("Failed to read file at \(path.path): \(error.localizedDescription)")
    }
  }

  /// Check if a file exists
  func fileExists(_ path: URL) -> Bool {
    return FileManager.default.fileExists(atPath: path.path)
  }

  /// Check if a directory exists
  func directoryExists(_ path: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) && isDir.boolValue
  }

  /// Get file attributes
  func getFileAttributes(_ path: URL) throws -> (size: Int, mtime: Date, mode: Int32) {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
      let size = (attributes[.size] as? Int) ?? 0
      let mtime = (attributes[.modificationDate] as? Date) ?? Date.distantPast
      let mode = (attributes[.posixPermissions] as? Int32) ?? 0
      return (size: size, mtime: mtime, mode: mode)
    } catch {
      throw GitError.ioError("Failed to get attributes for \(path.path): \(error.localizedDescription)")
    }
  }

  // MARK: - Repository Validation

  /// Validate that this is a proper Git repository
  func validateRepository() throws {
    // Check for essential files and directories
    let requiredPaths = [
      "HEAD",
      "objects",
      "refs",
    ]

    for path in requiredPaths {
      let fullPath = gitPath(path)
      if !fileExists(fullPath) {
        throw GitError.invalidRepository("Missing required Git component: \(path)")
      }
    }

    // Check objects directory structure
    let objectsDir = gitPath("objects")
    if !directoryExists(objectsDir) {
      throw GitError.invalidRepository("Invalid objects directory")
    }

    // Check refs directory
    let refsDir = gitPath("refs")
    if !directoryExists(refsDir) {
      throw GitError.invalidRepository("Invalid refs directory")
    }
  }

  // MARK: - Repository Information

  /// Get repository format version
  func getRepositoryFormat() throws -> Int {
    let formatFile = gitPath("format")
    if fileExists(formatFile) {
      let content = try readFileString(formatFile).trimmingCharacters(in: .whitespacesAndNewlines)
      return Int(content) ?? 0
    }
    return 0  // Default format version
  }

  /// Check if repository is bare
  var isBare: Bool {
    return gitDir.path.hasSuffix(".git") && !gitDir.deletingLastPathComponent().path.hasSuffix(".git")
  }

  /// Get repository configuration
  func getConfig() throws -> [String: String] {
    var config: [String: String] = [:]
    let configFile = gitPath("config")

    if fileExists(configFile) {
      let content = try readFileString(configFile)
      let lines = content.components(separatedBy: .newlines)

      for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("[") {
          continue
        }

        let parts = trimmed.components(separatedBy: "=")
        if parts.count == 2 {
          let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
          let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
          config[key] = value
        }
      }
    }

    return config
  }

  /// Get repository description
  func getDescription() -> String {
    let descriptionFile = gitPath("description")
    if fileExists(descriptionFile) {
      do {
        return try readFileString(descriptionFile).trimmingCharacters(in: .whitespacesAndNewlines)
      } catch {
        return "Unnamed repository; edit this file to name it."
      }
    }
    return "Unnamed repository; edit this file to name it."
  }
}

// MARK: - Convenience Extensions

extension GitRepository {
  /// Create a repository by searching up the directory tree
  static func findRepository(from path: String = ".") async throws -> GitRepository {
    let currentURL = URL(fileURLWithPath: path).standardizedFileURL
    var searchURL = currentURL

    while true {
      let gitDir = searchURL.appendingPathComponent(".git")
      var isDir: ObjCBool = false

      if FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDir), isDir.boolValue {
        return try await GitRepository(at: FilePath(searchURL.path))
      }

      // Move to parent directory
      guard searchURL.deletingLastPathComponent().pathComponents.count > 1 else {
        break
      }
      searchURL = searchURL.deletingLastPathComponent()

      // Stop at filesystem root
      if searchURL.path == "/" {
        break
      }
    }

    throw GitError.invalidRepository("No Git repository found containing \(currentURL.path)")
  }
}
