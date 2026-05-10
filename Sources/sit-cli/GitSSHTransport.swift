import Foundation
import Sit

/// Git smart protocol over SSH transport.
///
/// Spawns `ssh` to run `git-receive-pack` / `git-upload-pack` on the remote,
/// then speaks pkt-line over stdin/stdout — the same format as smart HTTP.
enum GitSSHTransport {

  // MARK: - SSH URL parsing

  /// Parsed components of a Git SSH URL.
  struct SSHURL: Equatable {
    let host: String
    let user: String
    let path: String
  }

  /// Parse `git@github.com:user/repo.git` or `ssh://git@github.com/user/repo.git`.
  static func parseSSHURL(_ url: String) -> SSHURL? {
    // ssh://git@host/path
    if url.hasPrefix("ssh://") {
      let rest = String(url.dropFirst(6))
      let parts = rest.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count >= 1 else { return nil }
      let hostUser = parts[0]
      let path = parts.count >= 2 ? String(parts[1...].joined(separator: "/")) : ""
      let huParts = hostUser.split(separator: "@", maxSplits: 1)
      if huParts.count == 2 {
        return SSHURL(host: String(huParts[1]), user: String(huParts[0]), path: path)
      } else {
        return SSHURL(host: String(huParts[0]), user: "git", path: path)
      }
    }
    // git@host:path
    if url.hasPrefix("git@") {
      let rest = String(url.dropFirst(4))
      let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return nil }
      return SSHURL(host: String(parts[0]), user: "git", path: String(parts[1]))
    }
    return nil
  }

  // MARK: - Ref advertisement

  /// Get the ref advertisement from the remote by running
  /// `ssh <user>@<host> "git-receive-pack '<path>'"` and parsing the pkt-line output.
  static func advertiseRefs(ssh: SSHURL) async throws -> GitSmartHTTP.RefAdvertisement {
    let command = "git-receive-pack '\(ssh.path)'"
    let data = try await sshInvoke(host: ssh.host, user: ssh.user, command: command)
    return GitSmartHTTP.parseRefAdvertisement(data)
  }

  // MARK: - Push

  /// Push ref updates and a packfile to the remote over SSH.
  ///
  /// Protocol (git-receive-pack over SSH):
  /// 1. Server sends ref advertisement → we parse it
  /// 2. We send pkt-line ref commands + flush + packfile
  /// 3. Server sends status report
  static func push(
    ssh: SSHURL,
    refUpdates: [(oldSha40: String, newSha40: String, refName: String)],
    packData: [UInt8],
    capabilities: Set<String> = []
  ) async throws -> [String] {
    let command = "git-receive-pack '\(ssh.path)'"

    // Build the push request body (same format as smart HTTP phase 2)
    var requestBody: [UInt8] = []

    let capStr = capabilities.filter { cap in
      ["report-status", "side-band-64k", "delete-refs"].contains(cap)
    }.joined(separator: " ")

    for (old, new, ref) in refUpdates {
      let line: String
      if capStr.isEmpty {
        line = "\(old) \(new) \(ref)\n"
      } else {
        line = "\(old) \(new) \(ref)\0\(capStr)\n"
      }
      requestBody.append(contentsOf: GitPktLine.encode(Array(line.utf8)))
    }
    requestBody.append(contentsOf: GitPktLine.flush)
    requestBody.append(contentsOf: packData)

    let responseBytes = try await sshInvokeWithInput(
      host: ssh.host,
      user: ssh.user,
      command: command,
      input: requestBody)

    return GitSmartHTTP.parsePushResponse(responseBytes)
  }

  // MARK: - SSH subprocess

  /// Spawn `ssh <user>@<host> <command>`, return all stdout bytes.
  private static func sshInvoke(
    host: String, user: String, command: String
  ) async throws -> [UInt8] {
    let sshArgs = buildSSHArgs(host: host, user: user, command: command)
    return try await runSSH(arguments: sshArgs, input: nil)
  }

  /// Spawn `ssh …`, send `input` to stdin, return all stdout bytes.
  private static func sshInvokeWithInput(
    host: String, user: String, command: String, input: [UInt8]
  ) async throws -> [UInt8] {
    let sshArgs = buildSSHArgs(host: host, user: user, command: command)
    return try await runSSH(arguments: sshArgs, input: input)
  }

  private static func buildSSHArgs(host: String, user: String, command: String) -> [String] {
    [
      "-o", "StrictHostKeyChecking=accept-new",
      "-o", "PasswordAuthentication=no",
      "\(user)@\(host)",
      command,
    ]
  }

  /// Run `/usr/bin/ssh` with the given arguments, optionally feeding `input` to stdin.
  /// Returns all stdout bytes. Throws on non-zero exit.
  private static func runSSH(arguments: [String], input: [UInt8]?) async throws -> [UInt8] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    if input != nil {
      let stdinPipe = Pipe()
      process.standardInput = stdinPipe
      try process.run()

      // Write input and close stdin so the remote sees EOF after our pack
      try stdinPipe.fileHandleForWriting.write(contentsOf: Data(input!))
      try stdinPipe.fileHandleForWriting.close()
    } else {
      // No stdin — but git-receive-pack still expects input after advertisement.
      // Close stdin immediately so the server sends advertisement and exits
      // (which is fine for the advertisement-only call).
      let stdinPipe = Pipe()
      process.standardInput = stdinPipe
      try process.run()
      try stdinPipe.fileHandleForWriting.close()
    }

    let stdoutData = try await stdoutPipe.fileHandleForReading.readToEndAsync()
    let stderrData = try await stderrPipe.fileHandleForReading.readToEndAsync()

    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let errStr = stderrData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      throw GitSSHError.sshFailed(
        exitCode: process.terminationStatus,
        stderr: errStr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return Array(stdoutData ?? Data())
  }
}

// MARK: - Errors

enum GitSSHError: Error, Equatable {
  case sshFailed(exitCode: Int32, stderr: String)
  case badSSHURL(String)
}

// MARK: - Async FileHandle reading

extension FileHandle {
  fileprivate func readToEndAsync() async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      do {
        let data = try self.readToEnd()
        continuation.resume(returning: data)
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}
