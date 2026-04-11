// Git binary delta apply (`patch_delta` in git’s patch-delta.c).

enum PackDelta {
  static func readDeltaHeaderSize(_ delta: [UInt8], pos: inout Int) throws -> Int {
    var size = 0
    var shift = 0
    while true {
      guard pos < delta.count else { throw GitPackError.truncatedDelta }
      let b = delta[pos]
      pos += 1
      size |= Int(b & 0x7f) << shift
      if b & 0x80 == 0 {
        break
      }
      shift += 7
    }
    return size
  }

  /// Apply `delta` to `base` (both uncompressed). Returns the reconstructed object bytes.
  static func apply(base: [UInt8], delta: [UInt8]) throws -> ContiguousArray<UInt8> {
    guard delta.count >= 4 else { throw GitPackError.truncatedDelta }
    var p = 0
    let baseExpected = try readDeltaHeaderSize(delta, pos: &p)
    guard baseExpected == base.count else {
      throw GitPackError.deltaBaseSizeMismatch
    }
    let resultSize = try readDeltaHeaderSize(delta, pos: &p)
    guard resultSize >= 0, resultSize <= 128 << 20 else {
      throw GitPackError.truncatedDelta
    }
    var out = ContiguousArray<UInt8>()
    out.reserveCapacity(resultSize)
    let top = delta.count
    var remaining = resultSize
    while p < top {
      let cmd = delta[p]
      p += 1
      if cmd & 0x80 != 0 {
        var cpOff = 0
        var cpSize = 0
        if cmd & 0x01 != 0 {
          guard p < top else { throw GitPackError.truncatedDelta }
          cpOff |= Int(delta[p])
          p += 1
        }
        if cmd & 0x02 != 0 {
          guard p < top else { throw GitPackError.truncatedDelta }
          cpOff |= Int(delta[p]) << 8
          p += 1
        }
        if cmd & 0x04 != 0 {
          guard p < top else { throw GitPackError.truncatedDelta }
          cpOff |= Int(delta[p]) << 16
          p += 1
        }
        if cmd & 0x08 != 0 {
          guard p < top else { throw GitPackError.truncatedDelta }
          cpOff |= Int(delta[p]) << 24
          p += 1
        }
        if cmd & 0x10 != 0 {
          guard p < top else { throw GitPackError.truncatedDelta }
          cpSize |= Int(delta[p])
          p += 1
        }
        if cmd & 0x20 != 0 {
          guard p < top else { throw GitPackError.truncatedDelta }
          cpSize |= Int(delta[p]) << 8
          p += 1
        }
        if cmd & 0x40 != 0 {
          guard p < top else { throw GitPackError.truncatedDelta }
          cpSize |= Int(delta[p]) << 16
          p += 1
        }
        if cpSize == 0 {
          cpSize = 0x1_0000
        }
        guard cpOff >= 0, cpSize >= 0, cpOff + cpSize <= base.count, cpSize <= remaining else {
          throw GitPackError.invalidDeltaCommand
        }
        out.append(contentsOf: base[cpOff..<(cpOff + cpSize)])
        remaining -= cpSize
      } else if cmd != 0 {
        let n = Int(cmd)
        guard n <= remaining, p + n <= top else { throw GitPackError.invalidDeltaCommand }
        out.append(contentsOf: delta[p..<(p + n)])
        p += n
        remaining -= n
      } else {
        throw GitPackError.invalidDeltaCommand
      }
    }
    guard p == top, remaining == 0 else {
      throw GitPackError.deltaReplayMismatch
    }
    return out
  }
}
