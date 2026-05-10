// Pure Swift DEFLATE (RFC 1951) compressor using **stored** blocks only.
// Interoperates with Sit’s inflater and with standard zlib (git objects).

public enum DeflateCompressError: Error, Equatable, Sendable {
  case inputTooLarge
  case internalState
}

/// RFC 1951 DEFLATE bit stream writer: Huffman bits are packed LSB-first per byte,
/// matching ``DeflateInputState/bits(_:)`` / `puff`.
private struct DeflateBitWriter {
  private var data: [UInt8] = []
  private var bitBucket: UInt32 = 0
  private var bitCount = 0

  mutating func writeBits(_ value: UInt32, _ nbits: Int) {
    precondition(nbits >= 0 && nbits <= 31)
    var v = value
    for _ in 0..<nbits {
      if v & 1 != 0 {
        bitBucket |= 1 << UInt32(bitCount)
      }
      v >>= 1
      bitCount += 1
      if bitCount == 8 {
        data.append(UInt8(truncatingIfNeeded: bitBucket & 0xff))
        bitBucket = 0
        bitCount = 0
      }
    }
  }

  mutating func padToByteBoundary() {
    while bitCount != 0 {
      writeBits(0, 1)
    }
  }

  mutating func appendRaw(_ bytes: some Sequence<UInt8>) {
    precondition(bitCount == 0)
    data.append(contentsOf: bytes)
  }

  mutating func takeBytes() throws -> [UInt8] {
    guard bitCount == 0 else {
      throw DeflateCompressError.internalState
    }
    return data
  }
}

public enum DeflateCompress: Sendable {
  /// Maximum DEFLATE stored block payload (RFC 1951).
  public static let maxStoredChunkLength = 65_535

  /// DEFLATE stream using only **stored** blocks (BTYPE `00`). Valid for any
  /// payload size; chunking uses non-final blocks then one final block.
  ///
  /// > Note: This implementation produces stored (uncompressed) blocks only,
  /// > which are always RFC 1951 compliant but may be 2–5× larger than a
  /// > Huffman-coded deflate stream.  Git and zlib can read them without issue.
  /// > A full Huffman-based compressor is future work.
  public static func compressStored(
    _ plain: [UInt8],
    maxPlainSize: Int = 64 << 20
  ) throws -> [UInt8] {
    guard plain.count <= maxPlainSize else {
      throw DeflateCompressError.inputTooLarge
    }
    var w = DeflateBitWriter()
    if plain.isEmpty {
      try appendStoredBlock(
        w: &w,
        chunk: [],
        isLast: true
      )
      return try w.takeBytes()
    }
    var pos = 0
    while pos < plain.count {
      let remaining = plain.count - pos
      let chunkLen = min(maxStoredChunkLength, remaining)
      let isLast = pos + chunkLen >= plain.count
      let chunk = Array(plain[pos..<(pos + chunkLen)])
      try appendStoredBlock(w: &w, chunk: chunk, isLast: isLast)
      pos += chunkLen
    }
    return try w.takeBytes()
  }

  private static func appendStoredBlock(
    w: inout DeflateBitWriter,
    chunk: [UInt8],
    isLast: Bool
  ) throws {
    w.writeBits(isLast ? 1 : 0, 1)
    w.writeBits(0, 2)
    w.padToByteBoundary()
    let len = UInt16(truncatingIfNeeded: chunk.count)
    let nlen = ~len
    w.appendRaw([
      UInt8(truncatingIfNeeded: len & 0xff),
      UInt8(truncatingIfNeeded: len >> 8),
      UInt8(truncatingIfNeeded: nlen & 0xff),
      UInt8(truncatingIfNeeded: nlen >> 8),
    ])
    w.appendRaw(chunk)
  }
}
