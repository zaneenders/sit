public import Foundation

public enum GitObjectReadError: Error, Equatable, Sendable {
  case objectNotFound
  case malformedLooseObject(String)
  case unknownPackType(Int)
  case commitMissingTreeLine
}

/// Resolves Git objects from loose storage and all `objects/pack/*.pack` indexes under `gitDir`.
public enum GitObjectDatabase: Sendable {
  public static func openAllPacks(gitDir: URL) throws -> [GitPack] {
    let packDir = gitDir.appendingPathComponent("objects/pack", isDirectory: true)
    let fm = FileManager.default
    guard fm.fileExists(atPath: packDir.path) else { return [] }
    let contents =
      (try? fm.contentsOfDirectory(
        at: packDir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )) ?? []
    var packs: [GitPack] = []
    for idxURL in contents where idxURL.pathExtension == "idx" {
      let packURL = idxURL.deletingPathExtension().appendingPathExtension("pack")
      guard fm.fileExists(atPath: packURL.path) else { continue }
      let idx = try Data(contentsOf: idxURL)
      let pack = try Data(contentsOf: packURL)
      packs.append(try GitPack(packBytes: Array(pack), indexBytes: Array(idx)))
    }
    return packs
  }

  /// Reads a Git object as `(type, payload)` where `payload` is the raw tree/blob/commit bytes (no `type SP size NUL` prefix).
  public static func readObject(gitDir: URL, packs: [GitPack], sha20: [UInt8]) throws -> (
    type: String,
    payload: [UInt8]
  ) {
    if let loose = try readLoose(gitDir: gitDir, sha20: sha20) {
      return loose
    }
    for pack in packs {
      guard pack.index.offset(for: sha20) != nil else { continue }
      let (t, payload) = try pack.objectTypeAndPayload(sha20: sha20)
      guard let typeName = packTypeName(t) else { throw GitObjectReadError.unknownPackType(t) }
      return (typeName, Array(payload))
    }
    throw GitObjectReadError.objectNotFound
  }

  private static func packTypeName(_ t: Int) -> String? {
    switch t {
    case 1: return "commit"
    case 2: return "tree"
    case 3: return "blob"
    case 4: return "tag"
    default: return nil
    }
  }

  private static func readLoose(gitDir: URL, sha20: [UInt8]) throws -> (String, [UInt8])? {
    let hex = GitHex.encodeLower(sha20)
    guard hex.count == 40 else { return nil }
    let dir = String(hex.prefix(2))
    let leaf = String(hex.dropFirst(2))
    let path = gitDir.appendingPathComponent("objects/\(dir)/\(leaf)", isDirectory: false)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let zlib = try Data(contentsOf: path)
    let plain = try Array(ZlibLooseObject.decompress(Array(zlib)))
    return try parseLooseHeader(plain)
  }

  private static func parseLooseHeader(_ plain: [UInt8]) throws -> (String, [UInt8]) {
    guard !plain.isEmpty else { throw GitObjectReadError.malformedLooseObject("empty") }
    var i = 0
    while i < plain.count, plain[i] != UInt8(ascii: " ") {
      i += 1
    }
    guard i < plain.count else { throw GitObjectReadError.malformedLooseObject("no space") }
    let type = String(decoding: plain[0..<i], as: UTF8.self)
    i += 1
    let numStart = i
    while i < plain.count, plain[i] >= UInt8(ascii: "0"), plain[i] <= UInt8(ascii: "9") {
      i += 1
    }
    guard numStart < i else { throw GitObjectReadError.malformedLooseObject("no size") }
    guard i < plain.count, plain[i] == 0 else { throw GitObjectReadError.malformedLooseObject("no nul") }
    i += 1
    return (type, Array(plain[i...]))
  }
}
