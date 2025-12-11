import BinaryParsing
import Foundation

struct LZ77: ExpressibleByParsing {
  let header: Header

  @_lifetime(&input)
  init(parsing input: inout ParserSpan) throws {
    self.header = try Header(parsing: &input)
    let value = try UInt8(parsingLittleEndian: &input, byteCount: 1)
    let (isBFINAL, bType) = try blockBegin(value: value)
  }

  struct Header {
    let compressionMethod: UInt8
    let flags: UInt8
    @_lifetime(&input)
    init(parsing input: inout ParserSpan) throws {
      let cmf = try UInt8(parsing: &input)
      let flg = try UInt8(parsing: &input)

      // --- 1. Validate CMF (Compression Method & Info) ---
      // Git almost always uses 0x78:
      //   Bits 0-3 (Method): 8 (Deflate)
      //   Bits 4-7 (Info):   7 (32KB Window Size) -> (7 << 4) | 8 = 0x78
      guard cmf == 0x78 else {
        throw LZ77Error.message("Invalid CMF: Expected 0x78 (Deflate + 32KB Window), got \(String(format:"%02X", cmf))")
      }

      // --- 2. Validate FLG (FCHECK) ---
      // The 16-bit value (CMF * 256 + FLG) must be a multiple of 31.
      let checkValue = (UInt16(cmf) * 256) + UInt16(flg)
      guard checkValue % 31 == 0 else {
        throw LZ77Error.message("Invalid Header Checksum (FCHECK)")
      }

      self.compressionMethod = cmf
      self.flags = flg
    }
  }
}

func blockBegin(value: UInt8) throws -> (Bool, BType) {
  let isBFINAL = (value & 1) == 1  // read LSB bit
  let BTYPE = (value & 6) >> 1  // read next 2 LSB bit

  let bType: BType
  switch BTYPE {
  case 0:
    // 00 - no compression
    bType = .notCompressed
  case 1:
    // 01 - compressed with fixed Huffman codes
    bType = .fixedCompression
  case 2:
    // 10 - compressed with dynamic Huffman codes
    bType = .dynamicCompression
  case 3:
    // 11 - reserved (error)
    throw LZ77Error.blockError("reserved, error")
  default:
    // ERROR
    throw LZ77Error.blockError("ERROR")
  }
  print(#function, isBFINAL, bType, String(value, radix: 2), String(value, radix: 16))
  return (isBFINAL, bType)
}

enum BType {
  case notCompressed
  case fixedCompression
  case dynamicCompression
}

enum LZ77Error: Error, Equatable {
  case message(String)
  case blockError(String)
}
