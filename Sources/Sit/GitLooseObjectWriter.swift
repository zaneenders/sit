public import Foundation

/// Write zlib-compressed loose objects under `.git/objects/` (SHA-1, RFC 1950 zlib).
public enum GitLooseObjectWriter {
  /// SHA-1 of the canonical loose `blob` object for `content` (no zlib, no disk I/O).
  public static func blobSha1(content: [UInt8]) -> [UInt8] {
    var header: [UInt8] = []
    header.append(contentsOf: "blob".utf8)
    header.append(UInt8(ascii: " "))
    header.append(contentsOf: String(content.count).utf8)
    header.append(0)
    var storage = header
    storage.append(contentsOf: content)
    return GitSHA1.digest(of: storage)
  }

  public static func writeBlob(gitDir: URL, content: [UInt8]) throws -> [UInt8] {
    try writeObject(gitDir: gitDir, type: "blob", body: content)
  }

  /// `entries` are sorted by `name` as git does (C byte order on typical names).
  public static func writeTree(
    gitDir: URL,
    entries: [(mode: String, name: String, sha20: [UInt8])]
  ) throws -> [UInt8] {
    var body: [UInt8] = []
    body.reserveCapacity(64 + entries.count * 40)
    let sorted = entries.sorted { $0.name < $1.name }
    for e in sorted {
      guard e.sha20.count == 20 else { throw GitObjectWriterError.badHexSha }
      for ch in e.name.utf8 {
        if ch == 0 || ch == UInt8(ascii: "/") {
          throw GitObjectWriterError.invalidTreeEntryName
        }
      }
      guard Self.isValidTreeMode(e.mode) else { throw GitObjectWriterError.invalidMode }
      body.append(contentsOf: e.mode.utf8)
      body.append(UInt8(ascii: " "))
      body.append(contentsOf: e.name.utf8)
      body.append(0)
      body.append(contentsOf: e.sha20)
    }
    return try writeObject(gitDir: gitDir, type: "tree", body: body)
  }

  /// `authorLine` / `committerLine` are the parts **after** `author ` / `committer ` (e.g. `x <x@y> 0 +0000`).
  public static func writeCommit(
    gitDir: URL,
    treeSha40HexLower: String,
    parentShas40HexLower: [String],
    authorLine: String,
    committerLine: String,
    message: String
  ) throws -> [UInt8] {
    guard treeSha40HexLower.count == 40 else { throw GitObjectWriterError.badHexSha }
    for p in parentShas40HexLower where p.count != 40 {
      throw GitObjectWriterError.badHexSha
    }
    var text = "tree \(treeSha40HexLower)\n"
    for p in parentShas40HexLower {
      text += "parent \(p)\n"
    }
    text += "author \(authorLine)\n"
    text += "committer \(committerLine)\n"
    text += "\n"
    var msg = message
    if !msg.hasSuffix("\n") {
      msg += "\n"
    }
    text += msg
    let body = Array(text.utf8)
    return try writeObject(gitDir: gitDir, type: "commit", body: body)
  }

  private static func isValidTreeMode(_ m: String) -> Bool {
    ["100644", "100755", "120000", "040000"].contains(m)
  }

  private static func writeObject(gitDir: URL, type: String, body: [UInt8]) throws -> [UInt8] {
    var header: [UInt8] = []
    header.append(contentsOf: type.utf8)
    header.append(UInt8(ascii: " "))
    header.append(contentsOf: String(body.count).utf8)
    header.append(0)
    var storage = header
    storage.append(contentsOf: body)
    let sha = GitSHA1.digest(of: storage)
    let zlib = try ZlibLooseObject.compress(storage)
    let hex = GitHex.encodeLower(sha)
    let dir = String(hex.prefix(2))
    let leaf = String(hex.dropFirst(2))
    let fm = FileManager.default
    let objDir = gitDir.appendingPathComponent("objects/\(dir)", isDirectory: true)
    try fm.createDirectory(at: objDir, withIntermediateDirectories: true)
    let path = objDir.appendingPathComponent(leaf)
    if fm.fileExists(atPath: path.path) {
      try fm.removeItem(at: path)
    }
    try Data(zlib).write(to: path, options: .atomic)
    return sha
  }
}
