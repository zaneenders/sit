import Subprocess
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

  /// Get the fetch ref advertisement by running
  /// `ssh <user>@<host> "git-upload-pack '<path>'"`.
  static func advertiseFetchRefs(ssh: SSHURL) async throws -> GitSmartHTTP.RefAdvertisement {
    let command = "git-upload-pack '\(ssh.path)'"
    let data = try await sshInvoke(host: ssh.host, user: ssh.user, command: command)
    return GitSmartHTTP.parseRefAdvertisement(data)
  }

  // MARK: - Fetch

  /// Negotiate and fetch a packfile from the remote over SSH.
  ///
  /// Protocol (git-upload-pack over SSH):
  /// 1. Server sends ref advertisement → we already parsed it
  /// 2. We reconnect and send want/have pkt-lines + done + flush
  /// 3. Server sends ACK/NAK + packfile
  static func fetch(
    ssh: SSHURL,
    wantHashes: [String],
    haveHashes: [String] = [],
    capabilities: Set<String> = []
  ) async throws -> [UInt8] {
    let command = "git-upload-pack '\(ssh.path)'"

    let supportedCaps = capabilities.filter { cap in
      ["multi_ack", "multi_ack_detailed", "thin-pack", "ofs-delta"].contains(cap)
    }

    var requestBody: [UInt8] = []

    var firstWant = true
    for sha in wantHashes {
      let line: String
      if firstWant && !supportedCaps.isEmpty {
        line = "want \(sha) \(supportedCaps.joined(separator: " "))\n"
        firstWant = false
      } else {
        line = "want \(sha)\n"
      }
      requestBody.append(contentsOf: GitPktLine.encode(Array(line.utf8)))
    }

    for sha in haveHashes {
      requestBody.append(contentsOf: GitPktLine.encode(Array("have \(sha)\n".utf8)))
    }

    requestBody.append(contentsOf: GitPktLine.encode("done\n"))
    requestBody.append(contentsOf: GitPktLine.flush)

    let responseBytes = try await sshInvokeWithInput(
      host: ssh.host,
      user: ssh.user,
      command: command,
      input: requestBody)

    return GitSmartHTTP.parseFetchResponse(responseBytes)
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
    let record: ExecutionRecord<BytesOutput, BytesOutput>
    if let input {
      record = try await Subprocess.run(
        .name("/usr/bin/ssh"),
        arguments: Arguments(arguments),
        input: .array(input),
        output: .bytes(limit: 100 * 1024 * 1024),  // 100 MB
        error: .bytes(limit: 65536))
    } else {
      record = try await Subprocess.run(
        .name("/usr/bin/ssh"),
        arguments: Arguments(arguments),
        output: .bytes(limit: 100 * 1024 * 1024),
        error: .bytes(limit: 65536))
    }

    guard record.terminationStatus.isSuccess else {
      let errStr = String(decoding: record.standardError, as: UTF8.self)
      throw GitSSHError.sshFailed(
        exitCode: sshExitCode(record.terminationStatus),
        stderr: String(errStr.trimming { $0.isWhitespace || $0.isNewline }))
    }

    return record.standardOutput
  }

  private static func sshExitCode(_ status: TerminationStatus) -> Int32 {
    switch status {
    case .exited(let code): return code
    case .signaled(let sig): return -sig
    }
  }
}

// MARK: - Errors

enum GitSSHError: Error, Equatable {
  case sshFailed(exitCode: Int32, stderr: String)
  case badSSHURL(String)
}
