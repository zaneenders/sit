/// Low-level parsers for Git object payloads: commit, tree, and tag.
/// These operate on the raw object body (after the `type SP size NUL` loose header).
public enum GitObjectParser: Sendable {

  // MARK: - Commit parsing

  /// Extract tree and parent SHAs from a commit payload.
  public static func parseCommit(_ payload: [UInt8])
    -> (treeHex: String, parentHexes: [String])
  {
    let str = String(decoding: payload, as: UTF8.self)
    var treeHex = ""
    var parents: [String] = []

    for line in str.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.isEmpty { break }  // header/body separator
      if line.hasPrefix("tree ") {
        treeHex = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
      } else if line.hasPrefix("parent ") {
        parents.append(
          String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces))
      }
    }

    return (treeHex, parents)
  }

  // MARK: - Tree parsing

  /// A single entry from a tree object.
  public struct TreeEntry: Equatable, Sendable {
    public let mode: String
    public let name: String
    public let sha20: [UInt8]

    public init(mode: String, name: String, sha20: [UInt8]) {
      self.mode = mode
      self.name = name
      self.sha20 = sha20
    }
  }

  /// Parse raw tree payload into individual entries.
  public static func parseTree(_ payload: [UInt8]) -> [TreeEntry] {
    var entries: [TreeEntry] = []
    var pos = 0

    while pos < payload.count {
      // Scan past "mode " — find the space
      guard let spaceIdx = payload[pos...].firstIndex(of: UInt8(ascii: " "))
      else { break }
      let mode = String(decoding: payload[pos..<spaceIdx], as: UTF8.self)
      pos = spaceIdx + 1

      // Scan past "name\0" — find the null
      guard let nullIdx = payload[pos...].firstIndex(of: 0) else { break }
      let name = String(decoding: payload[pos..<nullIdx], as: UTF8.self)
      pos = nullIdx + 1

      // Read 20-byte SHA
      guard pos + 20 <= payload.count else { break }
      let sha20 = Array(payload[pos..<(pos + 20)])
      pos += 20

      entries.append(TreeEntry(mode: mode, name: name, sha20: sha20))
    }

    return entries
  }

  // MARK: - Tag parsing

  /// Extract the object SHA referenced by a tag.
  public static func tagObjectSHA(_ payload: [UInt8]) -> [UInt8]? {
    guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
    for raw in text.split(separator: "\n") {
      let line = String(raw)
      guard line.hasPrefix("object ") else { continue }
      let shaStr = String(line.dropFirst(7).prefix(40))
      if let sha20 = try? GitHex.decode20(shaStr) { return sha20 }
    }
    return nil
  }

  // MARK: - Type conversions

  public static func typeString(from typeInt: Int) -> String? {
    switch typeInt {
    case 1: return "commit"
    case 2: return "tree"
    case 3: return "blob"
    case 4: return "tag"
    default: return nil
    }
  }

  public static func typeInt(from typeString: String) -> Int {
    switch typeString {
    case "commit": return 1
    case "tree":   return 2
    case "blob":   return 3
    case "tag":    return 4
    default:       return 3  // safest fallback
    }
  }
}
