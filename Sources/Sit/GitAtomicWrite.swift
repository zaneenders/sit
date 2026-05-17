import SystemPackage

#if canImport(System)
import System
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Write `content` to `target` atomically using Git's lockfile pattern:
/// write to `target.lock`, fsync, then `rename(2)` (atomic on same filesystem).
enum GitAtomicWrite {
  /// Overwrite `target` atomically. Parent directories must already exist.
  static func write(_ content: [UInt8], to target: FilePath) throws {
    let lockPath = FilePath(target.string + ".lock")
    let fd = try FileDescriptor.open(
      lockPath, .writeOnly,
      options: [.create, .truncate],
      permissions: .ownerReadWrite
    )
    try fd.closeAfter {
      try fd.writeAll(content)
      guard fsync(fd.rawValue) == 0 else {
        throw GitAtomicWriteError.syncFailed
      }
    }
    // rename(2) is atomic when old and new are on the same filesystem
    let result = target.string.withCString { new in
      lockPath.string.withCString { old in
        rename(old, new)
      }
    }
    guard result == 0 else {
      throw GitAtomicWriteError.renameFailed
    }
  }
}

enum GitAtomicWriteError: Error, Equatable, Sendable {
  case syncFailed
  case renameFailed
}
