import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Sit

/// Git smart HTTP protocol client for `git-receive-pack` (push) and
/// `git-upload-pack` (fetch).
///
/// Uses `async-http-client` for HTTP/1.1 transport.  Handles pkt-line
/// framing, reference advertisement parsing, and the push request flow.
enum GitSmartHTTP {

  // MARK: - Reference advertisement (phase 1 of push / fetch)

  /// A single ref advertised by the remote.
  struct AdvertisedRef: Equatable {
    let sha20: [UInt8]  // 20 bytes, all-zeros for "capabilities only" line
    let name: String
    /// Capabilities from this line (may be empty).
    let capabilities: [String]
  }

  /// Result of reference discovery.
  struct RefAdvertisement {
    let refs: [AdvertisedRef]
    /// Capabilities found across all lines (typically on the first ref,
    /// or a lone capabilities line with zero SHA).
    let capabilities: Set<String>
  }

  /// Fetch the reference advertisement from `url/info/refs?service=git-receive-pack`.
  ///
  /// - Parameter url: The remote repository URL (e.g. `https://github.com/user/repo.git`)
  /// - Returns: Parsed ref advertisement
  static func advertiseRefs(url: String) async throws -> RefAdvertisement {
    let refsURL = url.hasSuffix("/") ? "\(url)info/refs" : "\(url)/info/refs"
    var request = HTTPClientRequest(url: "\(refsURL)?service=git-receive-pack")
    request.method = .GET
    request.headers.add(name: "Accept", value: "application/x-git-receive-pack-advertisement")
    request.headers.add(name: "User-Agent", value: "sit/0.1")

    let client = HTTPClient.shared
    let response = try await client.execute(request, timeout: .seconds(30))
    guard response.status == .ok else {
      throw GitSmartHTTPError.badResponseStatus(response.status.code)
    }

    let body = try await response.body.collect(upTo: 1 << 20)  // 1 MB max
    let bytes = body.readableBytesView
    let data = Array(bytes)

    return parseRefAdvertisement(data)
  }

  /// Fetch the reference advertisement from `url/info/refs?service=git-upload-pack`.
  ///
  /// - Parameter url: The remote repository URL (e.g. `https://github.com/user/repo.git`)
  /// - Returns: Parsed ref advertisement
  static func advertiseFetchRefs(url: String) async throws -> RefAdvertisement {
    let refsURL = url.hasSuffix("/") ? "\(url)info/refs" : "\(url)/info/refs"
    var request = HTTPClientRequest(url: "\(refsURL)?service=git-upload-pack")
    request.method = .GET
    request.headers.add(name: "Accept", value: "application/x-git-upload-pack-advertisement")
    request.headers.add(name: "User-Agent", value: "sit/0.1")

    let client = HTTPClient.shared
    let response = try await client.execute(request, timeout: .seconds(30))
    guard response.status == .ok else {
      throw GitSmartHTTPError.badResponseStatus(response.status.code)
    }

    let body = try await response.body.collect(upTo: 1 << 20)  // 1 MB max
    let bytes = body.readableBytesView
    let data = Array(bytes)

    return parseRefAdvertisement(data)
  }

