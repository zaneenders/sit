/// Read git objects from a single version-2 packfile + `.idx`.
///
/// Unlike **loose** objects on disk (`blob <n>\\0…`), **packed** undeltified
/// entries zlib-decompress to the **payload only** (what `git cat-file <type>`
/// prints for that object). The pack object header carries `type` and size: for
/// undeltified objects that size is the uncompressed payload length; for
/// OFS/REF deltas it is the uncompressed **delta stream** length (after zlib),
/// while the reconstructed payload size is encoded inside the delta stream.
public struct GitPack: Sendable {
  public let packData: [UInt8]
  public let index: PackIndexV2

  public init(packBytes: [UInt8], indexBytes: [UInt8]) throws {
    _ = try Self.readPackFileHeader(packBytes)
    self.packData = packBytes
    self.index = try PackIndexV2.parse(bytes: indexBytes)
  }

  /// Uncompressed object **payload** (packed form; see ``GitPack`` discussion).
  public func serializedObject(sha20: [UInt8]) throws -> ContiguousArray<UInt8> {
    guard let off32 = index.offset(for: sha20) else {
      throw GitPackError.shaNotFoundInIndex
    }
    var memo: [Int: ContiguousArray<UInt8>] = [:]
    return try Self.decodeObject(
      pack: packData,
      index: index,
      at: Int(off32),
      memo: &memo,
      depth: 0
    )
  }

  /// Pack object type (`1` commit, `2` tree, `3` blob, `4` tag) and uncompressed payload (no loose-style header).
  public func objectTypeAndPayload(sha20: [UInt8]) throws -> (type: Int, payload: ContiguousArray<UInt8>) {
    guard let off32 = index.offset(for: sha20) else {
      throw GitPackError.shaNotFoundInIndex
    }
    var pos = Int(off32)
    let (type, _) = try Self.readPackObjectHeader(packData, pos: &pos)
    var memo: [Int: ContiguousArray<UInt8>] = [:]
    let payload = try Self.decodeObject(
      pack: packData,
      index: index,
      at: Int(off32),
      memo: &memo,
      depth: 0
    )
    return (type, payload)
  }

  // MARK: - Pack file

  private static func readPackFileHeader(_ pack: [UInt8]) throws -> UInt32 {
    guard pack.count >= 12 else { throw GitPackError.truncatedPack }
    guard pack[0] == 0x50, pack[1] == 0x41, pack[2] == 0x43, pack[3] == 0x4b else {
      throw GitPackError.badPackSignature
    }
    let ver = readBigEndianUInt32(pack, 4)
    guard ver == 2 else { throw GitPackError.unknownPackVersion(ver) }
    return readBigEndianUInt32(pack, 8)
  }

  // MARK: - Decode chain

  private static let maxDeltaDepth = 512

  private static func decodeObject(
    pack: [UInt8],
    index: PackIndexV2,
    at offset: Int,
    memo: inout [Int: ContiguousArray<UInt8>],
    depth: Int
  ) throws -> ContiguousArray<UInt8> {
    if let hit = memo[offset] {
      return hit
    }
    guard depth < maxDeltaDepth else { throw GitPackError.recursionDepthExceeded }
    var p = offset
    let (type, expectedSize) = try readPackObjectHeader(pack, pos: &p)
    switch type {
    case 1, 2, 3, 4:
      let (plain, _) = try ZlibLooseObject.decompressPrefix(in: pack, at: p)
      guard plain.count == expectedSize else {
        throw GitPackError.uncompressedSizeMismatch(expected: expectedSize, actual: plain.count)
      }
      memo[offset] = plain
      return plain
    case 6:
      let back = try readVariableWidthInt(pack, pos: &p)
      let baseOffset = offset - Int(back)
      guard baseOffset >= 12, baseOffset < offset else {
        throw GitPackError.truncatedPack
      }
      let base = try decodeObject(
        pack: pack,
        index: index,
        at: baseOffset,
        memo: &memo,
        depth: depth + 1
      )
      let (deltaBody, _) = try ZlibLooseObject.decompressPrefix(in: pack, at: p)
      // Pack header `size` for deltas is the uncompressed *delta instruction*
      // stream length (zlib plaintext), not the reconstructed object size.
      guard deltaBody.count == expectedSize else {
        throw GitPackError.uncompressedSizeMismatch(
          expected: expectedSize,
          actual: deltaBody.count
        )
      }
      let rebuilt = try PackDelta.apply(base: Array(base), delta: Array(deltaBody))
      memo[offset] = rebuilt
      return rebuilt
    case 7:
      guard p + 20 <= pack.count else { throw GitPackError.truncatedPack }
      let baseSha = Array(pack[p..<(p + 20)])
      p += 20
      guard let baseOff32 = index.offset(for: baseSha) else {
        throw GitPackError.baseObjectNotFound
      }
      let base = try decodeObject(
        pack: pack,
        index: index,
        at: Int(baseOff32),
        memo: &memo,
        depth: depth + 1
      )
      let (deltaBody, _) = try ZlibLooseObject.decompressPrefix(in: pack, at: p)
      guard deltaBody.count == expectedSize else {
        throw GitPackError.uncompressedSizeMismatch(
          expected: expectedSize,
          actual: deltaBody.count
        )
      }
      let rebuilt = try PackDelta.apply(base: Array(base), delta: Array(deltaBody))
      memo[offset] = rebuilt
      return rebuilt
    default:
      throw GitPackError.unknownObjectType(type)
    }
  }

  /// Git’s variable-length positive integer used in OFS_DELTA headers (see go-git
  /// `ReadVariableWidthInt`).
  private static func readVariableWidthInt(_ pack: [UInt8], pos: inout Int) throws -> Int64 {
    guard pos < pack.count else { throw GitPackError.truncatedPack }
    var c = pack[pos]
    pos += 1
    var v = Int64(c & 127)
    while c & 128 != 0 {
      v += 1
      guard pos < pack.count else { throw GitPackError.truncatedPack }
      c = pack[pos]
      pos += 1
      v = (v << 7) + Int64(c & 127)
    }
    return v
  }

  /// Pack object header: 3-bit type in upper nibble of first byte, size in lower
  /// nibble + continuation bytes (same layout go-git uses for v2 packs).
  private static func readPackObjectHeader(
    _ pack: [UInt8],
    pos: inout Int
  ) throws -> (type: Int, size: Int) {
    guard pos < pack.count else { throw GitPackError.truncatedPack }
    var c = pack[pos]
    pos += 1
    let type = (Int(c) >> 4) & 7
    var size = Int(c & 0x0f)
    var shift = 4
    while c & 0x80 != 0 {
      guard pos < pack.count else { throw GitPackError.truncatedPack }
      c = pack[pos]
      pos += 1
      size |= Int(c & 0x7f) << shift
      shift += 7
    }
    return (type, size)
  }
}
