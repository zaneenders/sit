import BinaryParsing
import Foundation

struct LZ77: ExpressibleByParsing {
  let header: Header

  @_lifetime(&input)
  init(parsing input: inout ParserSpan) throws {
    self.header = try Header(parsing: &input)
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

enum LZ77Error: Error {
  case message(String)
}
