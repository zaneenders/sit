import Compression
import Foundation

/// Reads Git objects from the .git/objects directory
class GitObjectReader {
  private let repository: GitRepository

  init(repository: GitRepository) {
    self.repository = repository
  }

  /// Read a Git object by SHA-1
  /// - Parameter sha1: 40-character SHA-1 hash
  /// - Returns: Parsed Git object
  /// - Throws: GitError if reading or parsing fails
  func readObject(sha1: String) throws -> GitObject {
    let validatedSHA1 = try validateSHA1(sha1)
    let objectData = try readObjectData(sha1: validatedSHA1)
    let (type, size, content) = try parseObjectHeader(objectData)

    switch type {
    case "blob":
      return try parseBlob(sha1: validatedSHA1, content: content, size: size)
    case "tree":
      return try parseTree(sha1: validatedSHA1, content: content)
    case "commit":
      return try parseCommit(sha1: validatedSHA1, content: content)
    case "tag":
      return try parseTag(sha1: validatedSHA1, content: content)
    default:
      throw GitError.invalidObjectFormat("Unknown object type: \(type)")
    }
  }

  /// Read raw object data (decompressed)
  /// - Parameter sha1: 40-character SHA-1 hash
  /// - Returns: Decompressed object data
  /// - Throws: GitError if reading or decompression fails
  private func readObjectData(sha1: String) throws -> Data {
    // Construct object path: .git/objects/ab/cdef...
    let prefix = String(sha1.prefix(2))
    let suffix = String(sha1.dropFirst(2))
    let objectPath = repository.gitPath("objects", prefix, suffix)

    guard repository.fileExists(objectPath) else {
      throw GitError.objectNotFound(sha1)
    }

    let compressedData = try repository.readFileData(objectPath)
    return try decompressZlibData(compressedData)
  }

  /// Parse Git object header: "<type> <size>\0<content>"
  /// - Parameter data: Decompressed object data
  /// - Returns: Tuple of (type, size, content)
  /// - Throws: GitError if header is invalid
  private func parseObjectHeader(_ data: Data) throws -> (type: String, size: Int, content: Data) {
    guard let nullByteIndex = data.firstIndex(of: 0) else {
      throw GitError.invalidObjectFormat("Missing null byte in object header")
    }

    let headerData = data[..<nullByteIndex]
    let contentData = data[data.index(after: nullByteIndex)...]

    guard let headerString = String(data: headerData, encoding: .utf8) else {
      throw GitError.invalidObjectFormat("Invalid header encoding")
    }

    let headerParts = headerString.split(separator: " ")
    guard headerParts.count == 2 else {
      throw GitError.invalidObjectFormat("Invalid header format: \(headerString)")
    }

    let type = String(headerParts[0])
    guard let size = Int(headerParts[1]) else {
      throw GitError.invalidObjectFormat("Invalid size in header: \(headerString)")
    }

    // Validate content size
    if contentData.count != size {
      throw GitError.invalidObjectFormat("Content size mismatch: expected \(size), got \(contentData.count)")
    }

    return (type: type, size: size, content: Data(contentData))
  }

  /// Parse a blob object
  private func parseBlob(sha1: String, content: Data, size: Int) throws -> Blob {
    return Blob(sha1: sha1, data: content, size: size)
  }

  /// Parse a tree object
  private func parseTree(sha1: String, content: Data) throws -> Tree {
    let entries = try TreeParser.parse(content)
    return Tree(sha1: sha1, entries: entries)
  }

  /// Parse a commit object
  private func parseCommit(sha1: String, content: Data) throws -> Commit {
    return try CommitParser.parse(content, sha1: sha1)
  }

  /// Parse a tag object
  private func parseTag(sha1: String, content: Data) throws -> Tag {
    return try TagParser.parse(content, sha1: sha1)
  }

  /// Decompress zlib data using Apple's Compression framework
  /// - Parameter compressedData: Compressed data
  /// - Returns: Decompressed data
  /// - Throws: GitError.decompressionFailed if decompression fails
  private func decompressZlibData(_ compressedData: Data) throws -> Data {
    // Try using NSData's built-in decompression first (simpler)
    do {
      return try (compressedData as NSData).decompressed(using: .zlib) as Data
    } catch {
      // Fallback to manual decompression if needed
      return try manualDecompression(compressedData)
    }
  }

