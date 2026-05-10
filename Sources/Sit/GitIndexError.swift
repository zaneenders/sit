public import Foundation

public enum GitIndexError: Error, Equatable, Sendable {
  case indexNotFound
  case indexCorrupt(String)
  case indexChecksumMismatch
  case unsupportedIndexVersion(UInt32)
  case pathTooLongForIndex(String)
  case fileNotInWorkTree(String)
  case notARegularFile(String)
  case duplicatePathInIndex(String)
  case fileAndDirectoryConflict(String)
  case emptyIndex
  case missingUserIdentity
  case cannotReadFile(String)
}

extension GitIndexError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .missingUserIdentity:
      return """
        No author identity for this commit. Do one of the following:
        • git config --global user.name 'Your Name' && git config --global user.email 'you@example.com'  (~/.gitconfig)
        • git config user.name 'Your Name' && git config user.email 'you@example.com'  (this repo’s .git/config)
        • export GIT_AUTHOR_NAME='Your Name' GIT_AUTHOR_EMAIL='you@example.com'
        • sit commit --author-name 'Your Name' --author-email 'you@example.com' -m '…'
        """
    default:
      return String(describing: self)
    }
  }
}

