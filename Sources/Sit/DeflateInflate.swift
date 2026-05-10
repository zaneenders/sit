// Pure Swift DEFLATE (RFC 1951) decompressor, algorithmically derived from Mark
// Adler’s reference `puff` (zlib/contrib/puff). See zlib’s `puff.c` for the
// authoritative bit layout and error semantics.
//
// **LZ77 background.** DEFLATE’s copy instructions (Huffman-coded *length* plus
// *distance*) are the practical form of **LZ77** sliding-window references:
// J. Ziv and A. Lempel, “A universal algorithm for sequential data
// compression,” *IEEE Trans. Information Theory*, vol. IT-23, no. 3, pp.
// 337–343, May 1977.  In prose: a phrase is encoded as “go back *distance*
// symbols in the already-emitted stream and repeat the next *length*
// symbols” (overlapping repeats allowed).  RFC 1951 §3.2.3 fixes the bit-level
// packaging on top of that idea.

enum InflateConstants {
  static let maxBits = 15
  static let maxLCodes = 286
  static let maxDCodes = 30
  static let maxCodes = maxLCodes + maxDCodes
  static let fixLCodes = 288

  static let lengthBase: [Int] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
  ]
  static let lengthExtra: [Int] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
  ]
  static let distBase: [Int] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577,
  ]
  static let distExtra: [Int] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
    12, 12, 13, 13,
  ]

  static let order: [Int] = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
  ]
}

struct HuffmanDecoder {
  var count: [Int]
  var symbol: [Int]

  /// `puff` `construct`: `residual` is zero for a complete code, positive for incomplete, negative means over-subscribed (throws).
  static func construct(lengths: [Int], n: Int) throws -> (HuffmanDecoder, Int) {
    var count = [Int](repeating: 0, count: InflateConstants.maxBits + 1)
    for symbol in 0..<n {
      let len = lengths[symbol]
      guard len >= 0, len <= InflateConstants.maxBits else {
        throw InflateError.invalidDynamicBlock("code length out of range")
      }
      count[len] += 1
    }
    if count[0] == n {
      return (HuffmanDecoder(count: count, symbol: []), 0)
    }
    var left = 1
    for len in 1...InflateConstants.maxBits {
      left <<= 1
      left -= count[len]
      if left < 0 {
        throw InflateError.invalidDynamicBlock("over-subscribed Huffman tree")
      }
    }
    var offs = [Int](repeating: 0, count: InflateConstants.maxBits + 1)
    offs[1] = 0
    for len in 1..<InflateConstants.maxBits {
      offs[len + 1] = offs[len] + count[len]
    }
    var symbol = [Int](repeating: 0, count: n)
    for sym in 0..<n {
      let len = lengths[sym]
      if len != 0 {
        symbol[offs[len]] = sym
        offs[len] += 1
      }
    }
    return (HuffmanDecoder(count: count, symbol: symbol), left)
  }
}

struct DeflateInputState {
  let input: [UInt8]
  var incnt: Int = 0
  var bitbuf: UInt32 = 0
  var bitcnt: Int = 0

  mutating func bits(_ need: Int) throws -> Int {
    var val = bitbuf
    while bitcnt < need {
      guard incnt < input.count else {
        throw InflateError.insufficientInput
      }
      val |= UInt32(input[incnt]) << UInt32(bitcnt)
      incnt += 1
      bitcnt += 8
    }
    bitbuf = val >> UInt32(need)
    bitcnt -= need
    return Int(val & ((1 << need) - 1))
  }

  mutating func decodeSlow(h: HuffmanDecoder) throws -> Int {
    var code = 0
    var first = 0
    var index = 0
    for len in 1...InflateConstants.maxBits {
      code |= try bits(1)
      let count = h.count[len]
      if code - count < first {
        return h.symbol[index + (code - first)]
      }
      index += count
      first += count
      first <<= 1
      code <<= 1
    }
    throw InflateError.invalidCode
  }

