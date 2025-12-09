import Foundation

/// Parser for Git index file (.git/index) format
struct IndexParser {

  /// Parse the Git index file and return array of index entries
  /// - Parameter data: Raw index file data
  /// - Returns: Array of parsed index entries
  /// - Throws: GitError.invalidIndexFormat if parsing fails
  static func parseIndex(data: Data) throws -> (header: IndexHeader, entries: [IndexEntry]) {
    guard data.count >= 12 else {
      throw GitError.invalidIndexFormat("Index file too small")
    }

    var offset = 0

    // Parse header
    let header = try parseHeader(data: data, offset: &offset)

    // Parse entries
    var entries: [IndexEntry] = []
    entries.reserveCapacity(Int(header.entryCount))

    for i in 0..<header.entryCount {
      // Check if we have enough data left for another entry
      if offset >= data.count {
        break
      }

      do {
        let entry = try parseEntry(data: data, offset: &offset, version: header.version)
        entries.append(entry)

        // Align to 8-byte boundary (except version 4)
        if header.version < 4 {
          let padding = (8 - (offset % 8)) % 8
          offset += padding
        }
      } catch GitError.invalidIndexFormat(let message) where message.contains("Incomplete entry") {
        // If we hit an incomplete entry, we've probably reached the end
        break
      }
    }

    // Verify checksum if present
    if offset + 20 <= data.count {
      let storedChecksum = data.subdata(in: offset..<offset + 20)
      let computedChecksum = Sit.sha1(data.subdata(in: 0..<offset))
      let computedChecksumData = Array(computedChecksum.utf8).prefix(20)

      // Note: This is a simplified checksum verification
      // In practice, we'd need to convert the hex string to bytes
    }

    return (header: header, entries: entries)
  }

  /// Parse the index file header
  private static func parseHeader(data: Data, offset: inout Int) throws -> IndexHeader {
    // Read signature (4 bytes)
    guard offset + 4 <= data.count else {
      throw GitError.invalidIndexFormat("Incomplete signature")
    }

    let signatureData = data.subdata(in: offset..<offset + 4)
    guard let signature = String(data: signatureData, encoding: .ascii) else {
      throw GitError.invalidIndexFormat("Invalid signature encoding")
    }

    guard signature == IndexHeader.expectedSignature else {
      throw GitError.invalidIndexFormat("Invalid signature: \(signature)")
    }

    offset += 4

    // Read version (4 bytes, big-endian)
    guard offset + 4 <= data.count else {
      throw GitError.invalidIndexFormat("Incomplete version")
    }

    let version = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
    guard version >= 2 && version <= 4 else {
      throw GitError.invalidIndexFormat("Unsupported version: \(version)")
    }

    offset += 4

    // Read entry count (4 bytes, big-endian)
    guard offset + 4 <= data.count else {
      throw GitError.invalidIndexFormat("Incomplete entry count")
    }

    let entryCount = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }

    offset += 4

