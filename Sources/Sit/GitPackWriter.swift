/// Writes Git pack files and pack index v2 files.
///
/// The pack writer serializes objects in pack format suitable for
/// `git receive-pack` (push) and `git gc`.  For v1 only undeltified
/// objects (type 1–4) are written — no OFS_DELTA / REF_DELTA.
/// zlib compression uses DeflateCompress (Huffman-coded DEFLATE).
public enum GitPackWriter: Sendable {

  /// An object ready to be packed.
  public struct PackObject: Sendable {
    /// 20-byte SHA-1
    public let sha20: [UInt8]
    /// Pack type: 1=commit, 2=tree, 3=blob, 4=tag
    public let type: Int
    /// Uncompressed payload (the raw object content without the
    /// `type SP size NUL` loose-object header).
    public let payload: [UInt8]

    public init(sha20: [UInt8], type: Int, payload: [UInt8]) {
      self.sha20 = sha20
      self.type = type
      self.payload = payload
    }
  }

  /// Result of pack writing.
  public struct PackResult: Sendable {
    /// The `.pack` file bytes.
    public let packData: [UInt8]
    /// The `.idx` v2 file bytes.
    public let indexData: [UInt8]
    /// Number of objects written.
    public let objectCount: Int
  }

  /// Per-object metadata collected during pack writing, used to build the index.
  private struct IndexEntry {
    let sha20: [UInt8]
    let offset: UInt32
    let crc32: UInt32
  }

  // MARK: - Public entry point

  /// Write a pack file and its index from the given objects.
  ///
  /// Objects are written in the order provided.  The caller is responsible
  /// for sorting (Git typically sorts by a "good" delta ordering, but for
  /// undeltified packs any order is valid).
  ///
  /// - Parameter objects: objects to pack (at least 1)
  /// - Returns: pack + index bytes
  public static func write(objects: [PackObject]) throws -> PackResult {
    guard !objects.isEmpty else {
      throw GitPackError.noObjectsToPack
    }

    // ---- Build pack body ----

    var packBody: [UInt8] = []
    packBody.reserveCapacity(12 + objects.count * 128)

    // Pack header: "PACK" + version 2 + object count
    packBody.append(contentsOf: [0x50, 0x41, 0x43, 0x4b])  // "PACK"
    packBody.append(contentsOf: withUnsafeBytes(of: UInt32(2).bigEndian, Array.init))
    packBody.append(
      contentsOf: withUnsafeBytes(of: UInt32(objects.count).bigEndian, Array.init))

    var entries: [IndexEntry] = []
    entries.reserveCapacity(objects.count)

    for obj in objects {
      guard obj.sha20.count == 20 else {
        throw GitPackError.badObjectSHA
      }
      guard (1...4).contains(obj.type) else {
        throw GitPackError.unknownObjectType(obj.type)
      }

      let offset = UInt32(packBody.count)

      // Pack objects store just the payload (zlib-compressed) — not the
      // loose-object `type SP size NUL` header.  The type and size are
      // encoded in the pack object header.
      let compressed = try ZlibLooseObject.compress(obj.payload)

      // Pack object header
      let header = encodePackObjectHeader(type: obj.type, size: obj.payload.count)

      // CRC-32 of the full pack object (header + compressed data), per index v2 spec
      let crc32 = CRC32.checksum(of: header + Array(compressed))

      packBody.append(contentsOf: header)
      packBody.append(contentsOf: compressed)

      entries.append(IndexEntry(sha20: obj.sha20, offset: offset, crc32: crc32))
    }

    // Pack trailer: SHA-1 of all bytes before the trailer
    let packSHA1 = GitSHA1.digest(of: packBody)
    packBody.append(contentsOf: packSHA1)

    // ---- Build index v2 ----

    let indexData = try buildIndexV2(entries: entries, packSHA1: packSHA1)

    return PackResult(packData: packBody, indexData: indexData, objectCount: objects.count)
  }

  // MARK: - Pack object header encoding

