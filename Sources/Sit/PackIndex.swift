/// Git pack index version 2 (`.idx` alongside `.pack`).
public struct PackIndexV2: Sendable {
  public struct Entry: Sendable {
    public let sha20: [UInt8]
    public let crc32: UInt32
    public let offset32: UInt32
  }

  public let entries: [Entry]

  public func offset(for sha20: [UInt8]) -> UInt32? {
    guard sha20.count == 20 else { return nil }
    var lo = 0
    var hi = entries.count
    while lo < hi {
      let mid = (lo + hi) / 2
      let c = compare(entries[mid].sha20, sha20)
      if c == 0 {
        let off = entries[mid].offset32
        if off & 0x8000_0000 != 0 { return nil }
        return off
      }
      if c < 0 { lo = mid + 1 }
      else { hi = mid }
    }
    return nil
  }

  public static func parse(bytes: [UInt8]) throws -> PackIndexV2 {
    let b = bytes
    guard b.count >= 8 + 1024 else { throw GitPackError.truncatedIndex }
    guard b[0] == 0xff, b[1] == 0x74, b[2] == 0x4f, b[3] == 0x63 else {
      throw GitPackError.badIndexMagic
    }
    let ver = readBE32(b, 4)
    guard ver == 2 else { throw GitPackError.unsupportedIndexVersion(ver) }
    var fanout = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
      fanout[i] = readBE32(b, 8 + i * 4)
    }
    let n = Int(fanout[255])
    let namesBase = 8 + 1024
    let crcBase = namesBase + 20 * n
    let offBase = crcBase + 4 * n
    guard b.count >= offBase + 4 * n else { throw GitPackError.truncatedIndex }
    var entries: [Entry] = []
    entries.reserveCapacity(n)
    for i in 0..<n {
      let s = namesBase + 20 * i
      let sha20 = Array(b[s..<(s + 20)])
      let crc = readBE32(b, crcBase + 4 * i)
      let off = readBE32(b, offBase + 4 * i)
      entries.append(Entry(sha20: sha20, crc32: crc, offset32: off))
    }
    return PackIndexV2(entries: entries)
  }
}

private func readBE32(_ b: [UInt8], _ i: Int) -> UInt32 {
  (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
}

private func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
  let n = min(a.count, b.count)
  for i in 0..<n {
    if a[i] < b[i] { return -1 }
    if a[i] > b[i] { return 1 }
  }
  return a.count - b.count
}
