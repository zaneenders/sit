/// Git pkt-line framing (used in smart HTTP and SSH transport).
///
/// Each packet is a 4-hex-digit length prefix followed by a payload.  The
/// length includes the 4 hex bytes themselves.
///
/// | Hex    | Meaning                                      |
/// |--------|----------------------------------------------|
/// | `0000` | Flush packet — end of message                |
/// | `0001` | Delim packet — separator (protocol v2)      |
/// | `0002` | End-of-response (protocol v2)                |
/// | other  | Data packet, payload = length - 4 bytes      |
///
/// Reference: Git `Documentation/technical/protocol-common.txt`
enum GitPktLine {

  // MARK: - Constants

  /// "0000" — signals end of a pkt-line stream.
  static let flush: [UInt8] = [0x30, 0x30, 0x30, 0x30]

  /// Maximum payload size (65516 bytes = 65535 - 4 hex digits - LF convention).
  /// Git implementations cap at 65520 (0xfff0).
  static let maxPayloadLength = 65520

  // MARK: - Encoding

  /// Encode `data` as a pkt-line data packet.
  ///
  /// Returns the length-prefixed bytes.  If `data` is empty a flush packet
  /// is returned instead (callers should use `flush` explicitly when they
  /// want a flush).
  static func encode(_ data: [UInt8]) -> [UInt8] {
    guard !data.isEmpty else { return flush }
    let totalLen = 4 + data.count
    precondition(totalLen <= 65535, "pkt-line payload too large: \(data.count)")
    let hex = String(format: "%04x", totalLen)
    return Array(hex.utf8) + data
  }

  /// Encode a string as a pkt-line data packet.
  static func encode(_ string: String) -> [UInt8] {
    encode(Array(string.utf8))
  }

  // MARK: - Decoding

  /// A decoded pkt-line packet.
  enum Packet: Equatable {
    /// Regular data packet with payload bytes.
    case data([UInt8])
    /// Flush packet (`0000`).
    case flush
    /// Delim packet (`0001`, protocol v2).
    case delim
    /// End-of-response (`0002`, protocol v2).
    case endOfResponse
  }

  /// Parse a single pkt-line from the start of `bytes`.
  ///
  /// Returns the packet and the number of bytes consumed (4 hex + payload),
  /// or `nil` if there aren't enough bytes for a complete packet.
  static func decodeOne(from bytes: [UInt8], at offset: Int = 0) -> (Packet, consumed: Int)? {
    guard offset + 4 <= bytes.count else { return nil }
    let lenStr = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    guard let totalLen = Int(lenStr, radix: 16), totalLen >= 0 else { return nil }

    switch totalLen {
    case 0:
      return (.flush, consumed: 4)
    case 1:
      return (.delim, consumed: 4)
    case 2:
      return (.endOfResponse, consumed: 4)
    default:
      guard offset + totalLen <= bytes.count else { return nil }
      let payload = Array(bytes[(offset + 4)..<(offset + totalLen)])
      return (.data(payload), consumed: totalLen)
    }
  }

  /// Decode all pkt-line packets from `bytes`.
  ///
  /// Parsing stops at the first flush packet (which is consumed but not
  /// included in the output).
  static func decode(_ bytes: [UInt8]) -> [Packet] {
    var packets: [Packet] = []
    var pos = 0
    while pos < bytes.count {
      guard let (packet, consumed) = decodeOne(from: bytes, at: pos) else {
        break
      }
      pos += consumed
      switch packet {
      case .flush:
        return packets
      case .delim, .endOfResponse:
        packets.append(packet)
      case .data:
        packets.append(packet)
      }
    }
    return packets
  }
}
