import Foundation

/// Runs `body` with a unique empty directory under the system temp folder, then deletes it.
enum TempDirectory {
  static func withRemoval<R>(_ body: (URL) throws -> R) throws -> R {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("sit-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: url)
    }
    return try body(url)
  }
}
