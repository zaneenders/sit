public enum GitObjectWriterError: Error, Equatable, Sendable {
  case badHexSha
  case invalidTreeEntryName
  case invalidMode
}
