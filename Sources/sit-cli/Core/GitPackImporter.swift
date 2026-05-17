import Foundation
import Sit

// MARK: - Pack Importer

/// Parses a raw packfile (as received from `git-upload-pack`) and writes every
/// object as a loose object under `.git/objects/`.  Handles undeltified objects
/// (types 1–4) as well as OFS_DELTA (6) and REF_DELTA (7).
enum GitPackImporter {

  /// Errors that can occur during pack import.
  enum Error: Swift.Error, Equatable {
    case truncatedPack(Int)
    case badPackSignature
    case unknownPackVersion(UInt32)
    case unknownObjectType(Int)
    case baseObjectNotFound
    case deltaBaseNotInPack
    case packChecksumMismatch
    case emptyPack
  }

  /// Result of importing a pack.
  struct ImportResult {
    /// 40-hex SHAs of all objects written.
    let importedSHAs: Set<String>
    /// Number of object references that could not be resolved (REF_DELTA with missing base).
    let unresolvedDeltas: Int

    init(importedSHAs: Set<String>, unresolvedDeltas: Int) {
      self.importedSHAs = importedSHAs
      self.unresolvedDeltas = unresolvedDeltas
    }
  }

  /// Process a raw pack and write all objects as loose objects.
  ///
  /// - Parameter gitDir: Path to `.git` directory
  /// - Parameter packData: Raw pack bytes (including header and trailer)
  /// - Parameter packs: Existing pack files for resolving REF_DELTA bases
  /// - Returns: Result with imported SHAs and unresolved count
  static func importPack(
    gitDir: URL,
    packData: [UInt8],
    packs: [GitPack]
  ) throws -> ImportResult {
    guard packData.count >= 12 else { throw Error.truncatedPack(packData.count) }
    guard packData[0] == 0x50, packData[1] == 0x41,
      packData[2] == 0x43, packData[3] == 0x4b
    else {
      throw Error.badPackSignature
    }
    let version = readBigEndianUInt32(packData, 4)
    guard version == 2 else { throw Error.unknownPackVersion(version) }
    let objectCount = readBigEndianUInt32(packData, 8)
    guard objectCount > 0 else { throw Error.emptyPack }

    // Verify trailing SHA-1
    let bodyEnd = packData.count - 20
    guard bodyEnd >= 12 else {
      throw Error.truncatedPack(packData.count)
    }
    let storedSHA = Array(packData[bodyEnd...])
    let computedSHA = GitSHA1.digest(of: Array(packData[0..<bodyEnd]))
    guard storedSHA == computedSHA else { throw Error.packChecksumMismatch }

    // Tracking: pack offset → (sha20: [UInt8], type: Int, payload: [UInt8])
    struct Imported {
      let sha20: [UInt8]
      let type: Int
      let payload: [UInt8]
    }
    var imported: [Int: Imported] = [:]
    var importedSHAs = Set<String>()
    var unresolvedDeltas = 0

    // Read pack in reverse to handle deltas — deltas may reference later objects
    var pos = 12
    for _ in 0..<Int(objectCount) {
      let objOffset = pos
      let (type, _) = try readPackObjectHeader(packData, pos: &pos)

      switch type {
      case 1, 2, 3, 4:
        // Undeltified: decompress zlib, compute SHA, write as loose
        let (payload, zlibConsumed) = try ZlibLooseObject.decompressPrefix(in: packData, at: pos)
        pos += zlibConsumed

        let typeStr = packTypeName(type)
        let sha20 = try writeLooseObject(gitDir: gitDir, type: typeStr, body: Array(payload))
        let shaHex = GitHex.encodeLower(sha20)

        imported[objOffset] = Imported(sha20: sha20, type: type, payload: Array(payload))
        importedSHAs.insert(shaHex)

      case 6:
        // OFS_DELTA: read negative offset, decompress delta, resolve base, apply
        let negativeOffset = try readVariableWidthInt(packData, pos: &pos)
        let (deltaBody, zlibConsumed) = try ZlibLooseObject.decompressPrefix(in: packData, at: pos)
        pos += zlibConsumed

        let baseOffset = objOffset - Int(negativeOffset)
        guard let base = imported[baseOffset] else {
          // Base not yet imported — attempt to walk back
          // The base should be at an earlier offset; try to reconstruct
          throw Error.deltaBaseNotInPack
        }

        let rebuilt = try PackDelta.apply(base: base.payload, delta: Array(deltaBody))
        let rebuiltTypeStr = packTypeName(base.type)
        let sha20 = try writeLooseObject(gitDir: gitDir, type: rebuiltTypeStr, body: Array(rebuilt))
        let shaHex = GitHex.encodeLower(sha20)

        imported[objOffset] = Imported(sha20: sha20, type: base.type, payload: Array(rebuilt))
        importedSHAs.insert(shaHex)

      case 7:
        // REF_DELTA: read base SHA, decompress delta, look up base, apply
        guard pos + 20 <= packData.count else { throw Error.truncatedPack(packData.count) }
        let baseSHA = Array(packData[pos..<(pos + 20)])
        pos += 20
        let (deltaBody, zlibConsumed) = try ZlibLooseObject.decompressPrefix(in: packData, at: pos)
        pos += zlibConsumed

        // Look up base: first in newly imported objects, then in existing packs
        let basePayload: [UInt8]
        let baseType: Int
        if let known = imported.first(where: { $0.value.sha20 == baseSHA }) {
          basePayload = known.value.payload
          baseType = known.value.type
        } else if let (typeStr, payload) = try? GitObjectDatabase.readObject(
          gitDir: gitDir, packs: packs, sha20: baseSHA)
        {
          basePayload = payload
          baseType = typeStrToInt(typeStr)
        } else {
          unresolvedDeltas += 1
          continue
        }

        let rebuilt = try PackDelta.apply(base: basePayload, delta: Array(deltaBody))
        let rebuiltTypeStr = packTypeName(baseType)
        let sha20 = try writeLooseObject(gitDir: gitDir, type: rebuiltTypeStr, body: Array(rebuilt))
        let shaHex = GitHex.encodeLower(sha20)

        imported[objOffset] = Imported(sha20: sha20, type: baseType, payload: Array(rebuilt))
        importedSHAs.insert(shaHex)

      default:
        throw Error.unknownObjectType(type)
      }
    }

    return ImportResult(importedSHAs: importedSHAs, unresolvedDeltas: unresolvedDeltas)
  }

