// RFC 1950 zlib wrapper around DEFLATE, as used for git loose objects.

public enum ZlibLooseObject {
  /// Decompress a zlib stream (CMF+FLG + deflate + Adler32) to raw bytes.
  public static func decompress(
    _ bytes: [UInt8],
    maxOutputSize: Int = 64 << 20
  ) throws -> ContiguousArray<UInt8> {
    guard bytes.count >= 6 else {
      throw InflateError.truncatedZlib
    }
    _ = try LZ77.Header(parsingCompressedBytes: bytes)
    let deflateSlice = Array(bytes[2..<(bytes.count - 4)])
    let plain = try DeflateInflate.inflate(deflateSlice, maxOutputSize: maxOutputSize)
    let stored = UInt32(bytes[bytes.count - 4]) << 24
      | UInt32(bytes[bytes.count - 3]) << 16
      | UInt32(bytes[bytes.count - 2]) << 8
      | UInt32(bytes[bytes.count - 1])
    let computed = Adler32.checksum(of: plain)
    guard stored == computed else {
      throw InflateError.adler32Mismatch
    }
    return plain
  }

  /// Decompress a zlib stream starting at `start`, returning plaintext and how
  /// many bytes of `bytes` the stream occupied (header + deflate + Adler32).
  public static func decompressPrefix(
    in bytes: [UInt8],
    at start: Int = 0,
    maxOutputSize: Int = 64 << 20
  ) throws -> (plain: ContiguousArray<UInt8>, consumed: Int) {
    guard start >= 0, bytes.count - start >= 6 else {
      throw InflateError.truncatedZlib
    }
    let tail = Array(bytes[start...])
    _ = try LZ77.Header(parsingCompressedBytes: tail)
    let afterHeader = Array(bytes[(start + 2)...])
    let (plain, defConsumed) = try DeflateInflate.inflateAllowTrailing(
      afterHeader,
      maxOutputSize: maxOutputSize
    )
    let adlerBase = start + 2 + defConsumed
    guard adlerBase + 4 <= bytes.count else {
      throw InflateError.truncatedZlib
    }
    let stored =
      UInt32(bytes[adlerBase]) << 24
        | UInt32(bytes[adlerBase + 1]) << 16
        | UInt32(bytes[adlerBase + 2]) << 8
        | UInt32(bytes[adlerBase + 3])
    let computed = Adler32.checksum(of: plain)
    guard stored == computed else {
      throw InflateError.adler32Mismatch
    }
    let total = 2 + defConsumed + 4
    return (plain, total)
  }
}