  mutating func stored(into output: inout ContiguousArray<UInt8>, maxOutput: Int) throws {
    bitbuf = 0
    bitcnt = 0
    guard incnt + 4 <= input.count else { throw InflateError.insufficientInput }
    var len = Int(input[incnt])
    incnt += 1
    len |= Int(input[incnt]) << 8
    incnt += 1
    let nlenLow = Int(input[incnt])
    incnt += 1
    let nlenHigh = Int(input[incnt])
    incnt += 1
    guard UInt8(truncatingIfNeeded: nlenLow) == ~UInt8(truncatingIfNeeded: len & 0xff),
      UInt8(truncatingIfNeeded: nlenHigh) == ~UInt8(truncatingIfNeeded: (len >> 8) & 0xff)
    else {
      throw InflateError.storedLengthMismatch
    }
    guard incnt + len <= input.count else { throw InflateError.insufficientInput }
    guard output.count + len <= maxOutput else { throw InflateError.outputSpaceExhausted }
    output.reserveCapacity(output.count + len)
    for _ in 0..<len {
      output.append(input[incnt])
      incnt += 1
    }
  }

  mutating func codes(
    lencode: HuffmanDecoder,
    distcode: HuffmanDecoder,
    into output: inout ContiguousArray<UInt8>,
    maxOutput: Int
  ) throws {
    while true {
      let sym = try decodeSlow(h: lencode)
      if sym < 256 {
        guard output.count < maxOutput else { throw InflateError.outputSpaceExhausted }
        output.append(UInt8(truncatingIfNeeded: sym))
      } else if sym == 256 {
        return
      } else {
        var symbol = sym - 257
        guard symbol < 29 else { throw InflateError.invalidCode }
        let extraLen = try bits(InflateConstants.lengthExtra[symbol])
        let len = InflateConstants.lengthBase[symbol] + extraLen
        symbol = try decodeSlow(h: distcode)
        guard symbol < 30 else { throw InflateError.invalidCode }
        let extraDist = try bits(InflateConstants.distExtra[symbol])
        let dist = InflateConstants.distBase[symbol] + extraDist
        guard dist <= output.count else { throw InflateError.distanceTooFarBack }
        guard output.count + len <= maxOutput else { throw InflateError.outputSpaceExhausted }
        let start = output.count - dist
        output.reserveCapacity(output.count + len)
        var i = 0
        while i < len {
          output.append(output[start + i])
          i += 1
        }
      }
    }
  }

  mutating func fixed(into output: inout ContiguousArray<UInt8>, maxOutput: Int) throws {
    try codes(
      lencode: FixedHuffmanTables.literalLength,
      distcode: FixedHuffmanTables.distance,
      into: &output,
      maxOutput: maxOutput)
  }

  mutating func dynamic(into output: inout ContiguousArray<UInt8>, maxOutput: Int) throws {
    let nlen = try bits(5) + 257
    let ndist = try bits(5) + 1
    let ncode = try bits(4) + 4
    guard nlen <= InflateConstants.maxLCodes, ndist <= InflateConstants.maxDCodes else {
      throw InflateError.invalidDynamicBlock("nlen/ndist out of range")
    }
    var lengths = [Int](repeating: 0, count: InflateConstants.maxCodes)
    for index in 0..<ncode {
      lengths[InflateConstants.order[index]] = try bits(3)
    }
    for index in ncode..<19 {
      lengths[InflateConstants.order[index]] = 0
    }
    let (lenCode, lenCodeResidual) = try HuffmanDecoder.construct(
      lengths: Array(lengths[0..<19]), n: 19)
    guard lenCodeResidual == 0 else {
      throw InflateError.invalidDynamicBlock("incomplete code length Huffman table")
    }
    var index = 0
    let totalLens = nlen + ndist
    while index < totalLens {
      let sym = try decodeSlow(h: lenCode)
      if sym < 16 {
        lengths[index] = sym
        index += 1
      } else {
        var repLen = 0
        var repVal = 0
        if sym == 16 {
          guard index > 0 else { throw InflateError.invalidDynamicBlock("repeat with no prior length") }
          repVal = lengths[index - 1]
          repLen = try bits(2) + 3
        } else if sym == 17 {
          repLen = try bits(3) + 3
        } else {
          repLen = try bits(7) + 11
        }
        guard index + repLen <= totalLens else {
          throw InflateError.invalidDynamicBlock("repeat overrun")
        }
        for _ in 0..<repLen {
          lengths[index] = repVal
          index += 1
        }
      }
    }
    guard lengths[256] > 0 else {
      throw InflateError.invalidDynamicBlock("missing end-of-block length for literal 256")
    }
    let litLen = Array(lengths[0..<nlen])
    let (lencode, litResidual) = try HuffmanDecoder.construct(lengths: litLen, n: nlen)
    if litResidual != 0, nlen != lencode.count[0] + lencode.count[1] {
      throw InflateError.invalidDynamicBlock("invalid literal/length Huffman code set")
    }
    let distLens = Array(lengths[nlen..<(nlen + ndist)])
    let (distcode, distResidual) = try HuffmanDecoder.construct(lengths: distLens, n: ndist)
    if distResidual != 0, ndist != distcode.count[0] + distcode.count[1] {
      throw InflateError.invalidDynamicBlock("invalid distance Huffman code set")
    }
    try codes(lencode: lencode, distcode: distcode, into: &output, maxOutput: maxOutput)
  }

