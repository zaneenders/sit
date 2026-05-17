public enum GitPackError: Error, Equatable, Sendable {
  case badIndexMagic
  case unsupportedIndexVersion(UInt32)
  case truncatedIndex
  case truncatedPack
  case unknownPackVersion(UInt32)
  case badPackSignature
  case unknownObjectType(Int)
  case shaNotFoundInIndex
  case baseObjectNotFound
  case deltaBaseSizeMismatch
  case truncatedDelta
  case invalidDeltaCommand
  case deltaReplayMismatch
  case uncompressedSizeMismatch(expected: Int, actual: Int)
  case recursionDepthExceeded
  case pack64OffsetsNotSupported
  case noObjectsToPack
  case badObjectSHA
}