  /// Parse a `git-receive-pack` advertisement response body.
  ///
  /// Format (pkt-line framed):
  /// ```
  /// <sha1> refs/heads/main\0cap1 cap2\n        ← first ref line
  /// <sha1> refs/heads/dev\n                     ← subsequent refs
  /// 0000                                        ← flush
  /// ```
  static func parseRefAdvertisement(_ data: [UInt8]) -> RefAdvertisement {
    let packets = GitPktLine.decode(data)
    var refs: [AdvertisedRef] = []
    var allCapabilities = Set<String>()

    for packet in packets {
      guard case .data(let payload) = packet else { continue }

      // Each ref line: "<40-hex-sha> <ref-name>\0<capabilities>\n"
      let str = String(decoding: payload, as: UTF8.self)
      let parts = str.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
      let front = String(parts[0])
      let capsStr = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

      // Parse "<sha> <name>"
      let frontParts = front.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
      let shaStr = String(frontParts[0]).trimmingCharacters(in: .whitespaces)
      let refName =
        frontParts.count > 1
        ? String(frontParts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

      let sha20: [UInt8]
      if shaStr.count == 40, let decoded = try? GitHex.decode20(shaStr) {
        sha20 = decoded
      } else {
        // capability-only line (all-zeros SHA)
        sha20 = [UInt8](repeating: 0, count: 20)
      }

      var capabilities: [String] = []
      if !capsStr.isEmpty {
        capabilities = capsStr.split(separator: " ").map(String.init)
        for cap in capabilities { allCapabilities.insert(cap) }
      }

      refs.append(AdvertisedRef(sha20: sha20, name: refName, capabilities: capabilities))
    }

    return RefAdvertisement(refs: refs, capabilities: allCapabilities)
  }

  // MARK: - Fetch (phase 2: upload-pack)

  /// Negotiate and fetch a packfile from `url/git-upload-pack`.
  ///
  /// - Parameter url: The remote repository URL
  /// - Parameter wantHashes: 40-hex SHAs of objects we want
  /// - Parameter haveHashes: 40-hex SHAs of objects we already have (for common-commit negotiation)
  /// - Parameter capabilities: Capabilities advertised by the server
  /// - Returns: The packfile bytes (including "PACK" header and SHA-1 trailer)
  static func fetch(
    url: String,
    wantHashes: [String],
    haveHashes: [String] = [],
    capabilities: Set<String> = []
  ) async throws -> [UInt8] {
    let fetchURL = url.hasSuffix("/") ? "\(url)git-upload-pack" : "\(url)/git-upload-pack"

    // Filter capabilities to what we support
    let supportedCaps = capabilities.filter { cap in
      ["multi_ack", "multi_ack_detailed", "thin-pack", "ofs-delta"].contains(cap)
    }

    // Build the pkt-line request body
    var body: [UInt8] = []

    // First want line carries capabilities
    var firstWant = true
    for sha in wantHashes {
      let line: String
      if firstWant && !supportedCaps.isEmpty {
        line = "want \(sha) \(supportedCaps.joined(separator: " "))\n"
        firstWant = false
      } else {
        line = "want \(sha)\n"
      }
      body.append(contentsOf: GitPktLine.encode(Array(line.utf8)))
    }

    // Have lines
    for sha in haveHashes {
      let line = "have \(sha)\n"
      body.append(contentsOf: GitPktLine.encode(Array(line.utf8)))
    }

    // Done + flush
    body.append(contentsOf: GitPktLine.encode("done\n"))
    body.append(contentsOf: GitPktLine.flush)

    // Send the request
    var request = HTTPClientRequest(url: fetchURL)
    request.method = .POST
    request.headers.add(name: "Content-Type", value: "application/x-git-upload-pack-request")
    request.headers.add(name: "User-Agent", value: "sit/0.1")
    request.body = .bytes(ByteBuffer(bytes: body))

    let client = HTTPClient.shared
    let response = try await client.execute(request, timeout: .seconds(300))
    guard response.status == .ok else {
      let errorBody = try? await response.body.collect(upTo: 4096)
      let errorMsg =
        errorBody.flatMap { String(decoding: $0.readableBytesView, as: UTF8.self) }
        ?? ""
      throw GitSmartHTTPError.badResponseStatusWithBody(response.status.code, errorMsg)
    }

    let responseBody = try await response.body.collect(upTo: 100 << 20)  // 100 MB max
    let responseBytes = Array(responseBody.readableBytesView)

    return parseFetchResponse(responseBytes)
  }

  /// Parse the fetch response: skip pkt-line ACK/NAK lines, extract the packfile.
  ///
  /// The server sends pkt-line ACK/NAK lines, then the packfile follows directly
  /// (not pkt-line framed). The packfile starts with "PACK" (0x50 0x41 0x43 0x4b).
  /// Critically, we must check for "PACK" *before* trying pkt-line decode, because
  /// the bytes "PACK" are valid hex (0x50AC) and would be misinterpreted as a
  /// pkt-line length prefix.
  static func parseFetchResponse(_ data: [UInt8]) -> [UInt8] {
    var pos = 0

    // Read pkt-line packets
    while pos < data.count {
      // Check for "PACK" magic before attempting pkt-line decode
      if pos + 4 <= data.count,
        data[pos] == 0x50, data[pos + 1] == 0x41,
        data[pos + 2] == 0x43, data[pos + 3] == 0x4b
      {
        return Array(data[pos...])
      }

      guard let (_, consumed) = GitPktLine.decodeOne(from: data, at: pos) else {
        // Can't parse pkt-line — scan forward for PACK
        while pos + 4 <= data.count {
          if data[pos] == 0x50, data[pos + 1] == 0x41,
            data[pos + 2] == 0x43, data[pos + 3] == 0x4b
          {
            return Array(data[pos...])
          }
          pos += 1
        }
        return []
      }
      pos += consumed
    }

    return []
  }

  // MARK: - Push (phase 2)

  /// Push ref update commands and a packfile to the remote.
  ///
  /// - Parameter url: The remote repository URL
  /// - Parameter refUpdates: List of (oldSha40, newSha40, refName) to update.
  ///   Use 40-zeros for `oldSha40` to create a new ref.
  ///   Use 40-zeros for `newSha40` to delete a ref.
  /// - Parameter packData: The packfile bytes (from `GitPackWriter.write`)
  /// - Parameter capabilities: Capabilities to advertise (from ref discovery)
  /// - Returns: Status report lines from the server
  static func push(
    url: String,
    refUpdates: [(oldSha40: String, newSha40: String, refName: String)],
    packData: [UInt8],
    capabilities: Set<String> = []
  ) async throws -> [String] {
    let pushURL = url.hasSuffix("/") ? "\(url)git-receive-pack" : "\(url)/git-receive-pack"

    // Build the pkt-line request body
    var body: [UInt8] = []

    // Filter capabilities to only what we support
    // Omit side-band-64k: parsePushResponse handles plain pkt-line only.
    let capStr = capabilities.filter { cap in
      ["report-status", "delete-refs"].contains(cap)
    }.joined(separator: " ")

    // Ref update commands
    for (old, new, ref) in refUpdates {
      let line: String
      if capStr.isEmpty {
        line = "\(old) \(new) \(ref)\n"
      } else {
        line = "\(old) \(new) \(ref)\0\(capStr)\n"
      }
      body.append(contentsOf: GitPktLine.encode(Array(line.utf8)))
    }

    // Flush after ref commands
    body.append(contentsOf: GitPktLine.flush)

    // Packfile follows (raw bytes, no pkt-line framing)
    body.append(contentsOf: packData)

    // Send the request
    var request = HTTPClientRequest(url: pushURL)
    request.method = .POST
    request.headers.add(name: "Content-Type", value: "application/x-git-receive-pack-request")
    request.headers.add(name: "User-Agent", value: "sit/0.1")
    request.body = .bytes(ByteBuffer(bytes: body))

    let client = HTTPClient.shared
    let response = try await client.execute(request, timeout: .seconds(300))
    guard response.status == .ok else {
      let errorBody = try? await response.body.collect(upTo: 4096)
      let errorMsg =
        errorBody.flatMap { String(decoding: $0.readableBytesView, as: UTF8.self) }
        ?? ""
      throw GitSmartHTTPError.badResponseStatusWithBody(response.status.code, errorMsg)
    }

    let responseBody = try await response.body.collect(upTo: 1 << 20)
    let responseBytes = Array(responseBody.readableBytesView)

    return parsePushResponse(responseBytes)
  }

  /// Parse a `git-receive-pack` response into status lines.
  static func parsePushResponse(_ data: [UInt8]) -> [String] {
    // Response can be:
    // - Side-band multiplexed (if side-band-64k was negotiated)
    // - Plain pkt-line
    //
    // For now we parse it as plain pkt-line; side-band support can be added later.
    let packets = GitPktLine.decode(data)
    var lines: [String] = []
    for packet in packets {
      guard case .data(let payload) = packet else { continue }
      if let str = String(bytes: payload, encoding: .utf8) {
        lines.append(str.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    return lines
  }
}

// MARK: - Errors

enum GitSmartHTTPError: Error, Equatable {
  case badResponseStatus(UInt)
  case badResponseStatusWithBody(UInt, String)
  case unsupportedProtocol
  case authenticationRequired(String)
}
