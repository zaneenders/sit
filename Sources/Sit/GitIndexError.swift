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
  case headUnrecognized(String)
  case missingUserIdentity
  case cannotReadFile(String)
}