  /// Manual zlib decompression using Compression framework
  private func manualDecompression(_ compressedData: Data) throws -> Data {
    return try compressedData.withUnsafeBytes { compressedBytes in
      let bufferSize = 4096
      var buffer = [UInt8](repeating: 0, count: bufferSize)

      return try buffer.withUnsafeMutableBufferPointer { bufferPtr in
        var stream = compression_stream(
          dst_ptr: bufferPtr.baseAddress!,
          dst_size: bufferSize,
          src_ptr: compressedBytes.bindMemory(to: UInt8.self).baseAddress!,
          src_size: compressedData.count,
          state: nil
        )

        let status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else {
          throw GitError.decompressionFailed
        }

        defer { compression_stream_destroy(&stream) }

        var decompressedData = Data()
        let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

        while true {
          let result = compression_stream_process(&stream, flags)

          if result == COMPRESSION_STATUS_OK {
            let outputCount = bufferSize - stream.dst_size
            if outputCount > 0 {
              decompressedData.append(bufferPtr.baseAddress!, count: outputCount)
              stream.dst_ptr = bufferPtr.baseAddress!
              stream.dst_size = bufferSize
            }
          } else if result == COMPRESSION_STATUS_END {
            let outputCount = bufferSize - stream.dst_size
            if outputCount > 0 {
              decompressedData.append(bufferPtr.baseAddress!, count: outputCount)
            }
            break
          } else {
            throw GitError.decompressionFailed
          }
        }

        return decompressedData
      }
    }
  }

  /// Validate SHA-1 format
  private func validateSHA1(_ sha1: String) throws -> String {
    let cleaned = sha1.trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.isValidSHA1 else {
      throw GitError.invalidSHA1(cleaned)
    }
    return cleaned
  }

  /// Check if an object exists
  /// - Parameter sha1: 40-character SHA-1 hash
  /// - Returns: true if object exists, false otherwise
  func objectExists(sha1: String) -> Bool {
    do {
      let validatedSHA1 = try validateSHA1(sha1)
      let prefix = String(validatedSHA1.prefix(2))
      let suffix = String(validatedSHA1.dropFirst(2))
      let objectPath = repository.gitPath("objects", prefix, suffix)
      return repository.fileExists(objectPath)
    } catch {
      return false
    }
  }

  /// Get object size without reading full content
  /// - Parameter sha1: 40-character SHA-1 hash
  /// - Returns: Object size in bytes
  /// - Throws: GitError if reading fails
  func getObjectSize(sha1: String) throws -> Int {
    let validatedSHA1 = try validateSHA1(sha1)
    let objectData = try readObjectData(sha1: validatedSHA1)
    let (_, size, _) = try parseObjectHeader(objectData)
    return size
  }

  /// Get object type without reading full content
  /// - Parameter sha1: 40-character SHA-1 hash
  /// - Returns: Object type (blob, tree, commit, tag)
  /// - Throws: GitError if reading fails
  func getObjectType(sha1: String) throws -> String {
    let validatedSHA1 = try validateSHA1(sha1)
    let objectData = try readObjectData(sha1: validatedSHA1)
    let (type, _, _) = try parseObjectHeader(objectData)
    return type
  }
}

// MARK: - Tree Parser

struct TreeParser {

  /// Parse tree object content into entries
  /// - Parameter data: Tree object content (decompressed)
  /// - Returns: Array of tree entries
  /// - Throws: GitError if parsing fails
  static func parse(_ data: Data) throws -> [TreeEntry] {
    var entries: [TreeEntry] = []
    var index = data.startIndex

    while index < data.endIndex {
      // Find null byte separator
      guard let nullIndex = data[index...].firstIndex(of: 0) else {
        break
      }

      // Parse mode and name
      let headerData = data[index..<nullIndex]
      guard let headerString = String(data: headerData, encoding: .utf8) else {
        throw GitError.invalidObjectFormat("Invalid tree entry encoding")
      }

      let parts = headerString.split(separator: " ")
      guard parts.count == 2 else {
        throw GitError.invalidObjectFormat("Invalid tree entry format: \(headerString)")
      }

      let mode = String(parts[0])
      let name = String(parts[1])

      // Read 20-byte SHA-1
      let sha1Start = data.index(after: nullIndex)
      let sha1End = data.index(sha1Start, offsetBy: 20)
      guard sha1End <= data.endIndex else {
        throw GitError.invalidObjectFormat("Incomplete SHA-1 in tree entry")
      }

      let sha1Data = data[sha1Start..<sha1End]
      let sha1Hex = sha1Data.map { String(format: "%02x", $0) }.joined()

      let isDirectory = mode == "040000"

      entries.append(
        TreeEntry(
          mode: mode,
          name: name,
          sha1: sha1Hex,
          isDirectory: isDirectory
        ))

      index = sha1End
    }

    return entries
  }
}

