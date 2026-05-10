public enum GitHex: Sendable {
  public static func encodeLower(_ sha20: [UInt8]) -> String {
    precondition(sha20.count == 20)
    let table = Array("0123456789abcdef".utf8)
    var out = [UInt8]()
    out.reserveCapacity(40)
    for b in sha20 {
      out.append(table[Int(b >> 4)])
      out.append(table[Int(b & 0x0f)])
    }
    return String(decoding: out, as: UTF8.self)
  }

  public static func decode20(_ hex40: String) throws -> [UInt8] {
    guard hex40.count == 40 else { throw GitObjectWriterError.badHexSha }
    var out: [UInt8] = []
    out.reserveCapacity(20)
    var i = hex40.startIndex
    while i < hex40.endIndex {
      let j = hex40.index(i, offsetBy: 2, limitedBy: hex40.endIndex) ?? hex40.endIndex
      guard let b = UInt8(hex40[i..<j], radix: 16) else { throw GitObjectWriterError.badHexSha }
      out.append(b)
      i = j
    }
    guard out.count == 20 else { throw GitObjectWriterError.badHexSha }
    return out
  }
}

/// Big-endian UInt32 from byte array at `offset` (no bounds check — caller must ensure).
package func readBigEndianUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
  (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
    | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
}
