public enum GitInitError: Error, Equatable, Sendable {
  case gitDirectoryAlreadyExists
  case templateDirectoryNotFound
  case fileSystemError(String)
}