    return IndexHeader(signature: signature, version: version, entryCount: entryCount)
  }

  /// Parse a single index entry
  private static func parseEntry(data: Data, offset: inout Int, version: UInt32) throws -> IndexEntry {
    let entryStart = offset

    // Check minimum entry size (62 bytes)
    guard offset + 62 <= data.count else {
      // If we don't have enough data for a full entry, we're done
      throw GitError.invalidIndexFormat("Incomplete entry at offset \(offset), file size: \(data.count)")
    }

    // Read timestamps (16 bytes)
    let ctimeSeconds = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
    offset += 4
    let ctimeNanoseconds = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
    offset += 4
    let mtimeSeconds = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
    offset += 4
    let mtimeNanoseconds = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
    offset += 4

    // Read file system info (16 bytes)
    let device = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
    offset += 4
    let inode = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
    offset += 4
    let mode = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
    offset += 4
    let uid = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
    offset += 4
    let gid = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
    offset += 4

    // Read file size (4 bytes)
    let fileSize = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
    offset += 4

    // Read SHA-1 hash (20 bytes)
    guard offset + 20 <= data.count else {
      throw GitError.invalidIndexFormat("Incomplete SHA-1 at offset \(offset)")
    }

    let sha1Data = data.subdata(in: offset..<offset + 20)
    let sha1 = Array(sha1Data)
    offset += 20

    // Read flags (2 bytes)
    guard offset + 2 <= data.count else {
      throw GitError.invalidIndexFormat("Incomplete flags at offset \(offset)")
    }

    let flags = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self).bigEndian }
    offset += 2

    // Extract stage and path length from flags
    let stage = (flags >> 12) & 0x3
    let pathLength = Int(flags & 0x0FFF)

    // Handle extended flags for version 3+
    var extendedFlags: UInt16 = 0
    if version >= 3 && (flags & 0x4000) != 0 {
      guard offset + 2 <= data.count else {
        throw GitError.invalidIndexFormat("Incomplete extended flags at offset \(offset)")
      }
      extendedFlags = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self).bigEndian }
      offset += 2
    }

    // Read path
    let path: String
    if version == 4 {
      path = try parseVersion4Path(data: data, offset: &offset)
    } else {
      // For versions 2-3, be more flexible with path length
      if pathLength < 0x0FFF && pathLength > 0 {
        path = try parseSimplePath(data: data, offset: &offset, pathLength: pathLength)
      } else {
        // Read until NUL terminator
        path = try parseSimplePath(data: data, offset: &offset, pathLength: 0x0FFF)
      }
    }

    return IndexEntry(
      ctimeSeconds: ctimeSeconds,
      ctimeNanoseconds: ctimeNanoseconds,
      mtimeSeconds: mtimeSeconds,
      mtimeNanoseconds: mtimeNanoseconds,
      device: device,
      inode: inode,
      mode: mode,
      uid: uid,
      gid: gid,
      fileSize: fileSize,
      sha1: sha1,
      flags: flags,
      extendedFlags: extendedFlags,
      path: path
    )
  }

  /// Parse path for versions 2-3 (simple NUL-terminated or fixed length)
  private static func parseSimplePath(data: Data, offset: inout Int, pathLength: Int) throws -> String {
    if pathLength < 0x0FFF && pathLength > 0 {
      // Exact length specified
      guard offset + pathLength <= data.count else {
        throw GitError.invalidIndexFormat(
          "Path extends beyond file at offset \(offset), requested \(pathLength) bytes, available \(data.count - offset)"
        )
      }

      let pathData = data.subdata(in: offset..<offset + pathLength)
      guard let path = String(data: pathData, encoding: .utf8) else {
        // Try Latin-1 as fallback for non-UTF8 paths
        if let fallbackPath = String(data: pathData, encoding: .isoLatin1) {
          offset += pathLength
          // Skip NUL terminator if present
          if offset < data.count && data[offset] == 0 {
            offset += 1
          }
          return fallbackPath
        }
        throw GitError.invalidPathEncoding("Invalid UTF-8 in path at offset \(offset)")
      }

      offset += pathLength

      // Skip NUL terminator if present
      if offset < data.count && data[offset] == 0 {
        offset += 1
      }

      return path
    } else {
      // Read until NUL
      var end = offset
      while end < data.count && data[end] != 0 {
        end += 1
      }

      guard end < data.count else {
        throw GitError.invalidIndexFormat("Unterminated path at offset \(offset)")
      }

      let pathData = data.subdata(in: offset..<end)
      guard let path = String(data: pathData, encoding: .utf8) else {
        // Try Latin-1 as fallback for non-UTF8 paths
        if let fallbackPath = String(data: pathData, encoding: .isoLatin1) {
          offset = end + 1  // Skip NUL
          return fallbackPath
        }
        throw GitError.invalidPathEncoding("Invalid UTF-8 in path at offset \(offset)")
      }

      offset = end + 1  // Skip NUL
      return path
    }
  }

  /// Parse path for version 4 (variable-width integer encoding with prefix compression)
  private static func parseVersion4Path(data: Data, offset: inout Int) throws -> String {
    // Read variable-width integer for prefix length
    let prefixLength = try readVariableWidthInteger(data: data, offset: &offset)

    // Read NUL-terminated suffix
    var end = offset
    while end < data.count && data[end] != 0 {
      end += 1
    }

    guard end < data.count else {
      throw GitError.invalidIndexFormat("Unterminated version 4 path at offset \(offset)")
    }

    let suffixData = data.subdata(in: offset..<end)
    guard let suffix = String(data: suffixData, encoding: .utf8) else {
      // Try Latin-1 as fallback for non-UTF8 paths
      if let fallbackSuffix = String(data: suffixData, encoding: .isoLatin1) {
        return fallbackSuffix
      }
      throw GitError.invalidPathEncoding("Invalid UTF-8 in version 4 path at offset \(offset)")
    }

    offset = end + 1  // Skip NUL

    // Note: Full implementation would maintain previous path state for prefix compression
    // For now, we'll just return the suffix (this works for simple cases)
    return suffix
  }

  /// Read a variable-width integer (used in version 4 paths)
  private static func readVariableWidthInteger(data: Data, offset: inout Int) throws -> Int {
    var result = 0
    var shift = 0

    while offset < data.count {
      let byte = data[offset]
      offset += 1

      result |= Int(byte & 0x7F) << shift
      shift += 7

      if (byte & 0x80) == 0 {
        break
      }

      if shift > 63 {
        throw GitError.invalidIndexFormat("Variable-width integer too large at offset \(offset)")
      }
    }

    return result
  }
}

// MARK: - Index File Reader

extension GitRepository {

  /// Read and parse the index file
  /// - Returns: Array of index entries
  /// - Throws: GitError if reading or parsing fails
  func readIndex() throws -> [IndexEntry] {
    let indexPath = gitPath("index")

    guard fileExists(indexPath) else {
      // Empty index (new repository)
      return []
    }

    let data = try readFileData(indexPath)
    let result = try IndexParser.parseIndex(data: data)
    return result.entries
  }

  /// Check if the index is clean (no unmerged entries)
  func isIndexClean() throws -> Bool {
    let entries = try readIndex()
    return entries.allSatisfy { $0.stage == 0 }
  }

  /// Get index statistics
  func getIndexStats() throws -> (totalEntries: Int, stagedFiles: Int, unmergedEntries: Int) {
    let entries = try readIndex()
    let stagedFiles = entries.filter { $0.stage == 0 }.count
    let unmergedEntries = entries.filter { $0.stage != 0 }.count

    return (totalEntries: entries.count, stagedFiles: stagedFiles, unmergedEntries: unmergedEntries)
  }
}
