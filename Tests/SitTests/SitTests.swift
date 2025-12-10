import Foundation
import Testing

@testable import Sit

@Suite
struct SitTests: ~Copyable {
  @Test func compress() throws {
    let path =
      "/Users/zane/.scribe/Code/sit/.git/objects/ff/517aa72881e9384c90332979fb3fe7743b2fcf"
    let data = try Data(contentsOf: URL(filePath: path))
    let lz77 = try LZ77(parsing: data)
    #expect(120 == lz77.header.compressionMethod)
    #expect(1 == lz77.header.flags)
  }
}