// MARK: - Commit Parser

struct CommitParser {

  /// Parse commit object content
  /// - Parameters:
  ///   - data: Commit object content (decompressed)
  ///   - sha1: Commit SHA-1
  /// - Returns: Parsed commit object
  /// - Throws: GitError if parsing fails
  static func parse(_ data: Data, sha1: String) throws -> Commit {
    guard let content = String(data: data, encoding: .utf8) else {
      throw GitError.invalidObjectFormat("Invalid commit encoding")
    }

    let lines = content.components(separatedBy: .newlines)
    var tree = ""
    var parents: [String] = []
    var author = ""
    var committer = ""
    var messageLines: [String] = []
    var inMessage = false

    for line in lines {
      if inMessage {
        messageLines.append(line)
        continue
      }

      if line.isEmpty {
        inMessage = true
        continue
      }

      if line.hasPrefix("tree ") {
        tree = String(line.dropFirst(5))
      } else if line.hasPrefix("parent ") {
        parents.append(String(line.dropFirst(7)))
      } else if line.hasPrefix("author ") {
        author = String(line.dropFirst(7))
      } else if line.hasPrefix("committer ") {
        committer = String(line.dropFirst(10))
      }
    }

    return Commit(
      sha1: sha1,
      tree: tree,
      parents: parents,
      author: author,
      committer: committer,
      message: messageLines.joined(separator: "\n")
    )
  }
}

// MARK: - Tag Parser

struct Tag: GitObject {
  let type = "tag"
  let sha1: String
  let object: String
  let objectType: String
  let tag: String
  let tagger: String
  let message: String
}

struct TagParser {

  /// Parse tag object content
  /// - Parameters:
  ///   - data: Tag object content (decompressed)
  ///   - sha1: Tag SHA-1
  /// - Returns: Parsed tag object
  /// - Throws: GitError if parsing fails
  static func parse(_ data: Data, sha1: String) throws -> Tag {
    guard let content = String(data: data, encoding: .utf8) else {
      throw GitError.invalidObjectFormat("Invalid tag encoding")
    }

    let lines = content.components(separatedBy: .newlines)
    var object = ""
    var objectType = ""
    var tag = ""
    var tagger = ""
    var messageLines: [String] = []
    var inMessage = false

    for line in lines {
      if inMessage {
        messageLines.append(line)
        continue
      }

      if line.isEmpty {
        inMessage = true
        continue
      }

      if line.hasPrefix("object ") {
        object = String(line.dropFirst(7))
      } else if line.hasPrefix("type ") {
        objectType = String(line.dropFirst(5))
      } else if line.hasPrefix("tag ") {
        tag = String(line.dropFirst(4))
      } else if line.hasPrefix("tagger ") {
        tagger = String(line.dropFirst(7))
      }
    }

    return Tag(
      sha1: sha1,
      object: object,
      objectType: objectType,
      tag: tag,
      tagger: tagger,
      message: messageLines.joined(separator: "\n")
    )
  }
}

// MARK: - Repository Extensions

extension GitRepository {

  /// Create an object reader for this repository
  func objectReader() -> GitObjectReader {
    return GitObjectReader(repository: self)
  }

  /// Read a Git object by SHA-1
  /// - Parameter sha1: 40-character SHA-1 hash
  /// - Returns: Parsed Git object
  /// - Throws: GitError if reading or parsing fails
  func readObject(sha1: String) throws -> GitObject {
    let reader = objectReader()
    return try reader.readObject(sha1: sha1)
  }

  /// Check if an object exists
  /// - Parameter sha1: 40-character SHA-1 hash
  /// - Returns: true if object exists, false otherwise
  func objectExists(sha1: String) -> Bool {
    let reader = objectReader()
    return reader.objectExists(sha1: sha1)
  }

  /// Get object type without reading full content
  /// - Parameter sha1: 40-character SHA-1 hash
  /// - Returns: Object type (blob, tree, commit, tag)
  /// - Throws: GitError if reading fails
  func getObjectType(sha1: String) throws -> String {
    let reader = objectReader()
    return try reader.getObjectType(sha1: sha1)
  }
}
