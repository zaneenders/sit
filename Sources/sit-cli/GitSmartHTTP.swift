import Foundation
import AsyncHTTPClient
import NIOHTTP1
import NIOCore
import Sit

/// Git smart HTTP protocol client for `git-receive-pack` (push) and
/// `git-upload-pack` (fetch).
///
/// Uses `async-http-client` for HTTP/1.1 transport.  Handles pkt-line
/// framing, reference advertisement parsing, and the push request flow.
enum GitSmartHTTP {

  // MARK: - Reference advertisement (phase 1 of push)

  /// A single ref advertised by the remote.
  struct AdvertisedRef: Equatable {
    let sha20: [UInt8]  // 20 bytes, all-zeros for "capabilities only" line
    let name: String
    /// Capabilities from this line (may be empty).
    let capabilities: [String]
  }

  /// Result of reference discovery (`/info/refs?service=git-receive-pack`).
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
      let refName = frontParts.count > 1
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
    let capStr = capabilities.filter { cap in
      ["report-status", "side-band-64k", "delete-refs"].contains(cap)
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
      let errorMsg = errorBody.flatMap { String(decoding: $0.readableBytesView, as: UTF8.self) }
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
