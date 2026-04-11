// Loose git objects use zlib (RFC 1950) wrapping raw deflate bitstream.
// Header checks follow RFC 1950 §2.2–2.3 (CMF/FLG, FCHECK, CM/CINFO, FDICT).

/// First bytes of a zlib stream used by git loose objects: CMF, FLG, and the
/// first byte of the first deflate block (BTYPE/BFINAL bitfield).
public struct LZ77: Sendable {
  public let header: Header
  public let firstBlockIsBFinal: Bool
  public let firstBlockType: BType

  public init(parsingCompressedBytes bytes: some RandomAccessCollection<UInt8>) throws(LZ77Error) {
    self.header = try Header(parsingCompressedBytes: bytes)
    guard bytes.count >= 3 else {
      throw LZ77Error.message("truncated stream: expected deflate block prefix after zlib header")
    }
    let thirdIndex = bytes.index(bytes.startIndex, offsetBy: 2)
    let (isBFinal, bType) = try blockBegin(value: bytes[thirdIndex])
    self.firstBlockIsBFinal = isBFinal
    self.firstBlockType = bType
  }

  public struct Header: Sendable {
    public let compressionMethod: UInt8
    public let flags: UInt8

    public init(parsingCompressedBytes bytes: some RandomAccessCollection<UInt8>) throws(LZ77Error) {
      guard bytes.count >= 2 else {
        throw LZ77Error.message("truncated zlib header")
      }
      let i0 = bytes.startIndex
      let i1 = bytes.index(i0, offsetBy: 1)
      let cmf = bytes[i0]
      let flg = bytes[i1]

      // CM (low nibble): only DEFLATE (8) is defined in RFC 1950 for this wrapper.
      let cm = cmf & 0x0f
      guard cm == 8 else {
        throw LZ77Error.message(
          "Invalid zlib CM: RFC 1950 requires CM=8 (deflate), got \(Self.hexByte(cmf)) (CM=\(cm))"
        )
      }
      // CINFO (high nibble): base-2 log of LZ77 window size minus eight; must be ≤7.
      let cinfo = (cmf >> 4) & 0x0f
      guard cinfo <= 7 else {
        throw LZ77Error.message("Invalid zlib CINFO (window size): \(cinfo) > 7")
      }

      let checkValue = UInt16(cmf) * 256 + UInt16(flg)
      guard checkValue % 31 == 0 else {
        throw LZ77Error.message("Invalid zlib header checksum (FCHECK)")
      }

      // RFC 1950 §2.3: without a known preset dictionary, FDICT must be rejected.
      guard (flg & 0x20) == 0 else {
        throw LZ77Error.message("zlib preset dictionary (FDICT) is not supported")
      }

      self.compressionMethod = cmf
      self.flags = flg
    }

    private static func hexByte(_ b: UInt8) -> String {
      let table = Array("0123456789abcdef".utf8)
      let hi = Int(b >> 4)
      let lo = Int(b & 0x0f)
      return String(decoding: [table[hi], table[lo]], as: UTF8.self)
    }
  }
}

public func blockBegin(value: UInt8) throws(LZ77Error) -> (Bool, BType) {
  let isBFinal = (value & 1) == 1
  let btypeBits = (value & 0b0110) >> 1
  let bType: BType
  switch btypeBits {
  case 0: bType = .notCompressed
  case 1: bType = .fixedCompression
  case 2: bType = .dynamicCompression
  case 3: throw LZ77Error.blockError("reserved BTYPE")
  default: throw LZ77Error.blockError("invalid BTYPE")
  }
  return (isBFinal, bType)
}

public enum BType: Sendable, Equatable {
  case notCompressed
  case fixedCompression
  case dynamicCompression
}

public enum LZ77Error: Error, Equatable, Sendable {
  case message(String)
  case blockError(String)
}