  mutating func inflate(maxOutputSize: Int) throws -> ContiguousArray<UInt8> {
    var output = ContiguousArray<UInt8>()
    output.reserveCapacity(min(input.count * 3, maxOutputSize))
    while true {
      let last = try bits(1)
      let type = try bits(2)
      switch type {
      case 0:
        try stored(into: &output, maxOutput: maxOutputSize)
      case 1:
        try fixed(into: &output, maxOutput: maxOutputSize)
      case 2:
        try dynamic(into: &output, maxOutput: maxOutputSize)
      default:
        throw InflateError.invalidBlockType
      }
      if last != 0 {
        break
      }
    }
    while bitcnt > 0 {
      _ = try bits(1)
    }
    return output
  }

  /// Same as ``inflate(maxOutputSize:)`` but allows extra trailing bytes after the
  /// DEFLATE stream (used by packfiles, where the next object follows immediately).
  mutating func inflateAllowTrailing(maxOutputSize: Int) throws -> (
    output: ContiguousArray<UInt8>, consumedDeflateBytes: Int
  ) {
    let out = try inflate(maxOutputSize: maxOutputSize)
    return (out, incnt)
  }
}

private enum FixedHuffmanTables {
  static let literalLength: HuffmanDecoder = {
    var lens = [Int](repeating: 0, count: InflateConstants.fixLCodes)
    for s in 0..<144 { lens[s] = 8 }
    for s in 144..<256 { lens[s] = 9 }
    for s in 256..<280 { lens[s] = 7 }
    for s in 280..<InflateConstants.fixLCodes { lens[s] = 8 }
    return try! HuffmanDecoder.construct(lengths: lens, n: InflateConstants.fixLCodes).0
  }()

  static let distance: HuffmanDecoder = {
    var lens = [Int](repeating: 5, count: InflateConstants.maxDCodes)
    return try! HuffmanDecoder.construct(lengths: lens, n: InflateConstants.maxDCodes).0
  }()
}

package enum DeflateInflate {
  package static func inflate(_ deflateBytes: [UInt8], maxOutputSize: Int = 64 << 20) throws
    -> ContiguousArray<UInt8>
  {
    var state = DeflateInputState(input: deflateBytes)
    let (out, consumed) = try state.inflateAllowTrailing(maxOutputSize: maxOutputSize)
    guard consumed == deflateBytes.count else {
      throw InflateError.invalidDynamicBlock("trailing deflate bytes after final block")
    }
    return out
  }

  /// Inflate a DEFLATE stream that may be followed by unrelated bytes.
  package static func inflateAllowTrailing(
    _ deflateBytes: [UInt8],
    maxOutputSize: Int = 64 << 20
  ) throws -> (ContiguousArray<UInt8>, consumedDeflateBytes: Int) {
    var state = DeflateInputState(input: deflateBytes)
    return try state.inflateAllowTrailing(maxOutputSize: maxOutputSize)
  }
}
