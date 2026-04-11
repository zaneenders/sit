// Adler-32 as used in zlib (RFC 1950).

enum Adler32 {
  static func checksum(of bytes: some Sequence<UInt8>) -> UInt32 {
    var s1: UInt32 = 1
    var s2: UInt32 = 0
    for b in bytes {
      s1 = (s1 + UInt32(b)) % 65521
      s2 = (s2 + s1) % 65521
    }
    return (s2 << 16) | s1
  }
}
