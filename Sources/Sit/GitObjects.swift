import Foundation

// MARK: - Core Protocols

protocol GitObject {
  var type: String { get }
  var sha1: String { get }
}

// MARK: - Git Object Types

struct Blob: GitObject {
  let type = "blob"
  let sha1: String
  let data: Data
  let size: Int
}

struct Tree: GitObject {
  let type = "tree"
  let sha1: String
  let entries: [TreeEntry]
}

struct TreeEntry {
  let mode: String
  let name: String
  let sha1: String
  let isDirectory: Bool

  var fileType: String {
    switch mode {
    case "100644": return "regular file"
    case "100755": return "executable"
    case "120000": return "symlink"
    case "040000": return "directory"
    default: return "unknown"
    }
  }
}

struct Commit: GitObject {
  let type = "commit"
  let sha1: String
  let tree: String
  let parents: [String]
  let author: String
  let committer: String
  let message: String

  var authorName: String {
    author.components(separatedBy: " <").first ?? author
  }

  var committerName: String {
    committer.components(separatedBy: " <").first ?? committer
  }
}

// MARK: - Index Structures

struct IndexHeader {
  let signature: String
  let version: UInt32
  let entryCount: UInt32

  static let expectedSignature = "DIRC"
}

struct IndexEntry {
  let ctimeSeconds: UInt32
  let ctimeNanoseconds: UInt32
  let mtimeSeconds: UInt32
  let mtimeNanoseconds: UInt32
  let device: UInt32
  let inode: UInt32
  let mode: UInt32
  let uid: UInt32
  let gid: UInt32
  let fileSize: UInt32
  let sha1: [UInt8]
  let flags: UInt16
  let extendedFlags: UInt16
  let path: String

  var stage: UInt16 {
    (flags >> 12) & 0x3
  }

  var pathLength: Int {
    Int(flags & 0x0FFF)
  }

  var isAssumeValid: Bool {
    (flags & 0x8000) != 0
  }

  var isExtended: Bool {
    (flags & 0x4000) != 0
  }

  var isSkipWorktree: Bool {
    (extendedFlags & 0x2000) != 0
  }

  var isIntentToAdd: Bool {
    (extendedFlags & 0x1000) != 0
  }

  var fileMode: String {
    String(format: "%06o", mode)
  }

  var sha1Hex: String {
    sha1.map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - Status Result Types

enum FileChangeType {
  case modified
  case added
  case deleted
  case renamed
  case copied
  case typeChanged

  var displaySymbol: String {
    switch self {
    case .modified: return "M"
    case .added: return "A"
    case .deleted: return "D"
    case .renamed: return "R"
    case .copied: return "C"
    case .typeChanged: return "T"
    }
  }
}

struct FileChange {
  let path: String
  let type: FileChangeType
  let oldPath: String?  // For renames/copies
  let indexSha1: String?
  let workTreeSha1: String?
}

struct StatusResult {
  let staged: [FileChange]
  let unstaged: [FileChange]
  let untracked: [String]
  let conflicted: [FileChange]
  let branch: String?
  let ahead: Int
  let behind: Int

  var hasChanges: Bool {
    !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty || !conflicted.isEmpty
  }

  var totalChanges: Int {
    staged.count + unstaged.count + untracked.count + conflicted.count
  }
}

// MARK: - Working Directory Structures

struct FileInfo {
  let path: String
  let size: Int
  let mtime: Date
  let mode: Int32
  let isDirectory: Bool
  let isSymlink: Bool
  let targetPath: String?  // For symlinks

  var fileMode: String {
    String(format: "%06o", mode)
  }
}

// MARK: - Error Types

enum GitError: Error, LocalizedError {
  case invalidRepository(String)
  case invalidObjectFormat(String)
  case invalidIndexFormat(String)
  case invalidSHA1(String)
  case objectNotFound(String)
  case referenceNotFound(String)
  case decompressionFailed
  case invalidPath(String)
  case invalidPathEncoding(String)
  case invalidHEAD(String)
  case ioError(String)

  var errorDescription: String? {
    switch self {
    case .invalidRepository(let path):
      return "Invalid Git repository: \(path)"
    case .invalidObjectFormat(let message):
      return "Invalid Git object format: \(message)"
    case .invalidIndexFormat(let message):
      return "Invalid Git index format: \(message)"
    case .invalidSHA1(let sha1):
      return "Invalid SHA-1 format: \(sha1)"
    case .objectNotFound(let sha1):
      return "Git object not found: \(sha1)"
    case .referenceNotFound(let ref):
      return "Git reference not found: \(ref)"
    case .decompressionFailed:
      return "Failed to decompress Git object"
    case .invalidPath(let path):
      return "Invalid path: \(path)"
    case .invalidPathEncoding(let message):
      return "Invalid path encoding: \(message)"
    case .invalidHEAD(let message):
      return "Invalid HEAD format: \(message)"
    case .ioError(let message):
      return "I/O error: \(message)"
    }
  }
}

// MARK: - Utility Extensions

extension Character {
  var isHexDigit: Bool {
    return self.isASCII && (self.isNumber || ("a"..."f").contains(self) || ("A"..."F").contains(self))
  }
}

extension String {
  var isValidSHA1: Bool {
    return count == 40 && allSatisfy { $0.isHexDigit }
  }

  var isValidShortSHA1: Bool {
    return count >= 4 && count <= 40 && allSatisfy { $0.isHexDigit }
  }
}