  // MARK: - Pack header helpers

  private static func readPackObjectHeader(
    _ pack: [UInt8],
    pos: inout Int
  ) throws -> (type: Int, size: Int) {
    guard pos < pack.count else { throw Error.truncatedPack(pack.count) }
    var c = pack[pos]
    pos += 1
    let type = (Int(c) >> 4) & 7
    var size = Int(c & 0x0f)
    var shift = 4
    while c & 0x80 != 0 {
      guard pos < pack.count else { throw Error.truncatedPack(pack.count) }
      c = pack[pos]
      pos += 1
      size |= Int(c & 0x7f) << shift
      shift += 7
    }
    return (type, size)
  }

  private static func readVariableWidthInt(_ pack: [UInt8], pos: inout Int) throws -> Int64 {
    guard pos < pack.count else { throw Error.truncatedPack(pack.count) }
    var c = pack[pos]
    pos += 1
    var v = Int64(c & 127)
    while c & 128 != 0 {
      v += 1
      guard pos < pack.count else { throw Error.truncatedPack(pack.count) }
      c = pack[pos]
      pos += 1
      v = (v << 7) + Int64(c & 127)
    }
    return v
  }

  // MARK: - Helpers

  private static func packTypeName(_ t: Int) -> String {
    return GitObjectParser.typeString(from: t) ?? "blob"
  }

  private static func typeStrToInt(_ t: String) -> Int {
    return GitObjectParser.typeInt(from: t)
  }

  /// Write a loose object to `.git/objects/`, returning the 20-byte SHA-1.
  private static func writeLooseObject(
    gitDir: URL, type: String, body: [UInt8]
  ) throws -> [UInt8] {
    return try GitLooseObjectWriter.writeObject(gitDir: gitDir, type: type, body: body)
  }
}
