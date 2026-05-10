import Foundation
import Testing

@testable import sit_cli

@Suite(.timeLimit(.minutes(1)))
struct GitPktLineTests: ~Copyable {

  // MARK: - Encoding

  @Test func encodeSimpleData() {
    let result = GitPktLine.encode("hello\n")
    // "hello\n" is 6 bytes + 4 hex = 10 = 0x000a
    #expect(result == Array("000ahello\n".utf8))
  }

  @Test func encodeEmptyDataReturnsFlush() {
    let result = GitPktLine.encode([])
    #expect(result == [0x30, 0x30, 0x30, 0x30])  // "0000"
  }

  @Test func encodeString() {
    let result = GitPktLine.encode("abc")
    // "abc" is 3 bytes + 4 hex = 7 = 0x0007
    #expect(result == Array("0007abc".utf8))
  }

  // MARK: - Decoding

  @Test func decodeSinglePacket() {
    let data = Array("0007abc".utf8)
    let (packet, consumed) = GitPktLine.decodeOne(from: data)!
    #expect(packet == .data(Array("abc".utf8)))
    #expect(consumed == 7)
  }

  @Test func decodeFlushPacket() {
    let data: [UInt8] = [0x30, 0x30, 0x30, 0x30]  // "0000"
    let (packet, consumed) = GitPktLine.decodeOne(from: data)!
    #expect(packet == .flush)
    #expect(consumed == 4)
  }

  @Test func decodeDelimPacket() {
    let data: [UInt8] = [0x30, 0x30, 0x30, 0x31]  // "0001"
    let (packet, consumed) = GitPktLine.decodeOne(from: data)!
    #expect(packet == .delim)
    #expect(consumed == 4)
  }

  @Test func decodeEndOfResponsePacket() {
    let data: [UInt8] = [0x30, 0x30, 0x30, 0x32]  // "0002"
    let (packet, consumed) = GitPktLine.decodeOne(from: data)!
    #expect(packet == .endOfResponse)
    #expect(consumed == 4)
  }

  @Test func decodeIncompletePacketReturnsNil() {
    let data = Array("000".utf8)  // only 3 bytes
    let result = GitPktLine.decodeOne(from: data)
    #expect(result == nil)
  }

  @Test func decodeTruncatedPayloadReturnsNil() {
    // Claims length 10 but only has 7 bytes
    let data = Array("000ahel".utf8)
    let result = GitPktLine.decodeOne(from: data)
    #expect(result == nil)
  }

  // MARK: - Decoding streams

  @Test func decodeMultiplePackets() {
    let packets = Array("0007abc000fhello world".utf8)
    let result = GitPktLine.decode(packets)
    #expect(result.count == 2)
    #expect(result[0] == .data(Array("abc".utf8)))
    #expect(result[1] == .data(Array("hello world".utf8)))
  }

  @Test func decodeStopsAtFlush() {
    let packets = Array(
      "0007abc00000009more".utf8)
    let result = GitPktLine.decode(packets)
    #expect(result.count == 1)
    #expect(result[0] == .data(Array("abc".utf8)))
    // "more" after flush is ignored
  }

  @Test func decodeMixedPackets() {
    // data packet, delim, data packet
    var stream: [UInt8] = []
    stream.append(contentsOf: GitPktLine.encode("first"))
    stream.append(contentsOf: [0x30, 0x30, 0x30, 0x31])  // delim
    stream.append(contentsOf: GitPktLine.encode("second"))
    stream.append(contentsOf: GitPktLine.flush)

    let result = GitPktLine.decode(stream)
    #expect(result.count == 3)
    #expect(result[0] == .data(Array("first".utf8)))
    #expect(result[1] == .delim)
    #expect(result[2] == .data(Array("second".utf8)))
  }

  // MARK: - Round-trip

  @Test func roundTrip() {
    let original = Array("hello pkt-line world\n".utf8)
    let encoded = GitPktLine.encode(original)
    let (packet, _) = GitPktLine.decodeOne(from: encoded)!
    guard case .data(let decoded) = packet else {
      Issue.record("Expected data packet")
      return
    }
    #expect(decoded == original)
  }
}
