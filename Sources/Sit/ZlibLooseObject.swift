// RFC 1950 zlib wrapper around DEFLATE, as used for git loose objects.

public enum ZlibLooseObject {
  /// Compress to a zlib stream (RFC 1950: CMF+FLG + DEFLATE + Adler32).
  /// Uses stored-only DEFLATE blocks (always valid; larger than zlib’s default).
  public static func compress(
    _ plain: [UInt8],
    maxPlainSize: Int = 64 << 20
  ) throws -> ContiguousArray<UInt8> {
    let deflateBytes = try DeflateCompress.compressStored(plain, maxPlainSize: maxPlainSize)
    let (cmf, flg) = (zlibCMF, zlibFLG)
    var out: [UInt8] = []
    out.reserveCapacity(2 + deflateBytes.count + 4)
    out.append(cmf)
    out.append(flg)
    out.append(contentsOf: deflateBytes)
    let adler = Adler32.checksum(of: plain)
    out.append(UInt8((adler >> 24) & 0xff))
    out.append(UInt8((adler >> 16) & 0xff))
    out.append(UInt8((adler >> 8) & 0xff))
    out.append(UInt8(truncatingIfNeeded: adler & 0xff))
    return ContiguousArray(out)
  }

  /// CMF + FLG for windowBits=15 (32K), default compression level.
  /// CMF=0x78 → CM=8 (deflate), CINFO=7 (32K window).
  /// FLG=0x9C → FLEVEL=2 (default algo), FDICT=0, FCHECK=28 ((0x7800+0x9C) % 31 == 0).
  private static let zlibCMF: UInt8 = 0x78
  private static let zlibFLG: UInt8 = 0x9C

  /// Decompress a zlib stream (CMF+FLG + deflate + Adler32) to raw bytes.
  public static func decompress(
    _ bytes: [UInt8],
    maxOutputSize: Int = 64 << 20
  ) throws -> ContiguousArray<UInt8> {
    guard bytes.count >= 6 else {
      throw InflateError.truncatedZlib
    }
    _ = try ZlibHeader.Header(parsingCompressedBytes: bytes)
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
    _ = try ZlibHeader.Header(parsingCompressedBytes: tail)
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
