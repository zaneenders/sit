/// Parsed `blob <size>\\0<payload>` object bytes (already zlib-decompressed).
public struct ParsedGitBlob: Sendable {
  public let declaredSize: Int
  public let payload: ContiguousArray<UInt8>

  public init(decodedLooseObjectBytes bytes: some RandomAccessCollection<UInt8>) throws(GitBlobError) {
    let blob = Array("blob ".utf8)
    let b = Array(bytes)
    guard b.count >= blob.count + 2 else {
      throw GitBlobError.malformed("truncated object header")
    }
    guard Array(b[0..<blob.count]) == blob else {
      throw GitBlobError.notABlob
    }
    var i = blob.count
    var size = 0
    var sawDigit = false
    while i < b.count, let d = (b[i]).asciiDigitValue {
      sawDigit = true
      size = size * 10 + d
      if size > (1 << 30) {
        throw GitBlobError.malformed("implausible blob size")
      }
      i += 1
    }
    guard sawDigit else { throw GitBlobError.malformed("missing size") }
    guard i < b.count, b[i] == 0 else { throw GitBlobError.malformed("missing header nul") }
    i += 1
    let rest = b.count - i
    guard rest == size else {
      throw GitBlobError.sizeMismatch(declared: size, actualPayload: rest)
    }
    self.declaredSize = size
    self.payload = ContiguousArray(b[i...])
  }
}

public enum GitBlobError: Error, Equatable, Sendable {
  case notABlob
  case malformed(String)
  case sizeMismatch(declared: Int, actualPayload: Int)
}

extension UInt8 {
  fileprivate var asciiDigitValue: Int? {
    guard self >= UInt8(ascii: "0"), self <= UInt8(ascii: "9") else { return nil }
    return Int(self - UInt8(ascii: "0"))
  }
}
