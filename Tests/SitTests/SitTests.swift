import Foundation
import Testing

@testable import Sit

@Suite
struct SitTests: ~Copyable {
  /*
  hexdump -C ".git/objects/ff/517aa72881e9384c90332979fb3fe7743b2fcf" | head -20
  */
  @Test func compress() throws {
    let a = ".git/objects/fe/877e3e1737e1ba0f7c1761f6c2229ca1a97d2e"
    let b = ".git/objects/fe/4cce2f832572c386a4fae794c52d7645a8e4aa"
    let c = ".git/objects/ff/517aa72881e9384c90332979fb3fe7743b2fcf"
    let d = ".git/objects/10/142352e88b8457141f6716aa1b43fc4dddfdf4"
    try inflate(a)
    try inflate(b)
    try inflate(c)
    try inflate(d)
  }

  @Test func blockBegin() throws {
    var (isBFINAL, bType) = try Sit.blockBegin(value: 0)
    #expect(!isBFINAL)
    #expect(bType == .notCompressed)
    (isBFINAL, bType) = try Sit.blockBegin(value: 1)
    #expect(isBFINAL)
    #expect(bType == .notCompressed)
    (isBFINAL, bType) = try Sit.blockBegin(value: 2)
    #expect(!isBFINAL)
    #expect(bType == .fixedCompression)
    (isBFINAL, bType) = try Sit.blockBegin(value: 3)
    #expect(isBFINAL)
    #expect(bType == .fixedCompression)
    (isBFINAL, bType) = try Sit.blockBegin(value: 4)
    #expect(!isBFINAL)
    #expect(bType == .dynamicCompression)
    (isBFINAL, bType) = try Sit.blockBegin(value: 5)
    #expect(isBFINAL)
    #expect(bType == .dynamicCompression)
    #expect(throws: LZ77Error.blockError("reserved, error")) {
      _ = try Sit.blockBegin(value: 6)
    }
    #expect(throws: LZ77Error.blockError("reserved, error")) {
      _ = try Sit.blockBegin(value: 7)
    }
    // Should this error?
    /*
    #expect(throws: LZ77Error.blockError("ERROR")) {
      _ = try Sit.blockBegin(value: 8)
    }
    */
  }
}

func inflate(_ path: String) throws {
  let data = try Data(contentsOf: URL(filePath: path))
  let lz77 = try LZ77(parsing: data)
  #expect(120 == lz77.header.compressionMethod)
  #expect(1 == lz77.header.flags)
}
