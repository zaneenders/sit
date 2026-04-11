import Crypto
import Foundation

/// Git object id (SHA-1 over the canonical loose-object header + body, before zlib).
enum GitSHA1 {
  static func digest(of bytes: [UInt8]) -> [UInt8] {
    Array(Insecure.SHA1.hash(data: Data(bytes)))
  }
}