  /// Encode a pack object header that `GitPack.readPackObjectHeader` can decode.
  ///
  /// Format: first byte = `(type << 4) | (size & 0x0f)`, with MSB set if
  /// additional size bytes follow.  Continuation bytes: 7 bits of size,
  /// MSB set except on the last byte.
  private static func encodePackObjectHeader(type: Int, size: Int) -> [UInt8] {
    var out: [UInt8] = []
    var c = UInt8(((type & 7) << 4) | (size & 0x0f))
    var remaining = size >> 4
    if remaining > 0 {
      c |= 0x80
    }
    out.append(c)
    while remaining > 0 {
      let b = UInt8(remaining & 0x7f)
      remaining >>= 7
      if remaining > 0 {
        out.append(b | 0x80)
      } else {
        out.append(b)
      }
    }
    return out
  }

  // MARK: - Index v2 building

  /// Build a pack index v2 file.
  ///
  /// Format:
  /// - Magic: `\xff\x74\x4f\x63` (4 bytes)
  /// - Version: 2 (4 bytes, big-endian)
  /// - Fanout table: 256 × uint32 (big-endian)
  /// - SHA-1 table: n × 20 bytes, sorted by SHA-1
  /// - CRC-32 table: n × uint32 (big-endian)
  /// - 32-bit offset table: n × uint32 (big-endian)
  /// - Packfile SHA-1: 20 bytes
  /// - Index SHA-1: 20 bytes (SHA-1 of all index bytes before this)
  private static func buildIndexV2(entries: [IndexEntry], packSHA1: [UInt8]) throws -> [UInt8] {
    // Sort by SHA-1
    let sorted = entries.sorted { a, b in
      for i in 0..<20 {
        if a.sha20[i] < b.sha20[i] { return true }
        if a.sha20[i] > b.sha20[i] { return false }
      }
      return false
    }

    let n = sorted.count

    // Fanout table: cumulative count of objects with first byte <= i
    var counts = [Int](repeating: 0, count: 256)
    for entry in sorted {
      counts[Int(entry.sha20[0])] += 1
    }
    var fanout = [UInt32](repeating: 0, count: 256)
    var cumulative: UInt32 = 0
    for i in 0..<256 {
      cumulative += UInt32(counts[i])
      fanout[i] = cumulative
    }

    // SHA-1 table
    var shaTable: [UInt8] = []
    shaTable.reserveCapacity(n * 20)
    for entry in sorted {
      shaTable.append(contentsOf: entry.sha20)
    }

    // CRC-32 table
    var crcTable: [UInt8] = []
    crcTable.reserveCapacity(n * 4)
    for entry in sorted {
      crcTable.append(
        contentsOf: withUnsafeBytes(of: entry.crc32.bigEndian, Array.init))
    }

    // 32-bit offset table
    var offsetTable: [UInt8] = []
    offsetTable.reserveCapacity(n * 4)
    for entry in sorted {
      offsetTable.append(
        contentsOf: withUnsafeBytes(of: entry.offset.bigEndian, Array.init))
    }

    // Assemble index
    var idx: [UInt8] = []
    idx.reserveCapacity(8 + 1024 + n * (20 + 4 + 4) + 40)

    idx.append(contentsOf: [0xff, 0x74, 0x4f, 0x63])  // Magic
    idx.append(contentsOf: withUnsafeBytes(of: UInt32(2).bigEndian, Array.init))  // Version
    for f in fanout {
      idx.append(contentsOf: withUnsafeBytes(of: f.bigEndian, Array.init))
    }
    idx.append(contentsOf: shaTable)
    idx.append(contentsOf: crcTable)
    idx.append(contentsOf: offsetTable)
    idx.append(contentsOf: packSHA1)

    // Index SHA-1
    let indexSHA1 = GitSHA1.digest(of: idx)
    idx.append(contentsOf: indexSHA1)

    return idx
  }
}

// MARK: - CRC-32

/// CRC-32 (ISO 3309 / zlib) checksum.
package enum CRC32 {
  private static let table: [UInt32] = {
    var t = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
      var c = UInt32(i)
      for _ in 0..<8 {
        if c & 1 != 0 {
          c = 0xedb8_8320 ^ (c >> 1)
        } else {
          c >>= 1
        }
      }
      t[i] = c
    }
    return t
  }()

  static func checksum(of bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for b in bytes {
      let idx = Int((crc ^ UInt32(b)) & 0xff)
      crc = table[idx] ^ (crc >> 8)
    }
    return crc ^ 0xffff_ffff
  }
}
